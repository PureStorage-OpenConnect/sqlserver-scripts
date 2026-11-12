##############################################################################################################################
# VMFS-VMDK Dev Test Refresh
#
# Scenario:
#    A production SQL Server VM (the source) keeps its database files on VMDKs in a VMFS datastore, which is one FlashArray
#    volume.  A non-production SQL Server VM (the target) needs a fresh copy of those databases on a schedule, for example every
#    night.  This script can be run again and again.  Each run removes the copy the previous run made and makes a new one.
#
#    A run takes a crash-consistent snapshot of the source datastore's FlashArray volume, clones it, presents it to the ESXi host,
#    resignatures the copy, hot-adds the VMDKs that hold the databases to the target VM, and attaches the databases there.  The source
#    stays online.  SQL Server write IO is NOT frozen, so each database on the target performs crash recovery when it is attached.
#
#    The copy is easy to find next time because it has stable names: the datastore is called <source datastore>-devtest, the
#    databases are called <database><suffix>, and the snapshots have a "devtest-" suffix.  The previous copy is removed first, in an order
#    that leaves no stale disk, datastore, path, volume or snapshot behind.
#
#    You only name the VMs, the databases and the vCenter and FlashArray.  The script works out the rest by lookup:
#    database files -> Windows drive -> Windows disk serial number -> VMDK (the serial is the VMDK's UUID)
#    -> datastore -> FlashArray volume -> FlashArray host group.
#
# Prerequisites:
#    1. PowerShell modules: dbatools, PureStoragePowerShellSDK2 and VMware PowerCLI.
#    2. PowerShell remoting (WinRM) to both VMs, and a SQL Server login that can attach and drop databases on the target.
#    3. All of the databases listed below must sit on VMDKs in ONE datastore, which is ONE FlashArray volume.
#    4. The target VM must be a different VM from the source VM, and have free SCSI slots for hot-adding disks.
#    5. Database files must be on drive letters (this script is written for drive letters and does not handle mount points).
#
# To remove the copy without making a new one, run only the section "Remove the previous copy".
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

$SourceVM          = 'source_vm'                      # Not FQDN
$TargetVM          = 'target_vm'                      # Not FQDN
$SourceSQLServer   = 'source_vm.example.com'
$TargetSQLServer   = 'target_vm.example.com'
$Databases         = @('AdventureWorks', 'WideWorldImporters')
$NewNameSuffix     = '_dev'                           # Databases are attached on the target as AdventureWorks_dev, ...



# Get Credentials - this example assumes the same credential for vCenter, the FlashArray and both VMs
$Credential = Get-Credential -UserName "$env:USERNAME" -Message 'Enter your credential information...'



# Connect to everything
$VIServer       = Connect-VIServer -Server $VIServerName -Protocol https -Credential $Credential
$FlashArray     = Connect-Pfa2Array -Endpoint $ArrayName -Credential $Credential -IgnoreCertificateError
$SourceSql      = Connect-DbaInstance -SqlInstance $SourceSQLServer -TrustServerCertificate
$TargetSql      = Connect-DbaInstance -SqlInstance $TargetSQLServer -TrustServerCertificate
$SourceVMObject = Get-VM -Name $SourceVM
$TargetVMObject = Get-VM -Name $TargetVM
$ESXiHost       = Get-VMHost -VM $TargetVMObject



###
# Look up where the database files live

# Every data and log file of the databases, as SQL Server sees them
$DbFiles = Get-DbaDbFile -SqlInstance $SourceSql -Database $Databases
$DbFiles | Select-Object Database, TypeDescription, PhysicalName



# For each drive letter in use, ask Windows on the source VM which disk it is on.  The disk serial number is the VMDK's UUID.
$DriveLetters = $DbFiles.PhysicalName | ForEach-Object { $_.Substring(0, 1).ToUpper() } | Select-Object -Unique

$SerialByDrive = Invoke-Command -ComputerName $SourceVM -Credential $Credential -ArgumentList (, $DriveLetters) -ScriptBlock {
    param($letters)
    $map = @{}
    foreach ($letter in $letters) {
        $map[$letter] = (Get-Partition -DriveLetter $letter | Get-Disk).SerialNumber.ToLower()
    }
    $map
}
$SerialByDrive



# Find those VMDKs in vSphere: the VMDK's backing UUID, without dashes, is the Windows disk serial number
$SourceDisks = Get-HardDisk -VM $SourceVMObject -DiskType Flat | Where-Object { # An RDM has no VMDK UUID, so only look at VMDKs
    $SerialByDrive.Values -contains $_.ExtensionData.Backing.Uuid.Replace('-', '').ToLower()
}
$SourceDisks | Select-Object Filename, CapacityGB

# The VMDK file names look like "[datastore name] folder/file.vmdk"
$SourceDatastoreName = ($SourceDisks.Filename | ForEach-Object { ($_ -split '\]')[0].TrimStart('[') } | Select-Object -Unique)
if (@($SourceDatastoreName).Count -ne 1) { throw "The database disks are in more than one datastore: $($SourceDatastoreName -join ', ')" }



# Look up the FlashArray volume behind the datastore, and the host group it is connected to
# The datastore's LUN is named naa.624a9370 followed by the FlashArray volume's serial number.  624a9370 is Pure Storage's vendor ID, so the prefix is the same on every FlashArray and would be different on another vendor's array.
$LunName       = (Get-Datastore -Name $SourceDatastoreName).ExtensionData.Info.Vmfs.Extent[0].DiskName
$VolumeSerial  = $LunName.Substring('naa.624a9370'.Length).ToUpper()
$SourceVolume  = Get-Pfa2Volume -Array $FlashArray | Where-Object { $_.Serial -eq $VolumeSerial }
# NOTE: do not pipe FlashArray cmdlets into Select-Object -First.  In Windows PowerShell 5.1 it can end the whole script silently.
$Connections   = @(Get-Pfa2Connection -Array $FlashArray -VolumeNames $SourceVolume.Name | Where-Object { $_.HostGroup.Name })
$FAHostGroup   = $Connections[0].HostGroup.Name
"Datastore $SourceDatastoreName is FlashArray volume $($SourceVolume.Name), connected to host group $FAHostGroup"



###
# Remove the previous copy
# The copy from the previous run is the datastore called <source datastore>-devtest.  If it is there, it is removed in the reverse order
# of how it was made.  On the first run there is nothing to remove.

$DevDatastoreName = "$SourceDatastoreName-devtest"
$Previous = Get-Datastore -Name $DevDatastoreName -ErrorAction SilentlyContinue

if ($Previous) {
    # Drop the databases on the target.  Remove-DbaDatabase closes any open sessions first.
    Get-DbaDatabase -SqlInstance $TargetSql -Database ($Databases | ForEach-Object { "$_$NewNameSuffix" }) | Remove-DbaDatabase -Confirm:$false -EnableException

    # Offline the copied disks in Windows.
    $PreviousDisks   = @(Get-HardDisk -VM $TargetVMObject | Where-Object { $_.Filename -like "[[]$DevDatastoreName]*" })
    $PreviousSerials = $PreviousDisks | ForEach-Object { $_.ExtensionData.Backing.Uuid.Replace('-', '').ToLower() }
    Invoke-Command -ComputerName $TargetVM -Credential $Credential -ArgumentList (, @($PreviousSerials)) -ScriptBlock {
        param($serials)
        foreach ($disk in (Get-Disk | Where-Object { $serials -contains "$($_.SerialNumber)".ToLower() })) {
            Set-Disk -Number $disk.Number -IsOffline $true
        }
    }

    # Remove the VMDKs from the target VM, then the datastore, then detach its LUN so the host does not report dead paths
    $PreviousDisks | Remove-HardDisk -Confirm:$false
    $PreviousLun    = $Previous.ExtensionData.Info.Vmfs.Extent[0].DiskName
    # naa.624a9370 is Pure Storage's vendor ID followed by the volume's serial number, as explained above.
    $PreviousVolume = Get-Pfa2Volume -Array $FlashArray | Where-Object { $_.Serial -eq $PreviousLun.Substring('naa.624a9370'.Length).ToUpper() }
    Remove-Datastore -Datastore $Previous -VMHost $ESXiHost -Confirm:$false
    (Get-EsxCli -VMHost $ESXiHost -V2).storage.core.device.set.Invoke(@{ device = $PreviousLun; state = 'off' })

    # On the FlashArray, disconnect and destroy the old clone and its snapshots.  They are eradicated at once, because a refresh
    # that left every old copy for the eradication period would keep a lot of space in use.
    Remove-Pfa2Connection -Array $FlashArray -HostGroupNames $FAHostGroup -VolumeNames $PreviousVolume.Name
    Remove-Pfa2Volume -Array $FlashArray -Name $PreviousVolume.Name
    Remove-Pfa2Volume -Array $FlashArray -Name $PreviousVolume.Name -Eradicate -Confirm:$false
    foreach ($OldSnapshot in @(Get-Pfa2VolumeSnapshot -Array $FlashArray -SourceNames $SourceVolume.Name | Where-Object { $_.Suffix -like 'devtest-*' })) {
        Remove-Pfa2VolumeSnapshot -Array $FlashArray -Name $OldSnapshot.Name
        Remove-Pfa2VolumeSnapshot -Array $FlashArray -Name $OldSnapshot.Name -Eradicate -Confirm:$false
    }

    # Rescan so the host forgets the detached LUN
    Get-VMHostStorage -RescanAllHba -VMHost $ESXiHost
}



###
# Snapshot and clone

# Take a crash-consistent snapshot of the source volume.  The source database stays online.
$Stamp    = (Get-Date).ToString('yyyyMMdd-HHmmss')
# NOTE: this takes a snapshot of ONE volume, the one behind the datastore.  If a server's database VMDKs are spread over several VMFS datastores,
# snapshot those volumes through a protection group, so they all share one point in time. 
$Snapshot = New-Pfa2VolumeSnapshot -Array $FlashArray -SourceNames $SourceVolume.Name -Suffix "devtest-$Stamp"
$Snapshot



# Create a new volume from the snapshot and present it to the ESXi host
$CloneName = "$($SourceVolume.Name)-devtest-$Stamp"
$Clone     = New-Pfa2Volume -Array $FlashArray -Name $CloneName -SourceName $Snapshot.Name
New-Pfa2Connection -Array $FlashArray -HostGroupNames $FAHostGroup -VolumeNames $CloneName



# The ESXi host must now rescan storage
Get-VMHostStorage -RescanAllHba -VMHost $ESXiHost



# Resignature the cloned datastore.  The copy has the same label as the original datastore, so name it exactly.
# NOTE: after a datastore is resignatured, its name will be "snap-[GUID chars]-[original DS name]"
$esxcli = Get-EsxCli -VMHost $ESXiHost -V2
$esxcli.storage.vmfs.snapshot.resignature.Invoke(@{ volumelabel = $SourceDatastoreName })



# Rescan again so the host sees the new datastore, then wait for it to appear
Get-VMHostStorage -RescanVmfs -VMHost $ESXiHost

# The copied datastore can take a little while to appear.  Wait until it is listed, running this until it is, then continue.
Get-Datastore | Where-Object { $_.Name -like "snap-*-$SourceDatastoreName" }
$ClonedDatastore = Get-Datastore | Where-Object { $_.Name -like "snap-*-$SourceDatastoreName" } | Sort-Object Name | Select-Object -Last 1

# Give it the stable name, so the next run can find it
$ClonedDatastore = Set-Datastore -Datastore $ClonedDatastore -Name $DevDatastoreName
$ClonedDatastore



###
# Attach the copied VMDKs to the target VM

foreach ($Disk in $SourceDisks) {
    $RelativePath = ($Disk.Filename -split '\] ', 2)[1]
    New-HardDisk -VM $TargetVMObject -DiskPath "[$($ClonedDatastore.Name)] $RelativePath"
}



# The copied disks arrive in Windows offline and read-only.  Find them by serial number, online them and make them writable.
# They keep the serial number of the originals, so no disk numbers or serials need to be typed in.
# The new disks can take a while to appear in Windows.  Wait until every new disk is listed, running this until it is, then continue.
Invoke-Command -ComputerName $TargetVM -Credential $Credential -ScriptBlock { Update-HostStorageCache; Get-Disk | Select-Object Number, SerialNumber, IsOffline, Size }

$TargetDriveBySerial = Invoke-Command -ComputerName $TargetVM -Credential $Credential -ArgumentList (, @($SerialByDrive.Values)) -ScriptBlock {
    param($serials)
    Update-HostStorageCache
    $found = @(Get-Disk | Where-Object { $serials -contains "$($_.SerialNumber)".ToLower() })
    $result = @{}
    foreach ($disk in $found) {
        Set-Disk -Number $disk.Number -IsOffline $false
        Set-Disk -Number $disk.Number -IsReadOnly $false
        $partition = Get-Partition -DiskNumber $disk.Number | Where-Object Type -eq 'Basic' | Select-Object -First 1
        if (-not $partition.DriveLetter) {
            Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -AssignDriveLetter
            $partition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber
        }
        $result[$disk.SerialNumber.ToLower()] = "$($partition.DriveLetter)"
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
        $NewLetter = $TargetDriveBySerial[$SerialByDrive[$OldLetter]]
        "(FILENAME = N'$NewLetter$($_.PhysicalName.Substring(1))')"
    }
    $Query = "CREATE DATABASE [$Database$NewNameSuffix] ON $($Files -join ', ') FOR ATTACH"
    Invoke-DbaQuery -EnableException -SqlInstance $TargetSql -Database master -Query $Query
}



###
# The databases are online on the target after crash recovery.  Check them.
Get-DbaDbState -SqlInstance $TargetSql -Database ($Databases | ForEach-Object { "$_$NewNameSuffix" })



Disconnect-Pfa2Array -Array $FlashArray
