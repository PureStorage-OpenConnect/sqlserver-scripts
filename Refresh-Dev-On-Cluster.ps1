#Requires -Version 5
#Requires -Modules PureStoragePowerShellSDK2

$TargetMachine = 'CLUSTER-NODE1'
$ArrayName = 'array.dns.name'
$ArrayUsername = 'pureuser'
$ArrayPassword = 'password'
$SourceVolumeName = 'source-volume-name'
$TargetVolumeName = 'target-volume-name'
$SqlInstance = 'CLUSTER-SQL'
$DatabaseName = 'DatabaseName'
$ClusterDiskName = 'Cluster Disk Name'

$TargetSession = New-PSSession -ComputerName $TargetMachine

try {
    # Initialize session variables
    Invoke-Command -Session $TargetSession -ScriptBlock {
        param (
            [string]$sql,
            [string]$dbName,
            [string]$dskNm
        )

        $sqlInstance = $sql
        $databaseName = $dbName
        $clusterDiskName = $dskNm
    } -ArgumentList $SqlInstance, $DatabaseName, $ClusterDiskName

    Write-Host 'Actual development instance downtime begins now.' -ForegroundColor Red

    Invoke-Command -Session $TargetSession -ScriptBlock {
        # Offline the database
        Write-Host 'Offlining the database...' -ForegroundColor Red
        Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "ALTER DATABASE [$databaseName] SET OFFLINE WITH ROLLBACK IMMEDIATE"

        # Remove SQL Server cluster resource dependency on database volume
        Write-Host 'Removing dependency on database volume...' -ForegroundColor Red
        Get-ClusterResource 'SQL Server' | Remove-ClusterResourceDependency $clusterDiskName | Out-Null

        # Stop the disk cluster resource
        Write-Host 'Offlining the disk cluster resource...' -ForegroundColor Red
        Stop-ClusterResource $clusterDiskName | Out-Null
    }

    # Connect to the FlashArray's REST API, get a session going - CHANGE THIS TO SECURED/ENCRYPTED FILE!
    Write-Host 'Establishing a session against the Pure Storage FlashArray...' -ForegroundColor Red
    $FlashArray = Connect-Pfa2Array -Endpoint $ArrayName -Username $ArrayUsername -Password (ConvertTo-SecureString -AsPlainText $ArrayPassword -Force) -IgnoreCertificateError
    try {
        # Perform the volume overwrite (no intermediate snapshot needed!)
        Write-Host "Overwriting the dev instance's volume with a fresh copy from production..." -ForegroundColor Red
        New-Pfa2Volume -Array $FlashArray -Name $TargetVolumeName -SourceName $SourceVolumeName -Overwrite $true | Out-Null
    }
    finally {
        Disconnect-Pfa2Array -Array $FlashArray
    }

    Invoke-Command -Session $TargetSession -ScriptBlock {
        # Start the disk cluster resource
        Write-Host 'Onlining the disk cluster resource...' -ForegroundColor Red
        Start-ClusterResource $clusterDiskName | Out-Null

        # Add a dependency on the volume for the SQL Server cluster resource
        Write-Host 'Adding dependency on database volume...' -ForegroundColor Red
        Get-ClusterResource 'SQL Server' | Add-ClusterResourceDependency $clusterDiskName | Out-Null

        # Online the database
        Write-Host 'Onlining the database...' -ForegroundColor Red
        Invoke-Sqlcmd -ServerInstance $sqlInstance -Query "ALTER DATABASE [$databaseName] SET ONLINE WITH ROLLBACK IMMEDIATE"
    }

    Write-Host 'Development database downtime ended.' -ForegroundColor Red
}
finally {
    # Clean up
    Remove-PSSession $TargetSession
}

Write-Host 'All done.' -ForegroundColor Red