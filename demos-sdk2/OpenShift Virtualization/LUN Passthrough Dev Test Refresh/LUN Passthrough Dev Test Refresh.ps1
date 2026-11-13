##############################################################################################################################
# LUN Passthrough Dev Test Refresh
#
# Scenario:
#    A production SQL Server VM (the source) on OpenShift Virtualization keeps its database files on block-mode PersistentVolumeClaims.
#    Each PVC is its own FlashArray volume (Portworx, backend pure_block) and is attached to the VM as a LUN passthrough disk, a KubeVirt lun disk,
#    so the guest sees the FlashArray volume itself and its serial number.  A non-production
#    SQL Server VM (the target) needs a fresh copy of those databases on a schedule, for example every night.  This script can be run
#    again and again.  Each run removes the copy the previous run made and makes a new one.
#
#    A run takes one crash-consistent snapshot of every source volume, clones each as a new FlashArray volume, imports each clone
#    into OpenShift as a PVC, hot-plugs the PVCs into the target VM and attaches the databases there.  The source stays online.
#    SQL Server write IO is NOT frozen, so each database on the target performs crash recovery when it is attached.
#
#    The copy is easy to find next time because it has stable names: each clone PVC and FlashArray volume is called
#    <source PVC>-devtest, the databases are called
#    <database><suffix>, and the snapshots have a "devtest-" suffix.  The previous copy is removed first, in an order that leaves
#    no stale disk, PVC, volume or snapshot behind.
#
#    You only name the VMs, the databases, the OpenShift project and the FlashArray.  The script works out the rest by lookup:
#    database files -> Windows drive -> Windows disk serial number (it is the FlashArray volume's serial number)
#    -> FlashArray volume -> PVC.
#
# Prerequisites:
#    1. PowerShell modules: dbatools and PureStoragePowerShellSDK2.
#    2. PowerShell remoting (WinRM) to both VMs, and a SQL Server login that can attach and drop databases on the target.
#    3. An OpenShift API token for an account that can read and change VMs and PVCs in the project (the oc login token).
#    4. Every disk that holds the listed databases is a block-mode PVC from the Portworx FlashArray storage class, attached to the source
#       VM as a LUN passthrough disk (a lun disk on the SCSI bus).
#    5. The target VM must be a different VM from the source VM.  It runs in the same project and can hot-plug disks.
#    6. Database files must be on drive letters (this script is written for drive letters and does not handle mount points).
#
# To remove the copy without making a new one, run only the section "Remove the previous copy".
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
$ProtectionGroupName = 'sql-devtest-pg'              # Made by this script the first run and reused, see "Protection group"
$NewNameSuffix     = '_dev'                           # Databases are attached on the target as AdventureWorks_dev, ...
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



# For each drive letter in use, ask Windows on the VM which disk it is on.  For a LUN passthrough disk the disk serial number is the
# FlashArray volume's serial number.
$DriveLetters = $DbFiles.PhysicalName | ForEach-Object { $_.Substring(0, 1).ToUpper() } | Select-Object -Unique

$SerialByDrive = Invoke-Command -ComputerName $SourceVM -Credential $Credential -ArgumentList (, $DriveLetters) -ScriptBlock {
    param($letters)
    $map = @{}
    foreach ($letter in $letters) {
        $map[$letter] = "$((Get-Partition -DriveLetter $letter | Get-Disk).SerialNumber)".Trim().ToUpper()
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
# Remove the previous copy
# The copy from the previous run is the PVCs called <source PVC>-devtest, attached to the target VM.  If they are there, they are removed
# in the reverse order of how they were made.  On the first run there is nothing to remove.

$TargetVMObject = Invoke-OpenShift GET "/apis/kubevirt.io/v1/namespaces/$Namespace/virtualmachines/$TargetVM"
$PreviousPvcs   = @($TargetVMObject.spec.template.spec.volumes | Where-Object { $_.persistentVolumeClaim.claimName -like '*-devtest' } | ForEach-Object { $_.persistentVolumeClaim.claimName })
$PreviousDisks  = @($TargetVMObject.spec.template.spec.volumes | Where-Object { $_.persistentVolumeClaim.claimName -like '*-devtest' })

if ($PreviousDisks.Count -gt 0) {
    # The guest reports the FlashArray serial number of each disk, so the serial numbers of the old clone volumes find them in Windows.
    $PreviousSerials = @($PreviousPvcs | ForEach-Object { (Get-Pfa2Volume -Array $FlashArray -Name $_).Serial })
    # Drop the databases on the target.  Remove-DbaDatabase closes any open sessions first.
    Get-DbaDatabase -SqlInstance $TargetSql -Database ($Databases | ForEach-Object { "$_$NewNameSuffix" }) | Remove-DbaDatabase -Confirm:$false -EnableException

    # Offline the copied disks in Windows.  diskpart only touches this machine's own disks.
    Invoke-Command -ComputerName $TargetVM -Credential $Credential -ArgumentList (, $PreviousSerials) -ScriptBlock {
        param($serials)
        foreach ($disk in (Get-Disk | Where-Object { $null -ne $_.Number -and $serials -contains "$($_.SerialNumber)".Trim().ToUpper() })) {
            Set-Disk -Number $disk.Number -IsOffline $true
        }
    }

    # Detach the old clones' disks from the running target VM, then delete their PVCs.  Deleting a PVC from this storage class also deletes
    # and eradicates the FlashArray volume behind it, so a nightly refresh does not pile up copies on the array.

    # Take the disks out in the reverse of the order they were attached.  Asked to remove a LUN passthrough disk that is not the last one attached,
    # OpenShift Virtualization (seen on KubeVirt 1.7.4) detaches the last one instead.  The disk's target (sdd, sde, ...) gives the attach order.
    $Targets = @{}
    foreach ($Volume in (Invoke-OpenShift GET "/apis/kubevirt.io/v1/namespaces/$Namespace/virtualmachineinstances/$TargetVM").status.volumeStatus) { $Targets[$Volume.name] = "$($Volume.target)" }
    foreach ($Name in @($PreviousDisks.name | Sort-Object { $Targets[$_].Length }, { $Targets[$_] } -Descending)) {
        $null = Invoke-OpenShift PUT "/apis/subresources.kubevirt.io/v1/namespaces/$Namespace/virtualmachines/$TargetVM/removevolume" @{ name = $Name }
        # OpenShift takes one disk out of a running VM at a time.  Wait until this disk has left the VM, running this until it is no longer listed.
        (Invoke-OpenShift GET "/apis/kubevirt.io/v1/namespaces/$Namespace/virtualmachineinstances/$TargetVM").status.volumeStatus | Where-Object { $_.name -eq $Name } | Select-Object name, phase
        Read-Host -Prompt 'Press Enter when the disk has left the VM' | Out-Null
    }
    foreach ($Name in $PreviousPvcs) {
        $null = Invoke-OpenShift DELETE "/api/v1/namespaces/$Namespace/persistentvolumeclaims/$Name"
    }

    # The PVC can be gone before its FlashArray volume is.  The new clones get the same names, and a clone cannot take the name until the old
    # volume is gone, which can take minutes.  Wait until nothing is listed, running this until it is.
    $PreviousPvcs | ForEach-Object { Get-Pfa2Volume -Array $FlashArray -Filter "name='$_'" -ErrorAction SilentlyContinue }
    Read-Host -Prompt 'Press Enter when the old volumes are gone' | Out-Null

    # The previous run's protection group snapshots.  The protection group itself stays, the next run reuses it.
    foreach ($OldSnapshot in @(Get-Pfa2ProtectionGroupSnapshot -Array $FlashArray -SourceName $PgName | Where-Object { $_.Suffix -like 'devtest-*' -and -not $_.Destroyed })) {
        Remove-Pfa2ProtectionGroupSnapshot -Array $FlashArray -Name $OldSnapshot.Name
        Remove-Pfa2ProtectionGroupSnapshot -Array $FlashArray -Name $OldSnapshot.Name -Eradicate -Confirm:$false
    }
}



###
# Protection group
# A protection group snapshot snapshots every volume in the group at the same moment.  That is how the database disks, one volume
# each, get one shared point in time.  This section makes the group the first time and leaves it in place for the runs after.
# If you already have a protection group that holds these volumes, comment out this section and set $PgName to that group.
# Every volume in the group is snapshotted, not only the source volumes.

if (-not @(Get-Pfa2ProtectionGroup -Array $FlashArray -Filter "name='$PgName'")) {
    New-Pfa2ProtectionGroup -Array $FlashArray -Name $PgName
    New-Pfa2ProtectionGroupVolume -Array $FlashArray -GroupName $PgName -MemberName $SourceVolumes.Name
}



###
# Snapshot and clone

# Take a crash-consistent snapshot of the protection group, so every source volume shares the same point in time.
# The source database stays online.
$Stamp      = (Get-Date).ToString('MMddHHmmss')
$PgSnapshot = New-Pfa2ProtectionGroupSnapshot -Array $FlashArray -SourceName $PgName -Suffix "devtest-$Stamp"

# The protection group snapshot holds one snapshot per volume, named <group>.<suffix>.<volume>.  Pick out the source volumes' snapshots.
# This stops with an error if the group does not hold one of the source volumes.
$Snapshots  = @(foreach ($Volume in $SourceVolumes) { Get-Pfa2VolumeSnapshot -Array $FlashArray -Name "$($PgSnapshot.Name).$($Volume.Name)" })
$Snapshots | Select-Object Name, Created



# Create a new FlashArray volume from each snapshot.  The clone keeps the size, the partition table and the file system of its source.
$Clones = @()
foreach ($Disk in $SourceDisks) {
    $Snapshot  = $Snapshots | Where-Object { $_.Name -like "*.$($Disk.Volume.Name)" }
    $Clone     = New-Pfa2Volume -Array $FlashArray -Name "$($Disk.Pvc)-devtest" -SourceName $Snapshot.Name
    $Clones   += [pscustomobject]@{ Source = $Disk; ArrayName = $Clone.Name; PvcName = "$($Disk.Pvc)-devtest"; Serial = $Clone.Serial }
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



# Hot-plug each PVC into the running target VM as a LUN passthrough disk.  The guest finds it again by its FlashArray serial number.
foreach ($Clone in $Clones) {
    $null = Invoke-OpenShift PUT "/apis/subresources.kubevirt.io/v1/namespaces/$Namespace/virtualmachines/$TargetVM/addvolume" @{
        name         = $Clone.PvcName
        disk         = @{ lun = @{ bus = 'scsi' } }
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
    $found = @(Get-Disk | Where-Object { $null -ne $_.Number -and $serials -contains "$($_.SerialNumber)".Trim().ToUpper() })
    $result = @{}
    foreach ($disk in $found) {
        Set-Disk -Number $disk.Number -IsOffline $false
        Set-Disk -Number $disk.Number -IsReadOnly $false
        $partition = Get-Partition -DiskNumber $disk.Number | Where-Object Type -eq 'Basic' | Select-Object -First 1
        if (-not $partition.DriveLetter) {
            Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -AssignDriveLetter
            $partition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber
        }
        $result["$($disk.SerialNumber)".Trim().ToUpper()] = "$($partition.DriveLetter)"
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
