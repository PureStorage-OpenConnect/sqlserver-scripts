##############################################################################################################################
# Protection Group Database Refresh - vVol
#
# Scenario: 
#    This script will refresh a database on the target server from a source database on a different server.  This script
#    utilizes a FlashArray Protection Group, to snapshot and clone two volumes simultaneously.  
#
# Prerequisities:
#    1. Two SQL Server instances with a single database, whose data file(s) are contained within 1 volume and log file(s)
#       are contained within a 2nd volume.  
#    2. A Protection Group defined with the two volumes (data and log) as members
# 
# Usage Notes:
#    This simple example assumes there is only one database residing on two different volumes (data & log).  If multiple 
#    databases are present, additional code must be added to offline/online all databases present on the affected volumes 
#    in the Protection Group.  Also note that the Protection Group use may include other volumes without negative impact.  
#    Any extraneous volumes will simply not be utilized during the cloning step.  
# 
# Disclaimer:
#    This example script is provided AS-IS and meant to be a building block to be adapted to fit an individual 
#    organization's infrastructure.
##############################################################################################################################



# Import powershell modules
Import-Module PureStorage.FlashArray.Backup



# Declare variables
$SourceSQLServer          = 'SqlServer1'                           # Name of source SQL Server
$TargetSQLServer          = 'SqlServer2'                           # Name of target SQL Server
$SourceArrayName          = 'flasharray1.example.com'              # Source FlashArray FQDN
$TargetArrayName          = 'flasharray2.example.com'              # Target FlashArray FQDN
$DatabaseName             = 'ExampleDb1'                           # Name of the database being snapshotted & cloned
$ProtectionGroupName      = 'SqlServer1_Pg'                        # Protection Group name in the FlashArray
$VolumeSet                = 'volset1'                              # Name of the Volume Set
$SourcePath               = 's:\'                                  # Path of Volumes to Snapshot
$TargetPath               = 'n:\'                                  # Path of Volumes to Mount
$VolumeType               = 'vvol'                                 # Physical, vVol, or RDM
$vCenterAddress           = 'vcenter.example.com'                  # vCenter Server
$SourceVMName             = 'sqlvm4'                               # Source VM
$TargetVMName             = 'sqlvm5'                               # Target VM

# Set Credentials - this assumes the same credential for the target SQL Server and the FlashArray. If this is a VMware VM using RDM or vVol, a vCenter credential is required.
$FlashArrayCredential = Get-Credential
$SQLServerCredential = Get-Credential
$vCenterCredential = Get-Credential

# Offline the target database
$Query = "ALTER DATABASE [$DatabaseName] SET OFFLINE WITH ROLLBACK IMMEDIATE"
Invoke-Sqlcmd -ServerInstance $TargetSQLServer -Database master -Query $Query



# Create a new snapshot of the Protection Group
$Snapshot = Invoke-PsbSnapshotJob -vcenteraddress $vcenteraddress -VcenterCredential $vcentercredential -vmname $sourceVMName -FlashArrayAddress $SourceArrayName -FlashArrayCredential $FlashArrayCredential -VolumeSetName $VolumeSet -VolumeType $VolumeType -ComputerAddress $SourceSQLServer -ComputerCredential $SQLServerCredential -Path $SourcePath -pgroupname $ProtectionGroupName -ReplicateNow



# Find the existing mounted snapshot so it can be dismounted
$FindMount = Get-PsbSnapshotSetMountHistory -FlashArrayAddress $TargetArrayName -FlashArrayCredential $FlashArrayCredential | Where-Object {($_.Computer -contains $TargetSQLServer -and $_.HistoryId -match $VolumeSet)}



# Dismount the snapshot
Dismount-PsbSnapshotSet -flasharrayaddress $TargetArrayName -flasharraycredential $FlashArrayCredential -mountid $FindMount[0].mountid -computeraddress $TargetSQLServer -computercredential $SQLServerCredential -vcenteraddress $vcenteraddress -vcentercredential $vcentercredential



# Mount the newer snapshot
Mount-PsbSnapshotSet -HistoryId $Snapshot.HistoryId -FlashArrayAddress $TargetArrayName -flasharraycredential $FlashArrayCredential -computeraddress $TargetSQLServer -computercredential $SQLServerCredential -Path $TargetPath -VMName $targetvmname -VCenterAddress $vCenterAddress -VCenterCredential $vCenterCredential



# Online the database
$Query = "ALTER DATABASE [$DatabaseName] SET ONLINE WITH ROLLBACK IMMEDIATE"
Invoke-Sqlcmd -ServerInstance $TargetSQLServer -Database master -Query $Query