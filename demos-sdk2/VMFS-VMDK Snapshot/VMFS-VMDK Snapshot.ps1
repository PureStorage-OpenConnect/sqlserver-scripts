##############################################################################################################################
# Refresh VMFS VMDK(s) with Snapshot Demo
#
# Example Scenario:
#    Production SQL Server & database(s) reside on a VMFS datastore.  Non-production SQL Server resides on 
#    a different VMFS datastore.  User database(s) data and log files reside on two different VMDK disks 
#    in each datastore.
# 
#    Each datastore also resides on a different FlashArray, to demonstrate use of async snapshot replication.
#
#    This example is for a repeatable refresh scenario, such as a nightly refresh of a production database on
#    another non-production SQL Server.
# 
#    This example's workflow takes an on-demand snapshot of the Production datastore and async replicates it to
#    the second FlashArray.  Then the snapshot is cloned as a new temporary volume/datastore.  The VMDKs with the
#    production database files, residing on the temporary cloned datastore are attached to the target SQL Server,
#    replacing the prior VMDKs that stored the database files previously.  Finally Storage vMotion is used to
#    migrate the VMDKs to the non-production datastore, then the temporary cloned datastore is discarded.
# 
#    This workflow is intended to only be impact select Windows Disks/VMDKs that contain user databases.  
#
# Disclaimer:
#    This example script is provided AS-IS and meant to be a building block to be adapted to fit an individual 
#    organization's infrastructure.
#
#    _PLEASE_ do not save your passwords in cleartext here. 
#    Use NTFS secured, encrypted files or whatever else -- never cleartext!
#
##############################################################################################################################



# Import powershell modules
Import-Module VMware.VimAutomation.Core
Import-Module PureStoragePowerShellSDK2



# Declare all variables
# VMware variables
$VIServerName           = 'vcenter.example.com'
$ClusterName            = 'WorkloadCluster1'
$SourceDatastoreName    = 'source_sql_datastore'
$TargetDatastoreName    = 'target_sql_datastore'
$SourceVMDKPaths        = @('source_vm/sqldata.vmdk','source_vm/sqllog.vmdk')
$TargetVMDKPaths        = @('target_vm/sqldata.vmdk','target_vm/sqllog.vmdk')

# FlashArray variables
$SourceArrayName        = 'flasharray1.example.com'    # FlashArray FQDN
$SourceArrayShortName   = 'flasharray1'
$TargetArrayName        = 'flasharray2.example.com'    # FlashArray FQDN
$FAHostGroupName        = 'FAHostGroupName'            # HostGroup Name on FlashArray for the ESXi cluster
$SourceVolumeName       = 'volume_name'
$SourceProtectionGroup  = 'protection_group'
$TargetVolumeName       = 'target_volume_name'
$TargetProtectionGroup  = "$($SourceArrayShortName):$($SourceProtectionGroup)"    # [source array name (not FQDN)]:[source protection group name]

# Windows/SQL Server variables
$SourceVM               = 'source_vm'	               # Not FQDN
$TargetVM               = 'target_vm'	               # Not FQDN
$Databases              = @('AdventureWorks','WideWorldImporters')
$TargetDevices          = @('1234c29689bc0888d32dcd2919a67z89', '1234c299721c4ba4a937552fb298a76')    # The serial numbers of the Windows volume containing database files; use get-disk 



# Get Credentials - this demo example assumes the same credential for the target VM and vCenter
$Credential = Get-Credential -UserName "$env:USERNAME" -Message 'Enter your credential information...'



# Connect to the source array
$FlashArray = Connect-Pfa2Array -Endpoint $SourceArrayName -Credential ($Credential) -IgnoreCertificateError



# Create an on-demand Protection Group snapshot
# NOTE: 
#   This example uses async replication to generate a snapshot on $SourceArrayName and
#   replicate it to $TargetArrayName.  Remove -Replication flag if snapshots are only
#   being used on local array.
#   Alternatively, you may substitute other code to select an existing snapshot here
$MostRecentSnapshot = New-Pfa2ProtectionGroupSnapshot -Array $FlashArray -SourceNames $SourceProtectionGroup -ApplyRetention $true -ReplicateNow $true
$MostRecentSnapshot



###
# Prepare for snapshot overlay



# Create a Powershell session against the target VM
$TargetVMSession = New-PSSession -ComputerName $TargetVM -Credential $Credential



# Import the SQLPS module so SQL commands are available
Import-Module SQLPS -PSSession $TargetVMSession -DisableNameChecking



# Connect to vCenter
$VIServer = Connect-VIServer -Server $VIServerName -Protocol https -Credential $Credential 
$TargetSQLServerVM = Get-VM -Server $VIServer -Name $TargetVM
$VMESXiHost = Get-VMhost -VM $TargetSQLServerVM




# Get discrete hosts connected to the ESXi cluster
$Hosts = Get-Cluster $ClusterName | Get-VMHost | where-object { ($_.ConnectionState -eq 'Connected') }



# Connect to the target array, authenticate. Remember disclaimer at the top!
$FlashArray = Connect-Pfa2Array -Endpoint $TargetArrayName -Credential ($Credential) -IgnoreCertificateError



# Get the most recent snapshot
# NOTE:
#   This next segment may be simplified if async snapshot replication is not being used.
#   Alternatively, substitute code to take a new protection group snapshot or use 
#   one created prior.
$MostRecentSnapshots = Get-Pfa2ProtectionGroupSnapshot -Array $FlashArray -Name $TargetProtectionGroup | Sort-Object created -Descending | Select-Object -Property name -First 5



# Check that the last snapshot has been fully replicated
$FirstSnapStatus = Get-Pfa2ProtectionGroupSnapshotTransfer -Array $FlashArray -Name $MostRecentSnapshots[0].name

if ($FirstSnapStatus.completed -ne $null) {     # If $FirstSnapStatus.completed, then it hasn't been fully replicated 
    $MostRecentSnapshot = $MostRecentSnapshots[0].name
}
else {
    # Use prior snapshot instead
    $MostRecentSnapshot = $MostRecentSnapshots[1].name
}



# Create a new volume from the selected snapshot of the source
$SnapshotSuffix = (Get-Date).ToString("yyyyMMdd-HHmmss")
$NewClonedVolumeName = "$($SourceVolumeName)-repl-clone-$($SnapshotSuffix)"
$ReplicatedSourceVolumeName = "$($MostRecentSnapshot).$($SourceVolumeName)"
New-Pfa2Volume -Array $FlashArray -Name $NewClonedVolumeName -SourceName $ReplicatedSourceVolumeName -Overwrite $true 



# Present the new volume to the ESXi host group.
New-Pfa2Connection -Array $FlashArray -HostGroupName $FAHostGroupName -VolumeName $NewClonedVolumeName



# ESXi host(s) must now rescan storage
Get-VMHostStorage -RescanAllHba -RescanVmfs -VMHost $VMESXiHost



# Connect to EsxCli
$esxcli = Get-EsxCli -VMHost $Hosts[0]



### Diagnostic
# Retrieve a list of the snapshots that have been presented to the host (our cloned volume should be present)
# $snapInfo = $esxcli.storage.vmfs.snapshot.list()
# $snapInfo | where-object { ($_.VolumeName -match $SourceDatastoreName) }
# $snapInfo



# Resignature the cloned datastore
$esxcli.storage.vmfs.snapshot.resignature($SourceDatastoreName)



# Find the newly resignatured datastore name
# NOTE:
#    After a datastore is resignatured, its name will be "snap-[GUID chars]-[original DS name]"
#    This is why the wildcard match below is needed.
$clonedDatastore = (Get-Datastore | ? { $_.name -match 'snap' -and $_.name -match $SourceDatastoreName })

while ($clonedDatastore -eq $null) {
    # We may have to wait a little bit before the datastore is fully operational
    Start-Sleep -Seconds 5
    $clonedDatastore = (Get-Datastore | Where-Object { $_.name -match 'snap' -and $_.name -match $SourceDatastoreName })
}
# $clonedDatastore



# Must rescan storage again so ESXi hosts(s) can see the new cloned datastore
Get-VMHostStorage -RescanAllHba -RescanVmfs -VMHost $VMESXiHost



###
# Prep SQL & Windows for VMDK overlay

# Offline the target database(s) in SQL Server by looping through $Databases array
Foreach ($database in $Databases) {
    # Offline the database
    $Query = "ALTER DATABASE " + $($database) + " SET OFFLINE WITH ROLLBACK IMMEDIATE"
    Invoke-Command -Session $TargetVMSession -ScriptBlock {Param($querytask) Invoke-Sqlcmd -ServerInstance . -Database master -Query $querytask} -ArgumentList ($Query)
}



# Offline the volumes that have SQL data in Windows by looping through $TargetDevices array
Foreach ($targetdevice in $TargetDevices) {
    Invoke-Command -Session $TargetVMSession -ScriptBlock {Param($currentdisk) Get-Disk | ? { $_.SerialNumber -eq $($currentdisk) } | Set-Disk -IsOffline $True } -ArgumentList ($targetdevice)
}



# Remove the VMDK(s) with stale database files from the VM
Foreach ($TargetVMDKPath in $TargetVMDKPaths) {
    $harddisk = Get-HardDisk -VM $TargetSQLServerVM | ? { $_.FileName -match $TargetVMDKPath } 
    Remove-HardDisk -HardDisk $harddisk -Confirm:$false -DeletePermanently
}



# Attach the VMDK from the newly cloned datastore back to the target VM
Foreach ($SourceVMDKPath in $SourceVMDKPaths) {
    $newlyAttachedDisk = New-HardDisk -VM $TargetSQLServerVM -DiskPath "[$($clonedDatastore.Name)] $SourceVMDKPath"
}



# Online the volume(s) on the target VM by looping through $TargetDevices array
Foreach ($targetdevice in $TargetDevices) {
    Invoke-Command -Session $TargetVMSession -ScriptBlock {Param($currentdisk) Get-Disk | Where-Object { $_.SerialNumber -eq $($currentdisk) } | Set-Disk -IsOffline $False } -ArgumentList ($targetdevice)
}



# Volume might be read-only, ensure it's read/write
Foreach ($targetdevice in $TargetDevices) {
    Invoke-Command -Session $TargetVMSession -ScriptBlock {Param($currentdisk) Get-Disk | Where-Object { $_.SerialNumber -eq $($currentdisk) } | Set-Disk -IsReadOnly $False } -ArgumentList ($targetdevice)
}



# Online the target database(s) by looping through $Databases array
Foreach ($database in $databases) {
    $Query = "ALTER DATABASE " + $($database) + " SET ONLINE WITH ROLLBACK IMMEDIATE"
    Invoke-Command -Session $TargetVMSession -ScriptBlock {Param($querytask) Invoke-Sqlcmd -ServerInstance . -Database master -Query $querytask} -ArgumentList ($Query)
}



###
# Databases should now be online and usable
# Start cleanup next



# Perform Storage vMotion to move the new VMDK disk(s) to the original source datastore.
$destinationDatastore = Get-Datastore -Name $TargetDatastoreName

Foreach ($SourceVMDKPath in $SourceVMDKPaths) {
    $newlyAttachedDisk = Get-HardDisk -VM $TargetSQLServerVM | ? { $_.FileName -match $SourceVMDKPath } 
    Move-HardDisk -HardDisk $newlyAttachedDisk -Datastore $destinationDatastore -Confirm:$false
}



# Guest hard disk removed, now remove the stale datastore - this can take a min or two
Remove-Datastore -Datastore $clonedDatastore -VMHost $Hosts[0] -Confirm:$false



# On FlashArray, disconnect the cloned volume from the ESXi cluster
Remove-Pfa2Connection -Array $FlashArray -HostGroupName $FAHostGroupName -VolumeName $NewClonedVolumeName



# On FlashArray, destroy the cloned volume
Remove-Pfa2Volume -Array $FlashArray -Name $NewClonedVolumeName



# Clean up
Remove-PSSession $TargetVMSession
