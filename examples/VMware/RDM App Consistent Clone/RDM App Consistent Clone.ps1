##############################################################################################################################
# RDM App Consistent Clone
#
# Scenario:
#    A source SQL Server VM keeps its database files on raw device mappings (RDMs).  Each RDM is its own FlashArray
#    volume.  A second SQL Server VM (the target) needs a copy of those databases, for example for dev/test.
#
#    This script uses SQL Server 2022 and later T-SQL Snapshot Backup to make the snapshot APPLICATION consistent:
#    the databases are frozen for write IO, one FlashArray snapshot of every volume that holds them is taken, and a
#    metadata-only backup releases the freeze.  Each snapshot is then cloned as a new volume, presented to the ESXi
#    host and added to the target VM as an RDM, where the databases are attached under new names.
#
#    Writes to the source databases are frozen only between the freeze and the metadata backup, which is the time the
#    snapshot takes.  Because the databases were frozen cleanly, the copies do not need crash recovery.
#
#    The ESXi host reads a copy of an RDM the same way as the original.
#
#    You only name the VMs, the databases and the vCenter and FlashArray.  The script works out the rest by lookup:
#    database files -> Windows drive -> Windows disk serial number (it is the FlashArray volume's serial number)
#    -> FlashArray volume -> FlashArray host group.
#
# Prerequisites:
#    1. PowerShell modules: dbatools, PureStoragePowerShellSDK2 and VMware PowerCLI.
#    2. SQL Server 2022 or later on the source (T-SQL Snapshot Backup).
#    3. PowerShell remoting (WinRM) to both VMs, and a SQL Server login that can attach databases on the target.
#    4. A share that the source SQL Server can write to, for the small metadata backup files.
#    5. Every disk that holds the listed databases is a FlashArray volume presented to the VM as an RDM.
#       Every one of those volumes is snapshotted together, and every one is copied.
#    6. The target VM must be a different VM from the source VM, and have free SCSI slots for hot-adding disks.
#    7. Database files must be on drive letters (this script is written for drive letters and does not handle mount points), and the databases must not exist on the target yet.
#
# Usage Notes:
#    SUSPEND_FOR_SNAPSHOT_BACKUP is tied to the SQL Server session.  The freeze and the metadata backup must run in the SAME
#    session, so this script uses a persistent, non-pooled dbatools connection for them.  Other cmdlets disconnect at once,
#    which would thaw the databases before the snapshot is taken.
#
# Disclaimer:
#    This example script is provided AS-IS and meant to be a building block to be adapted to fit an individual
#    organization's infrastructure.
#
#    _PLEASE_ do not save your passwords in cleartext here.
#    Use NTFS secured, encrypted files or whatever else -- never cleartext!
#
##############################################################################################################################

# Stop at the first error.  Several steps below remove or overwrite things, so never carry on after a failure.
$ErrorActionPreference = 'Stop'



# Import powershell modules
Import-Module VMware.VimAutomation.Core
Import-Module PureStoragePowerShellSDK2
Import-Module dbatools



# Declare all variables
$VIServerName      = 'vcenter.example.com'
$ArrayName         = 'flasharray1.example.com'        # FlashArray FQDN

$SourceVM          = 'source_vm'                      # Not FQDN
$TargetVM          = 'target_vm'                      # Not FQDN
$SourceSQLServer   = 'source_vm.example.com'
$TargetSQLServer   = 'target_vm.example.com'
$Databases         = @('AdventureWorks', 'WideWorldImporters')
$ProtectionGroupName = 'sql-clone-pg'                # Made by this script the first run and reused, see "Protection group"
$NewNameSuffix     = '_clone'                         # Databases are attached on the target as AdventureWorks_clone, ...
$BackupShare       = '\\fileserver\share\snapshot-metadata'    # Where the metadata-only backup files are written



# Get Credentials - this example assumes the same credential for vCenter, the FlashArray and both VMs
$Credential = Get-Credential -UserName "$env:USERNAME" -Message 'Enter your credential information...'



# Connect to everything
$VIServer      = Connect-VIServer -Server $VIServerName -Protocol https -Credential $Credential
$FlashArray    = Connect-Pfa2Array -Endpoint $ArrayName -Credential $Credential -IgnoreCertificateError
$SourceSql     = Connect-DbaInstance -SqlInstance $SourceSQLServer -TrustServerCertificate -NonPooledConnection   # persistent, for the freeze
$TargetSql     = Connect-DbaInstance -SqlInstance $TargetSQLServer -TrustServerCertificate
$TargetVMObject = Get-VM -Name $TargetVM
$ESXiHost       = Get-VMHost -VM $TargetVMObject



###
# Look up where the database files live

# Every data and log file of the databases, as SQL Server sees them
$DbFiles = Get-DbaDbFile -SqlInstance $SourceSql -Database $Databases
$DbFiles | Select-Object Database, TypeDescription, PhysicalName



# For each drive letter in use, ask Windows on the source VM which disk it is on.
# For an RDM the disk serial number is the FlashArray volume's serial number.
$DriveLetters = $DbFiles.PhysicalName | ForEach-Object { $_.Substring(0, 1).ToUpper() } | Select-Object -Unique

$SerialByDrive = Invoke-Command -ComputerName $SourceVM -Credential $Credential -ArgumentList (, $DriveLetters) -ScriptBlock {
    param($letters)
    $map = @{}
    foreach ($letter in $letters) {
        $map[$letter] = (Get-Partition -DriveLetter $letter | Get-Disk).SerialNumber.ToUpper()
    }
    $map
}
$SerialByDrive



# Look up the FlashArray volumes, and the host group they are connected to
$SourceVolumes = @(Get-Pfa2Volume -Array $FlashArray | Where-Object { $SerialByDrive.Values -contains $_.Serial })
if ($SourceVolumes.Count -ne @($SerialByDrive.Values | Select-Object -Unique).Count) { throw 'A database disk is not a FlashArray volume.  This script is for RDMs.' }

# NOTE: do not pipe FlashArray cmdlets into Select-Object -First.  In Windows PowerShell 5.1 it can end the whole script silently.
$Connections   = @(Get-Pfa2Connection -Array $FlashArray -VolumeNames $SourceVolumes[0].Name | Where-Object { $_.HostGroup.Name })
$FAHostGroup   = $Connections[0].HostGroup.Name
"Source volumes: $($SourceVolumes.Name -join ', '), connected to host group $FAHostGroup"



###
# Protection group
# A protection group snapshot snapshots every volume in the group at the same moment.  That is how the database disks, one volume
# each, get one shared point in time.  This section makes the group the first time and leaves it in place for the runs after.
# If you already have a protection group that holds these volumes, comment out this section and set $ProtectionGroupName to that group.
# Every volume in the group is snapshotted, not only the source volumes.

if (-not @(Get-Pfa2ProtectionGroup -Array $FlashArray -Filter "name='$ProtectionGroupName'")) {
    New-Pfa2ProtectionGroup -Array $FlashArray -Name $ProtectionGroupName
    New-Pfa2ProtectionGroupVolume -Array $FlashArray -GroupName $ProtectionGroupName -MemberName $SourceVolumes.Name
}



###
# Snapshot and clone

# Time the freeze window, this is how long writes to the databases are held
$Start = Get-Date

# Freeze every database for write IO.  Each stays frozen until its metadata backup below.
foreach ($Database in $Databases) {
    Invoke-DbaQuery -EnableException -SqlInstance $SourceSql -Database master -Query "ALTER DATABASE [$Database] SET SUSPEND_FOR_SNAPSHOT_BACKUP = ON"
}



# Take a snapshot of the protection group, so every source volume shares the same point in time, while the databases are frozen
$Stamp      = (Get-Date).ToString('yyyyMMdd-HHmmss')
$PgSnapshot = New-Pfa2ProtectionGroupSnapshot -Array $FlashArray -SourceName $ProtectionGroupName -Suffix "clone-$Stamp"

# The protection group snapshot holds one snapshot per volume, named <group>.<suffix>.<volume>.  Pick out the source volumes' snapshots.
# This stops with an error if the group does not hold one of the source volumes.
$Snapshots  = @(foreach ($Volume in $SourceVolumes) { Get-Pfa2VolumeSnapshot -Array $FlashArray -Name "$($PgSnapshot.Name).$($Volume.Name)" })
$Snapshots | Select-Object Name, Created



# Write a metadata-only backup of each database.  This releases the freeze.
# MEDIADESCRIPTION records the snapshot names and array, so the snapshots can be found again from the backup file.
foreach ($Database in $Databases) {
    $BackupFile = "$BackupShare\${Database}_$(Get-Date -Format FileDateTime).bkm"
    $Query = "BACKUP DATABASE [$Database] TO DISK = '$BackupFile' WITH METADATA_ONLY, MEDIADESCRIPTION = '$($Snapshots.Name -join ',')|$($FlashArray.ArrayName)'"
    Invoke-DbaQuery -EnableException -SqlInstance $SourceSql -Database master -Query $Query
}

"Writes were frozen for $([math]::Round(((Get-Date) - $Start).TotalMilliseconds)) ms"



# Create a new volume from each snapshot and present them to the ESXi host
$Clones = @()
foreach ($Snapshot in $Snapshots) {
    $CloneName = ($Snapshot.Name -split '\.')[-1] + "-clone-$Stamp"
    $Clones   += New-Pfa2Volume -Array $FlashArray -Name $CloneName -SourceName $Snapshot.Name
    New-Pfa2Connection -Array $FlashArray -HostGroupNames $FAHostGroup -VolumeNames $CloneName
}



# The ESXi host must now rescan storage
Get-VMHostStorage -RescanAllHba -VMHost $ESXiHost



###
# Add the clones to the target VM as RDMs

# The LUN is named naa.624a9370 followed by the FlashArray volume's serial number.  624a9370 is Pure Storage's vendor ID, so the prefix is the same on every FlashArray and would be different on another vendor's array.
foreach ($Clone in $Clones) {
    $Lun = Get-ScsiLun -VmHost $ESXiHost -CanonicalName ('naa.624a9370' + $Clone.Serial.ToLower())
    New-HardDisk -VM $TargetVMObject -DiskType RawPhysical -DeviceName $Lun.ConsoleDeviceName
}



# The copies arrive in Windows offline.  Find them by serial number (the clones' serials, not the originals'),
# online them and make them writable.  They keep the drive letters of the originals if those letters are free.
$CloneSerials = @($Clones.Serial)

# The new disks can take a while to appear in Windows.  Wait until every new disk is listed, running this until it is, then continue.
Invoke-Command -ComputerName $TargetVM -Credential $Credential -ScriptBlock { Update-HostStorageCache; Get-Disk | Select-Object Number, SerialNumber, IsOffline, Size }

$TargetDriveBySerial = Invoke-Command -ComputerName $TargetVM -Credential $Credential -ArgumentList (, $CloneSerials) -ScriptBlock {
    param($serials)
    Update-HostStorageCache
    $found = @(Get-Disk | Where-Object { $serials -contains "$($_.SerialNumber)".ToUpper() })
    $result = @{}
    foreach ($disk in $found) {
        Set-Disk -Number $disk.Number -IsOffline $false
        Set-Disk -Number $disk.Number -IsReadOnly $false
        $partition = Get-Partition -DiskNumber $disk.Number | Where-Object Type -eq 'Basic' | Select-Object -First 1
        if (-not $partition.DriveLetter) {
            Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -AssignDriveLetter
            $partition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber
        }
        $result[$disk.SerialNumber.ToUpper()] = "$($partition.DriveLetter)"
    }
    $result
}
$TargetDriveBySerial



###
# Attach the databases on the target SQL Server

# Each source volume has a clone.  Match them up by name: the clone's name starts with the source volume's name.
$CloneSerialBySourceSerial = @{}
foreach ($Source in $SourceVolumes) { $CloneSerialBySourceSerial[$Source.Serial] = ($Clones | Where-Object { $_.Name -like "$($Source.Name)-clone-*" }).Serial }

# Each file keeps its path, with the drive letter swapped for the letter the copy got on the target VM
foreach ($Database in $Databases) {
    $Files = $DbFiles | Where-Object { $_.Database -eq $Database } | ForEach-Object {
        $OldLetter = $_.PhysicalName.Substring(0, 1).ToUpper()
        $NewLetter = $TargetDriveBySerial[$CloneSerialBySourceSerial[$SerialByDrive[$OldLetter]]]
        "(FILENAME = N'$NewLetter$($_.PhysicalName.Substring(1))')"
    }
    $Query = "CREATE DATABASE [$Database$NewNameSuffix] ON $($Files -join ', ') FOR ATTACH"
    Invoke-DbaQuery -EnableException -SqlInstance $TargetSql -Database master -Query $Query
}



###
# The databases are online on the target.  Check them.
Get-DbaDbState -SqlInstance $TargetSql -Database ($Databases | ForEach-Object { "$_$NewNameSuffix" })



Disconnect-Pfa2Array -Array $FlashArray
