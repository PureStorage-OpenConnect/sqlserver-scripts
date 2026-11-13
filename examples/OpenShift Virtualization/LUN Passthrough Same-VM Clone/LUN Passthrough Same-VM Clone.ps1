##############################################################################################################################
# LUN Passthrough Same-VM Clone
#
# Scenario:
#    A SQL Server VM on OpenShift Virtualization keeps its database files on block-mode PersistentVolumeClaims.  Each PVC
#    is its own FlashArray volume (Portworx, backend pure_block) and is attached to the VM as a LUN passthrough disk, a KubeVirt lun disk,
#    so the guest sees the FlashArray volume itself and its serial number.
#    You want a copy of those databases on the SAME SQL Server instance, for example to test a change or to pull back
#    a table that was deleted by mistake.
#
#    This script takes one crash-consistent snapshot of every FlashArray volume that holds the databases, clones each
#    snapshot as a new FlashArray volume, imports each clone into OpenShift as a PVC and hot-plugs the PVCs into the same VM as
#    new disks.  The databases are then attached on the same SQL Server under new names.
#
#    The problem this script solves: a copy of a disk has the same disk GUID as the original.  Windows hides a copy
#    like that, keeps it offline and write-protected, and at the next reboot it can take the production disk offline
#    instead.  The fix is to give each copy a new disk GUID BEFORE it is onlined.  The copy is a new FlashArray volume and a new
#    PVC, so it already has its own serial number.
#
#    The source databases stay online throughout.  The snapshot is crash-consistent: SQL Server write IO is NOT
#    frozen, so each copy performs crash recovery when it is attached.
#
#    You only name the VM, the databases, the OpenShift project and the FlashArray.  The script works out the rest by lookup:
#    database files -> Windows drive -> Windows disk serial number (it is the FlashArray volume's serial number)
#    -> FlashArray volume -> PVC.
#
# Prerequisites:
#    1. PowerShell modules: dbatools and PureStoragePowerShellSDK2.
#    2. PowerShell remoting (WinRM) to the VM, and a SQL Server login that can attach databases.
#    3. An OpenShift API token for an account that can read and change VMs and PVCs in the project (the oc login token).
#    4. Every disk that holds the listed databases is a block-mode PVC from the Portworx FlashArray storage class, attached to the VM as a
#       LUN passthrough disk (a lun disk on the SCSI bus).  Every one of those volumes is snapshotted together, and every one is copied.
#    5. The VM can hot-plug disks, and has free drive letters for the copies.
#    6. Database files must be on drive letters (this script is written for drive letters and does not handle mount points), and the copies must not exist yet.
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
$Namespace         = 'sql-project'                    # OpenShift project that holds the VM
$ArrayName         = 'flasharray1.example.com'        # FlashArray FQDN

$SqlVM            = 'sql_vm'                         # Not FQDN.  Also the name of the VirtualMachine object
$SqlServer        = 'sql_vm.example.com'
$Databases         = @('AdventureWorks', 'WideWorldImporters')
$ProtectionGroupName = 'sql-clone-pg'                # Made by this script the first run and reused, see "Protection group"
$NewNameSuffix     = '_copy'                          # Databases are attached as AdventureWorks_copy, ...
$StorageClass      = 'flasharray-sc'                  # The Portworx FlashArray storage class that the source PVCs use



# Get Credentials - this example assumes the same credential for the FlashArray and the VM
$Credential = Get-Credential -UserName "$env:USERNAME" -Message 'Enter your credential information...'
$OpenShiftToken = Read-Host -Prompt 'OpenShift API token' -AsSecureString



# Connect to everything
$FlashArray    = Connect-Pfa2Array -Endpoint $ArrayName -Credential $Credential -IgnoreCertificateError
$Sql          = Connect-DbaInstance -SqlInstance $SqlServer -TrustServerCertificate

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
$DbFiles = Get-DbaDbFile -SqlInstance $Sql -Database $Databases
$DbFiles | Select-Object Database, TypeDescription, PhysicalName



# For each drive letter in use, ask Windows on the VM which disk it is on.  For a LUN passthrough disk the disk serial number is the
# FlashArray volume's serial number.
$DriveLetters = $DbFiles.PhysicalName | ForEach-Object { $_.Substring(0, 1).ToUpper() } | Select-Object -Unique

$SerialByDrive = Invoke-Command -ComputerName $SqlVM -Credential $Credential -ArgumentList (, $DriveLetters) -ScriptBlock {
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
    $Clones   += [pscustomobject]@{ Source = $Disk; ArrayName = $Clone.Name; PvcName = "$($Disk.Pvc)-c$Stamp"; Serial = $Clone.Serial }
}
$Clones | Select-Object @{ n = 'Source'; e = { $_.Source.Pvc } }, ArrayName, PvcName, Serial



###
# Import the clones into OpenShift and attach them to the VM

# A PVC with the annotation pure_vol_name makes Portworx use the existing FlashArray volume instead of creating a new empty one.
# The PVC size has to match the size of the volume.  The PVC binds when the VM first uses it.
foreach ($Clone in $Clones) {
    $null = Invoke-OpenShift POST "/api/v1/namespaces/$Namespace/persistentvolumeclaims" @{
        apiVersion = 'v1'; kind = 'PersistentVolumeClaim'
        metadata   = @{ name = $Clone.PvcName; annotations = @{ pure_vol_name = $Clone.ArrayName } }
        spec       = @{ accessModes = @('ReadWriteMany'); volumeMode = 'Block'; storageClassName = $StorageClass; resources = @{ requests = @{ storage = $Clone.Source.Size } } }
    }
}



# Hot-plug each PVC into the running VM as a LUN passthrough disk.  The guest finds it again by its FlashArray serial number.
foreach ($Clone in $Clones) {
    $null = Invoke-OpenShift PUT "/apis/subresources.kubevirt.io/v1/namespaces/$Namespace/virtualmachines/$SqlVM/addvolume" @{
        name         = $Clone.PvcName
        disk         = @{ lun = @{ bus = 'scsi' } }
        volumeSource = @{ persistentVolumeClaim = @{ claimName = $Clone.PvcName; hotpluggable = $true } }
    }
    Start-Sleep -Seconds 10   # OpenShift handles one hot-plug request at a time, so give it a moment before the next one
}

# Wait until OpenShift reports every new disk as Ready, running this until it does, then continue.
(Invoke-OpenShift GET "/apis/kubevirt.io/v1/namespaces/$Namespace/virtualmachineinstances/$SqlVM").status.volumeStatus | Where-Object { $_.hotplugVolume } | Select-Object name, phase, target



# The copies arrive in Windows offline.  Find them by serial number.  For each one, give it a new disk GUID while it is still offline,
# then make it writable and online it.  The partition gets the next free drive letter, because the original still has its letter.
$CloneSerials = @($Clones.Serial)
# The new disks can take a while to appear in Windows.  Wait until every new disk is listed, running this until it is, then continue.
Invoke-Command -ComputerName $SqlVM -Credential $Credential -ScriptBlock { Update-HostStorageCache; Get-Disk | Select-Object Number, SerialNumber, IsOffline, Size }

$DriveBySerial = Invoke-Command -ComputerName $SqlVM -Credential $Credential -ArgumentList (, $CloneSerials) -ScriptBlock {
    param($serials)
    Update-HostStorageCache
    $found = @(Get-Disk | Where-Object { $null -ne $_.Number -and $serials -contains "$($_.SerialNumber)".Trim().ToUpper() })
    $result = @{}
    foreach ($disk in $found) {
        Set-Content -Path "$env:TEMP\online.txt" -Value "select disk $($disk.Number)`r`nattributes disk clear readonly`r`nuniqueid disk id=$([guid]::NewGuid())`r`nonline disk"
        diskpart /s "$env:TEMP\online.txt" | Out-Null
        $partition = Get-Partition -DiskNumber $disk.Number | Where-Object Type -eq 'Basic' | Select-Object -First 1
        if (-not $partition.DriveLetter) {
            Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -AssignDriveLetter
            $partition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber
        }
        $result["$($disk.SerialNumber)".Trim().ToUpper()] = "$($partition.DriveLetter)"
    }
    $result
}
$DriveBySerial



###
# Attach the databases

# Each file keeps its path, with the drive letter swapped for the letter the copy got
foreach ($Database in $Databases) {
    $Files = $DbFiles | Where-Object { $_.Database -eq $Database } | ForEach-Object {
        $OldLetter = $_.PhysicalName.Substring(0, 1).ToUpper()
        $Clone     = $Clones | Where-Object { $_.Source.Serial -eq $SerialByDrive[$OldLetter] }
        $NewLetter = $DriveBySerial[$Clone.Serial]
        "(FILENAME = N'$NewLetter$($_.PhysicalName.Substring(1))')"
    }
    $Query = "CREATE DATABASE [$Database$NewNameSuffix] ON $($Files -join ', ') FOR ATTACH"
    Invoke-DbaQuery -EnableException -SqlInstance $Sql -Database master -Query $Query
}



###
# The databases are online after crash recovery.  Check them.
Get-DbaDbState -SqlInstance $Sql -Database ($Databases | ForEach-Object { "$_$NewNameSuffix" })



Disconnect-Pfa2Array -Array $FlashArray
