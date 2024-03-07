##############################################################################################################################
# Multi-ArraySnapshot - Using SQL Server 2022's T-SQL Snapshot Backup feature 
# to take a consistent snapshot across two arrays
#
# Scenario: 
#    Single test database named "MultiArraySnapshot" which has data files and a log file
#    on two volumes that are each on different FlashArrays.
#
# Prerequisites:
# 1. A SQL Server running SQL Server 2022 with a database having data files and a log file
#    on two volumes that are each on different FlashArrays.
# 2. This demo uses the dbatools cmdlet Connect-DbaInstance to build a persistent SMO 
#    session to the database instance.  This is required when using the T-SQL Snapshot 
#    feature because the session in which the database is frozen for IO must stay active.  
#    Other cmdlets disconnect immediately, which will thaw the database prematurely before 
#    the snapshot is taken.
# 3. The overall process is to freeze the database using TSQL Snapshot, 
#    then take a snapshot on each array, and then write the metadata file to a network 
#    share, which thaws the database.
#
#
# Usage Notes:
#   Each section of the script is meant to be run one after the other. The script is not meant to be executed all at once.
#
#
# Disclaimer:
#    This example script is provided AS-IS and is meant to be a building
#    block to be adapted to fit an individual organization's 
#    infrastructure.
##############################################################################################################################




# Import powershell modules
Import-Module dbatools
Import-Module PureStoragePowerShellSDK2



# Initalize a collection variables we'll use for connections to our SQL Server, it's base OS and our FlashArrays
$TargetSQLServer  = 'SqlServer1'                        # SQL Server Name
$ArrayName1       = 'flasharray1.example.com'           # First FlashArray
$ArrayName2       = 'flasharray2.example.com'           # Second FlashArray
$PGroupName1      = 'SqlServer1_Pg'                     # Name of the Protection Group on FlashArray1
$PGroupName2      = 'SqlServer1_Pg'                     # Name of the Protection Group on FlashArray2
$DbName           = 'MultiArraySnapshot'                # Name of database
$FlashArray1DbVol = 'Fa1_Sql_Volume_1'                  # Volume name on FlashArray1 containing database files
$FlashArray2DbVol = 'Fa2_Sql_Volume_1'                  # Volume name on FlashArray2 containing database files
$BackupShare      = '\\FileServer1\SHARE\BACKUP'        # File system location to write the backup metadata file
$TargetDisk1      = '6000c296dd4362f1a9263c53f2d9d6c1'  # The serial number if the Windows volume containing database files
$TargetDisk2      = '6000c29ef1396de0dad628b856523709'  # The serial number if the Windows volume containing database files



# Build a PowerShell Remoting Session to the Server and a persistent SMO connection.
$SqlServerSession = New-PSSession -ComputerName $TargetSQLServer
$SqlInstance = Connect-DbaInstance -SqlInstance $TargetSQLServer -TrustServerCertificate -NonPooledConnection



# Connect to the FlashArrays' REST APIs
$Credential = Get-Credential
$FlashArray1 = Connect-Pfa2Array –EndPoint $ArrayName1 -Credential $Credential -IgnoreCertificateError
$FlashArray2 = Connect-Pfa2Array –EndPoint $ArrayName2 -Credential $Credential -IgnoreCertificateError



# Freeze the database, using SQL Server 2022's T-SQL Snapshot Backup
$Query = "ALTER DATABASE $DbName SET SUSPEND_FOR_SNAPSHOT_BACKUP = ON"
Invoke-DbaQuery -SqlInstance $SqlInstance -Query $Query -Verbose



# Take a snapshot of the Protection Groups on each array
$SnapshotFlashArray1 = New-Pfa2ProtectionGroupSnapshot -Array $FlashArray1 -SourceName $PGroupName1
$SnapshotFlashArray2 = New-Pfa2ProtectionGroupSnapshot -Array $FlashArray2 -SourceName $PGroupName2



# Take a metadata backup of the database, this will automatically unfreeze if successful
# We'll use MEDIADESCRIPTION to hold some information about our snapshot
$BackupFile = "$BackupShare\$DbName_$(Get-Date -Format FileDateTime).bkm"
$Query = "BACKUP DATABASE $DbName 
          TO DISK='$BackupFile' 
          WITH METADATA_ONLY"
Invoke-DbaQuery -SqlInstance $SqlInstance -Query $Query -Verbose



# The backup is recorded in MSDB as a Full backup with snapshot
$BackupHistory = Get-DbaDbBackupHistory -SqlInstance $SqlInstance -Database $DbName -Last
$BackupHistory



# Delete a table...I should update my resume, right? :P 
Invoke-DbaQuery -SqlInstance $SqlInstance -Database $DbName -Query "DROP TABLE T1"



# Offline the database, which we'd have to do anyway if we were restoring a full backup
$Query = "ALTER DATABASE $DbName SET OFFLINE WITH ROLLBACK IMMEDIATE" 
Invoke-DbaQuery -SqlInstance $SqlInstance -Database master -Query $Query



# Offline the volume
Write-Output "Offlining the volume..." -ForegroundColor Red
Invoke-Command -Session $SqlServerSession `
  -ScriptBlock { 
    Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDisk1 } | Set-Disk -IsOffline $True;
    Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDisk2 } | Set-Disk -IsOffline $True;
}


# Restore the protection group snapshot over the volumes, first on $FlashArray1
New-Pfa2Volume -Array $FlashArray1 -Name $FlashArray1DbVol -SourceName ($SnapshotFlashArray1.Name + ".$FlashArray1DbVol") -Overwrite $true 



# Restore the protection group snapshot over the volumes, then on $FlashArray2
New-Pfa2Volume -Array $FlashArray2 -Name $FlashArray2DbVol -SourceName ($SnapshotFlashArray2.Name + ".$FlashArray2DbVol") -Overwrite $true



# Online the volumes
Invoke-Command -Session $SqlServerSession `
  -ScriptBlock { 
    Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDisk1 } | Set-Disk -IsOffline $False;
    Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDisk2 } | Set-Disk -IsOffline $False;
 }



# Restore the database with no recovery, which means we can restore LOG native SQL Server backups 
$Query = "RESTORE DATABASE $DbName FROM DISK = '$BackupFile' WITH METADATA_ONLY, REPLACE" 
Invoke-DbaQuery -SqlInstance $SqlInstance -Database master -Query $Query -Verbose




# Let's check the current state of the database...its ONLINE
Get-DbaDbState -SqlInstance $SqlInstance -Database $DbName



# Let's see if our table is back in our database...
# whew...we don't have to tell anybody since our restore was so fast :P 
Get-DbaDbTable -SqlInstance $SqlInstance -Database $DbName -Table 'T1' | Format-Table



# How long does this process take, this demo usually takes 450ms? 
$Start = (Get-Date)



# Freeze the database
$Query = "ALTER DATABASE $DbName SET SUSPEND_FOR_SNAPSHOT_BACKUP = ON"
Invoke-DbaQuery -SqlInstance $SqlInstance -Query $Query -Verbose



# Take a snapshot of the two volumes while the database is frozen
$SnapshotFlashArray1 = New-Pfa2ProtectionGroupSnapshot -Array $FlashArray1 -SourceName $PGroupName1
$SnapshotFlashArray2 = New-Pfa2ProtectionGroupSnapshot -Array $FlashArray2 -SourceName $PGroupName2



# Take a metadata backup of the database, this will automatically unfreeze if successful
# We'll use MEDIADESCRIPTION to hold some information about our snapshot
$BackupFile = "$BackupShare\$DbName_$(Get-Date -Format FileDateTime).bkm"
$Query = "BACKUP DATABASE $DbName 
          TO DISK='$BackupFile' 
          WITH METADATA_ONLY"
Invoke-DbaQuery -SqlInstance $SqlInstance -Query $Query -Verbose



$Stop = (Get-Date)
Write-Output "The snapshot time takes...$(($Stop - $Start).Milliseconds)ms!"



# Clean up
Remove-PSSession $SqlServerSession
Get-DbaConnectedInstance | Disconnect-DbaInstance