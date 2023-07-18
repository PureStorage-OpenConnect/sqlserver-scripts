#Requires -Version 5
#Requires -Modules @{ ModuleName="PureStoragePowerShellSDK2"; ModuleVersion="2.16" }

$TargetVMSession = New-PSSession -ComputerName 'MyVirtualMachineName'

try {
    Invoke-Command -Session $TargetVMSession -ScriptBlock {
        $diskSerialNumbers = @('423F93C2ECF544580001103B')
        $databaseName = 'My_DR_Database'
        $serverInstance = '.'

        # Offline the database
        Write-Host "Offlining the DR database..." -ForegroundColor Red
        Invoke-Sqlcmd -ServerInstance $serverInstance -Query "ALTER DATABASE $databaseName SET OFFLINE WITH ROLLBACK IMMEDIATE"

        # Offline the volume
        Write-Host "Offlining the DR volume..." -ForegroundColor Red
        Get-Disk | ? SerialNumber -in $diskSerialNumbers | Set-Disk -IsOffline $True
    }

    $connectionParams = @{
        # THIS IS A SAMPLE SCRIPT WE USE FOR DEMOS! _PLEASE_ do not save your password in cleartext here. 
        # Use NTFS secured, encrypted files or whatever else -- never cleartext!
        EndPoint = '10.128.0.2'
        Username = 'myusername'
        Password = ConvertTo-SecureString -String 'mypassword' -AsPlainText -Force
    }

    $flashArray = Connect-Pfa2Array @connectionParams -IgnoreCertificateError 

    try {
        Write-Host "Obtaining the most recent snapshot for the protection group..." -ForegroundColor Red
        $pgSnapshotParams = @{
            Name = 'MyArrayName:MyProtectionGroupName' 
            Sort = 'created-'
        }
        $mostRecentSnapshots = Get-Pfa2ProtectionGroupSnapshot @pgSnapshotParams -Limit 2 -Array $flashArray

        # Check that the last snapshot has been fully replicated
        $firstSnapStatus = Get-Pfa2ProtectionGroupSnapshotTransfer -Array $flashArray -Name $mostRecentSnapshots[0].name

        # If the latest snapshot's completed property is null, then it hasn't been fully replicated - the previous snapshot is good, though
        $mostRecentSnapName = if ($firstSnapStatus.Progress -lt 1.0) {
            $mostRecentSnapshots[0].name 
        }
        else {
            $mostRecentSnapshots[1].name
        }

        # Perform the DR volume overwrite
        $volumeParams = @{
            Name = 'MyVirtualMachineName-data-volume'
            SourceName = $mostRecentSnapName + '.MyProduction-data-volume'
        }

        Write-Host "Overwriting the DR database volume with a copy of the most recent snapshot..." -ForegroundColor Red
        New-Pfa2Volume @volumeParams -Overwrite $true -Array $flashArray
    }
    finally {
        Disconnect-Pfa2Array -Array $flashArray
    }

    Invoke-Command -Session $TargetVMSession -ScriptBlock { 
        # Online the volume
        Write-Host "Onlining the volume..." -ForegroundColor Red
        Get-Disk | ? SerialNumber -in $diskSerialNumbers | Set-Disk -IsOffline $False 

        # Online the database
        Write-Host "Onlining the database..." -ForegroundColor Red
        Invoke-Sqlcmd -ServerInstance $serverInstance -Query "ALTER DATABASE $databaseName SET ONLINE WITH ROLLBACK IMMEDIATE"
    }

    Write-Host "DR failover ended." -ForegroundColor Red
}
finally {
    # Clean up
    Remove-PSSession $TargetVMSession
    Write-Host "All done." -ForegroundColor Red
}