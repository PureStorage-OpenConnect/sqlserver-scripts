Import-Module PureStoragePowerShellSDK2

$TargetServer = 'MyTestServer'

$TargetServerSession = New-PSSession -ComputerName $TargetServer

# Offline the database
Write-Host "Offlining the target database..." 
Invoke-Command -Session $TargetServerSession -ScriptBlock { Invoke-Sqlcmd -ServerInstance '.' -Query "ALTER DATABASE MyDatabaseName SET OFFLINE WITH ROLLBACK IMMEDIATE" }

# Offline the volume
Write-Host "Offlining the target volumes..." 
Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? SerialNumber -eq '343E12644E64277800021120' | Set-Disk -IsOffline $True }
Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? SerialNumber -eq '343E12644E64277800021121' | Set-Disk -IsOffline $True }
Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? SerialNumber -eq '343E12644E64277800021122' | Set-Disk -IsOffline $True }
Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? SerialNumber -eq '343E12644E64277800021123' | Set-Disk -IsOffline $True }

# Connect to the FlashArray's REST API, get a session going
# THIS IS A SAMPLE SCRIPT WE USE FOR DEMOS! _PLEASE_ do not save your password in cleartext here. 
# Use NTFS secured, encrypted files or whatever else -- never cleartext!
Write-Host "Establishing a session against the Pure Storage FlashArray..." 
$FlashArray = Connect-Pfa2Array -EndPoint '10.10.1.22' -UserName 'pureuser' -Password (ConvertTo-SecureString -AsPlainText 'password' -Force) -IgnoreCertificateError

try {
    # If you don't want a new snapshot of the Protection Group generated whenever you run this script, comment this next line
    Write-Host "Creating a new snapshot of the Protection Group..."
    New-Pfa2ProtectionGroupSnapshot -Array $FlashArray -SourceNames 'MyDatabaseName-PG' -ApplyRetention $true

    Write-Host "Obtaining the most recent snapshot for the protection group..."
    $MostRecentSnapshot = Get-Pfa2ProtectionGroupSnapshot -Array $FlashArray -SourceNames 'MyDatabaseName-PG' -Sort 'created-' -Limit 1

    # Perform the target volume overwrite
    Write-Host "Overwriting the target database volumes with a copies of the volumes in the most recent snapshot..." 
    New-Pfa2Volume -Array $FlashArray -Name 'MyTestServer-data-PRIMARY' -SourceName ($MostRecentSnapshot.name + '.MyProdServer-data-PRIMARY') -Overwrite $true
    New-Pfa2Volume -Array $FlashArray -Name 'MyTestServer-data-FG1' -SourceName ($MostRecentSnapshot.name + '.MyProdServer-data-FG1') -Overwrite $true
    New-Pfa2Volume -Array $FlashArray -Name 'MyTestServer-data-FG2' -SourceName ($MostRecentSnapshot.name + '.MyProdServer-data-FG2') -Overwrite $true
    New-Pfa2Volume -Array $FlashArray -Name 'MyTestServer-data-log' -SourceName ($MostRecentSnapshot.name + '.MyProdServer-data-log') -Overwrite $true
}
finally {
    Disconnect-Pfa2Array -Array $FlashArray
}

# Online the volume
Write-Host "Onlining the target volumes..." 
Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? SerialNumber -eq '343E12644E64277800021120' | Set-Disk -IsOffline $False }
Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? SerialNumber -eq '343E12644E64277800021121' | Set-Disk -IsOffline $False }
Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? SerialNumber -eq '343E12644E64277800021122' | Set-Disk -IsOffline $False }
Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? SerialNumber -eq '343E12644E64277800021123' | Set-Disk -IsOffline $False }

# Online the database
Write-Host "Onlining the target database..." 
Invoke-Command -Session $TargetServerSession -ScriptBlock { Invoke-Sqlcmd -ServerInstance '.' -Query "ALTER DATABASE MyDatabaseName SET ONLINE WITH ROLLBACK IMMEDIATE" }

Write-Host "Target database downtime ended." 

# Clean up
Remove-PSSession $TargetServerSession
Write-Host "All done." 