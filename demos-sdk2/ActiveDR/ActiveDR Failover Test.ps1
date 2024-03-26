##############################################################################################################################
# ActiveDR - Non-Disruptive DR Test for SQL Server
# 
# Scenario: 
#    Test failover only in DR.  Does not impact Production.  
# 
#    Single test database "ExampleDb" on two RDM volumes: data & log, on each SQL Server. 
#
# Prerequisites:
#    1. DR Pod needs to be pre-created
#    2. Databases in DR Pod need to be "initialized" by being presented and attached to the DR SQL Server, then set offline
#    3. After Step 2 initialization, be sure to retrieve applicable DR disk serial numbers & substitute in code
#    4. On DR server, SQL Server service off. Service auto-start should be set to Manual as well.
#
# Usage Notes:
#    This script is meant to be run in chunks.  Note the Part X headers.  DO NOT run everything at once!
#
# Disclaimer:
#    This example script is provided AS-IS and meant to be a building block to be adapted to fit an individual 
#    organization's infrastructure.
##############################################################################################################################



#########################################
# PART 1: PROMOTE DR FAILOVER POD
#########################################



# Import PowerShell modules
Import-Module PureStoragePowerShellSDK2
Import-Module SqlServer



# Set Variables
$ArrayName          = "flasharray1.example.com"  # DR FlashArray
$PodName            = "ActiveDrPod"              # Pod name on the DR FlashArray
$DRSQLServer        = "SqlServer1"               # DR SQL Server
$DatabaseName       = "ExampleDb"                # Name of database



# Connect to DR SQL Server
$DRSQLServerSession = New-PSSession -ComputerName $DRSQLServer



# Connect to DR FlashArray
$Credential = Get-Credential
$FlashArray = Connect-Pfa2Array -Endpoint $ArrayName -Credential $Credential -IgnoreCertificateError



# Promote DR pod
Update-Pfa2Pod -Array $FlashArray -Name $PodName -RequestedPromotionState "promoted"



# Check status of pod - do not proceed until state is promoted - PromotionStatus : promoted
Get-Pfa2Pod -Array $FlashArray -Name $PodName



# Disks will be presented back to Windows but serial number may not be materialized.
# Because disk serial number can change between reboots, need to programmatically reference
# serial number to properly identify which disks to manipulate.
# Use Get-Disk to determine disk serial numbers
Invoke-Command -Session $DRSQLServerSession -ScriptBlock { Get-Disk | Format-Table }



# Set disk serial numbers to variables
$Disk1 = "6000c02022cb876dcd321example01b"  # Serial Number of data disk
$Disk2 = "6000c02022cb876dcd321example02b"  # Serial Number of log disk



# Online the windows disks 
Invoke-Command -Session $DRSQLServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:Disk1 } | Set-Disk -IsOffline $False }
Invoke-Command -Session $DRSQLServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:Disk2 } | Set-Disk -IsOffline $False }



# Setting volumes to Read/Write
Invoke-Command -Session $DRSQLServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:Disk1 } | Set-Disk -IsReadOnly $False }
Invoke-Command -Session $DRSQLServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:Disk2 } | Set-Disk -IsReadOnly $False }



# Confirm disks are online
Invoke-Command -Session $DRSQLServerSession -ScriptBlock { Get-Disk | Format-Table }



# Online the database
$Query = "ALTER DATABASE [$DatabaseName] SET ONLINE WITH ROLLBACK IMMEDIATE"
Invoke-Sqlcmd -ServerInstance $DRSQLServer -Database master -Query $Query



# Confirm database online
$Query = "SELECT [name], [state_desc] FROM sys.databases WHERE [name] = '$DatabaseName'"
Invoke-Sqlcmd -ServerInstance $DRSQLServer -Database master -Query $Query



#########################################
# PART 2: DEMOTE DR TEST
#########################################



# Offline the database
$Query = "ALTER DATABASE [$DatabaseName] SET OFFLINE WITH ROLLBACK IMMEDIATE"
Invoke-Sqlcmd -ServerInstance $DRSQLServer -Database master -Query $Query



# Confirm database offline
$Query = "SELECT [name], [state_desc] FROM sys.databases WHERE [name] = '$DatabaseName'"
Invoke-Sqlcmd -ServerInstance $DRSQLServer -Database master -Query $Query



# Offline the volume
Invoke-Command -Session $DRSQLServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:Disk1 } | Set-Disk -IsOffline $True }
Invoke-Command -Session $DRSQLServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:Disk2 } | Set-Disk -IsOffline $True }



# Confirm disks are offline
Invoke-Command -Session $DRSQLServerSession -ScriptBlock { Get-Disk | Format-Table }



# Demote DR Pod
Update-Pfa2Pod -Array $FlashArray -Name $PodName -RequestedPromotionState "demoted"



# Confirm DR Pod status is demoted - PromotionStatus : demoted
Get-Pfa2Pod -Array $FlashArray -Name $PodName