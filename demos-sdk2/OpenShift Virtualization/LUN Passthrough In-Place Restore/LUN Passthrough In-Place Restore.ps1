##############################################################################################################################
# LUN Passthrough In-Place Restore
#
# Scenario:
#    A SQL Server VM on OpenShift Virtualization keeps its database files on block-mode PersistentVolumeClaims.  Each PVC
#    is its own FlashArray volume (Portworx, backend pure_block) and is attached to the VM as a LUN passthrough disk, a KubeVirt lun disk,
#    so the guest sees the FlashArray volume itself and its serial number.
#    A FlashArray snapshot of those volumes was taken earlier (a restore point).  The databases have since been damaged
#    or changed, and you want them back as they were at the restore point, on the same VM, under the same names.
#
#    This script takes the databases offline, takes the disks offline in Windows, overwrites each FlashArray volume from
#    its snapshot, brings the disks and the databases back online.  Everything after the restore point is lost.
#
#    Nothing changes in OpenShift.  The PVCs, the VM disks, the disk serial numbers and the drive letters stay the same.
#    The volume is overwritten in place on the FlashArray, and the VM sees the same disk with the old contents.
#
#    You only name the VM, the databases and the FlashArray.  The script works out the rest by lookup:
#    database files -> Windows drive -> Windows disk serial number (it is the FlashArray volume's serial number)
#    -> FlashArray volume -> snapshot.
#
# Prerequisites:
#    1. PowerShell modules: dbatools and PureStoragePowerShellSDK2.
#    2. PowerShell remoting (WinRM) to the VM, and a SQL Server login that can take the databases offline.
#    3. Every disk that holds the listed databases is a block-mode PVC from the Portworx FlashArray storage class, attached to the VM as a
#       LUN passthrough disk (a lun disk on the SCSI bus), and those volumes are in a protection group.
#       A restore point is a snapshot of that group, so every volume shares one point in time (for example
#       New-Pfa2ProtectionGroupSnapshot -SourceName <group> -Suffix before-upgrade).
#    4. Nothing else uses those disks.  Every database with files on them must be listed below, or the restore fails.
#    5. Database files must be on drive letters (this script is written for drive letters and does not handle mount points).
#
# Disclaimer:
#    This example script is provided AS-IS and meant to be a building block to be adapted to fit an individual
#    organization's infrastructure.
#
#    _PLEASE_ do not save your passwords or tokens in cleartext here.
#    Use NTFS secured, encrypted files or whatever else -- never cleartext!
#
##############################################################################################################################

# Stop at the first error.  This script overwrites data, so never carry on after a failure.
$ErrorActionPreference = 'Stop'



# Import powershell modules
Import-Module PureStoragePowerShellSDK2
Import-Module dbatools



# Declare all variables
$ArrayName         = 'flasharray1.example.com'        # FlashArray FQDN

$SqlVM             = 'sql_vm'                         # Not FQDN
$SqlServer         = 'sql_vm.example.com'
$Databases         = @('AdventureWorks', 'WideWorldImporters')
$ProtectionGroupName = 'sql-restore-pg'               # The protection group whose snapshots are the restore points
$SnapshotSuffix    = ''                               # The restore point, for example 'before-upgrade'.  Empty means the newest one.



# Get Credentials - this example assumes the same credential for the FlashArray and the VM
$Credential = Get-Credential -UserName "$env:USERNAME" -Message 'Enter your credential information...'



# Connect to everything
$FlashArray    = Connect-Pfa2Array -Endpoint $ArrayName -Credential $Credential -IgnoreCertificateError
$Sql           = Connect-DbaInstance -SqlInstance $SqlServer -TrustServerCertificate




###
# Look up the volumes and the restore point

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
$Volumes = @(Get-Pfa2Volume -Array $FlashArray | Where-Object { $SerialByDrive.Values -contains $_.Serial -and -not $_.Destroyed })
if ($Volumes.Count -ne @($SerialByDrive.Values | Select-Object -Unique).Count) { throw 'A database disk is not a FlashArray volume.  This script is for LUN passthrough disks.' }




$PgName    = $ProtectionGroupName



# Pick the restore point.  A protection group snapshot is named "<group>.<suffix>" and holds one snapshot per volume, named
# "<group>.<suffix>.<volume>".
$PgSnapshots = @(Get-Pfa2ProtectionGroupSnapshot -Array $FlashArray -SourceName $PgName | Where-Object { -not $_.Destroyed } | Sort-Object Created -Descending)
if ($PgSnapshots.Count -eq 0) { throw "Protection group $PgName has no snapshot to restore from." }
if ($SnapshotSuffix -eq '') { $SnapshotSuffix = $PgSnapshots[0].Suffix }
foreach ($Volume in $Volumes) {
    if (-not (Get-Pfa2VolumeSnapshot -Array $FlashArray -Name "$PgName.$SnapshotSuffix.$($Volume.Name)")) { throw "Volume $($Volume.Name) has no snapshot in protection group snapshot $PgName.$SnapshotSuffix" }
}
"Restoring $($Volumes.Name -join ', ') to protection group snapshot $PgName.$SnapshotSuffix"



###
# Take the databases and disks offline

foreach ($Database in $Databases) {
    Invoke-DbaQuery -EnableException -SqlInstance $Sql -Database master -Query "ALTER DATABASE [$Database] SET OFFLINE WITH ROLLBACK IMMEDIATE"
}

Invoke-Command -ComputerName $SqlVM -Credential $Credential -ArgumentList (, @($SerialByDrive.Values)) -ScriptBlock {
    param($serials)
    foreach ($disk in (Get-Disk | Where-Object { $null -ne $_.Number -and $serials -contains "$($_.SerialNumber)".Trim().ToUpper() })) {
        Set-Disk -Number $disk.Number -IsOffline $true
    }
}



###
# Restore: overwrite each FlashArray volume from its snapshot.  The volume keeps its name, serial number and connections.
foreach ($Volume in $Volumes) {
    New-Pfa2Volume -Array $FlashArray -Name $Volume.Name -SourceName "$PgName.$SnapshotSuffix.$($Volume.Name)" -Overwrite $true
}



###
# Bring the disks and the databases back online

Invoke-Command -ComputerName $SqlVM -Credential $Credential -ArgumentList (, @($SerialByDrive.Values)) -ScriptBlock {
    param($serials)
    Update-HostStorageCache
    foreach ($disk in (Get-Disk | Where-Object { $null -ne $_.Number -and $serials -contains "$($_.SerialNumber)".Trim().ToUpper() })) {
        Set-Disk -Number $disk.Number -IsOffline $false
    }
}

foreach ($Database in $Databases) {
    Invoke-DbaQuery -EnableException -SqlInstance $Sql -Database master -Query "ALTER DATABASE [$Database] SET ONLINE"
}



###
# The databases are back at the restore point.  Check them.
Get-DbaDbState -SqlInstance $Sql -Database $Databases



Disconnect-Pfa2Array -Array $FlashArray
