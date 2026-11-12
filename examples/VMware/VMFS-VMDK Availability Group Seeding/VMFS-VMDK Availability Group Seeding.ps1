##############################################################################################################################
# VMFS-VMDK Availability Group Seeding
#
# Scenario:
#    Two SQL Server VMs (primary and secondary replica) each keep their database files on VMDKs in a VMFS datastore on a
#    FlashArray.  You want to add a large database to an existing availability group without streaming it over the network.
#
#    This script seeds the secondary from a FlashArray snapshot.  On the primary it freezes the databases with SQL Server's
#    T-SQL Snapshot Backup, takes a snapshot of the datastore's FlashArray volume and releases the freeze with a metadata-only
#    backup.  The snapshot is cloned and resignatured.  The copied VMDKs get new IDs (a new VMDK UUID, and a new GPT disk GUID on a
#    helper VM, because a failover cluster node does not mount a disk whose identity matches a disk on another node).  They are then
#    attached to the secondary VM with the same drive letters the primary uses.  The databases are restored
#    on the secondary WITH METADATA_ONLY and NORECOVERY, one log backup bridges the gap between the snapshot and now, and the databases
#    are added to the group.  Finally the VMDKs are Storage vMotioned onto the secondary's own datastore and the temporary clone is removed.
#
#    You name the VMs, the availability group, the databases and the vCenter and FlashArray.  The script works out the rest by lookup:
#    database files -> Windows drive -> Windows disk serial number -> VMDK (the serial is the VMDK's UUID)
#    -> datastore -> FlashArray volume -> FlashArray host group.
#
# Prerequisites:
#    1. PowerShell modules: dbatools, PureStoragePowerShellSDK2 and VMware PowerCLI.
#    2. SQL Server 2022 or later on both replicas.  The availability group exists and both instances are replicas.
#    3. The databases are online on the primary in FULL recovery and are all on VMDKs in ONE datastore.
#       The databases are not yet in the availability group and do not exist on the secondary.
#    4. A share both SQL Servers can reach, for the metadata backup files and one small log backup per database.
#    5. The secondary VM has free SCSI slots for hot-adding disks.
#    6. Database files are on drive letters (this script is written for drive letters and does not handle mount points), and the secondary must be able to use the same drive letters as the primary.
#    7. A helper VM: any Windows VM on the same ESXi host as the secondary that is NOT a node of the failover cluster, with free SCSI slots, VMware Tools running and a
#       login that can run commands in it.  It is reached through VMware Tools, so it needs no remoting or DNS setup.
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
$HelperVM             = 'helper_vm'                    # Any Windows VM that is NOT a node of the failover cluster.  Not FQDN
$PrimarySQLServer     = 'primary_vm.example.com'
$SecondarySQLServer   = 'secondary_vm.example.com'
$AgName               = 'ag1'                          # The availability group
$Databases            = @('AdventureWorks', 'WideWorldImporters')
$SecondaryDatastoreName = 'secondary_sql_datastore'    # The secondary's own datastore, where the seeded VMDKs end up
$BackupShare          = '\\fileserver\share\ag-seeding'   # Metadata backups and the log backups



# Get Credentials - this example assumes the same credential for vCenter, the FlashArray and both VMs
$Credential = Get-Credential -UserName "$env:USERNAME" -Message 'Enter your credential information...'



# Connect to everything
$VIServer         = Connect-VIServer -Server $VIServerName -Protocol https -Credential $Credential
$FlashArray       = Connect-Pfa2Array -Endpoint $ArrayName -Credential $Credential -IgnoreCertificateError
$PrimarySql       = Connect-DbaInstance -SqlInstance $PrimarySQLServer -TrustServerCertificate -NonPooledConnection   # persistent, for the freeze
$SecondarySql     = Connect-DbaInstance -SqlInstance $SecondarySQLServer -TrustServerCertificate
$PrimaryVMObject   = Get-VM -Name $PrimaryVM
$SecondaryVMObject = Get-VM -Name $SecondaryVM
$ESXiHost         = Get-VMHost -VM $SecondaryVMObject
$SecondaryDatastore = Get-Datastore -Name $SecondaryDatastoreName
$HelperVMObject   = Get-VM -Name $HelperVM
$DiskManager      = Get-View (Get-View ServiceInstance).Content.VirtualDiskManager
$Datacenter       = Get-Datacenter | Select-Object -First 1



###
# Look up where the database files live on the primary

$DbFiles = Get-DbaDbFile -SqlInstance $PrimarySql -Database $Databases
$DbFiles | Select-Object Database, TypeDescription, PhysicalName



# For each drive letter in use, ask Windows on the primary which disk it is on.  The disk serial number is the VMDK's UUID.
$DriveLetters = $DbFiles.PhysicalName | ForEach-Object { $_.Substring(0, 1).ToUpper() } | Select-Object -Unique

# The new disks can take a while to appear in Windows.  Wait until every new disk is listed, running this until it is, then continue.
Invoke-Command -ComputerName $PrimaryVM -Credential $Credential -ScriptBlock { Update-HostStorageCache; Get-Disk | Select-Object Number, SerialNumber, IsOffline, Size }

$SerialByDrive = Invoke-Command -ComputerName $PrimaryVM -Credential $Credential -ArgumentList (, $DriveLetters) -ScriptBlock {
    param($letters)
    $map = @{}
    foreach ($letter in $letters) {
        # On a failover cluster node Get-Disk also lists the other nodes' disks, which have no disk number.  Keep the local ones.
        $map[$letter] = (Get-Partition -DriveLetter $letter | Get-Disk | Where-Object { $null -ne $_.Number }).SerialNumber.ToLower()
    }
    $map
}
$SerialByDrive



# Find those VMDKs in vSphere: the VMDK's backing UUID, without dashes, is the Windows disk serial number
$SourceDisks = Get-HardDisk -VM $PrimaryVMObject -DiskType Flat | Where-Object { # An RDM has no VMDK UUID, so only look at VMDKs
    $SerialByDrive.Values -contains $_.ExtensionData.Backing.Uuid.Replace('-', '').ToLower()
}
$SourceDisks | Select-Object Filename, CapacityGB

$SourceDatastoreName = ($SourceDisks.Filename | ForEach-Object { ($_ -split '\]')[0].TrimStart('[') } | Select-Object -Unique)
if (@($SourceDatastoreName).Count -ne 1) { throw "The database disks are in more than one datastore: $($SourceDatastoreName -join ', ')" }



# Look up the FlashArray volume behind the datastore, and the host group it is connected to
$LunName      = (Get-Datastore -Name $SourceDatastoreName).ExtensionData.Info.Vmfs.Extent[0].DiskName
# The datastore's LUN is named naa.624a9370 followed by the FlashArray volume's serial number.  624a9370 is Pure Storage's vendor ID, so the prefix is the same on every FlashArray and would be different on another vendor's array.
$VolumeSerial = $LunName.Substring('naa.624a9370'.Length).ToUpper()
$SourceVolume = Get-Pfa2Volume -Array $FlashArray | Where-Object { $_.Serial -eq $VolumeSerial }
# NOTE: do not pipe FlashArray cmdlets into Select-Object -First.  In Windows PowerShell 5.1 it can end the whole script silently.
$Connections  = @(Get-Pfa2Connection -Array $FlashArray -VolumeNames $SourceVolume.Name | Where-Object { $_.HostGroup.Name })
$FAHostGroup  = $Connections[0].HostGroup.Name
"Datastore $SourceDatastoreName is FlashArray volume $($SourceVolume.Name), connected to host group $FAHostGroup"



###
# Take the application-consistent snapshot on the primary

# Freeze every database for write IO.  Each stays frozen until its metadata backup below.
foreach ($Database in $Databases) {
    Invoke-DbaQuery -EnableException -SqlInstance $PrimarySql -Database master -Query "ALTER DATABASE [$Database] SET SUSPEND_FOR_SNAPSHOT_BACKUP = ON"
}



# Take a snapshot of the volume while the databases are frozen
# NOTE: this takes a snapshot of ONE volume, the one behind the datastore.  If a server's database VMDKs are spread over several VMFS datastores,
# snapshot those volumes through a protection group, so they all share one point in time. 
$Snapshot = New-Pfa2VolumeSnapshot -Array $FlashArray -SourceNames $SourceVolume.Name
$Snapshot



# Write a metadata-only backup of each database.  This releases the freeze.
# MEDIADESCRIPTION records the snapshot name and array.  Keep the file names, the secondary restores from them below.
$BackupFiles = @{}
foreach ($Database in $Databases) {
    $BackupFiles[$Database] = "$BackupShare\${Database}_$(Get-Date -Format FileDateTime).bkm"
    $Query = "BACKUP DATABASE [$Database] TO DISK = '$($BackupFiles[$Database])' WITH METADATA_ONLY, MEDIADESCRIPTION = '$($Snapshot.Name)|$($FlashArray.ArrayName)'"
    Invoke-DbaQuery -EnableException -SqlInstance $PrimarySql -Database master -Query $Query
}



###
# Clone the snapshot and attach it to the secondary VM

$CloneName = "$($SourceVolume.Name)-seed-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
$Clone     = New-Pfa2Volume -Array $FlashArray -Name $CloneName -SourceName $Snapshot.Name
New-Pfa2Connection -Array $FlashArray -HostGroupNames $FAHostGroup -VolumeNames $CloneName

Get-VMHostStorage -RescanAllHba -VMHost $ESXiHost



# Resignature the cloned datastore.  The copy has the same label as the original datastore, so name it exactly.
$esxcli = Get-EsxCli -VMHost $ESXiHost -V2
$esxcli.storage.vmfs.snapshot.resignature.Invoke(@{ volumelabel = $SourceDatastoreName })

Get-VMHostStorage -RescanVmfs -VMHost $ESXiHost

# The copied datastore can take a little while to appear.  Wait until it is listed, running this until it is, then continue.
Get-Datastore | Where-Object { $_.Name -like "snap-*-$SourceDatastoreName" }
$ClonedDatastore = Get-Datastore | Where-Object { $_.Name -like "snap-*-$SourceDatastoreName" } | Sort-Object Name | Select-Object -Last 1
$ClonedDatastore



###
# Give the copies new IDs before they go near the secondary
# A copy of a disk has the same VMDK UUID (the Windows disk serial number) and the same GPT disk GUID as the original.  The replicas are
# nodes of one failover cluster, and a cluster node does not mount a disk whose identity matches a disk on another node: the disk is
# attached but no volume appears.  So both IDs are changed first, and the GPT GUID can only be changed on a machine where the copy is
# visible, which is a helper VM that is NOT in the cluster.

# 1. A new UUID for every copied VMDK, through the vSphere API.  The disk manager wants its own format: 16 bytes as hex pairs with a dash in the middle.
$NewSerialByOldSerial = @{}
foreach ($Disk in $SourceDisks) {
    $RelativePath = ($Disk.Filename -split '\] ', 2)[1]
    $CopyPath     = "[$($ClonedDatastore.Name)] $RelativePath"

    $Bytes = New-Object byte[] 13
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($Bytes)
    $Bytes[0] = ($Bytes[0] -band 0x0F) -bor 0x90          # keep the same shape as VMware's own UUIDs
    $Hex  = @('60', '00', 'C2') + ($Bytes | ForEach-Object { $_.ToString('x2') })
    $DiskManager.SetVirtualDiskUuid($CopyPath, $Datacenter.Id, (($Hex[0..7] -join ' ') + '-' + ($Hex[8..15] -join ' ')))

    $OldSerial = $Disk.ExtensionData.Backing.Uuid.Replace('-', '').ToLower()
    $NewSerialByOldSerial[$OldSerial] = ($DiskManager.QueryVirtualDiskUuid($CopyPath, $Datacenter.Id) -replace '[ -]', '').ToLower()
}
$NewSerialByOldSerial



# 2. A new GPT disk GUID on the helper VM, through VMware Tools, so the helper needs no remoting or DNS setup.
foreach ($Disk in $SourceDisks) {
    $RelativePath = ($Disk.Filename -split '\] ', 2)[1]
    New-HardDisk -VM $HelperVMObject -DiskPath "[$($ClonedDatastore.Name)] $RelativePath"
}

# diskpart is used because it only touches the machine's own disks.  Set-Disk -Guid is rejected for these disks ("Invalid Parameter").
$HelperScript = @'
$serials = @(__SERIALS__)
Update-HostStorageCache
$found = @(Get-Disk | Where-Object { $null -ne $_.Number -and $serials -contains "$($_.SerialNumber)".ToLower() })
foreach ($disk in $found) {
    Set-Content -Path "$env:TEMP\newguid.txt" -Value "select disk $($disk.Number)`r`nattributes disk clear readonly`r`nonline disk`r`nuniqueid disk id=$([guid]::NewGuid())`r`noffline disk"
    diskpart /s "$env:TEMP\newguid.txt" | Out-Null
}
'@
$HelperScript = $HelperScript.Replace('__SERIALS__', (($NewSerialByOldSerial.Values | ForEach-Object { "'$_'" }) -join ','))
Invoke-VMScript -VM $HelperVMObject -GuestCredential $Credential -ScriptType Powershell -ScriptText $HelperScript

Get-HardDisk -VM $HelperVMObject | Where-Object { $_.Filename -like "[[]$($ClonedDatastore.Name)]*" } | Remove-HardDisk -Confirm:$false



###
# Attach the copies to the secondary VM

foreach ($Disk in $SourceDisks) {
    $RelativePath = ($Disk.Filename -split '\] ', 2)[1]
    New-HardDisk -VM $SecondaryVMObject -DiskPath "[$($ClonedDatastore.Name)] $RelativePath"
}



# The copied disks arrive offline and read-only.  Online them and give each the SAME drive letter its original has on the primary,
# because the metadata restore below looks for the files at their original paths.  The copies are found by their NEW serial numbers.
$LetterBySerial = @{}
foreach ($Letter in $SerialByDrive.Keys) { $LetterBySerial[$NewSerialByOldSerial[$SerialByDrive[$Letter]]] = $Letter }

# The new disks can take a while to appear in Windows.  Wait until every new disk is listed, running this until it is, then continue.
Invoke-Command -ComputerName $SecondaryVM -Credential $Credential -ScriptBlock { Update-HostStorageCache; Get-Disk | Select-Object Number, SerialNumber, IsOffline, Size }

Invoke-Command -ComputerName $SecondaryVM -Credential $Credential -ArgumentList @($NewSerialByOldSerial.Values), $LetterBySerial -ScriptBlock {
    param($serials, $letterBySerial)
    Update-HostStorageCache
    $found = @(Get-Disk | Where-Object { $null -ne $_.Number -and $serials -contains "$($_.SerialNumber)".ToLower() })
    foreach ($disk in $found) {
        # diskpart only touches this machine's own disks.  Set-Disk goes through the clustered storage subsystem on a failover cluster node,
        # and a copy of a disk has the same ID as the original on the other node, so Set-Disk can take the OTHER node's disk offline.
        Set-Content -Path "$env:TEMP\online.txt" -Value "select disk $($disk.Number)`r`nattributes disk clear readonly`r`nonline disk"
        diskpart /s "$env:TEMP\online.txt" | Out-Null
        $partition = Get-Partition -DiskNumber $disk.Number | Where-Object Type -eq 'Basic' | Select-Object -First 1
        $wanted = $letterBySerial[$disk.SerialNumber.ToLower()]
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



###
# Move the seeded VMDKs onto the secondary's own datastore and remove the temporary clone

# Storage vMotion, while the databases stay online in the group
foreach ($Disk in (Get-HardDisk -VM $SecondaryVMObject | Where-Object { $_.Filename -like "[[]$($ClonedDatastore.Name)]*" })) {
    Move-HardDisk -HardDisk $Disk -Datastore $SecondaryDatastore -Confirm:$false
}



# Remove the cloned datastore, then detach its LUN so the host does not report dead paths
Remove-Datastore -Datastore $ClonedDatastore -VMHost $ESXiHost -Confirm:$false

# naa.624a9370 is Pure Storage's vendor ID followed by the volume's serial number, as explained above.
$CloneLun = 'naa.624a9370' + $Clone.Serial.ToLower()
(Get-EsxCli -VMHost $ESXiHost -V2).storage.core.device.set.Invoke(@{ device = $CloneLun; state = 'off' })



# On the FlashArray, disconnect and destroy the temporary volume.  The snapshot is kept, it is the seed's base.
Remove-Pfa2Connection -Array $FlashArray -HostGroupNames $FAHostGroup -VolumeNames $CloneName
Remove-Pfa2Volume -Array $FlashArray -Name $CloneName



Get-VMHostStorage -RescanAllHba -VMHost $ESXiHost

Disconnect-Pfa2Array -Array $FlashArray
