##############################################################################################################################
# iSCSI Crash Consistent Clone
#
# Scenario:
#    A source SQL Server VM keeps its database files on disks that the guest operating system reaches itself with the
#    Microsoft iSCSI initiator.  Each disk is its own FlashArray volume.  A second SQL Server VM (the target) needs a copy
#    of those databases, for example for dev/test.
#
#    This script takes one crash-consistent snapshot of every FlashArray volume that holds the databases, clones each
#    snapshot as a new volume, and connects the clones to the target VM's FlashArray host.  The target VM already
#    has iSCSI sessions to the array, so the new volumes appear in Windows after a storage rescan.  The databases are then
#    attached on the target SQL Server under new names.
#
#    The source SQL Server is not touched and stays online.  The snapshot is crash-consistent: SQL Server write IO is
#    NOT frozen, so each database on the target performs crash recovery when it is attached.
#
#    You only name the VMs, the databases and the FlashArray.  The script works out the rest by lookup:
#    database files -> Windows drive -> Windows disk serial number (it is the FlashArray volume's serial number)
#    -> FlashArray volume.  The target's FlashArray host is found from the target's iSCSI initiator name (IQN).
#
# Prerequisites:
#    1. PowerShell modules: dbatools and PureStoragePowerShellSDK2.
#    2. PowerShell remoting (WinRM) to both VMs, and a SQL Server login that can attach databases on the target.
#    3. Every disk that holds the listed databases is a FlashArray volume presented to the VM with the Microsoft iSCSI
#       initiator.  Every one of those volumes is snapshotted together, and every one is copied.
#    4. The target VM is a different VM from the source VM.  It is already logged in to the array's iSCSI portals
#       (persistent sessions, multipath enabled), and it is a host on the FlashArray, identified by its IQN.
#    5. Database files must be on drive letters (this script is written for drive letters and does not handle mount points), the databases must not exist on the target yet, and the
#       drive letters of the source must be free on the target.  A copy that cannot get its original letter gets another
#       one, and the script keeps working.
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
Import-Module PureStoragePowerShellSDK2
Import-Module dbatools



# Declare all variables
$ArrayName         = 'flasharray1.example.com'        # FlashArray FQDN

$SourceVM          = 'source_vm'                      # Not FQDN
$TargetVM          = 'target_vm'                      # Not FQDN
$SourceSQLServer   = 'source_vm.example.com'
$TargetSQLServer   = 'target_vm.example.com'
$Databases         = @('AdventureWorks', 'WideWorldImporters')
$ProtectionGroupName = 'sql-clone-pg'                # Made by this script the first run and reused, see "Protection group"
$NewNameSuffix     = '_clone'                         # Databases are attached on the target as AdventureWorks_clone, ...



# Get Credentials - this example assumes the same credential for the FlashArray and both VMs
$Credential = Get-Credential -UserName "$env:USERNAME" -Message 'Enter your credential information...'



# Connect to everything
$FlashArray    = Connect-Pfa2Array -Endpoint $ArrayName -Credential $Credential -IgnoreCertificateError
$SourceSql     = Connect-DbaInstance -SqlInstance $SourceSQLServer -TrustServerCertificate
$TargetSql     = Connect-DbaInstance -SqlInstance $TargetSQLServer -TrustServerCertificate



###
# Look up where the database files live

# Every data and log file of the databases, as SQL Server sees them
$DbFiles = Get-DbaDbFile -SqlInstance $SourceSql -Database $Databases
$DbFiles | Select-Object Database, TypeDescription, PhysicalName



# For each drive letter in use, ask Windows on the source VM which disk it is on.
# For an iSCSI disk from a FlashArray the disk serial number is the FlashArray volume's serial number.
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



# Look up the FlashArray volumes
$SourceVolumes = @(Get-Pfa2Volume -Array $FlashArray | Where-Object { $SerialByDrive.Values -contains $_.Serial })
if ($SourceVolumes.Count -ne @($SerialByDrive.Values | Select-Object -Unique).Count) { throw 'A database disk is not a FlashArray volume.  This script is for FlashArray volumes.' }
"Source volumes: $($SourceVolumes.Name -join ', ')"



# Look up the target's FlashArray host.  The target VM tells us its iSCSI initiator name, and the array knows which host owns it.
$TargetIqn = Invoke-Command -ComputerName $TargetVM -Credential $Credential -ScriptBlock {
    (Get-InitiatorPort | Where-Object { $_.ConnectionType -eq 'iSCSI' }).NodeAddress
}
$TargetHost = @(Get-Pfa2Host -Array $FlashArray | Where-Object { $_.Iqns -contains $TargetIqn })
if ($TargetHost.Count -ne 1) { throw "Expected one FlashArray host with the IQN $TargetIqn, found $($TargetHost.Count)." }
$FAHost = $TargetHost[0].Name
"Target FlashArray host: $FAHost"



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

# Take a crash-consistent snapshot of the protection group, so every source volume shares the same point in time.
# The source database stays online.
$Stamp      = (Get-Date).ToString('yyyyMMdd-HHmmss')
$PgSnapshot = New-Pfa2ProtectionGroupSnapshot -Array $FlashArray -SourceName $ProtectionGroupName -Suffix "clone-$Stamp"

# The protection group snapshot holds one snapshot per volume, named <group>.<suffix>.<volume>.  Pick out the source volumes' snapshots.
# This stops with an error if the group does not hold one of the source volumes.
$Snapshots  = @(foreach ($Volume in $SourceVolumes) { Get-Pfa2VolumeSnapshot -Array $FlashArray -Name "$($PgSnapshot.Name).$($Volume.Name)" })
$Snapshots | Select-Object Name, Created



# Create a new volume from each snapshot and connect it to the target's FlashArray host
$Clones = @()
foreach ($Snapshot in $Snapshots) {
    $CloneName = ($Snapshot.Name -split '\.')[-1] + "-clone-$Stamp"
    $Clones   += New-Pfa2Volume -Array $FlashArray -Name $CloneName -SourceName $Snapshot.Name
    New-Pfa2Connection -Array $FlashArray -HostNames $FAHost -VolumeNames $CloneName
}



###
# Bring the clones online on the target VM

# The copies arrive in Windows offline.  The target already has iSCSI sessions to the array, so no login is needed.  A storage rescan
# makes the new volumes appear, and multipath claims them.  Find them by serial number (the clones' serials, not the originals'),
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
# The databases are online on the target after crash recovery.  Check them.
Get-DbaDbState -SqlInstance $TargetSql -Database ($Databases | ForEach-Object { "$_$NewNameSuffix" })



Disconnect-Pfa2Array -Array $FlashArray
