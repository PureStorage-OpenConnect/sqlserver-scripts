# Refresh a dev database in a few seconds!
Import-Module PureStoragePowerShellSDK2


#Let's initalize some variables we'll use for connections to our SQL Server and it's base OS
$Target = 'aen-sql-22-b'
$TargetSession = New-PSSession -ComputerName $Target
$Credential = Import-CliXml -Path "$HOME\FA_Cred.xml"


# Offline the database
Write-Output "Offlining the target database..." 
Invoke-Sqlcmd -ServerInstance $Target -Database master -Query "ALTER DATABASE tpcc100 SET OFFLINE WITH ROLLBACK IMMEDIATE" 
Invoke-Sqlcmd -ServerInstance $Target -Database master -Query "ALTER DATABASE tpch100 SET OFFLINE WITH ROLLBACK IMMEDIATE" 


# Offline the volumes
Write-Output "Offlining the target volumes..." 
Invoke-Command -Session $TargetSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '6000c29bbfc45bd8e4e83a53ad8722b3' } | Set-Disk -IsOffline $True }
Invoke-Command -Session $TargetSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '6000c29a79c33073f83c8cc0247f77ad' } | Set-Disk -IsOffline $True }


# Connect to the FlashArray's REST API, get a session going
# THIS IS A SAMPLE SCRIPT WE USE FOR DEMOS! _PLEASE_ do not save your password in cleartext here. 
# Use NTFS secured, encrypted files or whatever else -- never cleartext!
Write-Output "Establishing a session against the Pure Storage FlashArray..." -ForegroundColor Red
$FlashArray = Connect-Pfa2Array –EndPoint sn1-m70-f06-33.puretec.purestorage.com -Credential $Credential -IgnoreCertificateError


# If you don't want a new snapshot of the Protection Group generated whenever you run this script, comment this next line
Write-Output "Creating a new snapshot of the Protection Group..."
$Snapshot = New-Pfa2ProtectionGroupSnapshot -Array $FlashArray -SourceName 'aen-sql-22-a-pg' 
$Snapshot


# Perform the target volume overwrite
Write-Output "Overwriting the target database volumes with a copies of the volumes in the most recent snapshot..." 
New-Pfa2Volume -Array $FlashArray -Name 'vvol-aen-sql-22-b-9b9a3477-vg/Data-700eaca4' -SourceName ($Snapshot.Name + ".vvol-aen-sql-22-a-1-3d9acfdd-vg/Data-87ee3d7c") -Overwrite $true
New-Pfa2Volume -Array $FlashArray -Name 'vvol-aen-sql-22-b-9b9a3477-vg/Data-d6a7747f' -SourceName ($Snapshot.Name + ".vvol-aen-sql-22-a-1-3d9acfdd-vg/Data-77084035") -Overwrite $true


# Online the volumes
Write-Output "Onlining the target volumes..." 
Invoke-Command -Session $TargetSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '6000c29bbfc45bd8e4e83a53ad8722b3' } | Set-Disk -IsOffline $False }
Invoke-Command -Session $TargetSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '6000c29a79c33073f83c8cc0247f77ad' } | Set-Disk -IsOffline $False }


#Online the database
Write-Output "Onlining the target database..." 
Invoke-Sqlcmd -ServerInstance $Target -Database master -Query "ALTER DATABASE tpcc100 SET ONLINE WITH ROLLBACK IMMEDIATE" 
Invoke-Sqlcmd -ServerInstance $Target -Database master -Query "ALTER DATABASE tpch100 SET ONLINE WITH ROLLBACK IMMEDIATE" 

Write-Output "Target database downtime ended." 

# Clean up
Remove-PSSession $TargetSession
Write-Output "All done." 