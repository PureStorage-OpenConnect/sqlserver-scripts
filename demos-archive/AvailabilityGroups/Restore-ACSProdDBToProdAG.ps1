<#
This script requires SQL 2016 or later to utilize automatic seeding.
This script requires the DBATools and the Pure Storage SSMS extension.
    The DBATools module is available from the PowerShell Gallery. This script will attempt to install it if it does not exist.
    The Pure Storage SSMS Extension is available here - https://github.com/PureStorage-Connect/FlashArray-SSMS-Extension/releases.
This script requires PowerShell 5.1.
#>

<#
.SYNOPSIS
  This script is will restore the latest SQL Server database that was backed up via an application consistent snapshot using the Pure Storage Backup SSMS extension and add it to an Availability Group.

.DESCRIPTION
  This script is will restore the latest SQL Server database application consistent snapshot from a Pure Storage FlashArray and add it to an Availability Group. If the database exists in the Availability Group, it will be removed from the Availability Group and dropped on all secondaries. Once the database is restored on the primary replica, it will be added to the secondaries. Automatic seeding will be used to initialize the secondaries.

.PARAMETER Ag
  The Availability Group the database will be restored to.

.PARAMETER Mountserver
  The database server to mount the restored snapshot to. PowerShell Remoting must be enabled on this server for drive mounting to work.

.PARAMETER Database
  The database to be restored.

.PARAMETER Driveletter
  The drive letter to use to mount the database to the primary. Eg. "S:" (colon must be present).

.PARAMETER Primary
  The primary replica for the Availability Group.

.PARAMETER Secondaries
  The secondary replica(s) for the Availability Group. If there is more than one secondary, define parameter values as an array.
  Example - $secondaries = @("sql2019vm2","sql2019vm3");

.NOTES
  Modified for the Pure Storage FlashArray and SSMS Extension.
  Thanks Frank Gill.

.EXAMPLE
  PSRestoreAgDatabase -Ag MyAgName -Mountserver MyServer -Database MyDatabase -BackupConfigname MyBackupConfig -Primary MyPrimary -Secondaries "Secondary1","Secondary2";

#>

Function Restore-AgDatabase{
  [CmdletBinding()]

    PARAM (
        [Parameter(Mandatory=$true)]
        [string]
        $Ag,
        [Parameter(Mandatory=$true)]
        [string]
        $Mountserver,
        [Parameter(Mandatory=$true)]
        [string]
        $Database,
        [Parameter(Mandatory=$true)]
        [string]
        $Primary,
        [Parameter(Mandatory=$true)]
        [string[]]
        $Secondaries,
        [Parameter(Mandatory=$true)]
        [string[]]
        $Driveletter,
        [Parameter(Mandatory=$true)]
        [string]
        $BackupConfigfile
    )

  Begin{
    Write-Host "Start PSRestore-AgDatabase function..."
    <# Check for DBATools and Pure Storage Backup SDK modules. If DBATools is not present, install it. If Pure Storage
        BackupSDK is not present, stop. If not loaded, import it. #>
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        if ((Get-InstalledModule -Name "DBATools" -ErrorAction SilentlyContinue) -eq $null) {
            Install-Module -Name DBATools -Force
            Import-Module DBATools
        }
        if ((Get-InstalledModule -Name "PureStorageBackupSDK" -ErrorAction SilentlyContinue) -eq $null) {
            Write-Host "The Pure Storage SSMS extension, which includes the Backup SDK, must be installed to use this script."
            Write-Host "Download the latest from https://github.com/PureStorage-Connect/FlashArray-SSMS-Extension/releases"
            Break
        else {
            Import-Module PureStorageBackupSDK
        }
        }
  }

  Process{
    Try{
        Write-Host "Restoring and mounting last available snapshot for primary database from FlashArray"
        $getSnapshot = Get-PfaBackupHistory | Where-Object component -eq $BackupConfigname | Sort-Object HistoryId -Descending;
        Mount-PfaBackupJob -HistoryId $getSnapshot[0].historyid -DriveLetter $Driveletter -MountComputer $Mountserver;

        $TestPSSession = New-PSSession -ComputerName $Mountserver
        Enter-PSSession $TestPSSession
        $backupexists = Test-Path -Path $Driveletter;

        if($backupexists -ne $true)
        {
            throw "The snapshot did not restore.  Please verify the snapshot in the FlashArray UI and try again.";
        else {
            Remove-PSSession
        }}

        $replicas = @();
        $replicas += $Primary;
        $replicas += $Secondaries;
        $version = Invoke-DbaQuery -SqlInstance $Primary -Database master -Query "SELECT SERVERPROPERTY('productversion')";
        $majorversion = $version.Column1.Substring(0,2);

        $primaryinfo = Get-DbaAgReplica -SqlInstance $Primary -AvailabilityGroup $Ag -Replica $Primary;
        $role = $primaryinfo.Role;

        if($role -ne "Primary")
        {
            throw "$Primary was entered as the primary replica and it is $role";
        }

        if($majorversion -lt 13)
        {
                throw "SQL version is less than 2016 and this script cannot be used.";
                Break
            else
            {
                foreach($replica in $replicas)
                {

                    $services = Get-DbaService -Computer $replica;
                    $serviceacct = $services | Select-Object ServiceName, StartName | Where-Object ServiceName -eq MSSQLSERVER;
                    $sqlacct = $serviceacct.StartName;
                }
            }
        }

        $exists = Get-DbaDatabase -SqlInstance $Primary -Database $Database;

        if($exists)
        {
            <# Remove the database to be restored from the Availability Group #>
            Remove-DbaAgDatabase -SqlInstance $Primary -Database $Database -Ag $Ag -Confirm:$false;
            <# Drop the database from all secondary replicas #>
            Remove-DbaDatabase -SqlInstance $Secondaries -Database $Database -Confirm:$false;
        }
        <# Attach the database to the primary replica #>
            Mount-DbaDatabase -SqlInstance $Primary -Path $Driveletter -DatabaseName $Database;

        <# Automatic seeding to initialize the secondaries. #>
            Add-DbaAgDatabase -SqlInstance $Primary -Ag $Ag -Database $Database -SeedingMode Automatic;
    }

    Catch{
      "Something went wrong. $_"
      Break
    }

  }

  End{
    If($?){
      Write-Host "Completed Restore."
    }
  }
}

