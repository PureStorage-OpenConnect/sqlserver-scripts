##############################################################################################################################
# ActiveDR - Manual Failover for SQL Server
# 
# Scenario: 
#    Manually failover Production to DR.  Then fully failback.
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
#    This script is meant to be run in chunks; note the Part X headers.  Each Part represents an independent workflow in 
#    the greater context of a DR manual failover and manual failback.  DO NOT run everything at once!
#
# Disclaimer:
#    This example script is provided AS-IS and meant to be a building block to be adapted to fit an individual 
#    organization's infrastructure.
##############################################################################################################################



#########################################
# PART 1: DEMOTE PRODUCTION POD
#########################################



# Import PowerShell modules
Import-Module PureStoragePowerShellSDK2
Import-Module SqlServer



# Set Variables
$ProductionArrayName          = "flasharray1.example.com"              # Production FlashArray
$PodName                      = "ActiveDrPod"                          # Pod name on the DR FlashArray
$ProductionSQLServer          = "SqlServer1"                           # Production SQL Server
$DatabaseName                 = "ExampleDb"                            # Name of database
$TargetDiskSerialNumber1      = '6000c02022cb876dcd321example01a'      # Target Disk Serial Number - ex: Data volume
$TargetDiskSerialNumber2      = '6000c02022cb876dcd321example02b'      # Target Disk Serial Number - ex: Log volume



# Connect to Production VM
$ProductionSQLServerSession = New-PSSession -ComputerName $ProductionSQLServer 



# Connect to FlashArray
$Credential = Get-Credential
$FlashArray = Connect-Pfa2Array -Endpoint $DRArrayName -Credential $Credential -IgnoreCertificateError



# Offline the database
$Query = "ALTER DATABASE [$DatabaseName] SET OFFLINE WITH ROLLBACK IMMEDIATE"
Invoke-Sqlcmd -ServerInstance $ProductionSQLServer -Database master -Query $Query



# Offline the volumes
Invoke-Command -Session $ProductionSQLServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDiskSerialNumber1 } | Set-Disk -IsOffline $True }
Invoke-Command -Session $ProductionSQLServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDiskSerialNumber2 } | Set-Disk -IsOffline $True }



# Confirm state of disks
Invoke-Command -Session $ProductionSQLServerSession -ScriptBlock { Get-Disk | Format-Table }



# Demote Production Pod with Quiesce
Update-Pfa2Pod -Array $FlashArray -Name $PodName -Quiesce $True -RequestedPromotionState "demoted"



# Confirm Production Pod status - PromotionStatus : demoted
Get-Pfa2Pod -Array $FlashArray -Name $PodName



#########################################
# PART 2: PROMOTE DR FAILOVER POD
#########################################



# Import PowerShell modules
Import-Module PureStoragePowerShellSDK2
Import-Module SqlServer



# Set Variables
$DRArrayName                  = "flasharray1.example.com"              # DR FlashArray
$PodName                      = "ActiveDrPod"                          # Pod name on the DR FlashArray
$DRSQLServer                  = "SqlServer1"                           # Production SQL Server
$DatabaseName                 = "ExampleDb"                            # Name of database



# Connect to DR VM
$DRSQLServerSession = New-PSSession -ComputerName $DRSQLServer 



# Connect to FlashArray
$Credential = Get-Credential
$FlashArray = Connect-Pfa2Array -Endpoint $DRArrayName -Credential $Credential -IgnoreCertificateError



# Promote DR pod
Update-Pfa2Pod -Array $FlashArray -Name $PodName -RequestedPromotionState "promoted"



# Confirm pod promoted - PromotionStatus : promoted
Get-Pfa2Pod -Array $FlashArray -Name $PodName



# Disks will be presented back to Windows but serial number may not be materialized.
# Because disk serial number can change between reboots, need to programmatically reference
# serial number to properly identify which disks to manipulate.
# Use Get-Disk to determine disk serial numbers
Invoke-Command -Session $DRSQLServerSession -ScriptBlock { Get-Disk | Format-Table }



# Set disk serial numbers to variables
$TargetDiskSerialNumber1 = "6000c02022cb876dcd321example01a"    # Serial Number of data disk
$TargetDiskSerialNumber2 = "6000c02022cb876dcd321example02b"    # Serial Number of log disk



# Waiting for DR volumes to come online
while (($DiskOne -eq $null) -or ($DiskTwo -eq $null)) {
    Invoke-Command -Session $DRSQLServerSession -ScriptBlock { Update-HostStorageCache }
    $DiskOne = Invoke-Command -Session $DRSQLServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDiskSerialNumber1 }  }
    $DiskTwo = Invoke-Command -Session $DRSQLServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDiskSerialNumber2 }  }
}



# Online the windows disks 
Invoke-Command -Session $DRSQLServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDiskSerialNumber1 } | Set-Disk -IsOffline $False }
Invoke-Command -Session $DRSQLServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDiskSerialNumber2 } | Set-Disk -IsOffline $False }



# Setting volumes to Read/Write
Invoke-Command -Session $DRSQLServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDiskSerialNumber1 } | Set-Disk -IsReadOnly $False }
Invoke-Command -Session $DRSQLServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDiskSerialNumber2 } | Set-Disk -IsReadOnly $False }



# Confirm state of disks
Invoke-Command -Session $DRSQLServerSession -ScriptBlock { Get-Disk | Format-Table }



# Online the database
$Query = "ALTER DATABASE [$DatabaseName] SET ONLINE WITH ROLLBACK IMMEDIATE"
Invoke-Sqlcmd -ServerInstance $DRSQLServer -Database master -Query $Query



#########################################
# PART 3: FAILBACK DR TO PRODUCTION
#########################################



# Import PowerShell modules
Import-Module PureStoragePowerShellSDK2
Import-Module SqlServer



# Set Variables
$ProductionArrayName          = "flasharray1.example.com"              # Production FlashArray
$DRArrayName                  = "flasharray1.example.com"              # DR FlashArray
$PodName                      = "ActiveDrPod"                          # Pod name on the DR FlashArray
$ProductionSQLServer          = "SqlServer1"                           # Production SQL Server  
$DRSQLServer                  = "SqlServer1"                           # DR SQL Server
$DatabaseName                 = "ExampleDb"                            # Name of database
$TargetDiskSerialNumber1      = '6000c02022cb876dcd321example01a'      # Target Disk Serial Number - ex: Data volume
$TargetDiskSerialNumber2      = '6000c02022cb876dcd321example02b'      # Target Disk Serial Number - ex: Log volume



# Connect to DR VM
$DRSQLServerSession = New-PSSession -ComputerName $DRSQLServer 



# Connect to FlashArray
$Credential = Get-Credential
$FlashArray = Connect-Pfa2Array -Endpoint $DRArrayName -Credential $Credential -IgnoreCertificateError



# Offline the database
$Query = "ALTER DATABASE [$DatabaseName] SET OFFLINE WITH ROLLBACK IMMEDIATE"
Invoke-Sqlcmd -ServerInstance $DRSQLServer -Database master -Query $Query



# Offline the volume
Invoke-Command -Session $DRSQLServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDiskSerialNumber1 } | Set-Disk -IsOffline $True }
Invoke-Command -Session $DRSQLServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDiskSerialNumber2 } | Set-Disk -IsOffline $True }



# Confirm state of disks
Invoke-Command -Session $DRSQLServerSession -ScriptBlock { Get-Disk | Format-Table}



# Demote Production Pod with Quiesce
Update-Pfa2Pod -Array $FlashArray -Name $PodName -Quiesce $true -RequestedPromotionState "demoted"



# Confirm Production Pod status - PromotionStatus : demoted
Get-Pfa2Pod -Array $FlashArray | Where-Object {$_.Name -eq $PodName}



# Connect to Production VM
$ProductionSQLServerSession = New-PSSession -ComputerName $ProductionSQLServer 



# Connect to FlashArray
$Credential = Get-Credential
$FlashArray = Connect-Pfa2Array -Endpoint $ProductionArrayName -Credential $Credential -IgnoreCertificateError



# Promote Production pod
Update-Pfa2Pod -Array $FlashArray -Name $PodName -RequestedPromotionState "promoted"



# Confirm pod promoted - PromotionStatus : promoted
Get-Pfa2Pod -Array $FlashArray -Name $PodName



# Online the windows disks 
Invoke-Command -Session $ProductionSQLServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDiskSerialNumber1 } | Set-Disk -IsOffline $False }
Invoke-Command -Session $ProductionSQLServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDiskSerialNumber2 } | Set-Disk -IsOffline $False }



# Setting volumes to Read/Write
Invoke-Command -Session $ProductionSQLServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDiskSerialNumber1 } | Set-Disk -IsReadOnly $False }
Invoke-Command -Session $ProductionSQLServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDiskSerialNumber2 } | Set-Disk -IsReadOnly $False }



# Confirm state of disks
Invoke-Command -Session $ProductionSQLServerSession -ScriptBlock { Get-Disk | Format-Table }



# Online the database
$Query = "ALTER DATABASE [$DatabaseName] SET OFFLINE WITH ROLLBACK IMMEDIATE"
Invoke-Sqlcmd -ServerInstance $ProductionSQLServer -Database master -Query $Query