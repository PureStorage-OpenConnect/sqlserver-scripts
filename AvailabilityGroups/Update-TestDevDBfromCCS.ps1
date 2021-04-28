<#
Update-TestDevDBFromCCS.ps1

: Revision 1.0.0.0
:: initial release

Example script to use crash consistent snapshots from a FlashArray to overwrite (refresh) a Test/Dev environment.
This is not intended to be a complete run script. It is for example purposes only.
Variables should be modified to suit the environment.

This script is provided AS-IS. No warranties expressed or implied by Pure Storage or the creator.

Requirements:
  PowerShell version 5.1
  Pure Storage PowerShell SDK v1 module
  FlashArray array admin login credentials

.SYNOPSIS
Use crash consistent snapshots from a FlashArray to overwrite (refresh) a Test/Dev environment.
.PARAMETERS
$faEndpiont - The array FQDN or IP address (preferred)
$sourceVolumeName - The volume name of the source DB
$targetServer1 - The first target server FQDN or IP address (preferred)
$targetServer2 - The second target server FQDN or IP address (preferred). If no second target server, do not use.
$targetVolume1 - The target volume on target server 1 for the DB
$targetVolume2 - The target volume on target server 2 for the DB. If no second target server, do not use.
.INPUTS
Credentials
.PREREQUISITES
Pure Storage PowerShell SDK 1.17 or later. This script is not yet compatabile with SDK version 2.
.NOTES
This script is provided without warranty and should not be used in a production environment without proper modifications.
.EXAMPLE
Pure_AG_CrashConsistent_Clone.ps1 -faEndpoint "192.168.1.1" -sourceVolumeName "AG1DBHost1-DataLog" -targetVolume1 "AG2DBHost1-DataLog"  -targetServer1 "AG2DBHost1" -targetVolume2 "AG2DBHost2-DataLog" -targetServer2 "AG2DBHost2"
#>

### Parameters
    [Parameter(Mandatory=$false)]
    $faEndpoint,
    [Parameter(Mandatory=$false)]
    $sourceVolumeName,
    [Parameter(Mandatory=$false)]
    $targetServer1,
    [Parameter(Mandatory=$false)]
    $targetServer2,
    [Parameter(Mandatory=$false)]
    $targetVolume1,
    [Parameter(Mandatory=$false)]
    $targetVolume2


### Get Credentials
    $faCreds = Get-Credential


# Build Array of servers and volumes
    $targetServers = $targetServer1,$targetServer2
    $targetVolumes = $targetVolume1,$targetVolume2


### Check for SDK Module. If not present, install it.
    if ((Get-InstalledModule -Name "PureStoragePowerShellSDK" -ErrorAction SilentlyContinue) -eq $null) {
        Install-Module -Name PureStoragePowerShellSDK
        Import-Module PureStoragePowershellSDK
    }

# Connect to FA $faArray
New-PfaArray -EndPoint $faEndpoint -Credentials $faCreds -IgnoreCertificateError

# Create Snap
    $suffixWithGUID = -join ((0x30..0x39) + ( 0x61..0x7A) | Get-Random -Count 10 | % {[char]$_}) +"-AG-Clone-Automation"
    Write-Host "Performing Snap of $sourceVolumeName" -ForegroundColor green
    $sourceSnap = New-PfaVolumeSnapshots -Array $faArray -Sources $sourceVolumeName -Suffix $suffixWithGUID
    Write-Host "Snap created by name $($sourceSnap.name)" -ForegroundColor green

# Stop SQL Service
    Write-Host "Attempting stop of SQL services on $targetServers" -ForegroundColor green
    foreach($server in $targetServers)
    {
        $service = get-service -ComputerName $server -Name MSSQL*
        $service.Stop()
        do{
        $service = Get-Service -ComputerName $server -Name MSSQL*
        Write-Host "Service $($service.displayname) on $server is in state $($service.status), we will retry continously if not Stopped" -ForegroundColor yellow
        Start-Sleep 5
        }while($service.status -ne "Stopped")
    }

# Offline disk on Target 1
    Write-Host "Starting offline appropriate disks on $targetServer1" -ForegroundColor green
    $targetVolume1SN = Get-PfaVolume -Array $faArray -name $targetVolume1 | Select-Object -ExpandProperty "serial"
    $targetDisk = Get-CimInstance Win32_DiskDrive -ComputerName $targetServer1 | ?{$_.serialnumber -eq $targetVolume1SN}| Select-Object *
    Write-Host "Invoking Remote call to $targetServer1 to offline disk with Serial Number $($targetDisk.SerialNumber)" -ForegroundColor Green
    $results = Invoke-Command -ArgumentList $targetDisk -ComputerName $targetServer1 -ScriptBlock{
        $targetDisk = $args[0]
        Get-Disk|where-object {$_.SerialNumber -eq $targetDisk.SerialNumber}| Set-Disk -IsOffline $true|Out-Null
        "rescan"|diskpart|Out-Null
        $theDisk = Get-Disk|where-object {$_.SerialNumber -eq $targetDisk.SerialNumber}
        New-Object -TypeName PSCustomObject -Property @{DiskStatus=$theDisk.OperationalStatus}
    }
    if($results.DiskStatus -ne "Offline")
    {
        Write-Error "Did not successfully offline disk on $targetServer1 with remote call.  Exiting"
        exit 1
    }
    else {
        Write-Host "Offline success of appropriate disks on $targetServer1" -ForegroundColor Green
    }

# Offline disk on Target 2
    Write-Host "Starting offline appropriate disks on $targetServer2" -ForegroundColor green
    $targetVolume2SN = Get-PfaVolume -Array $faArray -name $targetVolume2 | Select-Object -ExpandProperty "serial"
    $targetDisk = Get-CimInstance Win32_DiskDrive -ComputerName $targetServer2 | ?{$_.serialnumber -eq $targetVolume2SN}| Select-Object *
    Write-Host "Invoking Remote call to $targetServer2 to offline disk with Serial Number $($targetDisk.SerialNumber)" -ForegroundColor Green
    $results = Invoke-Command -ArgumentList $targetDisk -ComputerName $targetServer2 -ScriptBlock{
        $targetDisk = $args[0]
        Get-Disk | where-object {$_.SerialNumber -eq $targetDisk.SerialNumber}| Set-Disk -IsOffline $true|Out-Null
        "rescan"|diskpart|Out-Null
        $theDisk = Get-Disk|where-object {$_.SerialNumber -eq $targetDisk.SerialNumber}
        New-Object -TypeName PSCustomObject -Property @{DiskStatus=$theDisk.OperationalStatus}
    }
    if($results.DiskStatus -ne "Offline")
    {
        Write-Error "Did not successfully offline disk on $targetServer2 with remote call.  Exiting"
        exit 1
    }
    else {
        Write-Host "Offline success of appropriate disks on $targetServer2" -ForegroundColor Green
    }

# Overwrite Target Volumes
    Foreach($volume in $targetVolumes)
    {
        Write-Host "Overwriting Volume $volume with Snap $($sourceSnap.name)" -ForegroundColor green
        New-PfaVolume -Array $faArray -VolumeName $volume -Source $sourceSnap.name  -Overwrite
    }

# Online disk on Target 1
    Write-Host "Starting Online appropriate disks on $targetServer1" -ForegroundColor green
    $targetVolume1SN = Get-PfaVolume -Array $faArray -name $targetVolume1|Select-Object -ExpandProperty "serial"
    $targetDisk = Get-CimInstance Win32_DiskDrive -ComputerName $targetServer1 |?{$_.serialnumber -eq $targetVolume1SN}| Select-Object *
    Write-host "Invoking Remote call to $targetServer1 to online disk with Serial Number $($targetDisk.SerialNumber)" -ForegroundColor Green
    $results = Invoke-Command -ArgumentList $targetDisk -ComputerName $targetServer1 -ScriptBlock{
        "rescan"|diskpart|Out-Null
        $targetDisk = $args[0]
        get-disk|where-object {$_.SerialNumber -eq $targetDisk.SerialNumber}| set-disk -IsOffline $false
        "rescan"|diskpart|Out-Null
        $theDisk = get-disk|where-object {$_.SerialNumber -eq $targetDisk.SerialNumber}
        New-Object -TypeName PSCustomObject -Property @{DiskStatus=$theDisk.OperationalStatus}
    }
    if($results.DiskStatus -ne "Online")
    {
        Write-Error "Did not successfully Online disk on $targetServer1 with remote call.  Exiting"
        exit 1
    }
    else {
        write-host "Online success of appropriate disks on $targetServer1" -ForegroundColor Green
    }

# Online disk on Target 2
    Write-Host "Starting online appropriate disks on $targetServer2" -ForegroundColor green
    $targetVolume2SN = Get-PfaVolume -Array $faArray -name $targetVolume2|Select-Object -ExpandProperty "serial"
    $targetDisk = Get-CimInstance Win32_DiskDrive -ComputerName $targetServer2 |?{$_.serialnumber -eq $targetVolume2SN}| Select-Object *
    Write-Host "Invoking Remote call to $targetServer2 to online disk with Serial Number $($targetDisk.SerialNumber)" -ForegroundColor Green
    $results = Invoke-Command -ArgumentList $targetDisk -ComputerName $targetServer2 -ScriptBlock{
        "rescan"|diskpart|Out-Null
        $targetDisk = $args[0]
        get-disk|where-object {$_.SerialNumber -eq $targetDisk.SerialNumber}| set-disk -IsOffline $false
        "rescan"|diskpart|Out-Null
        $theDisk = get-disk|where-object {$_.SerialNumber -eq $targetDisk.SerialNumber}
        New-Object -TypeName PSCustomObject -Property @{DiskStatus=$theDisk.OperationalStatus}
    }
    if($results.DiskStatus -ne "Online")
    {
        Write-Error "Did not successfully Online disk on $targetServer2 with remote call.  Exiting"
        exit 1
    }
    else {
        Write-Host "Online success of appropriate disks on $targetServer2" -ForegroundColor Green
    }

# Start SQL Service
    Write-Host "Attempting start of SQL services on $targetServers" -ForegroundColor green
    foreach($server in $targetServers)
    {
        Write-Host "Attempting start of SQL services on $server now" -ForegroundColor green
        $service = Get-Service -ComputerName $server -Name MSSQL*
        $service.Start()
        do{
        $service = Get-Service -ComputerName $server -Name MSSQL*
        Write-Host "Service $($service.displayname) on $server is in state $($service.status), we will retry continously if not Running" -ForegroundColor yellow
        Start-Sleep 5
        }while($service.status -ne "Running")
    }

# Cleanup snapshot
    Write-Host "Removing snapshot $($sourceSnap.name) from Array $($faArray.Endpoint)" -ForegroundColor green
    Remove-PfaVolumeOrSnapshot -Array $faArray -Name $sourceSnap.name | Out-Null

# END