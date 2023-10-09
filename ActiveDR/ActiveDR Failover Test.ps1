#############################################################################
# ActiveDR - Non-Disruptive DR Test for SQL Server
# 
# Author: Andy Yun
# Written: 2023-05-10
# Updated: 2023-10-09
#
# Scenario: 
# Test failover only in DR.  Do not impact Production
# 
# Single test database "CookbookDemo_ADR" on two RDM volumes: 
# data & log, on each SQL Server. 
#
# Prerequisites:
# 1. DR Pod needs to be pre-created
# 2. Databases in DR Pod need to be "initialized" by being presented
#    and attached to the DR SQL Server, then set offline
# 3. After Step 2 initialization, be sure to retrieve applicable
#    DR disk serial numbers & substitute in code
# 4. On DR server, SQL Server service off. Service auto-start should
#    be set to Manual as well.
#
# Usage Notes:
# This script is meant to be run in chunks. Break/exit commands have
# been added where appropriate. 
#
# This example script is provided AS-IS and meant to be a building
# block to be adapted to fit an individual organization's 
# infrastructure.
#
#############################################################################

#########################################
# PART 1: PROMOTE DR FAILOVER POD
#########################################

# Import PowerShell modules
Import-Module PureStoragePowerShellSDK2

# Set Variables
$ArrayName = "sn1-x70-f06-27.puretec.purestorage.com"   # DR FlashArray
$PodName = "ayun-sql03-activedr-remote"                 # Pod name on the DR FlashArray
$TargetVM = "ayun-sql19-04"                             # DR Virtual Machine

# Connect to DR VM
Write-Host "Connecting to DR VM..." -ForegroundColor Red
$TargetVMSession = New-PSSession -ComputerName $TargetVM 

# Connect to DR FlashArray
Write-Host "Connecting to DR FlashArray..." -ForegroundColor Red
$Credential = Get-Credential -UserName "$env:USERNAME" -Message "Enter your FlashArray credential information..."
$FlashArray = Connect-Pfa2Array -Endpoint $ArrayName -Credential ($Credential) -IgnoreCertificateError
Break   # Safety-net to prevent accidental "run everything" of this script


# Promote DR pod
Write-Host "Promoting DR Pod..." -ForegroundColor Red
Update-Pfa2Pod -Array $FlashArray -Name $PodName -RequestedPromotionState "promoted"

# Confirm pod promoted
Write-Host "Confirming DR Pod Status..." -ForegroundColor Red
$PodStatus = Get-Pfa2Pod -Array $FlashArray -Name $PodName
while ($PodStatus.PromotionStatus -ne 'promoted') {     
    sleep 1
    Write-Host "Re-checking Pod Status..." -ForegroundColor Red
    $PodStatus = Get-Pfa2Pod -Array $FlashArray -Name $PodName
}
$PodStatus
Break   # Safety-net to prevent accidental "run everything" of this script

# Disks will be presented back to Windows but serial number may not be materialized.
# Because disk serial number can change between reboots, need to programmatically reference
# serial number to properly identify which disks to manipulate.
# Therefore, loop here until serial numbers we expect manifest
#
# Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk  }
$DiskOne = Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq '81F096D1C1642A69017A835C' }  }
$DiskTwo = Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq '81F096D1C1642A69017A835B' }  }
while (($DiskOne -eq $null) -or ($DiskTwo -eq $null)) {
    Write-Host "Waiting for DR volumes to come online" -ForegroundColor Red
    Invoke-Command -Session $TargetVMSession -ScriptBlock { Update-HostStorageCache }
    $DiskOne = Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq '81F096D1C1642A69017A835C' }  }
    $DiskTwo = Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq '81F096D1C1642A69017A835B' }  }
}

# Online the windows disks 
# NOTE: Change disk serial number(s) to appropriate disks
Write-Host "Onlining DR volumes..." -ForegroundColor Red
Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq '81F096D1C1642A69017A835C' } | Set-Disk -IsOffline $False }
Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq '81F096D1C1642A69017A835B' } | Set-Disk -IsOffline $False }

# Setting volumes to Read/Write
# NOTE: Change disk serial number(s) to appropriate disks
Write-Host "Setting Read/Write for DR volumes..." -ForegroundColor Red
Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq '81F096D1C1642A69017A835C' } | Set-Disk -IsReadOnly $False }
Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq '81F096D1C1642A69017A835B' } | Set-Disk -IsReadOnly $False }

# Confirm state of disks
Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk }    
Break   # Safety-net to prevent accidental "run everything" of this script


# Start SQL Server instance (if applicable)
Write-Host "Starting SQL Server Instance Services..." -ForegroundColor Red
Invoke-Command -Session $TargetVMSession -ScriptBlock {Start-Service MSSQLSERVER; Start-Service SQLSERVERAGENT}

Write-Host "Confirm SQL Server Instance is running..." -ForegroundColor Red
Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Service -name "MSSQLSERVER" }
Break   # Safety-net to prevent accidental "run everything" of this script


# Online the database
Write-Host "Onlining database CookbookDemo_ADR in DR..." -ForegroundColor Red
$Query = "ALTER DATABASE CookbookDemo_ADR SET ONLINE WITH ROLLBACK IMMEDIATE"
Invoke-Command -Session $TargetVMSession -ScriptBlock {Param($querytask) Invoke-Sqlcmd -ServerInstance . -Database master -Query $querytask} -ArgumentList ($Query)

# Force script termination to avoid accidental "run entire script"
Write-Host "DR Pod Promotion completed.  Go check SQL Server." -ForegroundColor Red
Exit   # Safety-net to prevent accidental "run everything" of this script


#########################################
# PART 2: DEMOTE DR TEST
#########################################

# Offline the database
Write-Host "Offlining the database(s)..." -ForegroundColor Red
$Query = "ALTER DATABASE CookbookDemo_ADR SET OFFLINE WITH ROLLBACK IMMEDIATE"
Invoke-Command -Session $TargetVMSession -ScriptBlock {Param($querytask) Invoke-Sqlcmd -ServerInstance . -Database master -Query $querytask} -ArgumentList ($Query)

# Offline the volume
Write-Host "Offlining the DR volume(s)..." -ForegroundColor Red
Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq '81F096D1C1642A69017A835C' } | Set-Disk -IsOffline $True }
Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq '81F096D1C1642A69017A835B' } | Set-Disk -IsOffline $True }

# Confirm state of disks
Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk }
Break   # Safety-net to prevent accidental "run everything" of this script

# Demote DR Pod
Update-Pfa2Pod -Array $FlashArray -Name $PodName -RequestedPromotionState "demoted"

# Confirm DR Pod status
Get-Pfa2Pod -Array $FlashArray -Name $PodName
Break   # Safety-net to prevent accidental "run everything" of this script