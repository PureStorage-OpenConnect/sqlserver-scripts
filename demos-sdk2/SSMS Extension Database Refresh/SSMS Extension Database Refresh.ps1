#Use a config from the SSMS Extension
$ConfigName = "aen-sql-22_ft_demo" 
$Target = 'aen-sql-02'
$AttachDbName = 'FT_Demo_NEW'

#Execute a SSMS Extension backup
Invoke-PfaBackupJob -ConfigName $ConfigName

#Get the most recent backup
$MostRecentBackup = Get-PfaBackupHistory | Where-Object { $_.ConfigName -eq $ConfigName } | Sort-Object -Property TimeCreated -Descending | Select-Object -First 1

#Get an available drive letter on the system we want to mount the snapshot to
$DriveLetter = Get-PfaBackupAvailableDrives -ComputerName $Target | Select-Object -Last 1

#Mount that backup to another Virtual Machine
Mount-PfaBackupJob -HistoryId $MostRecentBackup.HistoryId -DriveLetter $DriveLetter -MountComputer $Target -MountVMName $Target

$AttachDbSql = "USE [master]
    GO
    CREATE DATABASE [" + $AttachDbName + "] ON 
    ( FILENAME = N'Y:\FT_Demo.mdf' ),
    ( FILENAME = N'Y:\FT_Demo_log.LDF' ),
    ( FILENAME = N'Y:\FT_Demo_Base_1.ndf' ),
    ( FILENAME = N'Y:\FT_Demo_part_ci1_01.ndf' ),
    ( FILENAME = N'Y:\FT_Demo_part_ci2_01.ndf' ),
    ( FILENAME = N'Y:\FT_Demo_part_ci3_01.ndf' ),
    ( FILENAME = N'Y:\FT_Demo_part_ci4_01.ndf' ),
    ( FILENAME = N'Y:\FT_Demo_part_ci5_01.ndf' ),
    ( FILENAME = N'Y:\FT_Demo_part_ci6_01.ndf' ),
    ( FILENAME = N'Y:\FT_Demo_part_ci7_01.ndf' )
    FOR ATTACH
    GO
"

#Attach the Database
Invoke-Sqlcmd -ServerInstance $Target -Database master -Query $AttachDbSql

#####CLEANUP#####
###Detach the database
Invoke-Sqlcmd -ServerInstance $Target -Database master -Query "EXEC master.dbo.sp_detach_db @dbname = N'$AttachDbName'"

#Get the ID of the mounted volume job
$MountedDriveHistoryId = Get-PfaBackupHistory | Where-Object { $_.ConfigName -eq $ConfigName -and $_.MountDrive -eq $DriveLetter} | Sort-Object -Property TimeCreated -Descending | Select-Object -First 1

#Remove the mounted volume
Dismount-PfaDrive -HistoryId $MountedDriveHistoryId.HistoryId


