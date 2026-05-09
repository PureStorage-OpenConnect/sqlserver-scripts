##############################################################################################################################
# Pure Storage FlashArray Snapshot Clone - Hyper-V Edition
# Crash-Consistent Snapshot Clone to a Dev/Test SQL Server
#
# Scenario:
#    This script will clone a Hyper-V Cluster Shared Volume (CSV), using a crash-consistent snapshot, and present
#    it to a second VM running a dev/test SQL Server instance. The source SQL Server continues running uninterrupted
#    throughout the entire operation. The target SQL Server performs automatic crash recovery when the database is
#    brought online.
#
#    Storage topology:
#       Source  : hyperv-csv-01-DATA-PROD (CSV backing VM1 VHDXs)  -> SQL 01 (Production)
#       Target  : hyperv-csv-01-DATA-DEV  (CSV backing VM2 VHDXs)  -> SQL 02 (Dev/Test)
#
#    This example scenario is useful for refreshing a dev/test SQL Server database from a production FlashArray CSV
#    without any downtime on the source.
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
#    Credentials:
#       7. Saved credentials file: $HOME\FA_Cred.xml
#             $FACred | Export-CliXml -Path "$HOME\FA_Cred.xml"
#       8. $DbName must already exist on the target SQL Server.
#
#
# Usage Notes:
#
#    This is a crash-consistent snapshot — SQL Server write IO is NOT frozen before the snapshot is taken.
#    The source database remains online and unaffected. The target SQL Server will perform automatic crash
#    recovery (roll forward committed transactions, roll back uncommitted) when the database is brought online.
#
#
# Disclaimer:
#    This example script is provided AS-IS and meant to be a building block to be adapted to fit an individual
#    organization's infrastructure.
##############################################################################################################################



# Import PowerShell modules
Import-Module dbatools
Import-Module PureStoragePowerShellSDK2



# Initialize variables -- edit these to match your environment
$SourceSQLServer   = 'sql-01.example.com'                      # SQL Server hosting the source database
$TargetSQLServer   = 'sql-02.example.com'                      # SQL Server that will receive the clone
$ArrayName         = 'flasharray1.example.com'                 # FlashArray endpoint
$DbName            = 'MyDatabaseName'                          # Database name

# Hyper-V cluster details
$HVNode2           = 'hyperv-node-02.example.com'              # Hyper-V cluster node that owns the target CSV
$TargetCSVResource = 'Cluster Disk 3'                          # Cluster resource name for the target CSV

# FlashArray volume names
$SourceVolName     = 'hyperv-csv-01-DATA-PROD'                 # FA volume backing the source CSV
$TargetVolName     = 'hyperv-csv-01-DATA-DEV'                  # FA volume backing the target CSV

# VHDX paths on the target CSV (mirrors the source CSV layout after clone)
$ClonedDataVhdx    = 'C:\ClusterStorage\Volume3\hyperv-vm-01\hyperv-vm-01-Data.vhdx'
$ClonedLogVhdx     = 'C:\ClusterStorage\Volume3\hyperv-vm-01\hyperv-vm-01-Log.vhdx'

# Target VM name
$TargetVM          = 'hyperv-vm-02'
$DataCtrlNum = 0; $DataCtrlLoc = 1                             # Data VHDX at SCSI 0:1
$LogCtrlNum  = 0; $LogCtrlLoc  = 2                             # Log  VHDX at SCSI 0:2



# Build connections
# PowerShell remoting session to the Hyper-V cluster node hosting the target CSV
$HVSession = New-PSSession -ComputerName $HVNode2

# SQL connections -- dbatools maintains a persistent SMO connection across cmdlet calls
$SqlInstance1 = Connect-DbaInstance -SqlInstance $SourceSQLServer -TrustServerCertificate -NonPooledConnection
$SqlInstance2 = Connect-DbaInstance -SqlInstance $TargetSQLServer -TrustServerCertificate -NonPooledConnection

# Connect to the FlashArray's REST API
$FACred     = Import-CliXml -Path "$HOME\FA_Cred.xml"
$FlashArray = Connect-Pfa2Array -EndPoint $ArrayName -Credential $FACred -IgnoreCertificateError




# Let's get some information about the source database on SQL 01; take note of the size
Get-DbaDatabase -SqlInstance $SqlInstance1 -Database $DbName |
    Select-Object Name, SizeMB, Status



#############################################################################
# Take a Crash-Consistent Snapshot
#############################################################################

# Time the full operation from snapshot to database online on SQL 02
$Start = (Get-Date)


# Take a crash-consistent volume snapshot -- SQL Server is running, no freeze
# This is equivalent to pulling the power cord and taking a picture of the disk.
# SQL 02 will perform automatic crash recovery when the database is attached.
$Snapshot = New-Pfa2VolumeSnapshot -Array $FlashArray -SourceName $SourceVolName
$Snapshot



#############################################################################
# Prepare SQL 02 -- Offline Databases and Release File Handles
#############################################################################

# Offline any user databases on SQL 02 so their file handles are released
$Query = "ALTER DATABASE [$DbName] SET OFFLINE WITH ROLLBACK IMMEDIATE"
Invoke-DbaQuery -SqlInstance $SqlInstance2 -Query $Query



#############################################################################
# Prepare the Hyper-V Storage -- Detach, Clone, Reattach
#############################################################################

# Detach the data and log VHDXs from the target VM at the hypervisor level
# The CSV must be offlined before overwriting the FlashArray volume, and the
# VHDXs must be detached before the CSV can be taken offline cleanly
Invoke-Command -Session $HVSession -ScriptBlock {
    param($vm)
    Remove-VMHardDiskDrive -VMName $vm -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 1
    Remove-VMHardDiskDrive -VMName $vm -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 2
    Write-Output "Data VHDX detached (SCSI 0:1)"
    Write-Output "Log  VHDX detached (SCSI 0:2)"
} -ArgumentList $TargetVM


# Take the target CSV offline so the underlying FlashArray volume can be overwritten
Invoke-Command -Session $HVSession -ScriptBlock {
    param($res)
    Stop-ClusterResource -Name $res -Cluster (Get-Cluster).Name | Out-Null
    Write-Output "$res offline"
} -ArgumentList $TargetCSVResource


# Clone the snapshot to the target volume -- instantaneous on FlashArray
# New-Pfa2Volume with -Overwrite $true reverts the target volume to the snapshot's contents.
# On a Pure Storage FlashArray this is a metadata operation -- no data is copied.
New-Pfa2Volume -Array $FlashArray -Name $TargetVolName -SourceName $Snapshot.Name -Overwrite $true


# Bring the target CSV back online -- the cluster will mount the now-cloned volume
Invoke-Command -Session $HVSession -ScriptBlock {
    param($res)
    Start-ClusterResource -Name $res -Cluster (Get-Cluster).Name | Out-Null
    Write-Output "$res online"
} -ArgumentList $TargetCSVResource

Start-Sleep -Seconds 5


# Re-attach the cloned VHDXs to the target VM at the same SCSI controller locations
Invoke-Command -Session $HVSession -ScriptBlock {
    param($dataVhdx, $logVhdx, $dCN, $dCL, $lCN, $lCL, $vm)
    Add-VMHardDiskDrive -VMName $vm -Path $dataVhdx -ControllerType SCSI -ControllerNumber $dCN -ControllerLocation $dCL
    Add-VMHardDiskDrive -VMName $vm -Path $logVhdx  -ControllerType SCSI -ControllerNumber $lCN -ControllerLocation $lCL
    Write-Output "Attached: $dataVhdx  (SCSI $($dCN):$($dCL))"
    Write-Output "Attached: $logVhdx   (SCSI $($lCN):$($lCL))"
} -ArgumentList $ClonedDataVhdx, $ClonedLogVhdx, $DataCtrlNum, $DataCtrlLoc, $LogCtrlNum, $LogCtrlLoc, $TargetVM




#############################################################################
# Bring the Cloned Database Online on SQL 02
#############################################################################

# Wait briefly for CSV and VHDXs to settle
Start-Sleep -Seconds 5

# Bring the database online -- SQL Server performs automatic crash recovery
# The database was never cleanly shut down before the snapshot, so SQL Server will
# roll forward the log and roll back any incomplete transactions, just as it would
# after a server restart
$Query = "ALTER DATABASE [$DbName] SET ONLINE"
Invoke-DbaQuery -SqlInstance $SqlInstance2 -Query $Query
Write-Output "$DbName is online on $TargetSQLServer"



#############################################################################
# Verify
#############################################################################

# Check the database state on SQL 02 -- it should be ONLINE after crash recovery
Get-DbaDbState -SqlInstance $SqlInstance2 -Database $DbName

# Show all user databases on SQL 02
Get-DbaDatabase -SqlInstance $SqlInstance2 -Database $DbName |
    Select-Object Name, Status, SizeMB

$Stop = (Get-Date)
Write-Output "Total time from snapshot to database online: $(($Stop - $Start).Seconds) seconds"



#############################################################################
# Cleanup
#############################################################################

Remove-PSSession $HVSession
Disconnect-Pfa2Array -Array $FlashArray
