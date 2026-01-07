##############################################################################################################################
# Refresh VMFS VMDK with Snapshot Demo
#
#
# Scenario: 
#    Snapshot and clone a "production" VMDK in a VMFS datastore, then present it to a "non-production" server.
# 
#    This example has two databases: ExampleDb1, ExampleDb2, whose data and log files both reside on a single disk/VMDK.
#
#
# Usage Notes:
#
#    You must pre-setup the target VM with a cloned datastore from the source already.  You will ONLY be utilizing 
#    the SPECIFIC VMDK(s) that contain the data/log files of interest, from the cloned datastore.  Other VMDKs can safely be 
#    ignored since they are deduped on FlashArray.
#
#    For the cloned datastore pre-setup, you can use subsets of the code below to clone the source datastore, present it to 
#    the target server, then attach the VMDK(s) containing the production databases that will be re-cloned with this script.
#    Once "staged," you can then use this script fully to refresh the data files in the cloned datastore that is attached 
#    to the target server.
#
#    This script also assumes that all database files (data and log) are on the same volume/single VMDK.  If multiple
#    volumes/VMDKs are being used, adjust the code to add additional foreach loops when manipulating the VMDKs.
# 
# 2025/12/22: AYun - Renamed to "VMFS-VMDK Snapshot - V1.ps1" and migrated to archive in 
#                    PureStorage-OpenConnect\sqlserver-scripts\demos-archive\VMFS-VMDK Snapshot
# 
# Disclaimer:
#    This example script is provided AS-IS and meant to be a building block to be adapted to fit an individual 
#    organization's infrastructure.
##############################################################################################################################



# Import powershell modules
Import-Module PureStoragePowerShellSDK2
Import-Module VMware.VimAutomation.Core
Import-Module SqlServer



# Declare variables
$TargetVM                = 'SqlServer1'                           # Name of target VM
$Databases               = @('ExampleDb1','ExampleDb2')           # Array of database names
$TargetDiskSerialNumber  = '6000c02022cb876dcd321example01b'      # Target Disk Serial Number
$VIServerName            = 'vcenter.example.com'                  # vCenter FQDN
$ClusterName             = 'WorkloadCluster1'                     # VMware Cluster
$SourceDatastoreName     = 'vmware_sql_datastore'                 # VMware datastore name
$SourceVMDKPath          = 'SqlServer1_1/SqlServer1.vmdk'         # VMDK path inside the VMFS datastore
$ArrayName               = 'flasharray1.example.com'              # FlashArray FQDN
$SourceVolumeName        = 'sql_volume_1'                         # Source volume name on FlashArray (may be same as your datastore name)
$TargetVolumeName        = 'sql_volume_2'                         # Target volume name on FlashArray (may be same as your datastore name)



# Set Credential - this assumes the same credential for the target VM and vCenter
$Credential = Get-Credential



# Create a Powershell session against the target VM
$TargetVMSession = New-PSSession -ComputerName $TargetVM -Credential $Credential



# Connect to vCenter
$VIServer = Connect-VIServer -Server $VIServerName -Protocol https -Credential $Credential 



# Offline the target database(s) by looping through $Databases array
foreach ($Database in $Databases) {
    $Query = "ALTER DATABASE [$Database] SET OFFLINE WITH ROLLBACK IMMEDIATE"
    Invoke-Sqlcmd -ServerInstance $TargetVM -Database master -Query $Query
}



# Offline the volumes that have SQL data
Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDiskSerialNumber } | Set-Disk -IsOffline $True }



# Prepare to remove the VMDK from the VM
$VM = Get-VM -Server $VIServer -Name $TargetVM
$HardDisk = Get-HardDisk -VM $VM | Where-Object { $_.FileName -match $SourceVMDKPath } 



# Remove the VMDK from the VM
Remove-HardDisk -HardDisk $HardDisk -Confirm:$false



# Prepare to remove the stale datastore
$DataStore = $HardDisk.Filename.Substring(1, ($HardDisk.Filename.LastIndexOf(']') - 1))
$Hosts = Get-Cluster $ClusterName | Get-VMHost | Where-Object { ($_.ConnectionState -eq 'Connected') }



# Guest hard disk removed, now remove the stale datastore - this can take a min or two
Get-Datastore $DataStore | Remove-Datastore -VMHost $Hosts[0] -Confirm:$False



# Connect to the array, authenticate. Remember disclaimer at the top!
$FlashArray = Connect-Pfa2Array -Endpoint $ArrayName -Credential ($Credential) -IgnoreCertificateError



# Perform the volume overwrite (no intermediate snapshot needed!)
New-Pfa2Volume -Array $FlashArray -Name $TargetVolumeName -SourceName $SourceVolumeName -Overwrite $True



# Rescan storage on each ESX host in the $Hosts array
foreach ($VmHost in $Hosts) {
    Get-VMHostStorage -RescanAllHba -RescanVmfs -VMHost $VmHost | Out-Null
}



# Connect to EsxCli
$esxcli = Get-EsxCli -VMHost $Hosts[0]



# Resignature the cloned datastore
$EsxCli.Storage.Vmfs.Snapshot.Resignature($SourceDatastoreName)



# Find the assigned datastore name, this may take a few seconds
# NOTE: when a datastore comes back, it's name will be "snap-[GUID chars]-[original DS name]"
# This is why the wildcard match below is needed.
$DataStore = (Get-Datastore | Where-Object { $_.Name -match 'snap' -and $_.Name -match $SourceDatastoreName })



# Rescan storage again to make sure all hosts can see the new datastore
foreach ($VmHost in $Hosts) {
    Get-VMHostStorage -RescanAllHba -RescanVmfs -VMHost $VmHost | Out-Null
}



# Attach the VMDK from the newly cloned datastore back to the target VM
New-HardDisk -VM $VM -DiskPath "[$DataStore] $SourceVMDKPath"



# Online the volume on the target VM
Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDiskSerialNumber } | Set-Disk -IsOffline $False }



# Volume might be read-only, ensure it's read/write
Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDiskSerialNumber } | Set-Disk -IsReadOnly $False }



# Online the target database(s) by looping through $Databases array
foreach ($Database in $Databases) {
    $Query = "ALTER DATABASE [$Database] SET ONLINE WITH ROLLBACK IMMEDIATE"
    Invoke-Sqlcmd -ServerInstance $TargetVM -Database master -Query $Query
}



# Remove powershell session
Remove-PSSession $TargetVMSession
