# Refresh databases on a second array from a replicate protection group snapshot
Import-Module SqlServer
Import-Module PureStoragePowerShellSDK2

$Target = 'aen-sql-22-dr'
$TargetSession = New-PSSession -ComputerName $Target
$Credential = Import-CliXml -Path "$HOME\FA_Cred.xml"


# Offline the databases
Write-Warning "Offlining the target database..." 
Invoke-Sqlcmd -ServerInstance $Target -Database master -Query "ALTER DATABASE FT_Demo SET OFFLINE WITH ROLLBACK IMMEDIATE" 
Invoke-Sqlcmd -ServerInstance $Target -Database master -Query "ALTER DATABASE tpcc100 SET OFFLINE WITH ROLLBACK IMMEDIATE" 
Invoke-Sqlcmd -ServerInstance $Target -Database master -Query "ALTER DATABASE tpch100 SET OFFLINE WITH ROLLBACK IMMEDIATE" 


# Offline the volumes
Write-Warning "Offlining the target volumes..." 
Invoke-Command -Session $TargetSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '6000c29958cf0246e699034809badd49' } | Set-Disk -IsOffline $true }
Invoke-Command -Session $TargetSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '6000c295acdd84ef3ef0d2ca8f4a407f' } | Set-Disk -IsOffline $true }
Invoke-Command -Session $TargetSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '6000c29653be9c3badb2b5a7cd62ccb4' } | Set-Disk -IsOffline $true }


# Connect to the FlashArray's REST API, get a session going
# THIS IS A SAMPLE SCRIPT WE USE FOR DEMOS! _PLEASE_ do not save your password in cleartext here. 
# Use NTFS secured, encrypted files or whatever else -- never cleartext!
Write-Output "Establishing a session against the Pure Storage FlashArray..." -ForegroundColor Red
$FlashArray = Connect-Pfa2Array –EndPoint sn1-x70-f06-27.puretec.purestorage.com -Credential $Credential -IgnoreCertificateError


#Get the most recent snapshot that is replicated to this array
Write-Warning "Obtaining the most recent snapshot for the protection group..."
$Snapshot = Get-Pfa2ProtectionGroupSnapshot -Array $FlashArray -SourceName 'sn1-m70-f06-33:aen-sql-22-a-pg' | Sort-Object created -Descending | Select-Object -Property name -First 1
$Snapshot


# Perform the target volume overwrite
Write-Warning "Overwriting the target database volumes with a copies of the volumes in the most recent snapshot..." 
New-Pfa2Volume -Array $FlashArray -Name 'vvol-aen-sql-22-dr-b6405dd7-vg/Data-7fc763b5' -SourceName ($Snapshot.Name + ".vvol-aen-sql-22-a-1-3d9acfdd-vg/Data-87ee3d7c") -Overwrite $true
New-Pfa2Volume -Array $FlashArray -Name 'vvol-aen-sql-22-dr-b6405dd7-vg/Data-f3a857f4' -SourceName ($Snapshot.Name + ".vvol-aen-sql-22-a-1-3d9acfdd-vg/Data-77084035") -Overwrite $true
New-Pfa2Volume -Array $FlashArray -Name 'vvol-aen-sql-22-dr-b6405dd7-vg/Data-7170aa52' -SourceName ($Snapshot.Name + ".vvol-aen-sql-22-a-1-3d9acfdd-vg/Data-cabce242") -Overwrite $true


# Online the volume
Write-Warning "Onlining the target volumes..." 
Invoke-Command -Session $TargetSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '6000c29958cf0246e699034809badd49' } | Set-Disk -IsOffline $false }
Invoke-Command -Session $TargetSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '6000c295acdd84ef3ef0d2ca8f4a407f' } | Set-Disk -IsOffline $false }
Invoke-Command -Session $TargetSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '6000c29653be9c3badb2b5a7cd62ccb4' } | Set-Disk -IsOffline $false }


# Online the databases
Write-Warning "Onlining the target database..." 
Invoke-Sqlcmd -ServerInstance $Target -Database master -Query "ALTER DATABASE tpcc100 SET ONLINE WITH ROLLBACK IMMEDIATE" 
Invoke-Sqlcmd -ServerInstance $Target -Database master -Query "ALTER DATABASE tpch100 SET ONLINE WITH ROLLBACK IMMEDIATE" 
Invoke-Sqlcmd -ServerInstance $Target -Database master -Query "ALTER DATABASE FT_Demo SET ONLINE WITH ROLLBACK IMMEDIATE" 

Write-Warning "Target database downtime ended." 

# Clean up
Remove-PSSession $TargetServerSession
Write-Warning "All done." 