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
#    Requries PowerCLI 10 or higher, the PureStoragePowerShellSDK2 (v2), PureStorage.FlashArray.VMware, & SQLPS modules.      #
#                                                                                                                            #
# Drives are taken offline by their device unit number rather than serial number in the Target VM                            #
#                                                                                                                            #
# Updates - 13 NOV 2020                                                                                                      #
#    - Added Variable Section                                                                                                #
#    - Loop through volumes, devices, databases                                                                              #
#    - PowerShell Desktop is supported. PowerShell Core is not                                                               #
##############################################################################################################################

# Variables Section
$TargetServer = 'SQLDEMO'                            # Configure the target SQL Server 
$EndPoint     = 'targetpfa.demo.local'               # FQDN or IP of the FlashArray that the SQL Server resides on
$PureUser     = 'pureuser'                           # FlashArray username 
$PurePass     = 'password'                           # FlashArray password
$PGroupName   = 'sourcepfa:pgname'                   # Protection Group Name 

# Name(s) of the SQL database(s) to take offline
$databases = @('FT_Demo')                

# Ensure that the array position of the targetvolume, targetdevice, & sourcedevice match
# Name(s) of the Target SQL VM vVols that are going to be overwritten         
$targetvolumes = @('SQLDEMO-vg/SQLDEMO-Drive-D', 'SQLDEMO-vg/SQLDEMO-Drive-E', 'SQLDEMO-vg/SQLDEMO-Drive-F')
# Target Device ID(s)
$targetdevices = @(1, 2, 3)
# Corresponding Source SQL VM vVols that are going to be overwritten
$sourcevolumes = @('SQLPROD-VG/SQLPROD-Drive-D', 'SQLPROD-VG/SQLPROD-Drive-E', 'SQLPROD-VG/SQLPROD-Drive-F')

###########################################################
# It should not be necessary to make any changes below    #
###########################################################

# Ensure the Pure Storage PowerShell SDK (v2) is loaded
Import-Module PureStoragePowerShellSDK2

# Create a session to the target server
$TargetServerSession = New-PSSession -ComputerName $TargetServer #-Credential (Get-Credential)

try {
    # Offline the database(s)
    Write-Host 'Offlining the target database(s)...'
    foreach ($database in $databases) {
        # Offline the database
        Invoke-Command -Session $TargetServerSession -ScriptBlock {
            param([string]$Query)
            Invoke-Sqlcmd -ServerInstance '.' -Query $Query
        } -ArgumentList "ALTER DATABASE $database SET OFFLINE WITH ROLLBACK IMMEDIATE"
    }

    # Offline the volumes that have SQL data
    Write-Host 'Offlining the target volume(s)...'
    Invoke-Command -Session $TargetServerSession -ScriptBlock {
        param($TargetDevices)
        Get-Disk | ? Number -in $TargetDevices | Set-Disk -IsOffline $True
    } -ArgumentList $targetdevices

    # Connect to the FlashArray's REST API, get a session going
    # THIS IS A SAMPLE SCRIPT WE USE FOR DEMOS! _PLEASE_ do not save your password in cleartext here. 
    # Use NTFS secured, encrypted files or whatever else -- never cleartext!
    Write-Host 'Establishing a session against the Pure Storage FlashArray...' 
    $FlashArray = Connect-Pfa2Array -Endpoint $EndPoint -Username $PureUser -Password (ConvertTo-SecureString -AsPlainText $PurePass -Force) -IgnoreCertificateError

    try {
        # Only initiate a new snapshot if the Protection Group is local (not remote)
        If ($PGroupName -notlike '*:*') {
            Write-Host 'Creating a new snapshot of the Protection Group...'
            New-Pfa2ProtectionGroupSnapshot -Array $FlashArray -SourceNames $PGroupName -ApplyRetention $true
        }

        # Get the most recent snapshot
        Write-Host 'Obtaining the most recent snapshot for the protection group...'
        $MostRecentSnapshot = Get-Pfa2ProtectionGroupSnapshot -Array $FlashArray -SourceNames $PGroupName -Sort 'created-' -Limit 1

        # Perform the target volume(s) overwrite
        Write-Host 'Overwriting the target database volumes with a copies of the volumes in the most recent snapshot...' 
        Foreach ($targetvolume in $targetvolumes) {
            $sourcevolume = $MostRecentSnapshot.name + '.' + $sourcevolumes[$targetvolumes.IndexOf($targetvolume)]
            New-Pfa2Volume -Array $FlashArray -Name $targetvolume -SourceName $sourcevolume -Overwrite $true
        }
    }
    finally {
        Disconnect-Pfa2Array -Array $FlashArray
    }

    # Online the volume(s)
    Write-Host 'Onlining the target volumes...' 
    Invoke-Command -Session $TargetServerSession -ScriptBlock {
        param ($targetdevices)
        Get-Disk | ? Number -in $targetdevices | Set-Disk -IsOffline $False
    } -ArgumentList $targetdevices

    # Online the database
    Foreach ($database in $databases) {
        Write-Host "Onlining $database"
        Invoke-Command -Session $TargetServerSession -ScriptBlock {
            param ([string]$Query)
            Invoke-Sqlcmd -ServerInstance '.' -Query $Query
        } -ArgumentList "ALTER DATABASE $database SET ONLINE WITH ROLLBACK IMMEDIATE"
    }

    # Give an update
    Write-Host 'Target database downtime ended.' 
}
finally {
    # Clean up
    Remove-PSSession $TargetServerSession
}

Write-Host 'All done.'
