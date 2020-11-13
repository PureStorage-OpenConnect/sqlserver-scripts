##########################################################################################################################
# Modification of Refresh-Dev-ProtectionGroups.ps1 by DBArgenis for use with VMware vVols based SQL VMs                  #
# Original: https://github.com/PureStorage-OpenConnect/sqlserver-scripts/blob/master/Refresh-Dev-ProtectionGroups.ps1.   #
#                                                                                                                        #
# Updated by: Jase McCarty                                                                                               #
# Twitter:    @jasemccarty                                                                                               #
#                                                                                                                        #
# Requirements:                                                                                                          #
#    Must be executed from a Windows system/account that has credentials on the Target SQL server                        #
#    $TargetServer must have the Guest OS Hostname (MyTestServer in this example)                                        #
#    Must know the vVol Volume Group & volume names for the source & target VMs                                          #
#    SQLPROD-VG/VVOL-NAME for the Source VM and SQLTEST-VG/VVOLNAME for the Target VM                                    #
#    Target VM vVol Device number for each of the Target VM vVol Disks (Windows Device Number)                           #
#                                                                                                                        #
# Drives are taken offline by their device unit number rather than serial number in the Target VM                        #
#                                                                                                                        #
# Updates - 13 NOV 2020                                                                                                  #
#    - Adding Variable Section                                                                                           #
#    - Loop through volumes, devices, databases                                                                          #
##########################################################################################################################

# Variables Section
$TargetServer  = 'SQLDEMO'                            # Configure the target SQL Server 
$EndPoint      = 'targetpfa.demo.local'               # FQDN or IP of the FlashArray that the SQL Server resides on
$PureUser      = 'pureuser'                           # FlashArray username 
$PurePass      = 'password'                           # FlashArray password
$PGroupName    = 'sourcepfa:pgname'                   # Protection Group Name 

# Name(s) of the SQL database(s) to take offline
$databases     = @('FT_Demo')                

# Ensure that the array position of the targetvolume, targetdevice, & sourcedevice match
# Name(s) of the Target SQL VM vVols that are going to be overwritten         
  $targetvolumes = @('SQLDEMO-vg/SQLDEMO-Drive-D','SQLDEMO-vg/SQLDEMO-Drive-E','SQLDEMO-vg/SQLDEMO-Drive-F')
# Target Device ID(s)
  $targetdevices = @(1,2,3)
# Corresponding Source SQL VM vVols that are going to be overwritten
  $sourcevolumes = @('SQLPROD-VG/SQLPROD-Drive-D','SQLPROD-VG/SQLPROD-Drive-E','SQLPROD-VG/SQLPROD-Drive-F')

###########################################################
# It should not be necessary to make any changes below    #
###########################################################

# Ensure the Pure Storage PowerShell SDK is loaded
Import-Module PureStoragePowerShellSDK

# Create a session to the target server
$TargetServerSession = New-PSSession -ComputerName $TargetServer #-Credential (Get-Credential)

# Import the SQLPS module so SQL commands are available
Import-Module SQLPS -PSSession $TargetServerSession -DisableNameChecking

# Offline the database(s)
Write-Warning "Offlining the target database(s)..."
Foreach ($database in $databases) {
    $Scriptblock = "Invoke-Sqlcmd -ServerInstance . -Database master -Query  'ALTER DATABASE $database SET OFFLINE WITH ROLLBACK IMMEDIATE'"
    Invoke-Command -Session $TargetServerSession -ScriptBlock {$Scriptblock}
}

# Offline the volumes that have SQL data
Write-Warning "Offlining the target volume(s)..." 
Foreach ($targetdevice in $targetdevices) {
    Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? { $_.Number -eq $targetdevice } | Set-Disk -IsOffline $True }
}

# Connect to the FlashArray's REST API, get a session going
# THIS IS A SAMPLE SCRIPT WE USE FOR DEMOS! _PLEASE_ do not save your password in cleartext here. 
# Use NTFS secured, encrypted files or whatever else -- never cleartext!
Write-Warning "Establishing a session against the Pure Storage FlashArray..." 
$FlashArray = New-PfaArray -EndPoint $EndPoint -UserName $PureUser -Password (ConvertTo-SecureString -AsPlainText $PurePass -Force) -IgnoreCertificateError

# Only initiate a new snapshot if the Protection Group is local (not remote)
If ($PGroupName -notlike "*:*") {
    Write-Warning "Creating a new snapshot of the Protection Group..."
    New-PfaProtectionGroupSnapshot -Array $FlashArray -Protectiongroupname $PGroupName -ApplyRetention
}

# Get the most recent snapshot
Write-Warning "Obtaining the most recent snapshot for the protection group..."
$MostRecentSnapshot = Get-PfaProtectionGroupSnapshots -Array $FlashArray -Name $PGroupName | Sort-Object created -Descending | Select -Property name -First 1

# Perform the target volume(s) overwrite
Write-Warning "Overwriting the target database volumes with a copies of the volumes in the most recent snapshot..." 
Foreach ($targetvolume in $targetvolumes) {
    $sourcevolume = $MostRecentSnapshot.name + "." + $sourcevolumes[$targetvolumes.IndexOf($targetvolume)]
    New-PfaVolume -Array $FlashArray -VolumeName $targetvolume -Source $sourcevolume -Overwrite
}

# Online the volume(s)
Write-Warning "Onlining the target volumes..." 
Foreach ($targetdevice in $targetdevices) {
    Invoke-Command -Session $TargetServerSession -ScriptBlock { Get-Disk | ? { $_.Number -eq $targetdevice } | Set-Disk -IsOffline $True }
}

# Online the database
Write-Warning "Onlining the target database..." 
Foreach ($database in $databases) {
    $Scriptblock = "Invoke-Sqlcmd -ServerInstance . -Database master -Query  'ALTER DATABASE $database SET ONLINE WITH ROLLBACK IMMEDIATE'"
    Invoke-Command -Session $TargetServerSession -ScriptBlock {$Scriptblock}
}

# Give an update
Write-Warning "Target database downtime ended." 

# Clean up
Remove-PSSession $TargetServerSession

Write-Warning "All done." 
