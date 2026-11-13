##############################################################################################################################
# VMFS-VMDK In-Place Restore
#
# Scenario:
#    A SQL Server VM keeps its database files on VMDKs in a VMFS datastore, which is one FlashArray volume.  Something went
#    wrong (corruption, a bad release, a mistaken delete) and you want those databases back exactly as they were when an
#    earlier FlashArray snapshot of the volume was taken.
#
#    The obvious way is to unmount the datastore and overwrite the FlashArray volume from the snapshot.  That can fail: a datastore
#    that vSphere HA uses for heartbeating cannot be unmounted ("cannot be unmounted. Reason: Busy"), and neither can one that other
#    VMDKs or VMs are still using.  Whether it fails depends on how HA heartbeat datastores are configured in the cluster.  This script
#    does not unmount anything, so it does not depend on that.  It clones the snapshot as a temporary
#    volume and datastore, swaps the database VMDKs on the VM for the copies, Storage vMotions them back onto the original
#    datastore, and removes the temporary clone.  The original datastore, its name and its FlashArray volume stay as they were.
#
#    The CURRENT database VMDKs are deleted.  If you might want today's data back, take a FlashArray snapshot of the volume first.
#
#    Only the VMDKs that hold the listed databases are touched.  Other VMDKs on the same datastore (for example tempdb) stay.
#    The snapshot is whatever FlashArray snapshot of the volume you choose, so the restore is as consistent as that snapshot was.
#    A crash-consistent snapshot means each database performs crash recovery when it comes online.
#
#    You name the VM, the databases, the vCenter and the FlashArray.  The script works out the rest by lookup:
#    database files -> Windows drive -> Windows disk serial number -> VMDK (the serial is the VMDK's UUID)
#    -> datastore -> FlashArray volume -> FlashArray host group.
#
# Prerequisites:
#    1. PowerShell modules: dbatools, PureStoragePowerShellSDK2 and VMware PowerCLI.
#    2. PowerShell remoting (WinRM) to the VM, and a SQL Server login that can take databases offline and online.
#    3. All of the databases listed below must sit on VMDKs in ONE datastore, which is ONE FlashArray volume.
#    4. At least one FlashArray snapshot of the volume exists (by default the newest one is used).
#    5. Database files must be on drive letters (this script is written for drive letters and does not handle mount points).
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
$VIServerName    = 'vcenter.example.com'
$ArrayName       = 'flasharray1.example.com'          # FlashArray FQDN

$SQLVM           = 'sql_vm'                           # Not FQDN
$SQLServer       = 'sql_vm.example.com'
$Databases       = @('AdventureWorks', 'WideWorldImporters')
$SnapshotName    = ''                                 # Blank = the newest snapshot of the volume.  Otherwise the full name, e.g. 'volume_name.snapshot1'



# Get Credentials - this example assumes the same credential for vCenter, the FlashArray and the VM
$Credential = Get-Credential -UserName "$env:USERNAME" -Message 'Enter your credential information...'



# Connect to everything
$VIServer     = Connect-VIServer -Server $VIServerName -Protocol https -Credential $Credential
$FlashArray   = Connect-Pfa2Array -Endpoint $ArrayName -Credential $Credential -IgnoreCertificateError
$Sql          = Connect-DbaInstance -SqlInstance $SQLServer -TrustServerCertificate
$SQLVMObject  = Get-VM -Name $SQLVM
$ESXiHost     = Get-VMHost -VM $SQLVMObject



###
# Look up where the database files live

# Every data and log file of the databases, as SQL Server sees them
$DbFiles = Get-DbaDbFile -SqlInstance $Sql -Database $Databases
$DbFiles | Select-Object Database, TypeDescription, PhysicalName



# For each drive letter in use, ask Windows which disk it is on.  The disk serial number is the VMDK's UUID.
$DriveLetters = $DbFiles.PhysicalName | ForEach-Object { $_.Substring(0, 1).ToUpper() } | Select-Object -Unique

$SerialByDrive = Invoke-Command -ComputerName $SQLVM -Credential $Credential -ArgumentList (, $DriveLetters) -ScriptBlock {
    param($letters)
    $map = @{}
    foreach ($letter in $letters) {
        $map[$letter] = (Get-Partition -DriveLetter $letter | Get-Disk).SerialNumber.ToLower()
    }
    $map
}
$SerialByDrive



# Find those VMDKs in vSphere: the VMDK's backing UUID, without dashes, is the Windows disk serial number
$SourceDisks = Get-HardDisk -VM $SQLVMObject -DiskType Flat | Where-Object { # An RDM has no VMDK UUID, so only look at VMDKs
    $SerialByDrive.Values -contains $_.ExtensionData.Backing.Uuid.Replace('-', '').ToLower()
}
$SourceDisks | Select-Object Filename, CapacityGB

# The VMDK file names look like "[datastore name] folder/file.vmdk".  Remember the relative paths, the copies have the same ones.
$DatastoreName = ($SourceDisks.Filename | ForEach-Object { ($_ -split '\]')[0].TrimStart('[') } | Select-Object -Unique)
if (@($DatastoreName).Count -ne 1) { throw "The database disks are in more than one datastore: $($DatastoreName -join ', ')" }
$RelativePaths = $SourceDisks.Filename | ForEach-Object { ($_ -split '\] ', 2)[1] }



# Look up the FlashArray volume behind the datastore, and the host group it is connected to
# The datastore's LUN is named naa.624a9370 followed by the FlashArray volume's serial number.  624a9370 is Pure Storage's vendor ID, so the prefix is the same on every FlashArray and would be different on another vendor's array.
$Datastore    = Get-Datastore -Name $DatastoreName
$LunName      = $Datastore.ExtensionData.Info.Vmfs.Extent[0].DiskName
$VolumeSerial = $LunName.Substring('naa.624a9370'.Length).ToUpper()
$Volume       = Get-Pfa2Volume -Array $FlashArray | Where-Object { $_.Serial -eq $VolumeSerial }
# NOTE: do not pipe FlashArray cmdlets into Select-Object -First.  In Windows PowerShell 5.1 it can end the whole script silently.
$Connections  = @(Get-Pfa2Connection -Array $FlashArray -VolumeNames $Volume.Name | Where-Object { $_.HostGroup.Name })
$FAHostGroup  = $Connections[0].HostGroup.Name
"Datastore $DatastoreName is FlashArray volume $($Volume.Name), connected to host group $FAHostGroup"



# Choose the snapshot to restore
$Snapshots = @(Get-Pfa2VolumeSnapshot -Array $FlashArray -SourceNames $Volume.Name | Sort-Object Created -Descending)
$Snapshots | Select-Object Name, Created
if ($SnapshotName) { $Snapshot = $Snapshots | Where-Object { $_.Name -eq $SnapshotName } } else { $Snapshot = $Snapshots[0] }
if (-not $Snapshot) { throw "No snapshot found for volume $($Volume.Name)" }
"Restoring from snapshot $($Snapshot.Name), taken $($Snapshot.Created)"



###
# Clone the snapshot and present it

# Create a temporary volume from the snapshot and present it to the ESXi host
$CloneName = "$($Volume.Name)-restore-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
$Clone     = New-Pfa2Volume -Array $FlashArray -Name $CloneName -SourceName $Snapshot.Name
New-Pfa2Connection -Array $FlashArray -HostGroupNames $FAHostGroup -VolumeNames $CloneName



# The ESXi host must now rescan storage
Get-VMHostStorage -RescanAllHba -VMHost $ESXiHost



# Resignature the cloned datastore.  The copy has the same label as the original datastore, so name it exactly.
# NOTE: after a datastore is resignatured, its name will be "snap-[GUID chars]-[original DS name]"
$esxcli = Get-EsxCli -VMHost $ESXiHost -V2
$esxcli.storage.vmfs.snapshot.resignature.Invoke(@{ volumelabel = $DatastoreName })



# Rescan again so the host sees the new datastore, then wait for it to appear
Get-VMHostStorage -RescanVmfs -VMHost $ESXiHost

# The copied datastore can take a little while to appear.  Wait until it is listed, running this until it is, then continue.
Get-Datastore | Where-Object { $_.Name -like "snap-*-$DatastoreName" }
$ClonedDatastore = Get-Datastore | Where-Object { $_.Name -like "snap-*-$DatastoreName" } | Sort-Object Name | Select-Object -Last 1
$ClonedDatastore



###
# Swap the database VMDKs

# Offline the databases, rolling back anything open
foreach ($Database in $Databases) {
    Invoke-DbaQuery -EnableException -SqlInstance $Sql -Database master -Query "ALTER DATABASE [$Database] SET OFFLINE WITH ROLLBACK IMMEDIATE"
}



# Offline the disks in Windows
Invoke-Command -ComputerName $SQLVM -Credential $Credential -ArgumentList (, @($SerialByDrive.Values)) -ScriptBlock {
    param($serials)
    foreach ($disk in (Get-Disk | Where-Object { $serials -contains "$($_.SerialNumber)".ToLower() })) {
        Set-Disk -Number $disk.Number -IsOffline $true
    }
}



# Remove the current database VMDKs from the VM and delete them.  THIS DESTROYS TODAY'S DATA.
$SourceDisks | Remove-HardDisk -DeletePermanently -Confirm:$false



# Attach the VMDKs from the cloned datastore.  They have the same UUIDs as the ones just removed, so to Windows
# they are the same disks coming back and the volumes keep their drive letters.
foreach ($RelativePath in $RelativePaths) {
    New-HardDisk -VM $SQLVMObject -DiskPath "[$($ClonedDatastore.Name)] $RelativePath"
}



# Online the disks in Windows
# The new disks can take a while to appear in Windows.  Wait until every new disk is listed, running this until it is, then continue.
Invoke-Command -ComputerName $SQLVM -Credential $Credential -ScriptBlock { Update-HostStorageCache; Get-Disk | Select-Object Number, SerialNumber, IsOffline, Size }

Invoke-Command -ComputerName $SQLVM -Credential $Credential -ArgumentList (, @($SerialByDrive.Values)) -ScriptBlock {
    param($serials)
    Update-HostStorageCache
    $found = @(Get-Disk | Where-Object { $serials -contains "$($_.SerialNumber)".ToLower() })
    foreach ($disk in $found) {
        Set-Disk -Number $disk.Number -IsOffline $false
        Set-Disk -Number $disk.Number -IsReadOnly $false
    }
}



# Online the databases.  With a crash-consistent snapshot each one performs crash recovery now.
foreach ($Database in $Databases) {
    Invoke-DbaQuery -EnableException -SqlInstance $Sql -Database master -Query "ALTER DATABASE [$Database] SET ONLINE"
}



###
# The databases are back to the snapshot's state and online.  Check them.
Get-DbaDbState -SqlInstance $Sql -Database $Databases



###
# Move the VMDKs back to the original datastore and remove the temporary clone

# Storage vMotion the restored VMDKs onto the original datastore, while the databases stay online
foreach ($Disk in (Get-HardDisk -VM $SQLVMObject | Where-Object { $_.Filename -like "[[]$($ClonedDatastore.Name)]*" })) {
    Move-HardDisk -HardDisk $Disk -Datastore $Datastore -Confirm:$false
}



# Remove the cloned datastore, then detach its LUN so the host does not report dead paths
Remove-Datastore -Datastore $ClonedDatastore -VMHost $ESXiHost -Confirm:$false

# naa.624a9370 is Pure Storage's vendor ID followed by the volume's serial number, as explained above.
$CloneLun = 'naa.624a9370' + $Clone.Serial.ToLower()
(Get-EsxCli -VMHost $ESXiHost -V2).storage.core.device.set.Invoke(@{ device = $CloneLun; state = 'off' })



# On the FlashArray, disconnect and destroy the temporary volume.  The snapshot you restored from is kept.
Remove-Pfa2Connection -Array $FlashArray -HostGroupNames $FAHostGroup -VolumeNames $CloneName
Remove-Pfa2Volume -Array $FlashArray -Name $CloneName



# Rescan so the host forgets the detached LUN
Get-VMHostStorage -RescanAllHba -VMHost $ESXiHost

Disconnect-Pfa2Array -Array $FlashArray
