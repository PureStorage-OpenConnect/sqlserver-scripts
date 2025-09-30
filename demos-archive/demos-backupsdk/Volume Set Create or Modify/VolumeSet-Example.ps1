##############################################################################################################################
# VolumeSet Example - Create or Modify
#
# Scenario: 
#    This script will show examples in how to initially create a Volume Set, and what has to be changed if you need
#    Modify the number of volumes in the Volume Set.
# Prerequisities:
#    1. Install the PureStorage.FlashArray.Backup module
#    2. Have FlashArray administrator, Windows Server, and if a VMware VM, vCenter credentials.
# 
# Usage Notes:
#    These simple example show how to initially create and later modify a Volume Set that can be used 
#    for creating snapshots and mounting those snapshots.  
# 
# Disclaimer:
#    This example script is provided AS-IS and meant to be a building block to be adapted to fit an individual 
#    organization's infrastructure.
##############################################################################################################################



# Import powershell modules
Import-Module PureStorage.FlashArray.Backup



# Declare variables
$SourceSQLServer          = 'SqlServer1'                           # Name of source SQL Server
$SourceArrayName          = 'flasharray1.example.com'              # Source FlashArray FQDN
$ProtectionGroupName      = 'SqlServer1_Pg'                        # Protection Group name in the FlashArray
$VolumeSet                = 'volset1'                              # Name of the Volume Set
$SourcePath               = 's:\'                                  # Path of Volumes to Snapshot
$VolumeType               = 'vvol'                                 # Physical, vVol, or RDM
$vCenterAddress           = 'vcenter.example.com'                  # vCenter Server
$SourceVMName             = 'sqlvm4'                               # Source VM

# Set Credentials - this assumes the same credential for the target SQL Server and the FlashArray. If this is a VMware VM using pRDM or vVol, a vCenter credential is required.
$FlashArrayCredential = Get-Credential
$SQLServerCredential = Get-Credential
$vCenterCredential = Get-Credential

# Volume Sets can be manually created by specifying a set of volumes on a target Windows Server.
# New-PsbVolumeSet will connected to the declared ComputerAddress and match the drive letters and mount points
# to the corresponding volumes on the FlashArray. If VMware RDM/vVol additional parameters are required to
# assist in matching those supported disk types to Pure Storage Volumes.

# Example 1: Create a new volume set where the target computeraddress is a server that has a Host Record on 
# the FlashArray. This includes vHBA, in-guest iSCSI, and bare metal servers.

$VolumeType = 'Physical'
New-PsbVolumeSet -VolumeSetName $VolumeSet -ComputerAddress $SourceSQLServer -ComputerCredential $SQLServerCredential -FlashArrayAddress $SourceArrayName -FlashArrayCredential $FlashArrayCredential -Path $SourcePath -VolumeType $VolumeType

# Example 2: Create a new volume set where the target computeraddress is a VMware VM using physical RDMs.
# Note the query for the VMPID is optional, but if that is not passed and VM is renamed in vCenter,
# it will fail to find the VM if the -VMname parameter is not modified to the new VM name.
$VMPID = Get-PSBVMPersistentId -VCenterAddress $vCenterAddress -VCenterCredential $vCenterCredential -VMName $SourceVMName
$VolumeType = 'RDM'
New-PsbVolumeSet -VolumeSetName $VolumeSet -ComputerAddress $SourceSQLServer -ComputerCredential $SQLServerCredential -FlashArrayAddress $SourceArrayName -FlashArrayCredential $FlashArrayCredential -Path $SourcePath -VolumeType $VolumeType -VCenterAddress $vCenterCredential -VMName $SourceVMName -VMPersistentId $VMPID

# Example 3: Create a new volume set where the target computeraddress is a VMware VM using virtual volumes (vVol).
# Note the query for the VMPID is optional, but if that is not passed and VM is renamed in vCenter,
# it will fail to find the VM if the -VMname parameter is not modified to the new VM name.
$VMPID = Get-PSBVMPersistentId -VCenterAddress $vCenterAddress -VCenterCredential $vCenterCredential -VMName $SourceVMName
$VolumeType = 'vvol'
New-PsbVolumeSet -VolumeSetName $VolumeSet -ComputerAddress $SourceSQLServer -ComputerCredential $SQLServerCredential -FlashArrayAddress $SourceArrayName -FlashArrayCredential $FlashArrayCredential -Path $SourcePath -VolumeType $VolumeType -VCenterAddress $vCenterCredential -VMName $SourceVMName -VMPersistentId $VMPID

# Example 4: Building upon Example 1
# Modify a volume set by adding a disk in the path. In this example the Volume Set already exists, and only
# one disk, the 's:\' disk, is in the volume set. The Invoke-PsbSnapshotJob will see the drive letters
# and mount points in the path, and check that they are all marked as belonging to the Volume Set. If any of the
# declared volumes are not in the volume set, powershell will ask you to confirm overwriting the volume set on
# the FlashArray with the new set of disks. Simply changing the -Path parameter is not sufficient, as all
# volumes declared in the -path must be members of the declared -pgroupname or the invoke-psbsnapshotjob will fail
# with an error indicating that all of the volumes in the Volume Set are not members of the declared Protection Group.

$SourcePath               = 's:\,t:\'                                  # Path of Volumes to Snapshot
Invoke-PsbSnapshotJob -vcenteraddress $vcenteraddress -VcenterCredential $vcentercredential -vmname $sourceVMName -FlashArrayAddress $SourceArrayName -FlashArrayCredential $FlashArrayCredential -VolumeSetName $VolumeSet -VolumeType $VolumeType -ComputerAddress $SourceSQLServer -ComputerCredential $SQLServerCredential -Path $SourcePath -pgroupname $ProtectionGroupName 

# Example 5: Building upon Example 4
# Modify a volume set by removing a disk in the path. In this example the Volume Set already exists, and 
# two disks the 's:\,t:\' disks are members of the volume set. The Invoke-PsbSnapshotJob will see the drive letters
# and mount points in the path, and check that they are all marked as belonging to the Volume Set. If any volumes on
# the FlashArray are members of the Volume Set but not included in the -path parameter, powershell will ask you to
# confirm overwriting the volume set on the FlashArray with the new set of disks. This action will not remove
# volumes from the declared protection group.

$SourcePath               = 's:\'                                  # Path of Volumes to Snapshot
Invoke-PsbSnapshotJob -vcenteraddress $vcenteraddress -VcenterCredential $vcentercredential -vmname $sourceVMName -FlashArrayAddress $SourceArrayName -FlashArrayCredential $FlashArrayCredential -VolumeSetName $VolumeSet -VolumeType $VolumeType -ComputerAddress $SourceSQLServer -ComputerCredential $SQLServerCredential -Path $SourcePath -pgroupname $ProtectionGroupName 
