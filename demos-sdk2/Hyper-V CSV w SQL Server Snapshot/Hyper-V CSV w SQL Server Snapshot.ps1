##############################################################################################################################
# Hyper-V Cluster Shared Volume (CSV) with SQL Server Snapshot Example
#
# Scenario: 
#    This script will clone a Hyper-V Cluster Shared Volume (CSV), using a crash consistent snapshot, and present it back 
#    to the originating Hyper-V cluster as a second CSV "copy."  
#
#    This example scenario is useful if you have isolated a VLDB SQL Server database exclusively onto this CSV
#
#    See https://github.com/PureStorage-OpenConnect/sqlserver-scripts/tree/master/demos-sdk2/Hyper-V%20CSV%20Snapshot
#    for more details
#
#
# Prerequisities:
#    1. An additional Windows server (referred to as a staging server).   This staging server does not have to be a 
#       Hyper-V host.
#    2. A pre-created volume of equal size to the source CSV, pre-attached to the staging server.
#    3. The 'Failover Cluster Module for Windows PowerShell' Feature in Windows is required on the Hyper-V host.
#       Add-WindowsFeature RSAT-Clustering-PowerShell
#
# 
# Usage Notes:
#
#    The staging server is needed because each CSV has a unique signature.  If the CSV is presented back to the Hyper-V
#    host unaltered, a signature collision will be detected and the new CSV will not be able to be used by Windows. 
#    Hyper-V is unable to resignature in this state either.  Instead, the CSV must be presented to another machine (aka
#    the staging server), resignatured there, then can be re-snapshotted and cloned back to the originating Hyper-V
#    host.
#
#    This script may be adjusted to clone and present the CSV snapshot to a different Hyper-V host.  If this is done, then
#    the staging server and resignature step is not required, since the new target Hyper-V host will not have two of the
#    same CSV causing a signature conflict.
# 
# 
# Disclaimer:
#    This example script is provided AS-IS and meant to be a building block to be adapted to fit an individual 
#    organization's infrastructure.
##############################################################################################################################
Import-Module PureStoragePowerShellSDK2



# Variables
$FlashArrayEndPoint          = 'flasharray1.example.com'   
$SourceVMCluster             = 'hyperv-cluster-01.fsa.lab'
$SourceVMHost                = 'hyperv-host-01.example.com'                 
$SourceVM                    = 'hyperv-vm-source'										# No FQDN
$SourceVolumeName            = 'hyperv-vm-source-csv-01'      							# Name of the volume in FlashArray
$StagingServer               = 'windows-staging-server'
$StagingVolumeName           = 'temporary-volume-for-csv-resignature'
$StagingDiskSerialNumber     = '6000c2945ce069b03b9750d2afe72828'
$TargetVMHost                = 'hyperv-host-02.example.com'								# No FQDN
$TargetVM                    = 'hyperv-vm-target'										# No FQDN
$TargetVolumeName            = 'hyperv-vm-target-csv-01-cloned'
$TargetClusterDiskNumber     = 'Cluster Disk 3'
$DatabaseName                = 'MyDatabaseName'
$ClusteredStorageFolder      = "C:\ClusterStorage\volume4\hv-sqldata-01\data\*.*"		# Target Host Folder containing cloned VHDX/AVHDX files 



# Establish credential to use for all connections
$Credential = Get-Credential -Message 'Enter your Pure credentials'



# Connect to the FlashArray
$FlashArray = Connect-Pfa2Array -Endpoint $FlashArrayEndPoint -Credential ($Credential) -IgnoreCertificateError



# Determine which Hyper-V node each role currently resides on
$HyperVClusterSession = New-PSSession -ComputerName $SourceVMCluster -Credential $Credential

$SourceClusterGroup = Invoke-Command -Session $HyperVClusterSession -ScriptBlock { Get-ClusterGroup -Name $Using:SourceVM }
$TargetClusterGroup = Invoke-Command -Session $HyperVClusterSession -ScriptBlock { Get-ClusterGroup -Name $Using:TargetVM }

$SourceVMHost = $SourceClusterGroup.OwnerNode
$TargetVMHost = $TargetClusterGroup.OwnerNode

# Verify
$SourceVM
$SourceVMHost 

$TargetVM
$TargetVMHost



# Prepare the staging CSV for overlay
# Connect to staging VM
$StagingServerSession = New-PSSession -ComputerName $StagingServer -Credential $Credential



# Offline the volume 
# NOTE: use Get-Disk prior to get the correct Serial Number
Invoke-Command -Session $StagingServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:StagingDiskSerialNumber } | Set-Disk -IsOffline $True }

# Verify
Invoke-Command -Session $StagingServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $using:StagingDiskSerialNumber }}



# Snapshot the source CSV
# This example is for an on-demand snapshot. Can adjust code to also use a prior snapshot; ex. regularly scheduled
# snapshots or an asynchronously replicated snapshot from another FlashArray

# Clone the source CSV to the staging CSV
New-Pfa2Volume -Array $FlashArray -Name $StagingVolumeName -SourceName $SourceVolumeName -Overwrite $true



# Now must resignature the CSV on the staging VM
# Build DISKPART script commands for resignature
$StagingDisk = Invoke-Command -Session $StagingServerSession -ScriptBlock { Get-Disk | Where-Object { $_.SerialNumber -eq $Using:StagingDiskSerialNumber }}
$DiskNumber = $StagingDisk.Number
$NewUniqueID = [GUID]::NewGuid()
$Commands = "`"SELECT DISK $DiskNumber`"",
        "`"UNIQUEID DISK ID=$NewUniqueID`""
$ScriptBlock = [string]::Join(",",$Commands)
$DiskpartScriptBlock = $ExecutionContext.InvokeCommand.NewScriptBlock("$ScriptBlock | DISKPART")

# Verify DISKPART command
$DiskpartScriptBlock

# Issue resignature command
Invoke-Command -Session $StagingServerSession -ScriptBlock $DiskpartScriptBlock



# Prepare target VM
$TargetVMSession = New-PSSession -ComputerName $TargetVM -Credential $Credential

# Offline the database
$Query = "ALTER DATABASE $DatabaseName SET OFFLINE WITH ROLLBACK IMMEDIATE"
Invoke-Command -Session $TargetVMSession -ScriptBlock {Param($querytask) Invoke-Sqlcmd -ServerInstance . -Database master -Query $querytask} -ArgumentList ($Query)

# Offline the volume
# Because this is a Hyper-V VM, volume serial numbers are not populated by Hyper-V into a virtual machine
# Therefore must use a different method identify the proper volume to offline

# Confirm which drive you want
Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | Format-Table }



# Specify the drive number
$DiskNumber = 1
Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk -Number $using:DiskNumber | Get-Disk | Set-Disk -IsOffline $True } 

# Verify offline
Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | Format-Table }



# Prepare target VM Host
$TargetVMHostSession = New-PSSession -ComputerName $TargetVMHost -Credential $Credential

# Remove SQL Server cluster resource dependency on database volume
# Only use this if you are using Clustered Disks (NOT Clustered Shared Volumes)
# Invoke-Command -Session $TargetVMHostSession -ScriptBlock { Get-ClusterResource 'SQL Server' | Remove-ClusterResourceDependency $TargetVolumeName }

# Stop the disk cluster resource
# NOTE: need to know which Cluster Disk Number first
# This will put the target Hyper-V VM into a Saved state
Invoke-Command -Session $TargetVMHostSession -ScriptBlock { Stop-ClusterResource $Using:TargetClusterDiskNumber }

# Verify
Invoke-Command -Session $TargetVMHostSession -ScriptBlock { Get-ClusterSharedVolume $Using:TargetClusterDiskNumber }



# Clone the staging CSV to the target CSV
New-Pfa2Volume -Array $FlashArray -Name $TargetVolumeName -SourceName $StagingVolumeName -Overwrite $true



# Start the disk cluster resource
Invoke-Command -Session $TargetVMHostSession -ScriptBlock { Start-ClusterResource $Using:TargetClusterDiskNumber }

# Verify
Invoke-Command -Session $TargetVMHostSession -ScriptBlock { Get-ClusterSharedVolume $Using:TargetClusterDiskNumber }



# Must now update permissions in Windows to grant the new VM access to the VHDX files

Invoke-Command -Session $TargetVMHostSession -ScriptBlock { 
    $VMID = "NT VIRTUAL MACHINE\"
    Get-VM -name $Using:TargetVM | Select-Object -ExpandProperty VMID 

    $fileAclList = Get-Acl $Using:ClusteredStorageFolder
    Foreach ($acl in $fileAclList) {
        # Add a new rule to grant full control to a user
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($VMID, "FullControl", "Allow")
        $acl.AddAccessRule($rule)
        Set-Acl -Path $acl.PSPath -AclObject $acl 
    }
}



# Online the volume

# Confirm which drive you want
Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | Format-Table }



# Specify the drive number
$DiskNumber = 1
Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk -Number $using:DiskNumber | Get-Disk | Set-Disk -IsOffline $False } 

# Verify
Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | Format-Table }



# Online the database
$Query = "ALTER DATABASE $DatabaseName SET ONLINE"
Invoke-Command -Session $TargetVMSession -ScriptBlock {Param($querytask) Invoke-Sqlcmd -ServerInstance . -Database master -Query $querytask} -ArgumentList ($Query)

# Verify
$Query = "SELECT @@SERVERNAME, name, state_desc, GETDATE() FROM sys.databases WHERE database_id = DB_ID('$DatabaseName')"
Invoke-Command -Session $TargetVMSession -ScriptBlock {Param($querytask) Invoke-Sqlcmd -ServerInstance . -Database master -Query $querytask} -ArgumentList ($Query)

