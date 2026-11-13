##############################################################################################################################
# LUN Passthrough Availability Group Seeding
#
# Scenario:
#    Two SQL Server VMs on OpenShift Virtualization (primary and secondary replica) each keep their database files on block-mode
#    PersistentVolumeClaims.  Each PVC is its own FlashArray volume (Portworx, backend pure_block) attached to the VM as a virtual disk.
#    You want to add a large database to an existing availability group without streaming it over the network.
#
#    This script seeds the secondary from a FlashArray snapshot.  On the primary it freezes the databases with SQL Server's T-SQL
#    Snapshot Backup, takes one snapshot of every FlashArray volume that holds them and releases the freeze with a metadata-only backup.
#    Each snapshot is cloned as a new FlashArray volume, imported into OpenShift as a PVC and hot-plugged into the secondary VM.
#    The copy gets a new GPT disk GUID before it is onlined (the replicas are nodes of one failover
#    cluster, and a cluster node does not mount a disk whose identity matches a disk on another node), and the same drive letter the
#    primary uses.  The databases are restored on the secondary WITH METADATA_ONLY and NORECOVERY, one log backup bridges the gap between
#    the snapshot and now, and the databases are added to the group.
#
#    The cloned volumes stay in place as the secondary's database volumes.
#
#    You name the VMs, the availability group, the databases, the OpenShift project and the FlashArray.  The script works out the rest by lookup:
#    database files -> Windows drive -> Windows disk serial number (it is the FlashArray volume's serial number)
#    -> FlashArray volume -> PVC.
#
# Prerequisites:
#    1. PowerShell modules: dbatools and PureStoragePowerShellSDK2.
#    2. SQL Server 2022 or later on both replicas.  The availability group exists and both instances are replicas.
#    3. The databases are online on the primary in FULL recovery and every database disk is a block-mode PVC from the Portworx FlashArray
#       storage class, attached to the VM as a LUN passthrough disk.
#       The databases are not yet in the availability group and do not exist on the secondary.
#    4. A share both SQL Servers can reach, for the metadata backup files and one small log backup per database.
#    5. PowerShell remoting (WinRM) to both VMs, and an OpenShift API token for an account that can read and change VMs and PVCs in the
#       project (the oc login token).
#    6. The secondary VM can hot-plug disks.
#    7. Database files are on drive letters (this script is written for drive letters and does not handle mount points), and the secondary must be able to use the same drive letters as the primary.
#
# Usage Notes:
#    SUSPEND_FOR_SNAPSHOT_BACKUP is tied to the SQL Server session.  The freeze and the metadata backup must run in the SAME session, so
#    the primary uses a persistent, non-pooled dbatools connection.
#
# Disclaimer:
#    This example script is provided AS-IS and meant to be a building block to be adapted to fit an individual
#    organization's infrastructure.
#
#    _PLEASE_ do not save your passwords or tokens in cleartext here.
#    Use NTFS secured, encrypted files or whatever else -- never cleartext!
#
##############################################################################################################################

# Stop at the first error.  Several steps below remove or overwrite things, so never carry on after a failure.
$ErrorActionPreference = 'Stop'



# Import powershell modules
Import-Module PureStoragePowerShellSDK2
Import-Module dbatools



# Declare all variables
$ApiServer            = 'https://api.openshift.example.com:6443'   # OpenShift API endpoint
$Namespace            = 'sql-project'                  # OpenShift project that holds both VMs
$ArrayName            = 'flasharray1.example.com'      # FlashArray FQDN

$PrimaryVM            = 'primary_vm'                   # Not FQDN.  Also the name of the VirtualMachine object
$SecondaryVM          = 'secondary_vm'                 # Not FQDN.  Also the name of the VirtualMachine object
$PrimarySQLServer     = 'primary_vm.example.com'
$SecondarySQLServer   = 'secondary_vm.example.com'
$AgName               = 'ag1'                          # The availability group
$Databases            = @('AdventureWorks', 'WideWorldImporters')
$ProtectionGroupName  = 'sql-seed-pg'                   # Made by this script if it does not exist, see "Protection group"
$BackupShare          = '\\fileserver\share\ag-seeding'   # Metadata backups and the log backups
$StorageClass         = 'flasharray-sc'                # The Portworx FlashArray storage class that the primary's PVCs use



# Get Credentials - this example assumes the same credential for the FlashArray and both VMs
$Credential = Get-Credential -UserName "$env:USERNAME" -Message 'Enter your credential information...'
$OpenShiftToken = Read-Host -Prompt 'OpenShift API token' -AsSecureString



# Connect to everything
$FlashArray        = Connect-Pfa2Array -Endpoint $ArrayName -Credential $Credential -IgnoreCertificateError
$PrimarySql        = Connect-DbaInstance -SqlInstance $PrimarySQLServer -TrustServerCertificate -NonPooledConnection   # persistent, for the freeze
$SecondarySql      = Connect-DbaInstance -SqlInstance $SecondarySQLServer -TrustServerCertificate

# A small helper for the OpenShift API.  Bodies are sent as JSON.
$Token   = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($OpenShiftToken))
$Headers = @{ Authorization = "Bearer $Token" }
function Invoke-OpenShift($Method, $Path, $Body) {
    if ($null -ne $Body) { Invoke-RestMethod -Method $Method -Uri "$ApiServer$Path" -Headers $Headers -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 20) }
    else { Invoke-RestMethod -Method $Method -Uri "$ApiServer$Path" -Headers $Headers }
}



###
# Look up where the database files live on the primary

$DbFiles = Get-DbaDbFile -SqlInstance $PrimarySql -Database $Databases
$DbFiles | Select-Object Database, TypeDescription, PhysicalName



# For each drive letter in use, ask Windows on the VM which disk it is on.  For a LUN passthrough disk the disk serial number is the
# FlashArray volume's serial number.
$DriveLetters = $DbFiles.PhysicalName | ForEach-Object { $_.Substring(0, 1).ToUpper() } | Select-Object -Unique

$SerialByDrive = Invoke-Command -ComputerName $PrimaryVM -Credential $Credential -ArgumentList (, $DriveLetters) -ScriptBlock {
    param($letters)
    $map = @{}
    foreach ($letter in $letters) {
        $drive = Get-CimInstance -Query "ASSOCIATORS OF {Win32_LogicalDisk.DeviceID='${letter}:'} WHERE AssocClass=Win32_LogicalDiskToPartition" | ForEach-Object { Get-CimInstance -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$($_.DeviceID)'} WHERE AssocClass=Win32_DiskDriveToDiskPartition" }
        $map[$letter] = "$($drive.SerialNumber)".Trim().ToUpper()
    }
    $map
}
$SerialByDrive



# Look up the FlashArray volumes by serial number.
$SourceVolumes = @(Get-Pfa2Volume -Array $FlashArray | Where-Object { $SerialByDrive.Values -contains $_.Serial -and -not $_.Destroyed })
if ($SourceVolumes.Count -ne @($SerialByDrive.Values | Select-Object -Unique).Count) { throw 'A database disk is not a FlashArray volume.  This script is for LUN passthrough disks.' }

# Then look up the PVC behind each volume.  A Portworx FlashArray volume is named px_<cluster id>-pvc-<PVC uid>, so the
# name ends with the PVC uid.
$Pvcs = @((Invoke-OpenShift GET "/api/v1/namespaces/$Namespace/persistentvolumeclaims").items)
$SourceDisks = @()
foreach ($Volume in $SourceVolumes) {
    $Pvc = @($Pvcs | Where-Object { $Volume.Name -like "*pvc-$($_.metadata.uid)" })
    $SourceDisks += [pscustomobject]@{ Serial = $Volume.Serial; Pvc = $Pvc[0].metadata.name; Size = $Pvc[0].spec.resources.requests.storage; Volume = $Volume }
}
$SourceDisks | Select-Object Serial, Pvc, Size, @{ n = 'FlashArrayVolume'; e = { $_.Volume.Name } }

$PgName    = $ProtectionGroupName



###
# Protection group
# A protection group snapshot snapshots every volume in the group at the same moment.  That is how the database disks, one volume
# each, get one shared point in time.  This section makes the group if it does not exist yet.
# If you already have a protection group that holds these volumes, comment out this section and set $PgName to that group.
# Every volume in the group is snapshotted, not only the source volumes.

if (-not @(Get-Pfa2ProtectionGroup -Array $FlashArray -Filter "name='$PgName'")) {
    New-Pfa2ProtectionGroup -Array $FlashArray -Name $PgName
    New-Pfa2ProtectionGroupVolume -Array $FlashArray -GroupName $PgName -MemberName $SourceVolumes.Name
}



###
# Take the application-consistent snapshot on the primary

# Freeze every database for write IO.  Each stays frozen until its metadata backup below.
foreach ($Database in $Databases) {
    Invoke-DbaQuery -EnableException -SqlInstance $PrimarySql -Database master -Query "ALTER DATABASE [$Database] SET SUSPEND_FOR_SNAPSHOT_BACKUP = ON"
}



# Take a snapshot of the protection group, so every source volume shares the same point in time, while the databases are frozen
$Stamp      = (Get-Date).ToString('MMddHHmmss')
$PgSnapshot = New-Pfa2ProtectionGroupSnapshot -Array $FlashArray -SourceName $PgName -Suffix "seed-$Stamp"

# The protection group snapshot holds one snapshot per volume, named <group>.<suffix>.<volume>.
# The names are worked out here, without asking the array, so the freeze is released as soon as possible.
$SnapshotNames = @(foreach ($Volume in $SourceVolumes) { "$($PgSnapshot.Name).$($Volume.Name)" })



# Write a metadata-only backup of each database.  This releases the freeze.
# MEDIADESCRIPTION records the protection group snapshot and the array.  It holds at most 255 characters, so the one group snapshot name is
# recorded, not every volume snapshot name.  Keep the file names, the secondary restores from them below.
$BackupFiles = @{}
foreach ($Database in $Databases) {
    $BackupFiles[$Database] = "$BackupShare\${Database}_$(Get-Date -Format FileDateTime).bkm"
    $Query = "BACKUP DATABASE [$Database] TO DISK = '$($BackupFiles[$Database])' WITH METADATA_ONLY, MEDIADESCRIPTION = '$($PgSnapshot.Name)|$($FlashArray.ArrayName)'"
    Invoke-DbaQuery -EnableException -SqlInstance $PrimarySql -Database master -Query $Query
}

# Check that every snapshot exists.  This stops with an error if the group does not hold one of the source volumes.
$Snapshots  = @(foreach ($Name in $SnapshotNames) { Get-Pfa2VolumeSnapshot -Array $FlashArray -Name $Name })
$Snapshots | Select-Object Name, Created



###
# Clone the snapshots, import them into OpenShift and attach them to the secondary VM

# Create a new FlashArray volume from each snapshot.  The clone keeps the size, the partition table and the file system of its source.
$Clones = @()
foreach ($Disk in $SourceDisks) {
    $Snapshot  = $Snapshots | Where-Object { $_.Name -like "*.$($Disk.Volume.Name)" }
    $Clone     = New-Pfa2Volume -Array $FlashArray -Name "$($Disk.Pvc)-seed" -SourceName $Snapshot.Name
    $Clones   += [pscustomobject]@{ Source = $Disk; ArrayName = $Clone.Name; PvcName = "$($Disk.Pvc)-seed"; Serial = $Clone.Serial }
}
$Clones | Select-Object @{ n = 'Source'; e = { $_.Source.Pvc } }, ArrayName, PvcName, Serial

# A PVC with the annotation pure_vol_name makes Portworx use the existing FlashArray volume instead of creating a new empty one.
# The PVC size has to match the size of the volume.  The PVC binds when the VM first uses it.
foreach ($Clone in $Clones) {
    $null = Invoke-OpenShift POST "/api/v1/namespaces/$Namespace/persistentvolumeclaims" @{
        apiVersion = 'v1'; kind = 'PersistentVolumeClaim'
        metadata   = @{ name = $Clone.PvcName; annotations = @{ pure_vol_name = $Clone.ArrayName } }
        spec       = @{ accessModes = @('ReadWriteMany'); volumeMode = 'Block'; storageClassName = $StorageClass; resources = @{ requests = @{ storage = $Clone.Source.Size } } }
    }
}

# Hot-plug each PVC into the running secondary VM as a LUN passthrough disk.  The guest finds it again by its FlashArray serial number.
foreach ($Clone in $Clones) {
    $null = Invoke-OpenShift PUT "/apis/subresources.kubevirt.io/v1/namespaces/$Namespace/virtualmachines/$SecondaryVM/addvolume" @{
        name         = $Clone.PvcName
        disk         = @{ lun = @{ bus = 'scsi' } }
        volumeSource = @{ persistentVolumeClaim = @{ claimName = $Clone.PvcName; hotpluggable = $true } }
    }
    Start-Sleep -Seconds 10   # OpenShift handles one hot-plug request at a time, so give it a moment before the next one
}

# Wait until OpenShift reports every new disk as Ready, running this until it does, then continue.
(Invoke-OpenShift GET "/apis/kubevirt.io/v1/namespaces/$Namespace/virtualmachineinstances/$SecondaryVM").status.volumeStatus | Where-Object { $_.hotplugVolume } | Select-Object name, phase, target



###
# Give the copies new disk GUIDs, online them, and give each the SAME drive letter its original has on the primary
# A copy of a disk has the same GPT disk GUID as the original.  The replicas are nodes of one failover cluster, and a cluster node does
# not mount a disk whose identity matches a disk on another node.  So the GUID is changed while the disk is still offline, then it is
# onlined.  The partition must get the original's drive letter, because the metadata restore below looks for the files at their original
# paths.  The copies are found by the clones' serial numbers.

$LetterBySerial = @{}
foreach ($Clone in $Clones) {
    foreach ($Letter in $SerialByDrive.Keys) { if ($SerialByDrive[$Letter] -eq $Clone.Source.Serial) { $LetterBySerial[$Clone.Serial] = $Letter } }
}

# The new disks can take a while to appear in Windows.  Wait until every new disk is listed, running this until it is, then continue.
Invoke-Command -ComputerName $SecondaryVM -Credential $Credential -ScriptBlock { Update-HostStorageCache; Get-Disk | Select-Object Number, SerialNumber, IsOffline, Size }

Invoke-Command -ComputerName $SecondaryVM -Credential $Credential -ArgumentList @($Clones.Serial), $LetterBySerial -ScriptBlock {
    param($serials, $letterBySerial)
    Update-HostStorageCache
    $found = @(Get-Disk | Where-Object { $null -ne $_.Number -and $serials -contains "$($_.SerialNumber)".Trim().ToUpper() })
    foreach ($disk in $found) {
        # diskpart only touches this machine's own disks.  Set-Disk goes through the clustered storage subsystem on a failover cluster node,
        # and a copy of a disk has the same ID as the original on the other node, so Set-Disk can take the OTHER node's disk offline.
        Set-Content -Path "$env:TEMP\online.txt" -Value "select disk $($disk.Number)`r`nattributes disk clear readonly`r`nuniqueid disk id=$([guid]::NewGuid())`r`nonline disk"
        diskpart /s "$env:TEMP\online.txt" | Out-Null
        $partition = Get-Partition -DiskNumber $disk.Number | Where-Object Type -eq 'Basic' | Select-Object -First 1
        $wanted = $letterBySerial["$($disk.SerialNumber)".Trim().ToUpper()]
        if ("$($partition.DriveLetter)" -ne $wanted) {
            if ($partition.DriveLetter) { Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -AccessPath "$($partition.DriveLetter):\" }
            Set-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -NewDriveLetter $wanted
        }
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
