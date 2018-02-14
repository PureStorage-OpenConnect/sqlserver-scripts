<#

.SYNOPSIS
A PowerShell function to refresh one SQL Server database (the destination) from another (the source).

.DESCRIPTION
This PowerShell function uses calls to the PowerShell SDK and dbatools module functions to refresh one SQL Server
data (the destination) from another (the source).

.EXAMPLE
Refresh-Dev-PsFunc -Database           SsdtDevOpsDemo `
                   -SourceSqlInstance  SQL2016\DevOps_PRD `
                   -DestSqlInstance    SQL2016\DevOps_TST `
                   -PfaEndpoint        10.223.112.12 `
                   -PfaUser            pureuser `
                   -PfaPassword        P@ssw0rd99!

.NOTES
This script requires that both the dbatools and PureStorage SDK  modules available from the PowerShell gallery are
installed. It assumes that the source and destination databases reside on single logical volumes. The script needs
to  be run as a user that has execution privilges to  online / offline windows logical disks, online / offline the
target database  

This function is available under the Apache 2.0 license, stipulated as follows:

Copyright 2017 Pure Storage, Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on  an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

.LINK
TBD

#>
function Refresh-TestDbFromProd
{
    param(
          [parameter(mandatory=$true)][string] $Database          
         ,[parameter(mandatory=$true)][string] $SourceSqlInstance 
         ,[parameter(mandatory=$true)][string] $DestSqlInstance   
         ,[parameter(mandatory=$true)][string] $PfaEndpoint       
         ,[parameter(mandatory=$true)][string] $PfaUser           
         ,[parameter(mandatory=$true)][string] $PfaPassword       
    )

    try {
        $FlashArray = New-PfaArray –EndPoint $PfaEndpoint -UserName $PfaUser -Password (ConvertTo-SecureString -AsPlainText $PfaPassword -Force) -IgnoreCertificateError
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to connect to FlashArray endpoint $PfaEndpoint with: $ExceptionMessage"
        Return
    }

    try {
        $DestDb            = Get-DbaDatabase -sqlinstance $DestSqlInstance -Database $Database
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to connect to destination database $DestSqlInstance.$Database with: $ExceptionMessage"
        Return
    }

    try {
        $DestDisk          = Get-partition -DriveLetter $DestDb.PrimaryFilePath.Split(':')[0]| Get-Disk
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to determine destination database disk with: $ExceptionMessage"
        Return
    }

    try {
        $DestVolume        = Get-PfaVolumes -Array $FlashArray | Where-Object { $_.serial -eq $DestDisk.SerialNumber } | Select name
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to determine destination FlashArray volume with: $ExceptionMessage"
        Return
    }

    try {
        $SourceDb          = Get-DbaDatabase -sqlinstance $SourceSqlInstance -Database $Database
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to connect to source database $SourceSqlInstance.$Database with: $ExceptionMessage"
        Return
    }

    try {
        $SourceDisk        = Get-Partition -DriveLetter $SourceDb.PrimaryFilePath.Split(':')[0] | Get-Disk
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to determine source disk with: $ExceptionMessage"
        Return
    }

    try {
        $SourceVolume      = Get-PfaVolumes -Array $FlashArray | Where-Object { $_.serial -eq $SourceDisk.SerialNumber } | Select name
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to determine source volume with: $ExceptionMessage"
        Return
    }

    try {
        $DestDb.SetOffline()
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to offline database $Database with: $ExceptionMessage"
        Return
    }

    try {
        $TargetServer  = (Connect-DbaInstance -SqlInstance $DestSqlInstance).ComputerNamePhysicalNetBIOS
    }
    catch {
        Write-Error "Failed to determine target server name with: $ExceptionMessage"        
    }

    $OfflineDestDisk = { param ( $DiskNumber, $Status ) 
        Set-Disk -Number $DiskNumber -IsOffline $Status
    }

    try {
        Invoke-Command -ComputerName $TargetServer -ScriptBlock $OfflineDestDisk -ArgumentList $DestDisk.Number, $True
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to offline disk with : $ExceptionMessage" 
        Return
    }

    try {
        New-PfaVolume -Array $FlashArray -VolumeName $DestVolume.name -Source $SourceVolume.name -Overwrite
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to refresh test database volume with : $ExceptionMessage" 
        Set-Disk -Number $DestDisk.Number -IsOffline $False
        $DestDb.SetOnline()
        Return
    }

    try {
        Invoke-Command -ComputerName $TargetServer -ScriptBlock $OfflineDestDisk -ArgumentList $DestDisk.Number, $False
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to online disk with : $ExceptionMessage" 
        Return
    }

    try {
        $DestDb.SetOnline()
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to online database $Database with: $ExceptionMessage"
        Return
    }
}
