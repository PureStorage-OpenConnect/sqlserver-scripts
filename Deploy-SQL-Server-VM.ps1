param([Parameter(Mandatory=$true)][string]$VMGuestName,
    [Parameter(Mandatory=$true)][string]$VMHostname,
    [string]$VIServerName = 'MyVCenterServername',
    [string]$ADDomain = 'pure.lab',
    [string]$Username = 'PURELAB\Administrator',
    [string]$Password = 'MyP@ssword99!',
    [string]$TemplateName = 'Windows Server 2012 R2 Template',
    [Parameter(Mandatory=$true)][string]$DatastoreName,
    [int]$DataVolumeSizeGB = 2048,
    [string]$WindowsActivationKey = 'ABCDE-12345-FGHIJ-67890-KLMNO')

Import-Module VMware.VimAutomation.Core

Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false  # I'm ignoring certificate errors - this you probably won't want to ignore.

# Connect to vSphere vCenter server
$VIServer = Connect-VIServer -Server $VIServerName -Protocol https -User $Username -Password $Password 

# Issue new VM creation command
$VM = New-VM -Server $VIServer -VMHost $VMHostName -Template $TemplateName -Name $VMGuestName -Datastore $DatastoreName

# Install additional SCSI controller on VM; Create a new hard disk.

$VM | New-HardDisk -CapacityGB $DataVolumeSizeGB | New-ScsiController -Type ParaVirtual

# The VM is created with PowerState -eq PoweredOff. Let's start it.
Start-VM -VM $VM
While ($VM.PowerState -ne 'PoweredOn') {
    Write-Host -NoNewline 'VM is still powered off, waiting...'

    While ($VM.PowerState -ne 'PoweredOn') {
        Write-Host -NoNewline '.'
        $VM = Get-VM -Server $VIServer -Name $VMGuestName
        Start-Sleep -Milliseconds 500
    }

    Write-Host ''
} # Wait until it starts

# Let's wait until the VM's guest NICs object is available and it's connected
While ($VM.Guest.Nics -eq $null) {
    Write-Host -NoNewline 'VM NIC object does not exist, waiting...'

    While ($VM.Guest.Nics -eq $null) {
        Write-Host -NoNewline '.'
        $VM = Get-VM -Server $VIServer -Name $VMGuestName
        Start-Sleep -Milliseconds 500
    }

    Write-Host ''
}

While ($VM.Guest.Nics[0].Connected -ne $true) {
    Write-Host -NoNewline 'VM NIC is not connected, waiting...'

    While ($VM.Guest.Nics[0].Connected -ne $true) {
        Write-Host -NoNewline '.'
        $VM = Get-VM -Server $VIServer -Name $VMGuestName
        Start-Sleep -Milliseconds 500
    }

    Write-Host ''
}

# The VM is now connected to the network, let's run a script inside it
$Script = [ScriptBlock]::Create(" `$Credential = New-Object –TypeName System.Management.Automation.PSCredential –ArgumentList `'$Username', (ConvertTo-SecureString –String '$Password' –AsPlainText -Force); Add-Computer -Domain '$ADDomain' -Credential `$Credential -NewName '$VMGuestName'; ")

$ScriptOutput = Invoke-VMScript -VM $VM -ScriptText $Script

If ($ScriptOutput.ScriptOutput.Trim() -notmatch 'restart') {
    Write-Host 'Something happened while trying to join the VM to the domain. Exiting...'
    Exit
}

Restart-VMGuest -VM $VM -Confirm:$false

# Let's wait until the VM's guest NICs object is available and it's connected
While ($VM.Guest.Nics -eq $null) {
    Write-Host -NoNewline 'VM NIC object does not exist, waiting...'

    While ($VM.Guest.Nics -eq $null) {
        Write-Host -NoNewline '.'
        $VM = Get-VM -Server $VIServer -Name $VMGuestName
        Start-Sleep -Milliseconds 500
    }

    Write-Host ''
}

# Make sure the guest OS registers its IP address in DNS - this is probably redundant
$Script = { Register-DnsClient }

Invoke-VMScript -VM $VM -ScriptText $Script

# Install .NET 3.5 SP1

$Script = { Install-WindowsFeature Net-Framework-Core -Source D:\Sources\sxs }

Invoke-VMScript -VM $VM -ScriptText $Script

# Disable UAC

$Script = { Set-ItemProperty -Path registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name EnableLUA -Value 0 }

Invoke-VMScript -VM $VM -ScriptText $Script

# Online the X: drive, create the Windows volume, assign the drive letter and format it.

$Script = { Get-Disk | ? { $_.OperationalStatus -eq 'Offline' } | Initialize-Disk -PartitionStyle GPT -PassThru | New-Partition -UseMaximumSize -DriveLetter X ;
Format-Volume -DriveLetter X -NewFileSystemLabel 'SqlData' -FileSystem NTFS -AllocationUnitSize 65536 -UseLargeFRS -Confirm:$false;
mkdir X:\SqlData; mkdir X:\Backup; mkdir X:\tempdb }

Invoke-VMScript -VM $VM -ScriptText $Script

# Load the SQL Server 2014 ISO in the VM's CD/DVD drive
$VMCD = Get-CDDrive -VM $VM
Set-CDDrive -CD $VMCD -ISO '[Infrastructure Datastore] ISO/en_sql_server_2014_enterprise_core_edition_with_service_pack_1_x64_dvd_6672706.iso' -Connected:$true -Confirm:$false

# Check if CD drive is connected, otherwise wait a bit.
While ($VMCD.ConnectionState.Connected -ne $true) {
    Write-Host 'CD is not ready yet, waiting...'
    $VMCD = Get-CDDrive -VM $VM
    Start-Sleep -Milliseconds 500
}

# Check to see if D:\setup.exe is ready to be launched, otherwise wait a bit.
$Script = { Test-Path D:\Setup.exe }

$ScriptOutput = Invoke-VMScript -VM $VM -ScriptText $Script -GuestUser $Username -GuestPassword $Password

While ($ScriptOutput.ScriptOutput.Trim() -ne 'True') {
    Start-Sleep -Milliseconds 500

    $Script = { Test-Path D:\Setup.exe }

    $ScriptOutput = Invoke-VMScript -VM $VM -ScriptText $Script -GuestUser $Username -GuestPassword $Password
}


# Install SQL Server 2014
$Script = [ScriptBlock]::Create(" & D:\setup.exe /ACTION=`"Install`" /ERRORREPORTING=0 /FEATURES=SQLEngine,Replication,BC,Conn,SSMS,ADV_SSMS /UPDATEENABLED=1 /UPDATESOURCE=\\PSSQLAD\SQLServerUpdates /INSTANCENAME=MSSQLSERVER /AGTSVCACCOUNT=`"NT AUTHORITY\NETWORK SERVICE`" /SQLSVCACCOUNT=`"NT AUTHORITY\NETWORK SERVICE`" /SQLSYSADMINACCOUNTS=`"$Username`" /Q /SQMREPORTING=0 /BROWSERSVCSTARTUPTYPE=`"Disabled`" /SECURITYMODE=`"SQL`" /SAPWD=`"$Password`" /SQLSVCSTARTUPTYPE=`"Automatic`" /TCPENABLED=1 /IACCEPTSQLSERVERLICENSETERMS /SQLBACKUPDIR=X:\Backup /SQLTEMPDBDIR=X:\tempdb /SQLTEMPDBLOGDIR=X:\tempdb /SQLUSERDBDIR=X:\SqlData /SQLUSERDBLOGDIR=X:\SqlData ")

Invoke-VMScript -VM $VM -ScriptText $Script -GuestUser $Username -GuestPassword $Password

# Run SQL instance config: MAXDOP, tempdb files, max server memory - some hardcoded values here.

$Script = { Import-Module SQLPS; 
            Invoke-Sqlcmd -Query "EXEC sys.sp_configure 'show advanced options', N'1'; RECONFIGURE;" -ServerInstance . ;
            Invoke-Sqlcmd -Query "EXEC sys.sp_configure 'max server memory (MB)', N'28672'; EXEC sys.sp_configure 'max degree of parallelism', N'4'; EXEC sys.sp_configure N'optimize for ad hoc workloads', N'1'; RECONFIGURE;" -ServerInstance . ; 
            Invoke-SqlCmd -Query "ALTER DATABASE tempdb ADD FILE (NAME = tempdev2, FILENAME = 'X:\tempdb\tempdev2.mdf', SIZE = 512MB); ALTER DATABASE tempdb ADD FILE (NAME = tempdev3, FILENAME = 'X:\tempdb\tempdev3.mdf', SIZE = 512MB); ALTER DATABASE tempdb ADD FILE (NAME = tempdev4, FILENAME = 'X:\tempdb\tempdev4.mdf', SIZE = 512MB); ALTER DATABASE tempdb ADD FILE (NAME = tempdev5, FILENAME = 'X:\tempdb\tempdev5.mdf', SIZE = 512MB); ALTER DATABASE tempdb ADD FILE (NAME = tempdev6, FILENAME = 'X:\tempdb\tempdev6.mdf', SIZE = 512MB); ALTER DATABASE tempdb ADD FILE (NAME = tempdev7, FILENAME = 'X:\tempdb\tempdev7.mdf', SIZE = 512MB); ALTER DATABASE tempdb ADD FILE (NAME = tempdev8, FILENAME = 'X:\tempdb\tempdev8.mdf', SIZE = 512MB); ALTER DATABASE tempdb MODIFY FILE (NAME = tempdev, FILENAME = 'X:\tempdb\tempdev.mdf', SIZE=512MB) ALTER DATABASE tempdb MODIFY FILE (NAME = templog, FILENAME = 'X:\tempdb\templog.ldf', SIZE=2048MB)" -ServerInstance . ; 
          }
            
Invoke-VMScript -VM $VM -ScriptText $Script -GuestUser $Username -GuestPassword $Password

# Activate Windows

$Script = [ScriptBlock]::Create("cscript C:\Windows\System32\slmgr.vbs /ipk $WindowsActivationKey; cscript C:\Windows\System32\slmgr.vbs /ato")

Invoke-VMScript -VM $VM -ScriptText $Script -GuestUser $Username -GuestPassword $Password