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
#    Requries PowerCLI 10 or higher, & SQLPS modules.                                                                        #
#                                                                                                                            #
# Drives are taken offline by their device unit number rather than serial number in the Target VM                            #
#                                                                                                                            #
# Updates - 7 JULY 2021                                                                                                      #
#    - Added Variable Section                                                                                                #
#    - Loop through volumes, devices, databases                                                                              #
#    - Prompt for FlashArray Credentials if Session isn't already established                                                #
#    - PowerShell Core Support                                                                                               #
##############################################################################################################################

# REST Functions Section
. $PSScriptRoot\Pfa2REST.ps1

# Variables Section
$TargetServer = 'JSQLTEST.FSA.LAB'                        # Configure the target SQL Server 
$EndPoint     = 'sn1-m70-f06-33.puretec.purestorage.com'  # FQDN or IP of the FlashArray that the SQL Server resides on
$PGroupName   = 'sql-pg-demo-m-m'                         # Protection Group Name 
$userName     = 'pureuser'                                

# Name(s) of the SQL database(s) to take offline
$databases = @('FT_Demo')                

# Ensure that the array position of the targetvolume, targetdevice, & sourcedevice match
# Name(s) of the Target SQL VM vVols that are going to be overwritten         
$targetvolumes = @('JSQLTEST-vg/JSQLTEST-Drive-D', 'JSQLTEST-vg/JSQLTEST-Drive-E', 'JSQLTEST-vg/JSQLTEST-Drive-F')
# Target Device ID(s)
$targetdevices = @(1, 2, 3)
# Corresponding Source SQL VM vVols that are going to be overwritten
$sourcevolumes = @('JSQLPROD-vg/JSQLPROD-Drive-D', 'JSQLPROD-vg/JSQLPROD-Drive-E', 'JSQLPROD-vg/JSQLPROD-Drive-F')

###########################################################
# It should not be necessary to make any changes below    #
###########################################################

# Create a session to the target server
$TargetServerSession = New-PSSession -ComputerName $TargetServer

try {
    # Offline the database
    Foreach ($database in $databases) {
        Write-Host "Offlining $database"
        Invoke-Command -Session $TargetServerSession -ScriptBlock {
            param ([string]$Query)
            Invoke-Sqlcmd -ServerInstance '.' -Query $Query
        } -ArgumentList "ALTER DATABASE $database SET OFFLINE WITH ROLLBACK IMMEDIATE"
    }

    # Offline the volumes that have SQL data
    Write-Host 'Offlining the target volume(s)...' 
    Invoke-Command -Session $TargetServerSession -ScriptBlock {
        param ($TargetDevices)
        Get-Disk | ? Number -in $TargetDevices | Set-Disk -IsOffline $True
    } -ArgumentList $targetdevices

    # Connect to the FlashArray's REST API, get a session going
    Write-Host 'Establishing a session against the Pure Storage FlashArray...' 
    if ($PSEdition -ne 'core') {
        Set-Pfa2SkipCertificateCheck
    }

    $session = New-Pfa2Session -endpoint $endpoint -credential (Get-Credential -UserName $userName -Message 'Enter your credentials.') -skipCertificateCheck -version '2.11'

    try {
        # Only initiate a new snapshot if the Protection Group is local (not remote)
        If ($PGroupName -notlike '*:*') {
            Write-Host 'Creating a new snapshot of the Protection Group...'
            Invoke-Pfa2Operation -session $session -query "protection-group-snapshots?source_names=$PGroupName&apply_retention=true" | Out-Null
        }

        # Get the most recent snapshot
        Write-Host 'Obtaining the most recent snapshot for the protection group...'
        $res = Invoke-Pfa2Operation -session $session -query "protection-group-snapshots?source_names=$PGroupName&sort=created-&limit=1" -method 'Get'
        $MostRecentSnapshot = $res.items[0]

        # Perform the target volume(s) overwrite
        Write-Host 'Overwriting the target database volumes with a copies of the volumes in the most recent snapshot...' 
        Foreach ($targetvolume in $targetvolumes) {
            $sourcevolume = $MostRecentSnapshot.name + '.' + $sourcevolumes[$targetvolumes.IndexOf($targetvolume)]
            $src = @{'source' = @{'name' = $sourcevolume } } | ConvertTo-Json
            Invoke-Pfa2Operation -session $session -query "volumes?names=$targetvolume&overwrite=true" -rest @{'Body' = $src } | Out-Null
        }
    }
    finally {
        Remove-Pfa2Session -session $session
    }

    # Online the volume(s)
    Write-Host 'Onlining the target volumes...' 
    Invoke-Command -Session $TargetServerSession -ScriptBlock {
        param ($TargetDevices)
        Get-Disk | ? Number -in $TargetDevices | Set-Disk -IsOffline $False
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
