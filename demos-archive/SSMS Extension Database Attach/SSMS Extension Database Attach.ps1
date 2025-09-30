##############################################################################################################################
# SSMS Extension Database Attach
#
# Scenario: 
#   Script will mount a volume to a target server and attach a database
#
# Prerequisities:
#   SSMS extension installed
#   Backup configuration created in the SSMS extension
#   Source database data and log files on one volume
#
# Usage Notes:
#   Full details on configuring the SSMS extension can be found here: -
#   https://support.purestorage.com/Solutions/Microsoft_Platform_Guide/bbb_Microsoft_Integration_Releases/Pure_Storage_FlashArray_Management_Extension_for_Microsoft_SQL_Server_Management_Studio
#
#   Each section of the script is meant to be run one after the other. The script is not meant to be executed all at once.
#   The example here used the AdventureWorks database. The attach script will have to be updated if another database is used.
# 
# Disclaimer:
# This example script is provided AS-IS and meant to be a building block to be adapted to fit an individual 
# organization's infrastructure.
# 
#
##############################################################################################################################



# Declare variables
$ConfigName         = "example_config_name" # Use a config created in the SSMS Extension
$Target             = 'SqlServer1'          # Name of target VM
$DatabaseName       = 'AdventureWorks'      # Database to be attached



# Execute a SSMS Extension backup
Invoke-PfaBackupJob -ConfigName $ConfigName



# Get the most recent backup
$MostRecentBackup = Get-PfaBackupHistory | Where-Object { $_.ConfigName -eq $ConfigName } | Sort-Object -Property TimeCreated -Descending | Select-Object -First 1



# Get an available drive letter on the system we want to mount the snapshot to
$DriveLetter = Get-PfaBackupAvailableDrives -ComputerName $Target | Select-Object -Last 1



# Mount that backup to another Virtual Machine
Mount-PfaBackupJob -HistoryId $MostRecentBackup.HistoryId -DriveLetter $DriveLetter -MountComputer $Target -MountVMName $Target



# Attach the Database - confirm filepaths!
$AttachDbSql = "USE [master]
    GO
    CREATE DATABASE [" + $DatabaseName + "] ON 
    ( FILENAME = N'$DriveLetter:\$DatabaseName.mdf' ),
    ( FILENAME = N'$DriveLetter:\$($DatabaseName)_log.ldf' )
    FOR ATTACH
    GO
"
Invoke-Sqlcmd -ServerInstance $Target -Database master -Query $AttachDbSql


