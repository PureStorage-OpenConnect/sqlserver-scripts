Clear-Host

Import-Module PureStoragePowerShellSDK

$TargetMachine = 'CLUSTER-NODE1'
$TargetSQLInstance = 'SQL-FCI-VNN'

$TargetMachSession = New-PSSession -ComputerName $TargetMachine

Import-Module SQLPS -PSSession $TargetMachSession -DisableNameChecking

Write-Host "Actual development instance downtime begins now." -ForegroundColor Red

# Offline the database
Write-Host "Offlining the database..." -ForegroundColor Red
Invoke-Command -Session $TargetMachSession -ScriptBlock { Invoke-Sqlcmd -ServerInstance 'SQL-FCI-VNN' -Database master -Query "ALTER DATABASE DatabaseName SET OFFLINE WITH ROLLBACK IMMEDIATE" }

# Remove SQL Server cluster resource dependency on database volume
Invoke-Command -Session $TargetMachSession -ScriptBlock { Get-ClusterResource 'SQL Server' | Remove-ClusterResourceDependency 'Cluster Disk Name' }

# Stop the disk cluster resource
Invoke-Command -Session $TargetMachSession -ScriptBlock { Stop-ClusterResource 'Cluster Disk Name' }

# Connect to the FlashArray's REST API, get a session going - CHANGE THIS TO SECURED/ENCRYPTED FILE!
Write-Host "Establishing a session against the Pure Storage FlashArray..." -ForegroundColor Red
$FlashArray = New-PfaArray –EndPoint array.dns.name -UserName pureuser -Password (ConvertTo-SecureString -AsPlainText "pureuser" -Force) -IgnoreCertificateError

# Perform the volume overwrite (no intermediate snapshot needed!)
Write-Host "Overwriting the dev instance's volume with a fresh copy from production..." -ForegroundColor Red
New-PfaVolume -Array $FlashArray -VolumeName target-volume-name -Source source-volume-name -Overwrite

# Start the disk cluster resource
Invoke-Command -Session $TargetMachSession -ScriptBlock { Start-ClusterResource 'Cluster Disk Name' }

# Add a dependency on the volume for the SQL Server cluster resource 
Invoke-Command -Session $TargetMachSession -ScriptBlock { Get-ClusterResource 'SQL Server' | Add-ClusterResourceDependency 'Cluster Disk Name' }

# Online the database
Write-Host "Onlining the database..." -ForegroundColor Red
Invoke-Command -Session $TargetMachSession -ScriptBlock { Invoke-Sqlcmd -ServerInstance 'SQL-FCI-VNN' -Database master -Query "ALTER DATABASE DatabaseName SET ONLINE WITH ROLLBACK IMMEDIATE" }

Write-Host "Development database downtime ended." -ForegroundColor Red

# Clean up
Remove-PSSession $TargetMachSession
Write-Host "All done." -ForegroundColor Red