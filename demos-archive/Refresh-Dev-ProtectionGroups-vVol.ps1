##########################################################################################################################
# Modification of Refresh-Dev-ProtectionGroups.ps1 by DBArgenis for use with VMware vVols based SQL VMs                  #
# Original: https://github.com/PureStorage-OpenConnect/sqlserver-scripts/blob/master/Refresh-Dev-ProtectionGroups.ps1.   #
#                                                                                                                        #
# Updated by: Jase McCarty                                                                                               #
# Twitter:    @jasemccarty                                                                                               #
#                                                                                                                        #
# Requirements:                                                                                                          #
#    $TargetServer must have the Guest OS Hostname (MyTestServer in this example)                                        #
#    Must know the vVol Volume Group names and the vVol volume names for the source & target VMs                         #
#    VOLUMEGROUP1 for the Source VM and VOLUMEGROUP2 for the Target VM                                                   #
#    Source VM vVol Volumes SOURCEVM-vVol-Drive-E, SOURCEVM-vVol-Drive-F, & SOURCEVM-vVol-Drive-G                        #
#    Target VM vVol Volumes TARGETVM-vVol-Drive-E, TARGETVM-vVol-Drive-F, & TARGETVM-vVol-Drive-G                        #
#                                                                                                                        #
# Drives taken offline by their device unit number rather than serial number in the Target VM                            #
##########################################################################################################################

# Ensure the Pure Storage PowerShell SDK is loaded
Import-Module PureStoragePowerShellSDK

# Configure the target SQL Server 
$TargetServer = 'MyTestServer'

# Create a session to the target server
$TargetServerSession = New-PSSession -ComputerName $TargetServer

# Import the SQLPS module so SQL commands are available
Import-Module SQLPS -PSSession $TargetServerSession -DisableNameChecking

# Offline the database
Write-Warning "Offlining the target database..." 
Invoke-Command -Session $TargetServerSession -ScriptBlock { Invoke-Sqlcmd -ServerInstance . -Database master -Query "ALTER DATABASE MyDatabaseName SET OFFLINE WITH ROLLBACK IMMEDIATE" }

# Offline the volumes that have SQL data
Write-Warning "Offlining the target volumes..." 
Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? { $_.Number -eq '1' } | Set-Disk -IsOffline $True }
Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? { $_.Number -eq '2' } | Set-Disk -IsOffline $True }
Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? { $_.Number -eq '3' } | Set-Disk -IsOffline $True }

# Connect to the FlashArray's REST API, get a session going
# THIS IS A SAMPLE SCRIPT WE USE FOR DEMOS! _PLEASE_ do not save your password in cleartext here. 
# Use NTFS secured, encrypted files or whatever else -- never cleartext!
Write-Warning "Establishing a session against the Pure Storage FlashArray..." 
$FlashArray = New-PfaArray -EndPoint 10.10.1.22 -UserName pureuser -Password (ConvertTo-SecureString -AsPlainText "PASSWORD" -Force) -IgnoreCertificateError

# If you don't want a new snapshot of the Protection Group generated whenever you run this script, comment this next line
Write-Warning "Creating a new snapshot of the Protection Group..."
New-PfaProtectionGroupSnapshot -Array $FlashArray -Protectiongroupname 'MyDatabaseName-PG' -ApplyRetention

Write-Warning "Obtaining the most recent snapshot for the protection group..."
$MostRecentSnapshot = Get-PfaProtectionGroupSnapshots -Array $FlashArray -Name 'MyDatabaseName-PG' | Sort-Object created -Descending | Select -Property name -First 1

# Perform the target volume overwrite
# Differs from Refresh-Dev-ProtectionGroups.ps1 because vVols are part of a Volume Group
# This changes the syntax for the overwriting process
Write-Warning "Overwriting the target database volumes with a copies of the volumes in the most recent snapshot..." 
New-PfaVolume -Array $FlashArray -VolumeName VOLUMEGROUP2/TARGETVM-vVol-Drive-E -Source ($MostRecentSnapshot.name + '.VOLUMEGROUP1/SOURCEVM-vVol-Drive-E') -Overwrite
New-PfaVolume -Array $FlashArray -VolumeName VOLUMEGROUP2/TARGETVM-vVol-Drive-F -Source ($MostRecentSnapshot.name + '.VOLUMEGROUP1/SOURCEVM-vVol-Drive-F') -Overwrite
New-PfaVolume -Array $FlashArray -VolumeName VOLUMEGROUP2/TARGETVM-vVol-Drive-G -Source ($MostRecentSnapshot.name + '.VOLUMEGROUP1/SOURCEVM-vVol-Drive-G') -Overwrite

# Online the volume
Write-Warning "Onlining the target volumes..." 
Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? { $_.Number -eq '1' } | Set-Disk -IsOffline $False }
Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? { $_.Number -eq '2' } | Set-Disk -IsOffline $False }
Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? { $_.Number -eq '3' } | Set-Disk -IsOffline $False }

# Online the database
Write-Warning "Onlining the target database..." 
Invoke-Command -Session $TargetServerSession -ScriptBlock { Invoke-Sqlcmd -ServerInstance . -Database master -Query "ALTER DATABASE MyDatabaseName SET ONLINE WITH ROLLBACK IMMEDIATE" }

# Give an update
Write-Warning "Target database downtime ended." 

# Clean up
Remove-PSSession $TargetServerSession
Write-Warning "All done." 
