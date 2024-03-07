##############################################################################################################################
#Seeding an Availability Group - Using SQL Server 2022's T-SQL Snapshot Backup feature 

# Scenario
# Seeding an Availability Group (AG) from SQL Server 2022's T-SQL Snapshot Backup

# Prerequisites
# 1. This demo uses the dbatools cmdlet Connect-DbaInstance to build a persistent 
#    SMO session to the database instance.  This is required when using the T-SQL Snapshot 
#    feature because the session in which the database is frozen for IO must stay active. 
#    Other cmdlets disconnect immediately, which will thaw the database prematurely before 
#    the snapshot is taken.
# 2. Two SQL Servers running SQL Server 2022 with a database prepared to join an AG; 
#     this database is on volumes on one FlashArray and are contained in a Protection Group, 
#     and the soon-to-be secondary replica has volumes provisioned matching the primary in size and drive lettering.
# 3.  Async snapshot replication between two FlashArrays replicating the Protection Group.
# 4.  You've disabled or are, in some other way, accounting for log backups during the seeding process.
# 5.  You already have the AG up and running, with both instances configured as replicas,
# 6.  The database you want to seed is online on the primary but not the secondary.
#
# Usage Notes:
#   Each section of the script is meant to be run one after the other. The script is not meant to be executed all at once.
#
# Disclaimer
#   This example script is provided AS-IS and is meant to be a building 
#   block to be adapted to fit an individual organization's infrastructure.
##############################################################################################################################



# Import powershell modules
Import-Module dbatools
Import-Module PureStoragePowerShellSDK2



# Set up some variables and sessions to talk to the replicas in the AG
$PrimarySqlServer   = 'SqlServer1'                          # SQL Server Name - Primary Replica
$SecondarySqlServer = 'SqlServer2'                          # SQL Server Name - Secondary Replica
$AgName             = 'ag1'                                 # Name of availability group
$DbName             = 'AgTestDb1'                           # Name of database to place in AG
$BackupShare        = '\\FileServer1\SHARE\BACKUP'          # File location for metadata backup file.
$PrimaryArrayName   = 'flasharray1.example.com'             # FlashArray containing the volumes for our primary replica
$SecondaryArrayName = 'flasharray2.example.com'             # FlashArray containing the volumes for our secondary replica
$SourcePGroupName   = 'SqlServer1_Pg'                       # Name of the Protection Group on FlashArray1
$TargetPGroupName   = 'flasharray1:SqlServer1_Pg'           # Name of the Protection Group replicated from FlashArray1 to FlashArray2, in the format of ArrayName:ProtectionGroupName
$PrimaryFaDbVol     = 'Fa1_Sql_Volume_1'                    # Volume name on FlashArray containing database files of the primary replica
$SecondaryFaDbVol   = 'Fa2_Sql_Volume_1'                    # Volume name on FlashArray containing database files of the secondary replica
$TargetDisk         = '6000c29668589f61a386218139e21bb0'    # The serial number if the Windows volume containing database files



# Build a PowerShell Remoting Session to the secondary replica
$SecondarySession = New-PSSession -ComputerName $SecondarySqlServer



# Build persistent SMO connections to each SQL Server that will participate in the availability group
$SqlInstancePrimary = Connect-DbaInstance -SqlInstance $PrimarySqlServer -TrustServerCertificate -NonPooledConnection 
$SqlInstanceSecondary = Connect-DbaInstance -SqlInstance $SecondarySqlServer -TrustServerCertificate -NonPooledConnection 



# Connect to the FlashArray with for the AG Primary
$Credential = Get-Credential
$FlashArrayPrimary = Connect-Pfa2Array –EndPoint $PrimaryArrayName -Credential $Credential -IgnoreCertificateError



# Freeze the database 
$Query = "ALTER DATABASE [$DbName] SET SUSPEND_FOR_SNAPSHOT_BACKUP = ON"
Invoke-DbaQuery -SqlInstance $SqlInstancePrimary -Query $Query -Verbose



# Take a snapshot of the Protection Group, and replicate it to our other array
$SourceSnapshot = New-Pfa2ProtectionGroupSnapshot -Array $FlashArrayPrimary -SourceName $SourcePGroupName -ForReplication $true -ReplicateNow $true



# Take a metadata backup of the database, this will automatically unfreeze if successful
# We'll use MEDIADESCRIPTION to hold some information about our snapshot
$BackupFile = "$BackupShare\$DbName$(Get-Date -Format FileDateTime).bkm"
$Query = "BACKUP DATABASE $DbName 
          TO DISK='$BackupFile' 
          WITH METADATA_ONLY, MEDIADESCRIPTION='$($SourceSnapshot.Name)|$($FlashArrayPrimary.ArrayName)'"
Invoke-DbaQuery -SqlInstance $SqlInstancePrimary -Query $Query -Verbose



# Connect to the FlashArray's REST API where the secondary's data is located
$FlashArraySecondary = Connect-Pfa2Array –EndPoint $SecondaryArrayName -Credential $Credential -IgnoreCertificateError


# This is a loop that will block until the snapshot has completed replicating between the two arrays. 
Write-Warning "Obtaining the most recent snapshot for the protection group..."
$TargetSnapshot = $null
do {
    Write-Warning "Waiting for snapshot to replicate to target array..."
    $TargetSnapshot = Get-Pfa2ProtectionGroupSnapshotTransfer -Array $FlashArraySecondary -Name $TargetPGroupName | 
            Where-Object { $_.Name -eq "$TargetPGroupName.$($SourceSnapshot.Suffix)" } 

    if ( $TargetSnapshot -and $TargetSnapshot.Progress -ne 1.0 ){
        Write-Warning "Snapshot $($TargetSnapshot.Name) found on Target Array...replication progress is $($TargetSnapshot.Progress)"
        Start-Sleep 3
    }

} while ( [string]::IsNullOrEmpty($TargetSnapshot.Completed) -or ($TargetSnapshot.Progress -ne 1.0) )
Write-Warning "Snapshot $($TargetSnapshot.Name) replicated to Target Array. Completed at $($TargetSnapshot.Completed)"


### Diagnostic
# Use this code to output the state of the variables before moving on in the script
# Check the snapshot names...ensuring the the snapshot suffix is the same for each and 
# that the TargetSnapshot.Completed is populated with the completetion date and time and that TargetSnapshot.Progress is 1 
# $SourceSnapshot.Name
# $TargetSnapshot.Name
# $TargetSnapshot.Completed
# $TargetSnapshot.Progress



# Offline the volumes on the Secondary
Invoke-Command -Session $SecondarySession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDisk } | Set-Disk -IsOffline $True }



# Overwrite the volumes on the Secondary from the protection group snapshot
New-Pfa2Volume -Array $FlashArraySecondary -Name $SecondaryFaDbVol -SourceName ($TargetSnapshot.Name + ".$PrimaryFaDbVol") -Overwrite $true



# Online the volumes on the Secondary
Invoke-Command -Session $SecondarySession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDisk } | Set-Disk -IsOffline $False }



# Restore the database with no recovery...the database state should be RESTORING
$Query = "RESTORE DATABASE [$DbName] FROM DISK = '$BackupFile' WITH METADATA_ONLY, REPLACE, NORECOVERY" 
Invoke-DbaQuery -SqlInstance $SqlInstanceSecondary -Database master -Query $Query -Verbose



# Take a log backup on the Primary
$Query = "BACKUP LOG [$DbName] TO DISK = '$BackupShare\$DbName-seed.trn' WITH FORMAT, INIT" 
Invoke-DbaQuery -SqlInstance $SqlInstancePrimary -Database master -Query $Query -Verbose



# Restore it on the Secondary
$Query = "RESTORE LOG [$DbName] FROM DISK = '$BackupShare\$DbName-seed.trn' WITH NORECOVERY" 
Invoke-DbaQuery -SqlInstance $SqlInstanceSecondary -Database master -Query $Query -Verbose



# Set the seeding mode on the Seconary to manual
$Query = "ALTER AVAILABILITY GROUP [$AgName] MODIFY REPLICA ON N'$PrimarySqlServer' WITH (SEEDING_MODE = MANUAL)"
Invoke-DbaQuery -SqlInstance $SqlInstancePrimary -Database master -Query $Query -Verbose



# Add the database to the AG
$Query = "ALTER AVAILABILITY GROUP [$AgName] ADD DATABASE [$DbName];"
Invoke-DbaQuery -SqlInstance $SqlInstancePrimary -Database master -Query $Query -Verbose



# Now let's check the status of the AG...check to see if the SynchronizationState is Synchronized
Get-DbaAgDatabase -SqlInstance $SqlInstancePrimary -AvailabilityGroup $AgName






#RESET DEMO by removing database from the AG
Get-DbaConnectedInstance | Disconnect-DbaInstance
Remove-PSSession $SecondarySession
$Query = "ALTER AVAILABILITY GROUP [$AgName] REMOVE DATABASE [$DbName];"
Invoke-DbaQuery -SqlInstance $SqlInstancePrimary -Database master -Query $Query
Remove-DbaDatabase -SqlInstance $SqlInstanceSecondary -Database FT_DEMO -Confirm:$false 
