##############################################################################################################################
# Refresh VMFS VMDK with Snapshot Demo
#
# Author: Andy Yun
# Written: 2023-07-14
# Updated: 2023-12-01
#
# Scenario: 
# Snapshot and clone a "production" VMDK in a VMFS datastore, then present it to a "non-production" server.
# 
# This example has two databases: AutoDealershipDemo_VMFS, CookbookDemo_VMFS, whose data and log files both reside on a
# single disk/VMDK.
#
#
# IMPORTANT Usage Notes:
#
# You must pre-setup the target VM with a cloned datastore from the source already.  You will ONLY be utilizing 
# the SPECIFIC VMDK(s) that contain the data/log files of interest, from the cloned datastore.  Other VMDKs can safely be 
# ignored since they are deduped on FlashArray.
#
# For the cloned datastore pre-setup, you can use subsets of the code below to clone the source datastore, present it to 
# the target server, then attach the VMDK(s) containing the production databases that will be re-cloned with this script.
# Once "staged," you can then use this script fully to refresh the data files in the cloned datastore that is attached 
# to the target server.
#
# This script also assumes that all database files (data and log) are on the same volume/single VMDK.  If multiple
# volumes/VMDKs are being used, adjust the code to add additional foreach loops when manipulating the VMDKs.
# 
# Disclaimer:
# This example script is provided AS-IS and meant to be a building block to be adapted to fit an individual 
# organization's infrastructure.
# 
# THIS IS A SAMPLE SCRIPT WE USE FOR DEMOS! _PLEASE_ do not save your passwords in cleartext here. 
# Use NTFS secured, encrypted files or whatever else -- never cleartext!
#
##############################################################################################################################
Import-Module VMware.VimAutomation.Core
Import-Module PureStoragePowerShellSDK2

# Declare variables
$TargetVM = 'ayun-sql19-04'
$Databases = @('AutoDealershipDemo_VMFS','CookbookDemo_VMFS')
$TargetDiskSerialNumbers = @('6000c29d8fbd57d2c64b173eb9a6f3bd')                # Target Disk Serial Number(s)
$VIServerName = 'vc01.fsa.lab'
$ClusterName = 'Workload Cluster 1'                # VMware Cluster
$SourceDatastoreName = 'ayun_sql_ds1'                # VMware datastore name
$SourceVMDKPath = 'ayun-sql19-03_1/ayun-sql19-03.vmdk'                # VMDK path inside the VMFS datastore
$ArrayName = 'sn1-c60-e12-16.puretec.purestorage.com'
$SourceVolumeName = 'ayun_sql_ds1'                # Volume name on FlashArray (may be same as your datastore name)
$TargetVolumeName = 'ayun_sql_ds2'                # Volume name on FlashArray (may be same as your datastore name)

$Credential = Get-Credential -UserName "$env:USERNAME" -Message 'Enter your credential information...'

# Create a Powershell session against the target VM
$TargetVMSession = New-PSSession -ComputerName $TargetVM -Credential $Credential

# Import the SQLPS module so SQL commands are available
Import-Module SQLPS -PSSession $TargetVMSession -DisableNameChecking

# Connect to vCenter
Write-Host "Connecting to vCenter..." -ForegroundColor Red
$VIServer = Connect-VIServer -Server $VIServerName -Protocol https -Credential $Credential 

# Offline the target database(s)
Write-Warning "Offlining the target database(s)..."
Foreach ($database in $Databases) {
    # Offline the database
    Write-Warning "Offlining the target $database..."
    $Query = "ALTER DATABASE " + $($database) + " SET OFFLINE WITH ROLLBACK IMMEDIATE"
    Invoke-Command -Session $TargetVMSession -ScriptBlock {Param($querytask) Invoke-Sqlcmd -ServerInstance . -Database master -Query $querytask} -ArgumentList ($Query)
}

# Offline the volumes that have SQL data
Write-Warning "Offlining the target volume(s)..." 
Foreach ($targetdisk in $TargetDiskSerialNumbers) {
    Write-Host "Offlining Disk $($targetdisk)"
    Invoke-Command -Session $TargetVMSession -ScriptBlock {Param($currentdisk) Get-Disk | ? { $_.SerialNumber -eq $($currentdisk) } | Set-Disk -IsOffline $True } -ArgumentList ($targetdisk)
}

# Prepare to remove the VMDK from the VM
# NOTE: If there are multiple drives/volumes, this will have to be changed into a loop
# This example assumes database data and log files are on the same volume.
$VM = Get-VM -Server $VIServer -Name $TargetVM
$harddisk = Get-HardDisk -VM $VM | ? { $_.FileName -match $SourceVMDKPath } 

### Diagnostic
# $VM
# $harddisk
# $SourceVMDKPath

# Remove the VMDK from the VM
Write-Host "Removing hard disk from target VM..." -ForegroundColor Red
Remove-HardDisk -HardDisk $harddisk -Confirm:$false

# Prepare to remove the stale datastore
$datastore = $harddisk.filename.Substring(1, ($harddisk.filename.LastIndexOf(']') - 1))
$Hosts = Get-Cluster $ClusterName | Get-VMHost | where-object { ($_.ConnectionState -eq 'Connected') }

### Diagnostic
# Get-Datastore $datastore
# $datastore
# Get-Datastore -Server $VIServer

# Guest hard disk removed, now remove the stale datastore - this can take a min or two
Write-Host "Detaching datastore $datastore..." -ForegroundColor Red
Get-Datastore $datastore | Remove-Datastore -VMHost $Hosts[0] -Confirm:$false

# Connect to the array, authenticate. Remember disclaimer at the top!
Write-Host "Connecting to Pure FlashArray..." -ForegroundColor Red
$FlashArray = Connect-Pfa2Array -Endpoint $ArrayName -Credential ($Credential) -IgnoreCertificateError

# Perform the volume overwrite (no intermediate snapshot needed!)
Write-Host "Performing datastore array volume clone..." -ForegroundColor Red
New-Pfa2Volume -Array $FlashArray -Name $TargetVolumeName -SourceName $SourceVolumeName -Overwrite $true

# Now let's tell the ESX host to rescan storage
Write-Host "Rescanning storage on VM host..." -ForegroundColor Red
Foreach ($VmHost in $Hosts) {
    Write-Host "         Host: $($VmHost)"
    Get-VMHostStorage -RescanAllHba -RescanVmfs -VMHost $VmHost | Out-Null
}

# Connect to EsxCli
$esxcli = Get-EsxCli -VMHost $Hosts[0]

### Diagnostic
# Retrieve a list of the snapshots that have been presented to the host (our cloned volume should be present)
# $snapInfo = $esxcli.storage.vmfs.snapshot.list()
# $snapInfo | where-object { ($_.VolumeName -match $SourceDatastoreName) }

# Resignature the cloned datastore
Write-Host "Performing resignature of the new datastore $SourceDatastoreName..." -ForegroundColor Red
$esxcli.storage.vmfs.snapshot.resignature($SourceDatastoreName)

# Find the assigned datastore name
# NOTE: when a datastore comes back, it's name will be "snap-[GUID chars]-[original DS name]"
# This is why the wildcard match below is needed.
Write-Host "Waiting for new datastore to come online..." -ForegroundColor Red
$datastore = (Get-Datastore | ? { $_.name -match 'snap' -and $_.name -match $SourceDatastoreName })
while ($datastore -eq $null) {
    # We may have to wait a little bit before the datastore is fully operational
    Start-Sleep -Seconds 5
    $datastore = (Get-Datastore | Where-Object { $_.name -match 'snap' -and $_.name -match $SourceDatastoreName })
}
Write-Host "This is our new cloned datastore..." -ForegroundColor Red
$datastore

# Rescan storage again to make sure all hosts can see the new datastore
Foreach ($VmHost in $Hosts) {
    Write-Host "         Host: $($VmHost)"
    Get-VMHostStorage -RescanAllHba -RescanVmfs -VMHost $VmHost | Out-Null
}

# Attach the VMDK from the newly cloned datastore back to the target VM
Write-Host "Attaching VMDK to target VM..." -ForegroundColor Red
New-HardDisk -VM $VM -DiskPath "[$datastore] $SourceVMDKPath"

# Online the volume(s) on the target VM
Write-Host "Onlining guest volume on target VM..." -ForegroundColor Red
Foreach ($targetdisk in $TargetDiskSerialNumbers) {
    Write-Host "Offlining Disk $($targetdisk)"
    Invoke-Command -Session $TargetVMSession -ScriptBlock {Param($currentdisk) Get-Disk | Where-Object { $_.SerialNumber -eq $($currentdisk) } | Set-Disk -IsOffline $False } -ArgumentList ($targetdisk)
}

# Volume(s) might be read-only, let's force read/write. These things happen sometimes...
Write-Host "Setting guest volume to read/write on target VM..." -ForegroundColor Red
Foreach ($targetdisk in $TargetDiskSerialNumbers) {
    Write-Host "Onlining Disk $($targetdisk)"
    Invoke-Command -Session $TargetVMSession -ScriptBlock {Param($currentdisk) Get-Disk | Where-Object { $_.SerialNumber -eq $($currentdisk) } | Set-Disk -IsReadOnly $False } -ArgumentList ($targetdisk)
}

# Online the target database(s)
Foreach ($database in $databases) {
    Write-Host "Onlining $database"
    $Query = "ALTER DATABASE " + $($database) + " SET ONLINE WITH ROLLBACK IMMEDIATE"
    Invoke-Command -Session $TargetVMSession -ScriptBlock {Param($querytask) Invoke-Sqlcmd -ServerInstance . -Database master -Query $querytask} -ArgumentList ($Query)
}

# Give an update
Write-Warning "Target database downtime ended." 

# Clean up
Remove-PSSession $TargetVMSession

Write-Warning "All done."

