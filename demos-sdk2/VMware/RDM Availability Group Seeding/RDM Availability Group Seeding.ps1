##############################################################################################################################
# RDM Availability Group Seeding
#
# Scenario:
#    Two SQL Server VMs (primary and secondary replica) each keep their database files on raw device mappings (RDMs).  Each RDM is its
#    own FlashArray volume.  You want to add a large database to an existing availability group without streaming it over the network.
#
#    This script seeds the secondary from a FlashArray snapshot.  On the primary it freezes the databases with SQL Server's T-SQL
#    Snapshot Backup, takes one snapshot of every FlashArray volume that holds them and releases the freeze with a metadata-only backup.
#    Each snapshot is cloned as a new volume and added to the secondary VM as an RDM.  The copy gets a new
#    GPT disk GUID before it is onlined (the replicas are nodes of one failover cluster, and a cluster node does not mount a disk whose
#    identity matches a disk on another node), and the same drive letter the primary uses.  The databases are restored on the secondary
#    WITH METADATA_ONLY and NORECOVERY, one log backup bridges the gap between the snapshot and now, and the databases are added to
#    the group.
#
#    The cloned volumes stay in place as the secondary's database volumes.
#
#    You name the VMs, the availability group, the databases and the vCenter and FlashArray.  The script works out the rest by lookup:
#    database files -> Windows drive -> Windows disk serial number (it is the FlashArray volume's serial number)
#    -> FlashArray volume -> FlashArray host group.
#
# Prerequisites:
#    1. PowerShell modules: dbatools, PureStoragePowerShellSDK2 and VMware PowerCLI.
#    2. SQL Server 2022 or later on both replicas.  The availability group exists and both instances are replicas.
#    3. The databases are online on the primary in FULL recovery and every database disk is a FlashArray volume presented as an RDM.
#       The databases are not yet in the availability group and do not exist on the secondary.
#    4. A share both SQL Servers can reach, for the metadata backup files and one small log backup per database.
#    5. The secondary VM has free SCSI slots for hot-adding disks.
#    6. Database files are on drive letters (this script is written for drive letters and does not handle mount points), and the secondary must be able to use the same drive letters as the primary.
#
# Usage Notes:
#    SUSPEND_FOR_SNAPSHOT_BACKUP is tied to the SQL Server session.  The freeze and the metadata backup must run in the SAME session, so
#    the primary uses a persistent, non-pooled dbatools connection.
#
#    The snapshot must be application-consistent.  A crash-consistent snapshot (no freeze, so no metadata backup) cannot seed a group:
#    there is nothing to restore WITH METADATA_ONLY, and attaching the copied files with FOR ATTACH runs crash recovery and brings the
#    database online, so it cannot take a log restore or join the group, which both need it to be in the RESTORING state.
#    A copy-only snapshot (SUSPEND_FOR_SNAPSHOT_BACKUP = ON (MODE = COPY_ONLY)) seeds the group the same way and leaves the differential
#    base alone.  Start the log chain with a regular full backup first.
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
$VIServerName         = 'vcenter.example.com'
$ArrayName            = 'flasharray1.example.com'      # FlashArray FQDN

$PrimaryVM            = 'primary_vm'                   # Not FQDN
$SecondaryVM          = 'secondary_vm'                 # Not FQDN
$PrimarySQLServer     = 'primary_vm.example.com'
$SecondarySQLServer   = 'secondary_vm.example.com'
$AgName               = 'ag1'                          # The availability group
$Databases            = @('AdventureWorks', 'WideWorldImporters')
$ProtectionGroupName  = 'sql-seed-pg'                   # Made by this script the first run and reused, see "Protection group"
$BackupShare          = '\\fileserver\share\ag-seeding'   # Metadata backups and the log backups



# Get Credentials - this example assumes the same credential for vCenter, the FlashArray and both VMs
$Credential = Get-Credential -UserName "$env:USERNAME" -Message 'Enter your credential information...'



# Connect to everything
$VIServer          = Connect-VIServer -Server $VIServerName -Protocol https -Credential $Credential
$FlashArray        = Connect-Pfa2Array -Endpoint $ArrayName -Credential $Credential -IgnoreCertificateError
$PrimarySql        = Connect-DbaInstance -SqlInstance $PrimarySQLServer -TrustServerCertificate -NonPooledConnection   # persistent, for the freeze
$SecondarySql      = Connect-DbaInstance -SqlInstance $SecondarySQLServer -TrustServerCertificate
$SecondaryVMObject = Get-VM -Name $SecondaryVM
$ESXiHost          = Get-VMHost -VM $SecondaryVMObject



###
# Look up where the database files live on the primary

$DbFiles = Get-DbaDbFile -SqlInstance $PrimarySql -Database $Databases
$DbFiles | Select-Object Database, TypeDescription, PhysicalName



# For each drive letter in use, ask Windows on the primary which disk it is on.
# For an RDM the disk serial number is the FlashArray volume's serial number.
$DriveLetters = $DbFiles.PhysicalName | ForEach-Object { $_.Substring(0, 1).ToUpper() } | Select-Object -Unique

$SerialByDrive = Invoke-Command -ComputerName $PrimaryVM -Credential $Credential -ArgumentList (, $DriveLetters) -ScriptBlock {
    param($letters)
    $map = @{}
    foreach ($letter in $letters) {
        # On a failover cluster node Get-Disk also lists the other nodes' disks, which have no disk number.  Keep the local ones.
        $map[$letter] = (Get-Partition -DriveLetter $letter | Get-Disk | Where-Object { $null -ne $_.Number }).SerialNumber.ToUpper()
    }
    $map
}
$SerialByDrive



# Look up the FlashArray volumes, and the host group they are connected to
$SourceVolumes = @(Get-Pfa2Volume -Array $FlashArray | Where-Object { $SerialByDrive.Values -contains $_.Serial -and -not $_.Destroyed })
if ($SourceVolumes.Count -ne @($SerialByDrive.Values | Select-Object -Unique).Count) { throw 'A database disk is not a FlashArray volume.  This script is for RDMs.' }

# NOTE: do not pipe FlashArray cmdlets into Select-Object -First.  In Windows PowerShell 5.1 it can end the whole script silently.
$Connections = @(Get-Pfa2Connection -Array $FlashArray -VolumeNames $SourceVolumes[0].Name | Where-Object { $_.HostGroup.Name })
$FAHostGroup = $Connections[0].HostGroup.Name
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
# Take the application-consistent snapshot on the primary

# Freeze every database for write IO.  Each stays frozen until its metadata backup below.
foreach ($Database in $Databases) {
    Invoke-DbaQuery -EnableException -SqlInstance $PrimarySql -Database master -Query "ALTER DATABASE [$Database] SET SUSPEND_FOR_SNAPSHOT_BACKUP = ON"
}



# Take a snapshot of the protection group, so every source volume shares the same point in time, while the databases are frozen
$Stamp      = (Get-Date).ToString('yyyyMMdd-HHmmss')
$PgSnapshot = New-Pfa2ProtectionGroupSnapshot -Array $FlashArray -SourceName $ProtectionGroupName -Suffix "seed-$Stamp"

# The protection group snapshot holds one snapshot per volume, named <group>.<suffix>.<volume>.  Pick out the source volumes' snapshots.
# This stops with an error if the group does not hold one of the source volumes.
$Snapshots  = @(foreach ($Volume in $SourceVolumes) { Get-Pfa2VolumeSnapshot -Array $FlashArray -Name "$($PgSnapshot.Name).$($Volume.Name)" })
$Snapshots | Select-Object Name, Created



# Write a metadata-only backup of each database.  This releases the freeze.
# MEDIADESCRIPTION records the snapshot names and array.  Keep the file names, the secondary restores from them below.
$BackupFiles = @{}
foreach ($Database in $Databases) {
    $BackupFiles[$Database] = "$BackupShare\${Database}_$(Get-Date -Format FileDateTime).bkm"
    $Query = "BACKUP DATABASE [$Database] TO DISK = '$($BackupFiles[$Database])' WITH METADATA_ONLY, MEDIADESCRIPTION = '$($Snapshots.Name -join ',')|$($FlashArray.ArrayName)'"
    Invoke-DbaQuery -EnableException -SqlInstance $PrimarySql -Database master -Query $Query
}



###
# Clone the snapshots and add them to the secondary VM as RDMs

$Clones = @()
foreach ($Snapshot in $Snapshots) {
    $CloneName = ($Snapshot.Name -split '\.')[-1] + '-seed'
    $Clones   += New-Pfa2Volume -Array $FlashArray -Name $CloneName -SourceName $Snapshot.Name
    New-Pfa2Connection -Array $FlashArray -HostGroupNames $FAHostGroup -VolumeNames $CloneName
}

Get-VMHostStorage -RescanAllHba -VMHost $ESXiHost

# The LUN is named naa.624a9370 followed by the FlashArray volume's serial number.  624a9370 is Pure Storage's vendor ID, so the prefix is the same on every FlashArray and would be different on another vendor's array.
foreach ($Clone in $Clones) {
    $Lun = Get-ScsiLun -VmHost $ESXiHost -CanonicalName ('naa.624a9370' + $Clone.Serial.ToLower())
    New-HardDisk -VM $SecondaryVMObject -DiskType RawPhysical -DeviceName $Lun.ConsoleDeviceName
}



###
# Give the copies new disk GUIDs, online them, and give each the SAME drive letter its original has on the primary
# A copy of a disk has the same GPT disk GUID as the original.  The replicas are nodes of one failover cluster, and a cluster node does
# not mount a disk whose identity matches a disk on another node.  So the GUID is changed while the disk is still offline, then it is
# onlined.  The partition must get the original's drive letter, because the metadata restore below looks for the files at their original
# paths.  The copies are found by the clones' serial numbers.

$LetterBySerial = @{}
foreach ($Source in $SourceVolumes) {
    $CloneSerial = ($Clones | Where-Object { $_.Name -eq "$($Source.Name)-seed" }).Serial
    foreach ($Letter in $SerialByDrive.Keys) { if ($SerialByDrive[$Letter] -eq $Source.Serial) { $LetterBySerial[$CloneSerial] = $Letter } }
}

# The new disks can take a while to appear in Windows.  Wait until every new disk is listed, running this until it is, then continue.
Invoke-Command -ComputerName $SecondaryVM -Credential $Credential -ScriptBlock { Update-HostStorageCache; Get-Disk | Select-Object Number, SerialNumber, IsOffline, Size }

Invoke-Command -ComputerName $SecondaryVM -Credential $Credential -ArgumentList @($Clones.Serial), $LetterBySerial -ScriptBlock {
    param($serials, $letterBySerial)
    Update-HostStorageCache
    $found = @(Get-Disk | Where-Object { $null -ne $_.Number -and $serials -contains "$($_.SerialNumber)".ToUpper() })
    foreach ($disk in $found) {
        # diskpart only touches this machine's own disks.  Set-Disk goes through the clustered storage subsystem on a failover cluster node,
        # and a copy of a disk has the same ID as the original on the other node, so Set-Disk can take the OTHER node's disk offline.
        Set-Content -Path "$env:TEMP\online.txt" -Value "select disk $($disk.Number)`r`nattributes disk clear readonly`r`nuniqueid disk id=$([guid]::NewGuid())`r`nonline disk"
        diskpart /s "$env:TEMP\online.txt" | Out-Null
        $partition = Get-Partition -DiskNumber $disk.Number | Where-Object Type -eq 'Basic' | Select-Object -First 1
        $wanted = $letterBySerial[$disk.SerialNumber.ToUpper()]
        if ("$($partition.DriveLetter)" -ne $wanted) { Set-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -NewDriveLetter $wanted }
    }
}



###
# Seed the secondary

# Restore each database with METADATA_ONLY: the files are already in place from the snapshot.  NORECOVERY leaves it RESTORING.
foreach ($Database in $Databases) {
    $Query = "RESTORE DATABASE [$Database] FROM DISK = '$($BackupFiles[$Database])' WITH METADATA_ONLY, REPLACE, NORECOVERY"
    Invoke-DbaQuery -EnableException -SqlInstance $SecondarySql -Database master -Query $Query
}



# Take a log backup on the primary and restore it on the secondary.  This bridges the time since the snapshot.
foreach ($Database in $Databases) {
    $LogFile = "$BackupShare\$Database-seed-$(Get-Date -Format FileDateTime).trn"
    Invoke-DbaQuery -EnableException -SqlInstance $PrimarySql -Database master -Query "BACKUP LOG [$Database] TO DISK = '$LogFile' WITH FORMAT, INIT"
    Invoke-DbaQuery -EnableException -SqlInstance $SecondarySql -Database master -Query "RESTORE LOG [$Database] FROM DISK = '$LogFile' WITH NORECOVERY"
}



# Add the databases to the availability group on the primary, then join them on the secondary
foreach ($Database in $Databases) {
    Invoke-DbaQuery -EnableException -SqlInstance $PrimarySql -Database master -Query "ALTER AVAILABILITY GROUP [$AgName] ADD DATABASE [$Database]"
    Invoke-DbaQuery -EnableException -SqlInstance $SecondarySql -Database master -Query "ALTER DATABASE [$Database] SET HADR AVAILABILITY GROUP = [$AgName]"
}



# Check the group: the SynchronizationState should become Synchronized
# It can take a few seconds to show Synchronized.  Run this until every database does.
Get-DbaAgDatabase -SqlInstance $PrimarySql -AvailabilityGroup $AgName | Select-Object Name, SynchronizationState, IsSuspended



Disconnect-Pfa2Array -Array $FlashArray
