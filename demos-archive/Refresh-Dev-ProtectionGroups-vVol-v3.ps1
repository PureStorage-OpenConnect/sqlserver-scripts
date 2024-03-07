##############################################################################################################################
# Modification of Refresh-Dev-ProtectionGroups-vVol.ps1 by DBArgenis for use with VMware vVols based SQL VMs                 #
# Previous: https://github.com/PureStorage-OpenConnect/sqlserver-scripts/blob/master/Refresh-Dev-ProtectionGroups-vVol.ps1   #
#                                                                                                                            #
# Updated by: Jase McCarty                                                                                                   #
# Twitter:    @jasemccarty                                                                                                   #
#                                                                                                                            #
# Requirements:                                                                                                              #
#    Must be executed from a Windows system/account that has credentials on the Target SQL server                            #
#    $TargetServer must have the Guest OS Hostname (MyTestServer in this example)                                            #
#    Must know the vVol Volume Group & volume names for the source & target VMs                                              #
#    SQLPROD-VG/VVOL-NAME for the Source VM and SQLTEST-VG/VVOLNAME for the Target VM                                        #
#    Target VM vVol Device number for each of the Target VM vVol Disks (Windows Device Number)                               #
#                                                                                                                            #
#    Requries PowerCLI 10 or higher, the PureStoragePowerShellSDK (v1), PureStorage.FlashArray.VMware, & SQLPS modules.      #
#                                                                                                                            #
# Drives are taken offline by their device unit number rather than serial number in the Target VM                            #
#                                                                                                                            #
# Updates - 7 JULY 2021                                                                                                      #
#    - Added Variable Section                                                                                                #
#    - Loop through volumes, devices, databases                                                                              #
#    - Prompt for FlashArray Credentials if Session isn't already established                                                #
#    - PowerShell Core Support                                                                                               #
##############################################################################################################################

# Variables Section
$TargetServer  = 'JSQLTEST.FSA.LAB'                        # Configure the target SQL Server 
$EndPoint      = 'sn1-m70-f06-33.puretec.purestorage.com'  # FQDN or IP of the FlashArray that the SQL Server resides on
$PGroupName    = 'sql-pg-demo-m-m'                         # Protection Group Name 

# Name(s) of the SQL database(s) to take offline
$databases     = @('FT_Demo')                

# Ensure that the array position of the targetvolume, targetdevice, & sourcedevice match
# Name(s) of the Target SQL VM vVols that are going to be overwritten         
  $targetvolumes = @('JSQLTEST-vg/JSQLTEST-Drive-D','JSQLTEST-vg/JSQLTEST-Drive-E','JSQLTEST-vg/JSQLTEST-Drive-F')
# Target Device ID(s)
  $targetdevices = @(1,2,3)
# Corresponding Source SQL VM vVols that are going to be overwritten
  $sourcevolumes = @('JSQLPROD-vg/JSQLPROD-Drive-D','JSQLPROD-vg/JSQLPROD-Drive-E','JSQLPROD-vg/JSQLPROD-Drive-F')

###########################################################
# It should not be necessary to make any changes below    #
###########################################################

# Create a session to the target server
$TargetServerSession = New-PSSession -ComputerName $TargetServer

# Import the SQLPS module so SQL commands are available
Import-Module SQLPS -PSSession $TargetServerSession -DisableNameChecking

# Offline the database(s)
Write-Warning "Offlining the target database(s)..."
Foreach ($database in $databases) {
    Write-Host "Offlining $database"
    # Offline the database
    Write-Warning "Offlining the target database..."
    $Query = "ALTER DATABASE " + $($database) + " SET OFFLINE WITH ROLLBACK IMMEDIATE"
    Invoke-Command -Session $TargetServerSession -ScriptBlock {Param($querytask) Invoke-Sqlcmd -ServerInstance . -Database master -Query $querytask} -ArgumentList ($Query)
}

# Offline the volumes that have SQL data
Write-Warning "Offlining the target volume(s)..." 
Foreach ($targetdevice in $targetdevices) {
    Write-Host "Offlining Disk $($targetdevice)"
    Invoke-Command -Session $TargetServerSession -ScriptBlock {Param($currentdisk) Get-Disk | ? { $_.Number -eq $($currentdisk) } | Set-Disk -IsOffline $True } -ArgumentList ($targetdevice)
}


If ($DefaultFlashArray) {
    $FlashArray = $DefaultFlashArray 
} else {
    # Connect to the FlashArray's REST API, get a session going
    Write-Warning "Establishing a session against the Pure Storage FlashArray..." 
    $FlashArray = New-PfaArray -EndPoint $EndPoint -Credentials (Get-Credential) -IgnoreCertificateError
}

# Only initiate a new snapshot if the Protection Group is local (not remote)
If ($PGroupName -like "*:*") {
    Write-Warning "Creating a new snapshot of the Protection Group..."
    # New-PfaProtectionGroupSnapshot -Array $FlashArray -Protectiongroupname $PGroupName -ApplyRetention
    # Updated to work with PowerShell Core and New-PfaRestOperation
    $MostRecentSnapshot = New-PfaRestOperation -ResourceType pgroup -RestOperationType POST -Flasharray $DefaultFlashArray -SkipCertificateCheck -jsonBody "{`"snap`":true,`"source`":[`"$($PGroupName)`"]}"
} else {
    # Get the most recent snapshot
    Write-Warning "Obtaining the most recent snapshot for the protection group..."
    #$MostRecentSnapshot = Get-PfaProtectionGroupSnapshots -Array $FlashArray -Name $PGroupName | Sort-Object created -Descending | Select -Property name -First 1
    # Updated to work with PowerShell Core and New-PfaRestOperation
    $LatestSnapshot = New-PfaRestOperation -ResourceType volume -RestOperationType GET -Flasharray $DefaultFlashArray -SkipCertificateCheck -QueryFilter "?snap=true&pgrouplist=$($PGroupName)" | Where-Object {$_.source -in $sourcevolumes} | Sort-Object Created -Descending | Select-Object -First 1

    $MostRecentSnapshot = [PSCustomObject]@{
        Source = $LatestSnapshot.name.split(".")[0] 
        Created = $LatestSnapshot.created
        Name = $LatestSnapshot.name.split(".")[0] + "." + $LatestSnapshot.name.split(".")[1]
    }

}

# Perform the target volume(s) overwrite
Write-Warning "Overwriting the target database volumes with a copies of the volumes in the most recent snapshot..." 
Foreach ($targetvolume in $targetvolumes) {
    $sourcevolume = $MostRecentSnapshot.name + "." + $sourcevolumes[$targetvolumes.IndexOf($targetvolume)]
    #New-PfaVolume -Array $FlashArray -VolumeName $targetvolume -Source $sourcevolume -Overwrite
    New-PfaRestOperation -ResourceType volume/$($targetvolume) -RestOperationType POST -Flasharray $DefaultFlashArray -SkipCertificateCheck -jsonBody "{`"overwrite`":true,`"source`":`"$($sourcevolume)`"}"             
}

# Online the volume(s)
Write-Warning "Onlining the target volumes..." 
Foreach ($targetdevice in $targetdevices) {
    Write-Host "Onlining Disk $($targetdevice)"
    Invoke-Command -Session $TargetServerSession -ScriptBlock {Param($currentdisk) Get-Disk | ? { $_.Number -eq $($currentdisk) } | Set-Disk -IsOffline $False } -ArgumentList ($targetdevice)
}

# Online the database
Foreach ($database in $databases) {
    Write-Host "Onlining $database"
    $Query = "ALTER DATABASE " + $($database) + " SET ONLINE WITH ROLLBACK IMMEDIATE"
    Invoke-Command -Session $TargetServerSession -ScriptBlock {Param($querytask) Invoke-Sqlcmd -ServerInstance . -Database master -Query $querytask} -ArgumentList ($Query)
}

# Give an update
Write-Warning "Target database downtime ended." 

# Clean up
Remove-PSSession $TargetServerSession

Write-Warning "All done."
