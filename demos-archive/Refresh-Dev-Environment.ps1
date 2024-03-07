Import-Module PureStoragePowerShellSDK
# Refresh a dev database in a few seconds!

$TargetVM = 'MyVirtualMachineName'

$TargetVMSession = New-PSSession -ComputerName $TargetVM

Import-Module SQLPS -PSSession $TargetVMSession -DisableNameChecking

Write-Host "Actual development instance downtime begins now." -ForegroundColor Red

# Offline the database
Write-Host "Offlining the database..." -ForegroundColor Red
Invoke-Command -Session $TargetVMSession -ScriptBlock { Invoke-Sqlcmd -ServerInstance . -Database master -Query "ALTER DATABASE MyDatabase SET OFFLINE WITH ROLLBACK IMMEDIATE" }

# Offline the volume
Write-Host "Offlining the volume..." -ForegroundColor Red
Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq 'E33DF4A38D50A72500012265' } | Set-Disk -IsOffline $True }

# Connect to the FlashArray's REST API, get a session going
# THIS IS A SAMPLE SCRIPT WE USE FOR DEMOS! _PLEASE_ do not save your password in cleartext here. 
# Use NTFS secured, encrypted files or whatever else -- never cleartext!
Write-Host "Establishing a session against the Pure Storage FlashArray..." -ForegroundColor Red
$FlashArray = New-PfaArray –EndPoint 10.128.0.2 -UserName myusername -Password (ConvertTo-SecureString -AsPlainText "mypassword" -Force) -IgnoreCertificateError

# Perform the volume overwrite (no intermediate snapshot needed!)
Write-Host "Overwriting the dev instance's volume with a fresh copy from production..." -ForegroundColor Red
New-PfaVolume -Array $FlashArray -VolumeName MyVirtualMachineName-data-volume -Source MyProduction-data-volume -Overwrite

# Online the volume
Write-Host "Onlining the volume..." -ForegroundColor Red
Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq 'E33DF4A38D50A72500012265' } | Set-Disk -IsOffline $False }

# Online the database
Write-Host "Onlining the database..." -ForegroundColor Red
Invoke-Command -Session $TargetVMSession -ScriptBlock { Invoke-Sqlcmd -ServerInstance . -Database master -Query "ALTER DATABASE MyDatabase SET ONLINE WITH ROLLBACK IMMEDIATE" }

Write-Host "Development database downtime ended." -ForegroundColor Red

# Clean up
Remove-PSSession $TargetVMSession
Write-Host "All done." -ForegroundColor Red
