# THIS IS A SAMPLE SCRIPT WE USE FOR DEMOS! _PLEASE_ do not save your passwords in cleartext here. 
# Use NTFS secured, encrypted files or whatever else -- never cleartext!

Import-Module VMware.VimAutomation.Core
Import-Module PureStoragePowerShellSDK

$SourceVM = 'MySourceVM'
$TargetVM = 'MyTargetVM'
$DatabaseName = 'Database_Sitting_On_VMDK'
$VIServerName = 'MyVCenter'
$VMHostname = 'MyVHost'
$Username = 'cloner@puresql.lab'
$Password = 'P@ssword99!'
$TargetVMDiskNumber = 2  # To do: fetch this automatically
$SourceDatastoreName = 'MyDatastoreName'
$VMDKPath = 'MySourceVM/MySourceVM_Disk.vmdk'
$ArrayName = 'MyPureFlashArray.puresql.lab'
$ArrayUsername = 'pureuser'
$ArrayPassword = 'pureuser'
$SourceVolumeName = 'MyPureSourceVolume'
$TargetVolumeName = 'MyPureTargetVolume'

# Create a Powershell session against the target VM
$TargetVMSession = New-PSSession -ComputerName $TargetVM

Write-Host "Importing SQLPS module on target VM..." -ForegroundColor Red

Import-Module SQLPS -PSSession $TargetVMSession -DisableNameChecking

# Connect to vSphere vCenter server
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false  # I'm ignoring certificate errors - this you probably won't want to ignore.

Write-Host "Connecting to vCenter..." -ForegroundColor Red

$VIServer = Connect-VIServer -Server $VIServerName -Protocol https -User $Username -Password $Password 

# Offline the target database
$ScriptBlock = [ScriptBlock]::Create("Invoke-Sqlcmd -ServerInstance . -Database master -Query `"ALTER DATABASE $DatabaseName SET OFFLINE WITH ROLLBACK IMMEDIATE`"")

Write-Host "Offlining target database..." -ForegroundColor Red

Invoke-Command -Session $TargetVMSession -ScriptBlock $ScriptBlock

# Offline the guest target volume
Write-Host "Offlining target VM volume..." -ForegroundColor Red

Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | ? { $_.Number -eq $TargetVMDiskNumber } | Set-Disk -IsOffline $True }

# Remove the VMDK from the VM
$VM = Get-VM -Server $VIServer -Name $TargetVM

$harddisk = Get-HardDisk -VM $VM | ? { $_.FileName -match $VMDKPath } 

Write-Host "Removing hard disk from target VM..." -ForegroundColor Red

Remove-HardDisk -HardDisk $harddisk -Confirm:$false

# Guest hard disk removed, now remove the stale datastore
$datastore = $harddisk.filename.Substring(1, ($harddisk.filename.LastIndexOf(']') - 1))

Write-Host "Detaching datastore..." -ForegroundColor Red

Get-Datastore $datastore | Remove-Datastore -VMHost $VMhostname -Confirm:$false

# Let's do a quick CHECKPOINT on the source database to minimize crash recovery time upon startup on target - optional of course
$SourceVMSession = New-PSSession -ComputerName $SourceVM

$ScriptBlock = [ScriptBlock]::Create("Invoke-Sqlcmd -ServerInstance . -Database $DatabaseName -Query `"CHECKPOINT`"")

Write-Host "Forcing a CHECKPOINT on source database..." -ForegroundColor Red

Invoke-Command -Session $SourceVMSession -ScriptBlock $ScriptBlock

# Connect to the array, authenticate. Remember disclaimer at the top!
Write-Host "Connecting to Pure FlashArray..." -ForegroundColor Red

$FlashArray = New-PfaArray –EndPoint $ArrayName -UserName $ArrayUsername -Password (ConvertTo-SecureString -AsPlainText $ArrayPassword -Force) -IgnoreCertificateError

# Perform the volume overwrite (no intermediate snapshot needed!)
Write-Host "Performing datastore array volume clone..." -ForegroundColor Red

New-PfaVolume -Array $FlashArray -VolumeName $TargetVolumeName -Source $SourceVolumeName -Overwrite

# Now let's tell the ESX host to rescan storage

$VMHost = Get-VMHost $VMHostname 

Write-Host "Rescanning storage on VM host..." -ForegroundColor Red

Get-VMHostStorage -RescanAllHba -RescanVmfs -VMHost $VMHost

$esxcli = Get-EsxCli -VMHost $VMHost

# If debug needed, use: $snapInfo = $esxcli.storage.vmfs.snapshot.list()

# Do a resignature of the datastore
Write-Host "Performing resignature of the new datastore..." -ForegroundColor Red

$esxcli.storage.vmfs.snapshot.resignature($SourceDatastoreName)

# Find the assigned datastore name
Write-Host "Waiting for new datastore to come online..." -ForegroundColor Red

$datastore = (Get-Datastore | ? { $_.name -match 'snap' -and $_.name -match $SourceDatastoreName })

while ($datastore -eq $null) { # We may have to wait a little bit before the datastore is fully operational
    $datastore = (Get-Datastore | ? { $_.name -match 'snap' -and $_.name -match $SourceDatastoreName })
    Start-Sleep -Seconds 5
}

# Attach the VMDK to the target VM
Write-Host "Attaching VMDK to target VM..." -ForegroundColor Red

New-HardDisk -VM $VM -DiskPath "[$datastore] $VMDKPath"

# Online the guest target volume
Write-Host "Onlining guest volume on target VM..." -ForegroundColor Red

Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | ? { $_.Number -eq $TargetVMDiskNumber } | Set-Disk -IsOffline $False }

# Volume might be read-only, let's force read/write. These things happen sometimes...
Write-Host "Setting guest volume to read/write on target VM..." -ForegroundColor Red

Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | ? { $_.Number -eq $TargetVMDiskNumber } | Set-Disk -IsReadOnly $False }

# Online the database
$ScriptBlock = [ScriptBlock]::Create("Invoke-Sqlcmd -ServerInstance . -Database master -Query `"ALTER DATABASE $DatabaseName SET ONLINE WITH ROLLBACK IMMEDIATE`"")

Write-Host "Onlining target database..." -ForegroundColor Red

Invoke-Command -Session $TargetVMSession -ScriptBlock $ScriptBlock
