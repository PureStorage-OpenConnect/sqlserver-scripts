Import-Module PureStoragePowerShellSDK
Import-Module SQLPS
 
#DevServer
$Target1 = 'MyDevServerA'
$Target2 = 'MyDevServerB'
$TargetPSSession1 = New-PSSession -ComputerName $Target1
$TargetPSSession2 = New-PSSession -ComputerName $Target2
Write-Warning "Target database downtime begins now."
 
 
# Offline the availability group
Write-Warning "Stopping the AG..."
Invoke-Command -Session $TargetPSSession1 -ScriptBlock { Stop-ClusterGroup My_AG}
 
# Offline the target/copy volume
Write-Warning "Offlining the volume..."                                                                                           
Invoke-Command -Session $TargetPSSession1 -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '6000c29a3f3454691b7ad753cd4225d1' } | Set-Disk -IsOffline $True }
Invoke-Command -Session $TargetPSSession1 -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '6000c29a3f3454691b7ad753cd4225d2' } | Set-Disk -IsOffline $True }
Invoke-Command -Session $TargetPSSession2 -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '7000c29a3f3454691b7ad753cd4225d1' } | Set-Disk -IsOffline $True }
Invoke-Command -Session $TargetPSSession2 -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '7000c29a3f3454691b7ad753cd4225d2' } | Set-Disk -IsOffline $True }
 
# Connect to the FlashArray's REST API, get a session going - you're gonna have to excuse my laziness saving the password here :)
Write-Warning "Establishing a session against the Pure Storage FlashArray..."
$FlashArray = New-PfaArray -EndPoint 10.XX.XX.XX -UserName MyPureUser -Password (ConvertTo-SecureString -AsPlainText 'MyPurePassword' -Force) -IgnoreCertificateError
 
#Get the latest snapshot for yourt Protection Group
$MostRecentSnapshot = New-PFAProtectionGroupSnapshots -Array $FlashArray -Name 'MyPGGroupName' | Sort-Object created -Descending | Select -Property name -First 1
 
# Perform the volume overwrite 
Write-Warning "Overwriting the dev instance's volume with a fresh copy from production..."
New-PfaVolume -Array $FlashArray -VolumeName MyDevServer1-Data01 -Source ($MostRecentSnapshot.name + '.sql00-Data01') -Overwrite
New-PfaVolume -Array $FlashArray -VolumeName MyDevServer1-Log01 -Source ($MostRecentSnapshot.name + '.sql00-Log01') -Overwrite
New-PfaVolume -Array $FlashArray -VolumeName MyDevServer2-Data01 -Source ($MostRecentSnapshot.name + '.sql00-Data01') -Overwrite
New-PfaVolume -Array $FlashArray -VolumeName MyDevServer2-Log01 -Source ($MostRecentSnapshot.name + '.sql00-Log01') -Overwrite
 
# Online the volume
Write-Warning "Onlining the volume..."
Invoke-Command -Session $TargetPSSession1 -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '6000c29a3f3454691b7ad753cd4225d1' } | Set-Disk -IsOffline $False }                                                                                 
Invoke-Command -Session $TargetPSSession1 -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '6000c29a3f3454691b7ad753cd4225d2' } | Set-Disk -IsOffline $False }                                                                                 
Invoke-Command -Session $TargetPSSession2 -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '7000c29a3f3454691b7ad753cd4225d1' } | Set-Disk -IsOffline $False }                                                                                 
Invoke-Command -Session $TargetPSSession2 -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq '7000c29a3f3454691b7ad753cd4225d2' } | Set-Disk -IsOffline $False }                                                                                 
 
# Start the availability group
Write-Warning "Starting the AG..."
Invoke-Command -Session $TargetPSSession1 -ScriptBlock { Start-ClusterGroup My_AG}
 
 
Write-Warning "Development database downtime ended."
 
 
# Clean up
Disconnect-PfaArray $FlashArray
Remove-PSSession $TargetPSSession
Remove-PSSession $SourcePSSession
Write-Output "All done."
