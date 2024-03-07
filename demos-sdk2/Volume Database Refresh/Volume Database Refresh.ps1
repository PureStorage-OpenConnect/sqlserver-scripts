# Refresh a dev database in a few seconds!
Import-Module SqlServer
Import-Module PureStoragePowerShellSDK2



#Let's initalize some variables we'll use for connections to our SQL Server and it's base OS
$Target = 'aen-sql-22-b'
$TargetSession = New-PSSession -ComputerName $Target
$Credential = Import-CliXml -Path "$HOME\FA_Cred.xml"


# Offline the database
Write-Output "Actual development instance downtime begins now." -ForegroundColor Red
Write-Output "Offlining the database..." -ForegcroundColor Red
Invoke-Sqlcmd -ServerInstance $Target -Database master -Query "ALTER DATABASE FT_Demo SET OFFLINE WITH ROLLBACK IMMEDIATE" 


# Offline the volume
Write-Output "Offlining the volume..." -ForegroundColor Red
Invoke-Command -Session $TargetSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq '6000c2967c745d1964f4706e41bc85ac' } | Set-Disk -IsOffline $True }


# Connect to the FlashArray's REST API
Write-Output "Establishing a session against the Pure Storage FlashArray..." -ForegroundColor Red
$FlashArray = Connect-Pfa2Array –EndPoint sn1-m70-f06-33.puretec.purestorage.com -Credential $Credential -IgnoreCertificateError


# Perform the volume overwrite (no intermediate snapshot needed!)
Write-Output "Overwriting the dev instance's volume with a fresh copy from production..." -ForegroundColor Red
New-Pfa2Volume -Array $FlashArray -Name 'vvol-aen-sql-22-b-9b9a3477-vg/Data-f08e715f' -SourceName 'vvol-aen-sql-22-a-1-3d9acfdd-vg/Data-cabce242' -Overwrite $true 


# Online the volume
Write-Output "Onlining the volume..." -ForegroundColor Red
Invoke-Command -Session $TargetSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '6000c2967c745d1964f4706e41bc85ac' } | Set-Disk -IsOffline $False }


# Online the database
Write-Output "Onlining the database..." -ForegroundColor Red
Invoke-Sqlcmd -ServerInstance $Target -Database master -Query "ALTER DATABASE FT_Demo SET ONLINE WITH ROLLBACK IMMEDIATE" 


Write-Output "Development database downtime ended." -ForegroundColor Red


# Clean up
Remove-PSSession $TargetSession
Write-Output "All done." -ForegroundColor Red
