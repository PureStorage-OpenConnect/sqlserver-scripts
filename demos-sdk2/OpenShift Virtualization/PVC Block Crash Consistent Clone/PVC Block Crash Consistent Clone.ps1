##############################################################################################################################
# PVC Block Crash Consistent Clone
#
# Scenario:
#    A source SQL Server VM on OpenShift Virtualization keeps its database files on block-mode PersistentVolumeClaims.  Each PVC
#    is its own FlashArray volume (Portworx, backend pure_block) and is attached to the VM as a virtual disk.  A second SQL Server
#    VM (the target) needs a copy of those databases, for example for dev/test.
#
#    This script takes one crash-consistent snapshot of every FlashArray volume that holds the databases, clones each snapshot as
#    a new FlashArray volume, imports each clone into OpenShift as a PVC and hot-plugs the PVCs into the target VM.  The databases
#    are then attached on the target SQL Server under new names.
#
#    The source SQL Server is not touched and stays online.  The snapshot is crash-consistent: SQL Server write IO is
#    NOT frozen, so each database on the target performs crash recovery when it is attached.
#
#    You only name the VMs, the databases, the OpenShift project and the FlashArray.  The script works out the rest by lookup:
#    database files -> Windows drive -> Windows disk serial number (set on the VM disk, and equal to the PVC name)
#    -> PVC -> PVC uid -> FlashArray volume.
#
# Prerequisites:
#    1. PowerShell modules: dbatools and PureStoragePowerShellSDK2.
#    2. PowerShell remoting (WinRM) to both VMs, and a SQL Server login that can attach databases on the target.
#    3. An OpenShift API token for an account that can read and change VMs and PVCs in the project (the oc login token).
#    4. Every disk that holds the listed databases is a block-mode PVC from the Portworx FlashArray storage class, attached to the VM as a
#       virtual disk whose serial number is the PVC name.  Every one of those volumes is snapshotted together, and every one is copied.
#    5. The target VM must be a different VM from the source VM.  It runs in the same project and can hot-plug disks.
#    6. Database files must be on drive letters (this script is written for drive letters and does not handle mount points), and the databases must not exist on the target yet.
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
$ApiServer         = 'https://api.openshift.example.com:6443'   # OpenShift API endpoint
$Namespace         = 'sql-project'                    # OpenShift project that holds both VMs
$ArrayName         = 'flasharray1.example.com'        # FlashArray FQDN

$SourceVM          = 'source_vm'                      # Not FQDN.  Also the name of the VirtualMachine object
$TargetVM          = 'target_vm'                      # Not FQDN.  Also the name of the VirtualMachine object
$SourceSQLServer   = 'source_vm.example.com'
$TargetSQLServer   = 'target_vm.example.com'
$Databases         = @('AdventureWorks', 'WideWorldImporters')
$ProtectionGroupName = 'sql-clone-pg'                # Made by this script the first run and reused, see "Protection group"
$NewNameSuffix     = '_clone'                         # Databases are attached on the target as AdventureWorks_clone, ...
$StorageClass      = 'flasharray-sc'                  # The Portworx FlashArray storage class that the source PVCs use



# Get Credentials - this example assumes the same credential for the FlashArray and both VMs
$Credential = Get-Credential -UserName "$env:USERNAME" -Message 'Enter your credential information...'
$OpenShiftToken = Read-Host -Prompt 'OpenShift API token' -AsSecureString



# Connect to everything
$FlashArray    = Connect-Pfa2Array -Endpoint $ArrayName -Credential $Credential -IgnoreCertificateError
$SourceSql     = Connect-DbaInstance -SqlInstance $SourceSQLServer -TrustServerCertificate
$TargetSql     = Connect-DbaInstance -SqlInstance $TargetSQLServer -TrustServerCertificate

# A small helper for the OpenShift API.  Bodies are sent as JSON.
$Token   = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($OpenShiftToken))
$Headers = @{ Authorization = "Bearer $Token" }
function Invoke-OpenShift($Method, $Path, $Body) {
    if ($null -ne $Body) { Invoke-RestMethod -Method $Method -Uri "$ApiServer$Path" -Headers $Headers -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 20) }
    else { Invoke-RestMethod -Method $Method -Uri "$ApiServer$Path" -Headers $Headers }
}



###
# Look up where the database files live

# Every data and log file of the databases, as SQL Server sees them
$DbFiles = Get-DbaDbFile -SqlInstance $SourceSql -Database $Databases
$DbFiles | Select-Object Database, TypeDescription, PhysicalName



# For each drive letter in use, ask Windows on the source VM which disk it is on.
# The disk serial number is what the VM disk's serial field says, which is the PVC name.
$DriveLetters = $DbFiles.PhysicalName | ForEach-Object { $_.Substring(0, 1).ToUpper() } | Select-Object -Unique

$SerialByDrive = Invoke-Command -ComputerName $SourceVM -Credential $Credential -ArgumentList (, $DriveLetters) -ScriptBlock {
    param($letters)
    $map = @{}
    foreach ($letter in $letters) {
        $drive = Get-CimInstance -Query "ASSOCIATORS OF {Win32_LogicalDisk.DeviceID='${letter}:'} WHERE AssocClass=Win32_LogicalDiskToPartition" | ForEach-Object { Get-CimInstance -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$($_.DeviceID)'} WHERE AssocClass=Win32_DiskDriveToDiskPartition" }
        $map[$letter] = "$($drive.SerialNumber)".Trim()
    }
    $map
}
$SerialByDrive



# Look up the PVC for each disk serial number, then the FlashArray volume behind each PVC.
# A Portworx FlashArray volume is named px_<cluster id>-pvc-<PVC uid>, so the PVC uid finds it.
$SourceVMObject = Invoke-OpenShift GET "/apis/kubevirt.io/v1/namespaces/$Namespace/virtualmachines/$SourceVM"
$VMDisks   = $SourceVMObject.spec.template.spec.domain.devices.disks
$VMVolumes = $SourceVMObject.spec.template.spec.volumes

$SourceDisks = @()
foreach ($Serial in ($SerialByDrive.Values | Select-Object -Unique)) {
    $VMDisk = @($VMDisks | Where-Object { $_.serial -eq $Serial })
    if ($VMDisk.Count -ne 1) { throw "No single disk of $SourceVM has the serial number $Serial.  The disk serial number must be the PVC name." }
    $PvcName = ($VMVolumes | Where-Object { $_.name -eq $VMDisk[0].name }).persistentVolumeClaim.claimName
    $Pvc    = Invoke-OpenShift GET "/api/v1/namespaces/$Namespace/persistentvolumeclaims/$PvcName"
    $Volume = @(Get-Pfa2Volume -Array $FlashArray -Filter "name='*pvc-$($Pvc.metadata.uid)'")
    $SourceDisks += [pscustomobject]@{ Serial = $Serial; Pvc = $PvcName; Size = $Pvc.spec.resources.requests.storage; Volume = $Volume[0] }
}
$SourceVolumes = @($SourceDisks.Volume)
$SourceDisks | Select-Object Serial, Pvc, Size, @{ n = 'FlashArrayVolume'; e = { $_.Volume.Name } }




###
# Protection group
# A protection group snapshot snapshots every volume in the group at the same moment.  That is how the database disks, one volume
# each, get one shared point in time.  This section makes the group the first time and leaves it in place for the runs after.
# If you already have a protection group that holds these volumes, comment out this section and set $PgName to that group.
# Every volume in the group is snapshotted, not only the source volumes.

$PgName = $ProtectionGroupName
if (-not @(Get-Pfa2ProtectionGroup -Array $FlashArray -Filter "name='$PgName'")) {
    New-Pfa2ProtectionGroup -Array $FlashArray -Name $PgName
    New-Pfa2ProtectionGroupVolume -Array $FlashArray -GroupName $PgName -MemberName $SourceVolumes.Name
}



###
# Snapshot and clone

# Take a crash-consistent snapshot of the protection group, so every source volume shares the same point in time.
# The source database stays online.
$Stamp      = (Get-Date).ToString('MMddHHmmss')
$PgSnapshot = New-Pfa2ProtectionGroupSnapshot -Array $FlashArray -SourceName $PgName -Suffix "clone$Stamp"

# The protection group snapshot holds one snapshot per volume, named <group>.<suffix>.<volume>.  Pick out the source volumes' snapshots.
# This stops with an error if the group does not hold one of the source volumes.
$Snapshots  = @(foreach ($Volume in $SourceVolumes) { Get-Pfa2VolumeSnapshot -Array $FlashArray -Name "$($PgSnapshot.Name).$($Volume.Name)" })
$Snapshots | Select-Object Name, Created



# Create a new FlashArray volume from each snapshot.  The clone keeps the size, the partition table and the file system of its source.
$Clones = @()
foreach ($Disk in $SourceDisks) {
    $CloneName = "$($Disk.Pvc)-c$Stamp"
    $Snapshot  = $Snapshots | Where-Object { $_.Name -like "*.$($Disk.Volume.Name)" }
    $Clone     = New-Pfa2Volume -Array $FlashArray -Name $CloneName -SourceName $Snapshot.Name
    $Clones   += [pscustomobject]@{ Source = $Disk; ArrayName = $Clone.Name; PvcName = "$($Disk.Pvc)-c$Stamp"; Serial = "c$Stamp$($Clones.Count)" }
}
$Clones | Select-Object @{ n = 'Source'; e = { $_.Source.Pvc } }, ArrayName, PvcName, Serial



###
# Import the clones into OpenShift and attach them to the target VM

# A PVC with the annotation pure_vol_name makes Portworx use the existing FlashArray volume instead of creating a new empty one.
# The PVC size has to match the size of the volume.  The PVC binds when the VM first uses it.
foreach ($Clone in $Clones) {
    $null = Invoke-OpenShift POST "/api/v1/namespaces/$Namespace/persistentvolumeclaims" @{
        apiVersion = 'v1'; kind = 'PersistentVolumeClaim'
        metadata   = @{ name = $Clone.PvcName; annotations = @{ pure_vol_name = $Clone.ArrayName } }
        spec       = @{ accessModes = @('ReadWriteMany'); volumeMode = 'Block'; storageClassName = $StorageClass; resources = @{ requests = @{ storage = $Clone.Source.Size } } }
    }
}



# Hot-plug each PVC into the running target VM as a disk.  The disk serial number is how the guest finds it again.
foreach ($Clone in $Clones) {
    $null = Invoke-OpenShift PUT "/apis/subresources.kubevirt.io/v1/namespaces/$Namespace/virtualmachines/$TargetVM/addvolume" @{
        name         = $Clone.PvcName
        disk         = @{ serial = $Clone.Serial; disk = @{ bus = 'scsi' } }
        volumeSource = @{ persistentVolumeClaim = @{ claimName = $Clone.PvcName; hotpluggable = $true } }
    }
    Start-Sleep -Seconds 10   # OpenShift handles one hot-plug request at a time, so give it a moment before the next one
}

# Wait until OpenShift reports every new disk as Ready, running this until it does, then continue.
(Invoke-OpenShift GET "/apis/kubevirt.io/v1/namespaces/$Namespace/virtualmachineinstances/$TargetVM").status.volumeStatus | Where-Object { $_.hotplugVolume } | Select-Object name, phase, target



# The copies arrive in Windows offline.  Find them by serial number, online them and make them writable.
# They keep their partitions.  Windows gives each volume the next free drive letter.
$CloneSerials = @($Clones.Serial)
# The new disks can take a while to appear in Windows.  Wait until every new disk is listed, running this until it is, then continue.
Invoke-Command -ComputerName $TargetVM -Credential $Credential -ScriptBlock { Update-HostStorageCache; Get-Disk | Select-Object Number, SerialNumber, IsOffline, Size }

$TargetDriveBySerial = Invoke-Command -ComputerName $TargetVM -Credential $Credential -ArgumentList (, $CloneSerials) -ScriptBlock {
    param($serials)
    Update-HostStorageCache
    $found = @(Get-Disk | Where-Object { $null -ne $_.Number -and $serials -contains "$($_.SerialNumber)".Trim() })
    $result = @{}
    foreach ($disk in $found) {
        Set-Disk -Number $disk.Number -IsOffline $false
        Set-Disk -Number $disk.Number -IsReadOnly $false
        $partition = Get-Partition -DiskNumber $disk.Number | Where-Object Type -eq 'Basic' | Select-Object -First 1
        if (-not $partition.DriveLetter) {
            Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -AssignDriveLetter
            $partition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber
        }
        $result["$($disk.SerialNumber)".Trim()] = "$($partition.DriveLetter)"
    }
    $result
}
$TargetDriveBySerial



###
# Attach the databases on the target SQL Server

# Each file keeps its path, with the drive letter swapped for the letter the copy got on the target VM
foreach ($Database in $Databases) {
    $Files = $DbFiles | Where-Object { $_.Database -eq $Database } | ForEach-Object {
        $OldLetter = $_.PhysicalName.Substring(0, 1).ToUpper()
        $Clone     = $Clones | Where-Object { $_.Source.Serial -eq $SerialByDrive[$OldLetter] }
        $NewLetter = $TargetDriveBySerial[$Clone.Serial]
        "(FILENAME = N'$NewLetter$($_.PhysicalName.Substring(1))')"
    }
    $Query = "CREATE DATABASE [$Database$NewNameSuffix] ON $($Files -join ', ') FOR ATTACH"
    Invoke-DbaQuery -EnableException -SqlInstance $TargetSql -Database master -Query $Query
}



###
# The databases are online on the target after crash recovery.  Check them.
Get-DbaDbState -SqlInstance $TargetSql -Database ($Databases | ForEach-Object { "$_$NewNameSuffix" })



Disconnect-Pfa2Array -Array $FlashArray
