##############################################################################################################################
# VMFS-VMDK Same-VM Clone
#
# Scenario:
#    A SQL Server VM keeps its database files on VMDKs in a VMFS datastore (one FlashArray volume).  You want a
#    point-in-time copy of some of those databases attached BESIDE the live ones, on the same SQL Server, for example to
#    recover rows from yesterday's data without overwriting today's.
#
#    A snapshot copy of a VMDK cannot simply be added back to the VM that has the original.  Two IDs are copied with it:
#       1. The VMDK UUID.  vSphere refuses to attach a second disk with the same UUID to a VM.
#       2. The GPT disk GUID inside the disk.  Windows hides the duplicate from disk management and, after a reboot, can take
#          the PRODUCTION disk offline instead of the copy.
#    This script gives each copy a new VMDK UUID (a vSphere API call), then attaches the copies to a second VM (the helper VM) where
#    they are visible, gives each a new GPT disk GUID with diskpart, and finally attaches them to the source VM.
#
#    The source SQL Server stays online.  The snapshot is crash-consistent: SQL Server write IO is NOT frozen, so each
#    copy performs crash recovery when it is attached.
#
#    You name the VM, the helper VM, the databases and the vCenter and FlashArray.  Everything else is looked up:
#    database files -> Windows drive -> Windows disk serial number -> VMDK (the serial is the VMDK's UUID)
#    -> datastore -> FlashArray volume -> FlashArray host group.
#
# Prerequisites:
#    1. PowerShell modules: dbatools, PureStoragePowerShellSDK2 and VMware PowerCLI.
#    2. PowerShell remoting (WinRM) to the SQL VM and a SQL Server login that can attach databases.  The helper VM is reached through
#       VMware Tools, so it only needs VMware Tools running and a login that can run commands in it.
#    3. All of the databases listed below must sit on VMDKs in ONE datastore, which is ONE FlashArray volume.
#    4. The helper VM is any other Windows VM on the same ESXi host.  It never holds the originals, so nothing collides there.
#       It is only used to change the GPT disk GUIDs.  Both VMs need free SCSI slots for hot-adding disks.
#    5. Database files must be on drive letters (this script is written for drive letters and does not handle mount points), and the copies must not exist yet.
#
# Do NOT attach a snapshot copy of a VMDK to the VM that has the original without changing both IDs.  After a reboot Windows
# may keep the copy online and take the original offline.
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

$SQLVM             = 'sql_vm'                         # The VM with the live databases.  Not FQDN
$SQLServer         = 'sql_vm.example.com'
$HelperVM          = 'helper_vm'                      # Any other Windows VM on the same ESXi host.  Not FQDN
$Databases         = @('AdventureWorks', 'WideWorldImporters')
$NewNameSuffix     = '_copy'                          # Databases are attached beside the live ones as AdventureWorks_copy, ...



# Get Credentials - this example assumes the same credential for vCenter, the FlashArray and both VMs
$Credential = Get-Credential -UserName "$env:USERNAME" -Message 'Enter your credential information...'



# Connect to everything
$VIServer       = Connect-VIServer -Server $VIServerName -Protocol https -Credential $Credential
$FlashArray     = Connect-Pfa2Array -Endpoint $ArrayName -Credential $Credential -IgnoreCertificateError
$Sql            = Connect-DbaInstance -SqlInstance $SQLServer -TrustServerCertificate
$SQLVMObject    = Get-VM -Name $SQLVM
$HelperVMObject = Get-VM -Name $HelperVM
$ESXiHost       = Get-VMHost -VM $SQLVMObject
$DiskManager    = Get-View (Get-View ServiceInstance).Content.VirtualDiskManager
$Datacenter     = Get-Datacenter | Select-Object -First 1



###
# Look up where the database files live

# Every data and log file of the databases, as SQL Server sees them
$DbFiles = Get-DbaDbFile -SqlInstance $Sql -Database $Databases
$DbFiles | Select-Object Database, TypeDescription, PhysicalName



# For each drive letter in use, ask Windows which disk it is on.  The disk serial number is the VMDK's UUID.
$DriveLetters = $DbFiles.PhysicalName | ForEach-Object { $_.Substring(0, 1).ToUpper() } | Select-Object -Unique

# The new disks can take a while to appear in Windows.  Wait until every new disk is listed, running this until it is, then continue.
Invoke-Command -ComputerName $SQLVM -Credential $Credential -ScriptBlock { Update-HostStorageCache; Get-Disk | Select-Object Number, SerialNumber, IsOffline, Size }

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
# Snapshot and clone

# Take a crash-consistent snapshot of the source volume.  The source database stays online.
# NOTE: this takes a snapshot of ONE volume, the one behind the datastore.  If a server's database VMDKs are spread over several VMFS datastores,
# snapshot those volumes through a protection group, so they all share one point in time. 
$Snapshot = New-Pfa2VolumeSnapshot -Array $FlashArray -SourceNames $SourceVolume.Name
$Snapshot



# Create a new volume from the snapshot and present it to the ESXi host
$CloneName = "$($SourceVolume.Name)-copy-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
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
$ClonedDatastore



###
# Change the first of the two duplicate IDs: give every copied VMDK a new UUID

# The disk manager wants its own format: 16 bytes as hex pairs, with a dash in the middle ("60 00 C2 93 ...-...")
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
    $NewSerial = ($DiskManager.QueryVirtualDiskUuid($CopyPath, $Datacenter.Id) -replace '[ -]', '').ToLower()
    $NewSerialByOldSerial[$OldSerial] = $NewSerial
}
$NewSerialByOldSerial



###
# Change the second ID on the helper VM: give every copied disk a new GPT disk GUID
# The helper VM never held the originals, so the copies are visible there and nothing collides.

foreach ($Disk in $SourceDisks) {
    $RelativePath = ($Disk.Filename -split '\] ', 2)[1]
    New-HardDisk -VM $HelperVMObject -DiskPath "[$($ClonedDatastore.Name)] $RelativePath"
}

# The steps on the helper VM run through VMware Tools, so the helper needs no remoting or DNS setup, only a login that can run commands.
# diskpart is used because it only touches the machine's own disks.  Set-Disk -Guid is rejected for these disks ("Invalid Parameter").
$HelperScript = @'
$serials = @(__SERIALS__)
Update-HostStorageCache
$found = @(Get-Disk | Where-Object { $serials -contains "$($_.SerialNumber)".ToLower() })
foreach ($disk in $found) {
    Set-Content -Path "$env:TEMP\newguid.txt" -Value "select disk $($disk.Number)`r`nattributes disk clear readonly`r`nonline disk`r`nuniqueid disk id=$([guid]::NewGuid())`r`noffline disk"
    diskpart /s "$env:TEMP\newguid.txt" | Out-Null
}
'@
$HelperScript = $HelperScript.Replace('__SERIALS__', (($NewSerialByOldSerial.Values | ForEach-Object { "'$_'" }) -join ','))
Invoke-VMScript -VM $HelperVMObject -GuestCredential $Credential -ScriptType Powershell -ScriptText $HelperScript

# Take the copies off the helper VM again
Get-HardDisk -VM $HelperVMObject | Where-Object { $_.Filename -like "[[]$($ClonedDatastore.Name)]*" } | Remove-HardDisk -Confirm:$false



###
# Attach the copies to the source VM

foreach ($Disk in $SourceDisks) {
    $RelativePath = ($Disk.Filename -split '\] ', 2)[1]
    New-HardDisk -VM $SQLVMObject -DiskPath "[$($ClonedDatastore.Name)] $RelativePath"
}



# The copies arrive offline and read-only.  Online them and make them writable, and find the drive letter each one got.
# The new disks can take a while to appear in Windows.  Wait until every new disk is listed, running this until it is, then continue.
Invoke-Command -ComputerName $SQLVM -Credential $Credential -ScriptBlock { Update-HostStorageCache; Get-Disk | Select-Object Number, SerialNumber, IsOffline, Size }

$NewLetterBySerial = Invoke-Command -ComputerName $SQLVM -Credential $Credential -ArgumentList (, @($NewSerialByOldSerial.Values)) -ScriptBlock {
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
$NewLetterBySerial



###
# Attach the databases beside the live ones

# Each file keeps its path, with the drive letter swapped for the letter its copy got
foreach ($Database in $Databases) {
    $Files = $DbFiles | Where-Object { $_.Database -eq $Database } | ForEach-Object {
        $OldLetter = $_.PhysicalName.Substring(0, 1).ToUpper()
        $NewLetter = $NewLetterBySerial[$NewSerialByOldSerial[$SerialByDrive[$OldLetter]]]
        "(FILENAME = N'$NewLetter$($_.PhysicalName.Substring(1))')"
    }
    $Query = "CREATE DATABASE [$Database$NewNameSuffix] ON $($Files -join ', ') FOR ATTACH"
    Invoke-DbaQuery -EnableException -SqlInstance $Sql -Database master -Query $Query
}



###
# The copies are online beside the originals after crash recovery.  Check them.
Get-DbaDbState -SqlInstance $Sql -Database ($Databases | ForEach-Object { "$_$NewNameSuffix" })



Disconnect-Pfa2Array -Array $FlashArray
