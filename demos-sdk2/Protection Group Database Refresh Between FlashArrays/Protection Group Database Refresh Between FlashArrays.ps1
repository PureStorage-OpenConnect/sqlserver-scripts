##############################################################################################################################
# Protection Group Database Refresh Between FlashArrays
#
# Scenario: 
#    This script will refresh a database on the target server, that is backed by a different FlashArray.  The source 
#    for the snapshot will be a replicated Protection Group snapshot from the original/source FlashArray.
#
# Prerequisities:
#    1. Two SQL Server instances with a single database, whose data file(s) are contained within 1 volume and log file(s)
#       are contained within a 2nd volume.  
#    2. A Protection Group defined with the two volumes (data and log) as members.
#    3. This script assumes Protection Group snapshots & replication are pre-scheduled and already occurring. 
# 
# Usage Notes:
#    This simple example assumes there is only one database residing on two different volumes (data & log).  If multiple 
#    databases are present, additional code must be added to offline/online all databases present on the affected volumes 
#    in the Protection Group.  Also note that the Protection Group use may include other volumes without negative impact.  
#    Any extraneous volumes will simply not be utilized during the cloning step.  Finally, remember that snapshot replication
#    between FlashArrays is asynchronous.  Thus it is possible at runtime, that the most recent snapshot is still in the
#    middle of being replicated.  There is a step to validate the state of the snapshot, before the cloning step.
# 
# Disclaimer:
#    This example script is provided AS-IS and meant to be a building block to be adapted to fit an individual 
#    organization's infrastructure.
##############################################################################################################################



# Import powershell modules
Import-Module SqlServer
Import-Module PureStoragePowerShellSDK2



# Declare variables
$TargetSQLServer          = 'SqlServer2'                           # Name of target SQL Server
$SourceArrayName          = 'flasharray1.example.com'              # Source FlashArray containing source Protection Group
$TargetArrayName          = 'flasharray2.example.com'              # Target FlashArray of Snapshot Replication
$DatabaseName             = 'ExampleDb'                            # Name of the database being snapshotted & cloned
$ProtectionGroupName      = 'SqlServer1_Pg'                        # Protection Group name in the FlashArray
$TargetDiskSerialNumber1  = '6000c02022cb876dcd321example01a'      # Target Disk Serial Number - ex: Data volume
$TargetDiskSerialNumber2  = '6000c02022cb876dcd321example02b'      # Target Disk Serial Number - ex: Log volume
$SourceVolumeName1        = 'SourceSqlVolume1'                     # Source volume name 1 on FlashArray - ex: Data volume
$SourceVolumeName2        = 'SourceSqlVolume2'                     # Source volume name 2 on FlashArray - ex: Log volume
$TargetVolumeName1        = 'TargetSqlVolume1'                     # Target volume name 1 on FlashArray - ex: Data volume
$TargetVolumeName2        = 'TargetSqlVolume2'                     # Target volume name 2 on FlashArray - ex: Log volume



# Set Credentials - this assumes the same credential for the target SQL Server and the FlashArray
$Credential = Get-Credential



# Connect to the source FlashArray's REST API
$SourceFlashArray = Connect-Pfa2Array –EndPoint $TargetArrayName -Credential $Credential -IgnoreCertificateError



# Take a snapshot of the Protection Group and replicate it to the target array
$Snapshot = New-Pfa2ProtectionGroupSnapshot -Array $FlashArray -SourceName $ProtectionGroupName -ForReplication $true -ReplicateNow $true



# Create a Powershell session against the target SQL Server
$TargetSession = New-PSSession -ComputerName $TargetSQLServer -Credential $Credential



# Offline the target database
$Query = "ALTER DATABASE [$DatabaseName] SET OFFLINE WITH ROLLBACK IMMEDIATE"
Invoke-Sqlcmd -ServerInstance $TargetSQLServer -Database master -Query $Query



# Offline the target volumes
Invoke-Command -Session $TargetSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDiskSerialNumber1 } | Set-Disk -IsOffline $True }
Invoke-Command -Session $TargetSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDiskSerialNumber2 } | Set-Disk -IsOffline $True }



# Connect to the target FlashArray's REST API
$TargetFlashArray = Connect-Pfa2Array –EndPoint $TargetArrayName -Credential $Credential -IgnoreCertificateError



# Get the most recent snapshot that is replicated to this array
$Snapshot = Get-Pfa2ProtectionGroupSnapshot -Array $TargetFlashArray -SourceName $TargetArrayName + ':' + $ProtectionGroupName | Sort-Object created -Descending | Select-Object -Property name -First 1



# Confirm that the snapshot has been fully replicated
# If the snapshot's completed property is null, then it has not been fully replicated
Get-Pfa2ProtectionGroupSnapshotTransfer -Array $TargetFlashArray -Name $Snapshot.name



### Diagnostic 
# Validate that the correct volume(s) will be used from the protection group snapshot. 
# Note the final naming scheme of a replicated protection group volume snapshot is
# [source array]:[protection group name].[volume name]
# $Snapshot
# $Snapshot.Name + "." + $SourceVolumeName1
# $Snapshot.Name + "." + $SourceVolumeName2



# Perform the target volume overwrite
New-Pfa2Volume -Array $TargetFlashArray -Name $TargetVolumeName1 -SourceName ($Snapshot.Name + "." + $SourceVolumeName1) -Overwrite $true 
New-Pfa2Volume -Array $TargetFlashArray -Name $TargetVolumeName2 -SourceName ($Snapshot.Name + "." + $SourceVolumeName2) -Overwrite $true 



# Online the newly cloned volumes
Invoke-Command -Session $TargetSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDiskSerialNumber1 } | Set-Disk -IsOffline $False }
Invoke-Command -Session $TargetSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:TargetDiskSerialNumber2 } | Set-Disk -IsOffline $False }



# Online the database
$Query = "ALTER DATABASE [$DatabaseName] SET ONLINE WITH ROLLBACK IMMEDIATE"
Invoke-Sqlcmd -ServerInstance $TargetSQLServer -Database master -Query $Query



# Clean up
Remove-PSSession $TargetSession