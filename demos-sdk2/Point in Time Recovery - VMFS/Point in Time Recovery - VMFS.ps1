##############################################################################################################################
# Point In Time Recovery - Using SQL Server 2022's T-SQL Snapshot Backup feature w. VMFS/VMDK datastore/files.
#
# Scenario: 
#    Perform a point in time restore using SQL Server 2022's T-SQL Snapshot Backup 
#    feature. This uses a FlashArray snapshot as the base of the restore, then restores 
#    a log backup.
#
# IMPORTANT NOTE:
#    This example script is built for 1 database spanned across two VMDK files/volumes
#    from a single datastore. 
# 
#    The granularity or unit of work for this workflow is a VMDK file(s) and the entirety 
#    of its contents. Therefore, everything in the VMDK file(s) including files for other 
#    databases will be impacted/overwritten. 
#
#    This example will need to be adapted if you wish to support multiple databases on 
#    the same set of VMDK(s).
#
# Prerequisites:
#    1. PowerShell Modules: dbatools & PureStoragePowerShellSDK2
#
# Usage Notes:
#    * Each section of the script is meant to be run individually, one after another. 
#    * The script is NOT meant to be executed all at once.
#
# Disclaimer:
#    This example script is provided AS-IS and is meant to be a building
#    block to be adapted to fit an individual organization's 
#    infrastructure.
##############################################################################################################################



# Import powershell modules
Import-Module dbatools
Import-Module PureStoragePowerShellSDK2



# Declare all variables
# VMware variables
$VIServerName          = 'vcenter.example.com'
$SourceDatastoreName   = 'source_sql_datastore'
$SourceVMDKPaths       = @('source_vm/sqldata.vmdk','source_vm/sqllog.vmdk')



# FlashArray variables
$ArrayName             = 'flasharray1.example.com'              # FlashArray FQDN
$FAHostGroupName       = 'FAHostGroupName'                      # HostGroup Name on FlashArray for the ESXi cluster
$SourceVolumeName      = 'volume_name'                          # Volume name on FlashArray containing database files
$PGroupName            = 'protection_group'                     # Name of the Protection Group on FlashArray1



# Windows/SQL Server variables
$TargetSQLServer       = 'target_sqlserver.example.com'         # SQL Server Instance FQDN
$TargetVM              = 'target_sqlserver'                     # SQL Server VM name in VCenter
$DbName                = 'AdventureWorks'                       # Name of database
$BackupShare           = '\\flashblade1.example.com\backups'    # File system location to write the backup metadata file
$TargetDisks           = @('1234c29689bc0888d32dcd2919a67z89', '1234c299721c4ba4a937552fb298a76')    # The serial numbers of the Windows volume containing database files; use get-disk 



# Build a PowerShell Remoting Session to the Server
$SqlServerSession = New-PSSession -ComputerName $TargetSQLServer



# Build a persistent SMO connection
$SqlInstance = Connect-DbaInstance -SqlInstance $TargetSQLServer -TrustServerCertificate -NonPooledConnection



# Let's get some information about our database, take note of the size
Get-DbaDatabase -SqlInstance $SqlInstance -Database $DbName |
  Select-Object Name, SizeMB



# Connect to the FlashArray's REST API
$Credential = Get-Credential -UserName "$env:USERNAME" -Message 'Enter your credential information...'
$FlashArray = Connect-Pfa2Array –EndPoint $ArrayName -Credential $Credential -IgnoreCertificateError



####
# Execute our backup

# Freeze the database
$Query = "ALTER DATABASE $DbName SET SUSPEND_FOR_SNAPSHOT_BACKUP = ON"
Invoke-DbaQuery -SqlInstance $SqlInstance -Query $Query -Verbose



# Take a snapshot of the Protection Group while the database is frozen
$Snapshot = New-Pfa2ProtectionGroupSnapshot -Array $FlashArray -SourceName $PGroupName 



# Take a metadata backup of the database, this will automatically unfreeze 
# if successful
# We'll use MEDIADESCRIPTION to hold some information about our snapshot and 
# the flasharray its held on
$BackupFile = "$BackupShare\$DbName-$(Get-Date -Format FileDateTime).bkm"

$Query = "BACKUP DATABASE $DbName 
          TO DISK='$BackupFile' 
          WITH METADATA_ONLY, MEDIADESCRIPTION='$($Snapshot.Name)|$($FlashArray.ArrayName)'"
Invoke-DbaQuery -SqlInstance $SqlInstance -Query $Query -Verbose

###
# Backup completed



###
# Backup Verification

# Let's check out the error log to see what SQL Server thinks happened
Get-DbaErrorLog -SqlInstance $SqlInstance -LogNumber 0 -After (Get-Date).AddMinutes(-15) | Format-Table



# The backup is recorded in MSDB as a Full backup with snapshot
$BackupHistory = Get-DbaDbBackupHistory -SqlInstance $SqlInstance -Database $DbName -Last
$BackupHistory



# Let's explore the stuff in the backup header...
# Remember, VDI is just a contract saying what's in the backup matches what SQL Server thinks is in the backup.
Read-DbaBackupHeader -SqlInstance $SqlInstance -Path $BackupFile



###
# Take a Transaction Log backup
#
# NOTE: If you are testing this with a database in SIMPLE RECOVERY, there seems to be an occasional bug in 
# Backup-DbaDatabase that keeps a DataReader connection open.  Subsequent dbatools cmdlet steps may fail.
# Skip this step if your database in SIMPLE RECOVERY.
$LogBackup = Backup-DbaDatabase -SqlInstance $SqlInstance -Database $DbName -Type Log -Path $BackupShare -CompressBackup



###
# DEMO - Delete a table
Invoke-DbaQuery -SqlInstance $SqlInstance -Database $DbName -Query "SELECT TOP 10 * FROM Sales.Customer"



# Delete a table 
Invoke-DbaQuery -SqlInstance $SqlInstance -Database $DbName -Query "DROP TABLE Sales.Customer"



# Confirm it is gone
Invoke-DbaQuery -SqlInstance $SqlInstance -Database $DbName -Query "SELECT TOP 10 * FROM Sales.Customer"



###
# Review State of Database and backup

# Let's check out the state of the database, size, last full and last log
Get-DbaDatabase -SqlInstance $SqlInstance -Database $DbName | 
  Select-Object Name, Size, LastFullBackup, LastLogBackup



# We can get the snapshot name from the $Snapshot variable above, but what if we didn't know this ahead of time?
# We can also get the snapshot name from the MEDIADESCRIPTION in the backup file. 
$Query = "RESTORE LABELONLY FROM DISK = '$BackupFile'"
$Labels = Invoke-DbaQuery -SqlInstance $SqlInstance -Query $Query -Verbose
$SnapshotName = (($Labels | Select-Object MediaDescription -ExpandProperty MediaDescription).Split('|'))[0]
$ArrayName = (($Labels | Select-Object MediaDescription -ExpandProperty MediaDescription).Split('|'))[1]



###
# Start the Restore Process

# Connect to vCenter
$VIServer = Connect-VIServer -Server $VIServerName -Protocol https -Credential $Credential 
$TargetSQLServerVM = Get-VM -Server $VIServer -Name $TargetVM
$VMESXiHost = Get-VMhost -VM $TargetSQLServerVM



# Create a new volume from the selected snapshot of the source
$SnapshotSuffix = (Get-Date).ToString("yyyyMMdd-HHmmss")
$NewClonedVolumeName = "$($SourceVolumeName)-clone-$($SnapshotSuffix)"
$SnapshotSourceVolumeName = $SnapshotName + ".$SourceVolumeName"
New-Pfa2Volume -Array $FlashArray -Name $NewClonedVolumeName -SourceName $SnapshotSourceVolumeName -Overwrite $true 



# Present the new volume to the ESXi host group
New-Pfa2Connection -Array $FlashArray -HostGroupName $FAHostGroupName -VolumeName $NewClonedVolumeName



# ESXi host must now rescan storage
Get-VMHostStorage -RescanAllHba -RescanVmfs -VMHost $VMESXiHost



# Connect to EsxCli
$EsxCli = Get-EsxCli -VMHost $VMESXiHost



### Diagnostic
# Retrieve a list of the snapshots that have been presented to the host (our cloned volume should be present)
# $snapInfo = $EsxCli.storage.vmfs.snapshot.list()
# $snapInfo | where-object { ($_.VolumeName -match $SourceDatastoreName) }
# $snapInfo



# Resignature the cloned datastore
$EsxCli.storage.vmfs.snapshot.resignature($SourceDatastoreName)



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



# Must rescan storage again so ESXi hosts(s) can see the new cloned datastore
Get-VMHostStorage -RescanAllHba -RescanVmfs -VMHost $VMESXiHost



########################################
# Prepare SQL Server & Windows for the 
# snapshot overlay operation
########################################
# Offline the database, which we'd have to do anyway if we were restoring a full backup
$Query = "ALTER DATABASE $DbName SET OFFLINE WITH ROLLBACK IMMEDIATE" 
Invoke-DbaQuery -SqlInstance $SqlInstance -Database master -Query $Query



# Offline the volume(s) in Windows
Foreach ($TargetDisk in $TargetDisks) {
   Invoke-Command -Session $SqlServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDisk } | Set-Disk -IsOffline $True }
}



# Remove the original VMDK(s), within the original datastore
Foreach ($SourceVMDKPath in $SourceVMDKPaths) {
    $harddisk = Get-HardDisk -VM $TargetSQLServerVM | ? { $_.FileName -match $SourceVMDKPath } 
    Remove-HardDisk -HardDisk $harddisk -Confirm:$false -DeletePermanently
}



# Attach the new VMDK(s) from the newly cloned datastore back to the target VM
Foreach ($SourceVMDKPath in $SourceVMDKPaths) {
    $newlyAttachedDisk = New-HardDisk -VM $TargetSQLServerVM -DiskPath "[$($clonedDatastore.Name)] $SourceVMDKPath"
}



# Online the volume(s) in Windows
Foreach ($TargetDisk in $TargetDisks) {
   Invoke-Command -Session $SqlServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDisk } | Set-Disk -IsOffline $False }
}



# Restore the database with no recovery, which means we can restore LOG native SQL Server backups 
$Query = "RESTORE DATABASE $DbName FROM DISK = '$BackupFile' WITH METADATA_ONLY, REPLACE, NORECOVERY" 
Invoke-DbaQuery -SqlInstance $SqlInstance -Database master -Query $Query -Verbose



# Let's check the current state of the database...its RESTORING
Get-DbaDbState -SqlInstance $SqlInstance -Database $DbName 



# Restore the log backup.
Restore-DbaDatabase -SqlInstance $SqlInstance -Database $DbName -Path $LogBackup.BackupPath -NoRecovery -Continue



# Online the database
$Query = "RESTORE DATABASE $DbName WITH RECOVERY" 
Invoke-DbaQuery -SqlInstance $SqlInstance -Database master -Query $Query



# Verify Restore
Invoke-DbaQuery -SqlInstance $SqlInstance -Database $DbName -Query "SELECT TOP 10 * FROM dbo.Recipes"



#########################
# Begin Clean Up Steps 
#########################
$destinationDatastore = Get-Datastore -Name $SourceDatastoreName



# Perform Storage vMotion to move the new VMDK disk(s) to the original source datastore. Should be fast 
# thanks to XCOPY
Foreach ($SourceVMDKPath in $SourceVMDKPaths) {
    $newlyAttachedDisk = Get-HardDisk -VM $TargetSQLServerVM | ? { $_.FileName -match $SourceVMDKPath } 
    Move-HardDisk -HardDisk $newlyAttachedDisk -Datastore $destinationDatastore -Confirm:$false
}



# Now that the VMDKs have been moved back to the primary datastore, we can remove the temporary cloned 
# datastore - this can take a min or two.
# First, removing from VCenter
Remove-Datastore -Datastore $clonedDatastore -VMHost $VMESXiHost -Confirm:$false



# On FlashArray, disconnect the cloned volume from the ESXi cluster
Remove-Pfa2Connection -Array $FlashArray -HostGroupName $FAHostGroupName -VolumeName $NewClonedVolumeName



# On FlashArray, destroy the cloned volume
Remove-Pfa2Volume -Array $FlashArray -Name $NewClonedVolumeName



# Clean up
Remove-PSSession $SqlServerSession



