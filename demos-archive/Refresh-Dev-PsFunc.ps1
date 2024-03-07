<#
.SYNOPSIS
A PowerShell function to refresh one or more SQL Server databases (the destination) from either a snapshot or 
database.

.DESCRIPTION
This PowerShell function uses calls to the PowerShell SDK and dbatools module functions to refresh one or more SQL Server
server databases either from a snapshot (either supplied explicitly or from a list associated with a volume) or from a source
database directly. 

.EXAMPLE
# Refresh a single database from a snapshot selected from a list of snapshots associated with the volume specified by the 
# -RefreshSource parameter.
$Targets = @("Z-STN-WIN2016-A\DEVOPSTST")
Refresh-Dev-PsFunc -RefreshDatabase    refresh-database `
                   -RefreshSource      z-sql2016-devops-prd `
                   -DestSqlInstance    $Targets `
                   -PfaEndpoint        10.225.112.10 `
                   -PfaUser            pureuser `
                   -PfaPassword        pureuser `
                   -PromptForSnapshot

.EXAMPLE
# Refresh multiple databases from a snapshot selected from a list of snapshots associated with the volume specified by the 
# -RefreshSource parameter.$Targets = @("Z-STN-WIN2016-A\DEVOPSTST", "Z-STN-WIN2016-A\DEVOPSDEV")
Refresh-Dev-PsFunc -RefreshDatabase    refresh-database `
                   -RefreshSource      z-sql2016-devops-prd `
                   -DestSqlInstance    $Targets `
                   -PfaEndpoint        10.225.112.10 `
                   -PfaUser            pureuser `
                   -PfaPassword        pureuser `
                   -PromptForSnapshot

.EXAMPLE
# Refresh a single database using the snapshot specified by the RefreshSource parameter:
$Targets = @("Z-STN-WIN2016-A\DEVOPSTST")
Refresh-Dev-PsFunc -RefreshDatabase    refresh-database `
                   -RefreshSource      source-snap `
                   -DestSqlInstance    $Targets `
                   -PfaEndpoint        10.225.112.10 `
                   -PfaUser            pureuser `
                   -PfaPassword        pureuser `
                   -RefreshFromSnapshot

.EXAMPLE
# Refresh multiple databases using the snapshot specified by the RefreshSource parameter:
$Targets = @("Z-STN-WIN2016-A\DEVOPSTST", "Z-STN-WIN2016-A\DEVOPSDEV")
Refresh-Dev-PsFunc -RefreshDatabase    refresh-database
                   -RefreshSource      source-snap `
                   -DestSqlInstance    $Targets `
                   -PfaEndpoint        10.225.112.10 `
                   -PfaUser            pureuser `
                   -PfaPassword        pureuser `
                   -RefreshFromSnapshot

#.EXAMPLE
# Refresh a single database from the database specified by the SourceDatabase parameter residing on the instance specified by RefreshSource
$Targets = @("Z-STN-WIN2016-A\DEVOPSTST")
Refresh-Dev-PsFunc -$RefreshDatabase   refresh-database `
                   -RefreshSource      z-sql-prd `
                   -DestSqlInstance    $Targets `
                   -PfaEndpoint        10.225.112.10 `
                   -PfaUser            pureuser `
                   -PfaPassword        pureuser 

.EXAMPLE
# Refresh multiple databases from the database specified by the SourceDatabase parameter residing on the instance specified by RefreshSource 
$Targets = @("Z-STN-WIN2016-A\DEVOPSTST", "Z-STN-WIN2016-A\DEVOPSDEV")
Refresh-Dev-PsFunc -$RefreshDatabase   refresh-database `
                   -RefreshSource      z-sql-prd `
                   -DestSqlInstance    $Targets `
                   -PfaEndpoint        10.225.112.10 `
                   -PfaUser            pureuser `
                   -PfaPassword        pureuser 

.NOTES
This script requires that both the dbatools and PureStorage SDK  modules available from the PowerShell gallery are
installed. It assumes that the source and destination databases reside on single logical volumes. The script needs
to  be run as a user that has execution privilges to  online / offline windows logical disks, online / offline the
target database.

It is recommended that this script be saved to a directory (C:\scripts\PowerShell\autoload in this example) on the
server it is executed from and autoloaded by the following commands being added to the PowerShell profile: 

Import-Module -Name C:\scripts\PowerShell\dbatools
Import-Module -Name C:\scripts\PowerShell\PureStoragePowerShellSDK
$psdir="C:\scripts\PowerShell\autoload"  
Get-ChildItem "${psdir}\*.ps1" | %{.$_} 
Write-Host "Custom scripts loaded"

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
function Refresh-Dev-PsFunc
{
    param(
          [parameter(mandatory=$true)]  [string]   $RefreshDatabase          
         ,[parameter(mandatory=$true)]  [string]   $RefreshSource 
         ,[parameter(mandatory=$true)]  [string[]] $DestSqlInstances   
         ,[parameter(mandatory=$true)]  [string]   $PfaEndpoint       
         ,[parameter(mandatory=$true)]  [string]   $PfaUser           
         ,[parameter(mandatory=$true)]  [string]   $PfaPassword       
         ,[parameter(mandatory=$false)] [switch]   $PromptForSnapshot
         ,[parameter(mandatory=$false)] [switch]   $RefreshFromSnapshot
    )

    $StartMs = Get-Date

    if ( $PromptForSnapshot.IsPresent.Equals($false) -And $RefreshFromSnapshot.IsPresent.Equals($false) ) { 
        Write-Host "Connecting to source SQL Server instance" -ForegroundColor Yellow

        try {
            $SourceDb          = Get-DbaDatabase -sqlinstance $RefreshSource -Database $RefreshDatabase
        }
        catch {
            $ExceptionMessage = $_.Exception.Message
            Write-Error "Failed to connect to source database $RefreshSource.$Database with: $ExceptionMessage"
            Return
        }

        try {
            $SourceServer  = (Connect-DbaInstance -SqlInstance $RefreshSource).ComputerNamePhysicalNetBIOS
        }
        catch {
            Write-Error "Failed to determine target server name with: $ExceptionMessage"        
        }
    }

    Write-Host "Connecting to array endpoint" -ForegroundColor Yellow

    try {
        $FlashArray = New-PfaArray –EndPoint $PfaEndpoint -UserName $PfaUser -Password (ConvertTo-SecureString -AsPlainText $PfaPassword -Force) -IgnoreCertificateError
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to connect to FlashArray endpoint $PfaEndpoint with: $ExceptionMessage"
        Return
    }

    $GetDbDisk = { param ( $Db ) 
        $DbDisk = Get-partition -DriveLetter $Db.PrimaryFilePath.Split(':')[0]| Get-Disk
        return $DbDisk
    }

    $Snapshots = $(Get-PfaAllVolumeSnapshots $FlashArray)
    $FilteredSnapshots = $Snapshots.where({ ([string]$_.Source) -eq $RefreshSource })

    if ( $PromptForSnapshot.IsPresent ) { 
        Write-Host ' '
        for ($i=0; $i -lt $FilteredSnapshots.Count; $i++) {
            Write-Host 'Snapshot ' $i.ToString()
            $FilteredSnapshots[$i]
        }
                   
        $SnapshotId = Read-Host -Prompt 'Enter the number of the snapshot to be used for the database refresh'
    }
    elseif ( $RefreshFromSnapshot.IsPresent.Equals( $false ) ) {
        try {
            $SourceDisk        = Invoke-Command -ComputerName $SourceServer -ScriptBlock $GetDbDisk -ArgumentList $SourceDb
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
    } 

    Foreach($DestSqlInstance in $DestSqlInstances) {
        Write-Host "Connecting to destination SQL Server instance" -ForegroundColor Yellow

        try {
            $DestDb            = Get-DbaDatabase -sqlinstance $DestSqlInstance -Database $RefreshDatabase
        }
        catch {
            $ExceptionMessage = $_.Exception.Message
            Write-Error "Failed to connect to destination database $DestSqlInstance.$Database with: $ExceptionMessage"
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
            $DestDisk = Invoke-Command -ComputerName $TargetServer -ScriptBlock $GetDbDisk -ArgumentList $DestDb
        }
        catch {
            $ExceptionMessage  = $_.Exception.Message
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

        $OfflineDestDisk = { param ( $DiskNumber, $Status ) 
            Set-Disk -Number $DiskNumber -IsOffline $Status
        }

        Write-Host "Offlining destination database" -ForegroundColor Yellow

        try {
            $DestDb.SetOffline()
        }
        catch {
            $ExceptionMessage = $_.Exception.Message
            Write-Error "Failed to offline database $Database with: $ExceptionMessage"
            Return
        }

        Write-Host "Offlining destination Windows volume" -ForegroundColor Yellow

        try {
            Invoke-Command -ComputerName $TargetServer -ScriptBlock $OfflineDestDisk -ArgumentList $DestDisk.Number, $True
        }
        catch {
            $ExceptionMessage = $_.Exception.Message
            Write-Error "Failed to offline disk with : $ExceptionMessage" 
            Return
        }


        $StartCopyVolMs = Get-Date
        Write-Host ' '

        try {
           if ( $PromptForSnapshot.IsPresent ) {
               Write-Host "Snap -> DB refresh: Overwriting destination FlashArray volume <" $DestVolume.name "> with snapshot <" $FilteredSnapshots[$SnapshotId].name ">" -ForegroundColor Yellow
               New-PfaVolume -Array $FlashArray -VolumeName $DestVolume.name -Source $FilteredSnapshots[$SnapshotId].name -Overwrite
           }
           elseif ( $RefreshFromSnapshot.IsPresent ) {
               Write-Host "DB -> DB refresh  : Overwriting destination FlashArray volume <" $DestVolume.name "> with snapshot <" $RefreshSource ">" -ForegroundColor Yellow
               New-PfaVolume -Array $FlashArray -VolumeName $DestVolume.name -Source $RefreshSource -Overwrite
           }
           else {
               Write-Host "DB -> DB refresh  : Overwriting destination FlashArray volume <" $DestVolume.name "> with a copy of the source volume <" $SourceVolume.name ">" -ForegroundColor Yellow
               New-PfaVolume -Array $FlashArray -VolumeName $DestVolume.name -Source $SourceVolume.name -Overwrite
           }
        }
        catch {
            $ExceptionMessage = $_.Exception.Message
            Write-Error "Failed to refresh test database volume with : $ExceptionMessage" 
            Set-Disk -Number $DestDisk.Number -IsOffline $False
            $DestDb.SetOnline()
            Return
        }

        $EndCopyVolMs = Get-Date

        Write-Host "Volume overwrite duration (ms) = " ($EndCopyVolMs - $StartCopyVolMs).TotalMilliseconds -ForegroundColor Yellow
        Write-Host " "
        Write-Host "Onlining destination Windows volume" -ForegroundColor Yellow

        try {
            Invoke-Command -ComputerName $TargetServer -ScriptBlock $OfflineDestDisk -ArgumentList $DestDisk.Number, $False
        }
        catch {
            $ExceptionMessage = $_.Exception.Message
            Write-Error "Failed to online disk with : $ExceptionMessage" 
            Return
        }

        Write-Host "Onlining destination database" -ForegroundColor Yellow

        try {
            $DestDb.SetOnline()
        }
        catch {
            $ExceptionMessage = $_.Exception.Message
            Write-Error "Failed to online database $Database with: $ExceptionMessage"
            Return
        }
    }
    
    $EndMs = Get-Date
    Write-Host " "
    Write-Host "-------------------------------------------------------"         -ForegroundColor Green
    Write-Host " "
    Write-Host "D A T A B A S E      R E F R E S H      C O M P L E T E"         -ForegroundColor Green
    Write-Host " "
    Write-Host "              Duration (s) = " ($EndMs - $StartMs).TotalSeconds  -ForegroundColor White
    Write-Host " "
    Write-Host "-------------------------------------------------------"         -ForegroundColor Green
} 
