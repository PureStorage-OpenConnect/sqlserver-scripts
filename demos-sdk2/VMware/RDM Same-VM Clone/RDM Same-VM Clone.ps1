##############################################################################################################################
# RDM Same-VM Clone
#
# Scenario:
#    A SQL Server VM keeps its database files on raw device mappings (RDMs).  Each RDM is its own FlashArray volume.
#    You want a copy of those databases on the SAME SQL Server instance, for example to test a change or to pull back
#    a table that was deleted by mistake.
#
#    This script takes one crash-consistent snapshot of every FlashArray volume that holds the databases, clones each
#    snapshot as a new volume, presents the clones to the ESXi host, and adds them to the same VM as new RDMs.
#    The databases are then attached on the same SQL Server under new names.
#
#    The problem this script solves: a copy of a disk has the same disk GUID as the original.  Windows hides a copy
#    like that, keeps it offline and write-protected, and at the next reboot it can take the production disk offline
#    instead.  The fix is to give each copy a new disk GUID BEFORE it is onlined.  That is all it takes, because
#    the copy is a new FlashArray volume and already has its own serial number.
#
#    The source databases stay online throughout.  The snapshot is crash-consistent: SQL Server write IO is NOT
#    frozen, so each copy performs crash recovery when it is attached.
#
#    You only name the VMs, the databases and the vCenter and FlashArray.  The script works out the rest by lookup:
#    database files -> Windows drive -> Windows disk serial number (it is the FlashArray volume's serial number)
#    -> FlashArray volume -> FlashArray host group.
#
# Prerequisites:
#    1. PowerShell modules: dbatools, PureStoragePowerShellSDK2 and VMware PowerCLI.
#    2. PowerShell remoting (WinRM) to the VM, and a SQL Server login that can attach databases.
#    3. Every disk that holds the listed databases is a FlashArray volume presented to the VM as an RDM.
#       Every one of those volumes is snapshotted together, and every one is copied.
#    4. The VM must have free SCSI slots for hot-adding disks, and free drive letters for the copies.
#    5. Database files must be on drive letters (this script is written for drive letters and does not handle mount points), and the copies must not exist yet.
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

$SqlVM             = 'sql_vm'                         # Not FQDN
$SqlServer         = 'sql_vm.example.com'
$Databases         = @('AdventureWorks', 'WideWorldImporters')
$ProtectionGroupName = 'sql-clone-pg'                # Made by this script the first run and reused, see "Protection group"
$NewNameSuffix     = '_copy'                          # Databases are attached as AdventureWorks_copy, ...



# Get Credentials - this example assumes the same credential for vCenter, the FlashArray and the VM
$Credential = Get-Credential -UserName "$env:USERNAME" -Message 'Enter your credential information...'



# Connect to everything
$VIServer      = Connect-VIServer -Server $VIServerName -Protocol https -Credential $Credential
$FlashArray    = Connect-Pfa2Array -Endpoint $ArrayName -Credential $Credential -IgnoreCertificateError
$Sql           = Connect-DbaInstance -SqlInstance $SqlServer -TrustServerCertificate
$VMObject       = Get-VM -Name $SqlVM
$ESXiHost       = Get-VMHost -VM $VMObject



###
# Look up where the database files live

# Every data and log file of the databases, as SQL Server sees them
$DbFiles = Get-DbaDbFile -SqlInstance $Sql -Database $Databases
$DbFiles | Select-Object Database, TypeDescription, PhysicalName



# For each drive letter in use, ask Windows which disk it is on.
# For an RDM the disk serial number is the FlashArray volume's serial number.
$DriveLetters = $DbFiles.PhysicalName | ForEach-Object { $_.Substring(0, 1).ToUpper() } | Select-Object -Unique

$SerialByDrive = Invoke-Command -ComputerName $SqlVM -Credential $Credential -ArgumentList (, $DriveLetters) -ScriptBlock {
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

# Take a crash-consistent snapshot of the protection group, so every source volume shares the same point in time.
# The source database stays online.
$Stamp      = (Get-Date).ToString('yyyyMMdd-HHmmss')
$PgSnapshot = New-Pfa2ProtectionGroupSnapshot -Array $FlashArray -SourceName $ProtectionGroupName -Suffix "clone-$Stamp"

# The protection group snapshot holds one snapshot per volume, named <group>.<suffix>.<volume>.  Pick out the source volumes' snapshots.
# This stops with an error if the group does not hold one of the source volumes.
$Snapshots  = @(foreach ($Volume in $SourceVolumes) { Get-Pfa2VolumeSnapshot -Array $FlashArray -Name "$($PgSnapshot.Name).$($Volume.Name)" })
$Snapshots | Select-Object Name, Created



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
# Add the clones to the VM as RDMs

# The LUN is named naa.624a9370 followed by the FlashArray volume's serial number.  624a9370 is Pure Storage's vendor ID, so the prefix is the same on every FlashArray and would be different on another vendor's array.
foreach ($Clone in $Clones) {
    $Lun = Get-ScsiLun -VmHost $ESXiHost -CanonicalName ('naa.624a9370' + $Clone.Serial.ToLower())
    New-HardDisk -VM $VMObject -DiskType RawPhysical -DeviceName $Lun.ConsoleDeviceName
}



# The copies arrive in Windows offline.  Find them by serial number (the clones' serials, not the originals').
# For each one, give it a new disk GUID while it is still offline, then make it writable and online it.
# The partition gets the next free drive letter, because the original still has its letter.
$CloneSerials = @($Clones.Serial)

# The new disks can take a while to appear in Windows.  Wait until every new disk is listed, running this until it is, then continue.
Invoke-Command -ComputerName $SqlVM -Credential $Credential -ScriptBlock { Update-HostStorageCache; Get-Disk | Select-Object Number, SerialNumber, IsOffline, Size }

$TargetDriveBySerial = Invoke-Command -ComputerName $SqlVM -Credential $Credential -ArgumentList (, $CloneSerials) -ScriptBlock {
    param($serials)
    Update-HostStorageCache
    $found = @(Get-Disk | Where-Object { $serials -contains "$($_.SerialNumber)".ToUpper() })
    $result = @{}
    foreach ($disk in $found) {
        # diskpart gives the copy a new disk GUID while it is still offline, then onlines it.
        Set-Content -Path "$env:TEMP\online.txt" -Value "select disk $($disk.Number)`r`nattributes disk clear readonly`r`nuniqueid disk id=$([guid]::NewGuid())`r`nonline disk"
        diskpart /s "$env:TEMP\online.txt" | Out-Null
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
# Attach the databases

# Each source volume has a clone.  Match them up by name: the clone's name starts with the source volume's name.
$CloneSerialBySourceSerial = @{}
foreach ($Source in $SourceVolumes) { $CloneSerialBySourceSerial[$Source.Serial] = ($Clones | Where-Object { $_.Name -like "$($Source.Name)-clone-*" }).Serial }

# Each file keeps its path, with the drive letter swapped for the letter the copy got
foreach ($Database in $Databases) {
    $Files = $DbFiles | Where-Object { $_.Database -eq $Database } | ForEach-Object {
        $OldLetter = $_.PhysicalName.Substring(0, 1).ToUpper()
        $NewLetter = $TargetDriveBySerial[$CloneSerialBySourceSerial[$SerialByDrive[$OldLetter]]]
        "(FILENAME = N'$NewLetter$($_.PhysicalName.Substring(1))')"
    }
    $Query = "CREATE DATABASE [$Database$NewNameSuffix] ON $($Files -join ', ') FOR ATTACH"
    Invoke-DbaQuery -EnableException -SqlInstance $Sql -Database master -Query $Query
}



###
# The databases are online after crash recovery.  Check them.
Get-DbaDbState -SqlInstance $Sql -Database ($Databases | ForEach-Object { "$_$NewNameSuffix" })



Disconnect-Pfa2Array -Array $FlashArray
