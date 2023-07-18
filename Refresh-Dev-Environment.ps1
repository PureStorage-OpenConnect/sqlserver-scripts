#Requires -Version 5

#Requires -Modules PureStoragePowerShellSDK2

# Refresh a dev database in a few seconds!

$TargetVMSession = New-PSSession -ComputerName 'MyVirtualMachineName'

try {
    Write-Host "Actual development instance downtime begins now." -ForegroundColor Red

    Invoke-Command -Session $TargetVMSession -ScriptBlock {

        $diskSerialNumbers = @('E33DF4A38D50A72500012265')
        $sqlServerInstance = '.'
        $databaseName = 'MyDatabase'

        # Offline the database
        Write-Host "Offlining the database..." -ForegroundColor Red
        Invoke-Sqlcmd -ServerInstance $sqlServerInstance -Query "ALTER DATABASE $databaseName SET OFFLINE WITH ROLLBACK IMMEDIATE"

        # Offline the volume
        Write-Host "Offlining volumes..." -ForegroundColor Red
        Get-Disk | ? { $_.SerialNumber -in $diskSerialNumbers } | Set-Disk -IsOffline $true

    }

    # Connect to the FlashArray's REST API, get a session going
    Write-Host "Establishing a session against the Pure Storage FlashArray..." -ForegroundColor Red

    $connectionParams = @{
        EndPoint = '10.128.0.2'
        Username = 'myusername'
    
        # THIS IS A SAMPLE SCRIPT WE USE FOR DEMOS! _PLEASE_ do not save your password in cleartext here. 
        # Use NTFS secured, encrypted files or whatever else -- never cleartext!
        Password = ConvertTo-SecureString -String 'mypassword' -AsPlainText -Force
    }

    $FlashArray = Connect-Pfa2Array @connectionParams -IgnoreCertificateError 

    try {

        # Perform the volume overwrite (no intermediate snapshot needed!)
        Write-Host "Overwriting the dev instance's volume with a fresh copy from production..." -ForegroundColor Red

        $newVolumeParams = @{
            Name = 'MyVirtualMachineName-data-volume'
            SourceName = 'MyProduction-data-volume'
        }

        New-Pfa2Volume @newVolumeParams -Array $FlashArray -Overwrite $true

    }
    finally {
        Disconnect-Pfa2Array -Array $FlashArray
    }

    Invoke-Command -Session $TargetVMSession -ScriptBlock {

        # Online the volume
        Write-Host "Onlining volumes..." -ForegroundColor Red
        Get-Disk | ? { $_.SerialNumber -in $diskSerialNumbers } | Set-Disk -IsOffline $False 

        # Online the database
        Write-Host "Onlining the database..." -ForegroundColor Red
        Invoke-Sqlcmd -ServerInstance $sqlServerInstance  -Query "ALTER DATABASE $databaseName SET ONLINE WITH ROLLBACK IMMEDIATE" 

    }
}
finally {
    Write-Host "Development database downtime ended." -ForegroundColor Red
    # Clean up
    Remove-PSSession $TargetVMSession
}

Write-Host "All done." -ForegroundColor Red
