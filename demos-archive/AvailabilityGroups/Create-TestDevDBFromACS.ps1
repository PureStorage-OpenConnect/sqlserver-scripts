<#
Create-TestDevDBFromACS.ps1

: Revision 1.0.0.0
:: initial release

Example script to create a Test/Dev database using application consistant snapshots (ACS).
This is not intended to be a complete run script. It is for example purposes only.
Variables should be modified to suit the environment.

This script is provided AS-IS. No warranties expressed or implied by Pure Storage or the creator.

Requirements:
  PowerShell version 5.1
  Run from a SQL management machine with SSMS and the PureStorage SSMS extension installed.
  PowerShell remoting must also be enabled on the source and target servers.

.SYNOPSIS
Create a Test/Dev database using application consistant snapshots (ACS)

.INPUTS
None

.NOTES
This script is provided without warranty and should not be used in a production environment without proper modifications.

#>

# Declare variables
# the new DB name and mount drive letter cannot be variables as they have to be declared for the Invoke-SqlCmd.
$sourceServer = 'source' # Change to your source server
$targetServer = 'target' # Change to your target server
$sourcePSSession = New-PSSession -ComputerName $sourceServer
$targetPSSession = New-PSSession -ComputerName $targetServer
$FlashArray = 'fa1' # FlashArray IP or FQDN
$metadataDirectory = 'C:\Users\administrator\AppData\Roaming' # Folder that contains Pure SSMS extension metadata
$sourceSnapConfigName = 'configname' # Backup config name
$sourceDBName = "sourcedb" # Name of the source DB
$targetDBName = "targetdb" # name of the new target DB
$driveLetter = "s:" # Drive letter to mount to

# Enter remoting session on source server
Enter-PSSession $sourcePSSession


# Check for Pure SSMS extension on source server. This is required.
$VSSPresent = Test-Path 'HKLM:\SOFTWARE\PureStorage\VSS'
if ($VSSPresent -eq 'false') {
    Write-Host "The PureStorage SSMS extension is not installed but is required by this script. Exiting."
    Exit-PSSession
    exit
}

# Check for SQL SDK Module on source server. If not present, install it.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if ((Get-InstalledModule -Name "SQLServer" -ErrorAction SilentlyContinue) -eq $null) {
    Install-Module -Name SQLServer
    Import-Module SQLServer
}

# Backup the secondary. Set to "-CopyOnly". Could change to "-Full".
Add-PfaBackupJob -ConfigName $sourceSnapConfigName -Component $sourceDBName -ComputerName $sourceServer -FAName $FlashArray -MetadataDir $metadataDirectory -CopyOnly
Invoke-PfaBackupJob -ConfigName $sourceSnapConfigName
Remove-PfaBackupJob -ConfigName $sourceSnapConfigName

# Retrieve the snapshot and mount it to the target to drive letter s:.
$getSnapshot = Get-PfaBackupHistory | Where-Object component -eq $secondadryDB | Sort-Object HistoryId -Descending
Mount-PfaBackupJob -Historyid $getSnapshot[0].historyid -driveletter $driveLetter -mountcomputer $targetServer

Enter-PSSession $targetPSSession

# Set up variables and a splat for the SQL Invoke.
$SqlcmdVariables = @(
    "DBName=$targetDBName",
    "dataFilename=$($driveLetter):\$($sourceDBName).mdf",
    "logFilename=$($driveLetter):\$($sourceDBName).ldf"
)
$SqlcmdParameters = @{
    ServerInstance = $targetServer
    QueryTimeout   = 3600
    Query          = "SELECT '`$(DBName)' AS DBName, '`$(dataFilename)' AS dataFilename, '`$(logFilename)' AS logFilename"
    Verbose        = $true
    Variable       = $SqlcmdVariables
}

Invoke-Sqlcmd $SqlcmdParameters -erroraction 'silentlycontinue'

Exit-PSSession
Remove-PSSession $targetPSSession
Remove-PSSession $sourcePSSession

# END