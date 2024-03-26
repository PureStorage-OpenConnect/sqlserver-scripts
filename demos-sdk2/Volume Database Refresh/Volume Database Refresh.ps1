##############################################################################################################################
# Volume Database Refresh
#
# Scenario: 
#   Script will refresh a database on the target server from a source database on a separate server
#
# Prerequisities:
#   sqlserver and PureStoragePowerShellSDK modules installed on client machine
#   Two SQL instances with a database that has its data and log files on one volume on both servers
#   Example here assumes vVols but RDMs will work as well
#
# Usage Notes:
#   Each section of the script is meant to be run one after the other. The script is not meant to be executed all at once.
# 
# Disclaimer:
# This example script is provided AS-IS and meant to be a building block to be adapted to fit an individual 
# organization's infrastructure.
# 
# THIS IS A SAMPLE SCRIPT WE USE FOR DEMOS! _PLEASE_ do not save your passwords in cleartext here. 
# Use NTFS secured, encrypted files or whatever else -- never cleartext!
#
##############################################################################################################################



# Import powershell modules
Import-Module SqlServer
Import-Module PureStoragePowerShellSDK2



# Declare variables
$Target                  = 'SqlServer1'                                     # Name of target VM
$ArrayName               = 'flasharray1.example.com'                        # FlashArray FQDN
$DatabaseName            = 'AdventureWorks'                                 # Database to be refreshed
$TargetDiskSerialNumber  = '6000c02022cb876dcd321example01b'                # Target Disk Serial Number
$SourceVolumeName        = 'vvol-SERVERNAME-a-1-3d9acfdd-vg/Data-example'   # Source volume name on FlashArray
$TargetVolumeName        = 'vvol-SERVERNAME-a-1-3d9acfdd-vg/Data-example'   # Target volume name on FlashArray



# Create a Powershell session against the target VM
$TargetSession = New-PSSession -ComputerName $Target



# Set credential to connect to FlashArray
$Credential = Get-Credential



# Offline the database
Invoke-Sqlcmd -ServerInstance $Target -Database master -Query "ALTER DATABASE [$DatabaseName] SET OFFLINE WITH ROLLBACK IMMEDIATE" 



# Offline the volume
Invoke-Command -Session $TargetSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDiskSerialNumber } | Set-Disk -IsOffline $True }



# Connect to the FlashArray's REST API
$FlashArray = Connect-Pfa2Array –EndPoint $ArrayName -Credential $Credential -IgnoreCertificateError



# Perform the volume overwrite (no intermediate snapshot needed!)
New-Pfa2Volume -Array $FlashArray -Name $TargetVolumeName -SourceName $SourceVolumeName  -Overwrite $true 



# Online the volume
Invoke-Command -Session $TargetSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq $using:TargetDiskSerialNumber } | Set-Disk -IsOffline $False }



# Online the database
Invoke-Sqlcmd -ServerInstance $Target -Database master -Query "ALTER DATABASE [$DatabaseName] SET ONLINE WITH ROLLBACK IMMEDIATE" 



# Clean up
Remove-PSSession $TargetSession
