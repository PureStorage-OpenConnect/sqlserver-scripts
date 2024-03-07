Import-Module PureStoragePowerShellSDK

$TargetServer = 'MyTestServer'

$TargetServerSession = New-PSSession -ComputerName $TargetServer

Import-Module SQLPS -PSSession $TargetServerSession -DisableNameChecking

# Offline the database
Write-Warning "Offlining the target database..." 
Invoke-Command -Session $TargetServerSession -ScriptBlock { Invoke-Sqlcmd -ServerInstance . -Database master -Query "ALTER DATABASE MyDatabaseName SET OFFLINE WITH ROLLBACK IMMEDIATE" }

# Offline the volume
Write-Warning "Offlining the target volumes..." 
Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '343E12644E64277800021120' } | Set-Disk -IsOffline $True }
Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '343E12644E64277800021121' } | Set-Disk -IsOffline $True }
Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '343E12644E64277800021122' } | Set-Disk -IsOffline $True }
Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '343E12644E64277800021123' } | Set-Disk -IsOffline $True }

# Connect to the FlashArray's REST API, get a session going
# THIS IS A SAMPLE SCRIPT WE USE FOR DEMOS! _PLEASE_ do not save your password in cleartext here. 
# Use NTFS secured, encrypted files or whatever else -- never cleartext!
Write-Warning "Establishing a session against the Pure Storage FlashArray..." 
$FlashArray = New-PfaArray -EndPoint 10.10.1.22 -UserName pureuser -Password (ConvertTo-SecureString -AsPlainText "pureuser" -Force) -IgnoreCertificateError

# If you don't want a new snapshot of the Protection Group generated whenever you run this script, comment this next line
Write-Warning "Creating a new snapshot of the Protection Group..."
New-PfaProtectionGroupSnapshot -Array $FlashArray -Protectiongroupname 'MyDatabaseName-PG' -ApplyRetention

Write-Warning "Obtaining the most recent snapshot for the protection group..."
$MostRecentSnapshot = Get-PfaProtectionGroupSnapshots -Array $FlashArray -Name 'MyDatabaseName-PG' | Sort-Object created -Descending | Select -Property name -First 1

# Perform the target volume overwrite
Write-Warning "Overwriting the target database volumes with a copies of the volumes in the most recent snapshot..." 
New-PfaVolume -Array $FlashArray -VolumeName MyTestServer-data-PRIMARY -Source ($MostRecentSnapshot.name + '.MyProdServer-data-PRIMARY') -Overwrite
New-PfaVolume -Array $FlashArray -VolumeName MyTestServer-data-FG1 -Source ($MostRecentSnapshot.name + '.MyProdServer-data-FG1') -Overwrite
New-PfaVolume -Array $FlashArray -VolumeName MyTestServer-data-FG2 -Source ($MostRecentSnapshot.name + '.MyProdServer-data-FG2') -Overwrite
New-PfaVolume -Array $FlashArray -VolumeName MyTestServer-data-log -Source ($MostRecentSnapshot.name + '.MyProdServer-data-log') -Overwrite

# Online the volume
Write-Warning "Onlining the target volumes..." 
Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '343E12644E64277800021120' } | Set-Disk -IsOffline $False }
Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '343E12644E64277800021121' } | Set-Disk -IsOffline $False }
Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '343E12644E64277800021122' } | Set-Disk -IsOffline $False }
Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '343E12644E64277800021123' } | Set-Disk -IsOffline $False }

# Online the database
Write-Warning "Onlining the target database..." 
Invoke-Command -Session $TargetServerSession -ScriptBlock { Invoke-Sqlcmd -ServerInstance . -Database master -Query "ALTER DATABASE MyDatabaseName SET ONLINE WITH ROLLBACK IMMEDIATE" }

Write-Warning "Target database downtime ended." 

# Clean up
Remove-PSSession $TargetServerSession
Write-Warning "All done." 