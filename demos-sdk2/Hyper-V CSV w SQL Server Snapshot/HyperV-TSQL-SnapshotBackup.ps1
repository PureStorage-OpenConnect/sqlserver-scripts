##############################################################################################################################
# T-SQL Snapshot Backup and Point-in-Time Recovery - Hyper-V Edition
#
# Scenario:
#    This script demonstrates SQL Server 2022 T-SQL Snapshot Backup on a Hyper-V cluster where database files
#    reside on VHDXs stored on a Pure Storage FlashArray Cluster Shared Volume (CSV). An application-consistent
#    snapshot is taken while SQL Server is running on VM1 (SQL 01), then the cloned volume is presented to VM2
#    (SQL 02) for a point-in-time restore.
#
#    Storage topology:
#       Source  : hyperv-csv-01-DATA-PROD (CSV backing VM1 VHDXs)  -> SQL 01 (Production)
#       Target  : hyperv-csv-01-DATA-DEV  (CSV backing VM2 VHDXs)  -> SQL 02 (Dev/Test)
#
#    This example scenario is useful for seeding a dev/test SQL Server from a production FlashArray CSV with
#    a full point-in-time recovery chain.
#
#
# Prerequisites:
#
#    FlashArray:
#       1. Source and target volumes must be pre-configured on the FlashArray.
#          The target volume must be the same size as the source CSV volume.
#
#    Hyper-V Cluster:
#       2. The Failover Cluster PowerShell module must be installed on the Hyper-V node(s).
#             Add-WindowsFeature RSAT-Clustering-PowerShell
#       3. PowerShell Remoting (WinRM) must be enabled on all Hyper-V cluster nodes.
#       4. The target VM must have a SCSI controller — hot-add/remove of virtual disks requires SCSI (not IDE).
#
#    Modules:
#       5. PureStoragePowerShellSDK2 must be installed on the machine running this script.
#             Install-Module PureStoragePowerShellSDK2
#       6. dbatools must be installed.
#             Install-Module dbatools
#
#    SQL Server:
#       7. SQL Server 2022 or later is required on both instances for T-SQL Snapshot Backup support.
#       8. $DbName must already exist on the target SQL Server.
#       9. A backup share must be accessible from both SQL 01 and SQL 02 for metadata and log backup files.
#
#    Credentials:
#      10. Saved credentials file: $HOME\FA_Cred.xml
#             $FACred | Export-CliXml -Path "$HOME\FA_Cred.xml"
#
#
# Usage Notes:
#
#    This script uses a volume snapshot (New-Pfa2VolumeSnapshot) rather than a Protection Group snapshot because
#    the data and log VHDXs share a single CSV volume — a single volume snapshot captures both files consistently.
#    The SUSPEND_FOR_SNAPSHOT_BACKUP and BACKUP METADATA_ONLY commands must share the same SQL Server session;
#    this script uses a persistent, non-pooled dbatools connection to satisfy that requirement.
#
#
# Disclaimer:
#    This example script is provided AS-IS and meant to be a building block to be adapted to fit an individual
#    organization's infrastructure.
##############################################################################################################################



# Import PowerShell modules
Import-Module dbatools
Import-Module PureStoragePowerShellSDK2



# Initialize variables — edit these to match your environment
$SourceSQLServer   = 'sql-01.example.com'                     # SQL Server hosting the source database
$TargetSQLServer   = 'sql-02.example.com'                     # SQL Server that will receive the clone
$ArrayName         = 'flasharray1.example.com'                # FlashArray endpoint
$DbName            = 'MyDatabaseName'                         # Database name
$BackupShare       = '\\backup-server\BACKUP'                 # UNC path for metadata and log backups

# Hyper-V cluster details
$HVNode2           = 'hyperv-node-02.example.com'             # Hyper-V cluster node that owns the target CSV
$TargetVM          = 'hyperv-vm-02'                            # VM name receiving the cloned VHDXs
$TargetCSVResource = 'Cluster Disk 3'                          # Cluster resource name for the target CSV

# FlashArray volume names
$SourceVolName     = 'hyperv-csv-01-DATA-PROD'                 # FA volume backing the source CSV
$TargetVolName     = 'hyperv-csv-01-DATA-DEV'                  # FA volume backing the target CSV

# VHDX paths on the target CSV (after clone)
$ClonedDataVhdx    = 'C:\ClusterStorage\Volume3\hyperv-vm-01\hyperv-vm-01-Data.vhdx'
$ClonedLogVhdx     = 'C:\ClusterStorage\Volume3\hyperv-vm-01\hyperv-vm-01-Log.vhdx'

# SCSI controller locations for VHDXs on the target VM
$DataCtrlNum = 0; $DataCtrlLoc = 1                             # Data VHDX at SCSI 0:1
$LogCtrlNum  = 0; $LogCtrlLoc  = 2                             # Log  VHDX at SCSI 0:2



# Build connections
# PowerShell remoting session to the Hyper-V cluster node hosting the target CSV
$HVSession = New-PSSession -ComputerName $HVNode2

# Persistent, non-pooled SMO connections — required so SUSPEND_FOR_SNAPSHOT_BACKUP
# and BACKUP METADATA_ONLY share the same session (SUSPEND is session-scoped)
$SqlInstance1 = Connect-DbaInstance -SqlInstance $SourceSQLServer -TrustServerCertificate -NonPooledConnection
$SqlInstance2 = Connect-DbaInstance -SqlInstance $TargetSQLServer -TrustServerCertificate -NonPooledConnection

# Connect to the FlashArray's REST API
$FACred     = Import-CliXml -Path "$HOME\FA_Cred.xml"
$FlashArray = Connect-Pfa2Array -EndPoint $ArrayName -Credential $FACred -IgnoreCertificateError




# Let's get some information about the source database; take note of the size
Get-DbaDatabase -SqlInstance $SqlInstance1 -Database $DbName |
    Select-Object Name, SizeMB, Status



#############################################################################
# Take a T-SQL Snapshot Backup
#############################################################################

# Time the freeze window — this measures how long SQL Server write IO is frozen
$Start = (Get-Date)


# Freeze the database for write IO on SQL 01
$Query = "ALTER DATABASE [$DbName] SET SUSPEND_FOR_SNAPSHOT_BACKUP = ON"
Invoke-DbaQuery -SqlInstance $SqlInstance1 -Query $Query -Verbose


# Take a volume snapshot while the database is frozen
$Snapshot = New-Pfa2VolumeSnapshot -Array $FlashArray -SourceName $SourceVolName
$Snapshot


# Write the metadata-only backup — this releases the write IO freeze
# MEDIADESCRIPTION stores the snapshot name and array so we can locate the snapshot later
$BackupFile = "$BackupShare\${DbName}_$(Get-Date -Format FileDateTime).bkm"
$Query = "BACKUP DATABASE [$DbName]
          TO DISK='$BackupFile'
          WITH METADATA_ONLY,
               MEDIADESCRIPTION='$($Snapshot.Name)|$($FlashArray.ArrayName)'"
Invoke-DbaQuery -SqlInstance $SqlInstance1 -Query $Query -Verbose

$Stop = (Get-Date)
Write-Output "The snapshot time takes...$(($Stop - $Start).TotalMilliseconds)ms!"


# Check the error log to see what SQL Server thinks happened
Get-DbaErrorLog -SqlInstance $SqlInstance1 -LogNumber 0 | Format-Table


# The backup is recorded in MSDB as a Full backup with snapshot
Get-DbaDbBackupHistory -SqlInstance $SqlInstance1 -Database $DbName -Last



#############################################################################
# Take a Log Backup — this extends the restore chain for point-in-time recovery
#############################################################################

$LogBackup = Backup-DbaDatabase -SqlInstance $SqlInstance1 `
    -Database $DbName `
    -Type Log `
    -Path $BackupShare `
    -CompressBackup

$LogBackup



#############################################################################
# Point in Time Recovery — Clone the Snapshot to SQL 02
#
# This is the Hyper-V equivalent of taking the database disk offline, cloning
# the storage snapshot, and bringing the disk back online as described in the
# blog series. Instead of managing a Windows disk serial number, we manage the
# CSV cluster resource and the VHDXs attached to the target Hyper-V VM.
#############################################################################

# Retrieve the snapshot name from the metadata backup file
# MEDIADESCRIPTION holds the pipe-delimited string we wrote during the backup
$Query = "RESTORE LABELONLY FROM DISK = '$BackupFile'"
$Labels = Invoke-DbaQuery -SqlInstance $SqlInstance2 -Query $Query -Verbose
$SnapshotName = (($Labels | Select-Object MediaDescription -ExpandProperty MediaDescription).Split('|'))[0]
$ArrayName    = (($Labels | Select-Object MediaDescription -ExpandProperty MediaDescription).Split('|'))[1]
$SnapshotName
$ArrayName


# Offline the database on SQL 02 to release file handles
$Query = "ALTER DATABASE [$DbName] SET OFFLINE WITH ROLLBACK IMMEDIATE"
Invoke-DbaQuery -SqlInstance $SqlInstance2 -Query $Query
$RestoreStart = (Get-Date)



# Detach VHDXs from the target VM before taking the CSV offline
Invoke-Command -Session $HVSession -ScriptBlock {
    param($vm)
    Remove-VMHardDiskDrive -VMName $vm -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 1
    Remove-VMHardDiskDrive -VMName $vm -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 2
    Write-Output "Data VHDX detached (SCSI 0:1)"
    Write-Output "Log  VHDX detached (SCSI 0:2)"
} -ArgumentList $TargetVM


# Take the target CSV offline so the FlashArray volume can be overwritten
Invoke-Command -Session $HVSession -ScriptBlock {
    param($res)
    Stop-ClusterResource -Name $res -Cluster (Get-Cluster).Name | Out-Null
    Write-Output "$res offline"
} -ArgumentList $TargetCSVResource


# Clone the snapshot to the target volume — instantaneous on FlashArray
New-Pfa2Volume -Array $FlashArray -Name $TargetVolName -SourceName $SnapshotName -Overwrite $true


# Bring the target CSV back online
Invoke-Command -Session $HVSession -ScriptBlock {
    param($res)
    Start-ClusterResource -Name $res -Cluster (Get-Cluster).Name | Out-Null
    Write-Output "$res online"
} -ArgumentList $TargetCSVResource

Start-Sleep -Seconds 5


# Re-attach the cloned VHDXs to the target VM
Invoke-Command -Session $HVSession -ScriptBlock {
    param($dataVhdx, $logVhdx, $dCN, $dCL, $lCN, $lCL, $vm)
    Add-VMHardDiskDrive -VMName $vm -Path $dataVhdx -ControllerType SCSI -ControllerNumber $dCN -ControllerLocation $dCL
    Add-VMHardDiskDrive -VMName $vm -Path $logVhdx  -ControllerType SCSI -ControllerNumber $lCN -ControllerLocation $lCL
    Write-Output "Attached: $dataVhdx  (SCSI $($dCN):$($dCL))"
    Write-Output "Attached: $logVhdx   (SCSI $($lCN):$($lCL))"
} -ArgumentList $ClonedDataVhdx, $ClonedLogVhdx, $DataCtrlNum, $DataCtrlLoc, $LogCtrlNum, $LogCtrlLoc, $TargetVM



# Restore the database from the metadata-only backup file
# METADATA_ONLY tells SQL Server the files are already in place from the snapshot
# NORECOVERY leaves the database in RESTORING mode so we can apply log backups
$Query = "RESTORE DATABASE [$DbName] FROM DISK = '$BackupFile' WITH METADATA_ONLY, REPLACE, NORECOVERY"
Invoke-DbaQuery -SqlInstance $SqlInstance2 -Database master -Query $Query -Verbose


# Check the current state of the database — it should be in RESTORING mode
Get-DbaDbState -SqlInstance $SqlInstance2 -Database $DbName


# Restore the log backup up to the point in time — database remains in RESTORING mode
$Query = "RESTORE LOG [$DbName] FROM DISK = '$($LogBackup.BackupPath)' WITH NORECOVERY"
Invoke-DbaQuery -SqlInstance $SqlInstance2 -Database master -Query $Query -Verbose


# Bring the database online
$Query = "RESTORE DATABASE [$DbName] WITH RECOVERY"
Invoke-DbaQuery -SqlInstance $SqlInstance2 -Database master -Query $Query

$RestoreStop = (Get-Date)
Write-Output "The restore time takes...$(($RestoreStop - $RestoreStart).TotalMilliseconds)ms!"


# Verify the database is online
Get-DbaDbState -SqlInstance $SqlInstance2 -Database $DbName

Get-DbaDatabase -SqlInstance $SqlInstance2 -Database $DbName |
    Select-Object Name, Status, SizeMB




#############################################################################
# Cleanup
#############################################################################

Remove-PSSession $HVSession
Disconnect-Pfa2Array -Array $FlashArray
