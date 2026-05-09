##############################################################################################################################
# ActiveDR Failover Testing for SQL Server Failover Cluster Instance
#
# Scenario:
#    This demo script runs through two scenarios:
#       1. Failover of a clustered SQL Server role to a node on the same storage array
#       2. Failover of a clustered SQL Server role to a node on a remote storage array
#
#    The remote array failover involves the following steps:
#       - Stop the clustered SQL Server role in the FCI
#       - Demote the source pod
#       - Promote the target pod
#       - Move the clustered role to a node on the target array
#       - Start the clustered SQL Server role
#
# Disclaimer:
#    This example script is provided AS-IS and meant to be a building block to be adapted to fit an individual
#    organization's infrastructure.
##############################################################################################################################



# Import PowerShell modules
Import-Module FailoverClusters
Import-Module PureStoragePowerShellSDK2



# Variables
$ClusterName        = "WindowsClusterName"
$ClusterRole        = "SQL Server (MSSQLSERVER)"        # Clustered SQL Server role name
$NodeSameArray      = "NodeOnSameArray"                 # Cluster node on the same storage array
$NodeRemoteArray    = "NodeOnRemoteArray"               # Cluster node on the remote storage array
$SourceFlashArrayIp = "flasharray1.example.com"         # Source FlashArray endpoint
$SourcePodName      = "PodNameOnSourceArray"            # Pod name on the source FlashArray
$TargetFlashArrayIp = "flasharray2.example.com"         # Target FlashArray endpoint
$TargetPodName      = "PodNameOnTargetArray"            # Pod name on the target FlashArray



# Set credentials
$PureCred = Get-Credential



####################################################################################################################
#
# Performing failover to node on same storage array
#
####################################################################################################################



# Confirm cluster
Get-Cluster $ClusterName



# Confirm cluster nodes
Get-Cluster $ClusterName | Get-ClusterNode



# Confirm clustered SQL Server service
Get-ClusterGroup -Cluster $ClusterName -Name $ClusterRole



# Test failing over clustered service to node on same storage array
Move-ClusterGroup -Cluster $ClusterName -Name $ClusterRole -Node $NodeSameArray



# Confirm clustered SQL Server service
Get-ClusterGroup -Cluster $ClusterName -Name $ClusterRole



####################################################################################################################
#
# Performing failover to node on remote storage array
#
####################################################################################################################



# Connect to the source FlashArray
$SourceFlashArray = Connect-Pfa2Array -EndPoint $SourceFlashArrayIp -Credential $PureCred -IgnoreCertificateError



# Confirm pod replication status
Get-Pfa2PodReplicaLink -Array $SourceFlashArray -LocalPodName $SourcePodName



# Confirm clustered SQL Server service
Get-ClusterGroup -Cluster $ClusterName -Name $ClusterRole



# Stop clustered service - taking volumes offline
Stop-ClusterGroup -Cluster $ClusterName -Name $ClusterRole



# Confirm clustered service offline
Get-ClusterGroup -Cluster $ClusterName -Name $ClusterRole



# Demote the source pod with quiesce
Update-Pfa2Pod -Array $SourceFlashArray -Name $SourcePodName -Quiesce $True -RequestedPromotionState "demoted"



# Confirm source pod status - PromotionStatus : demoted
Get-Pfa2Pod -Array $SourceFlashArray -Name $SourcePodName



# Connect to the target FlashArray
$TargetFlashArray = Connect-Pfa2Array -EndPoint $TargetFlashArrayIp -Credential $PureCred -IgnoreCertificateError



# Promote the target pod
Update-Pfa2Pod -Array $TargetFlashArray -Name $TargetPodName -RequestedPromotionState "promoted"



# Confirm pod promoted - PromotionStatus : promoted
Get-Pfa2Pod -Array $TargetFlashArray -Name $TargetPodName



# Move clustered role to node on the target array
Move-ClusterGroup -Cluster $ClusterName -Name $ClusterRole -Node $NodeRemoteArray



# Start the clustered role
Start-ClusterGroup -Cluster $ClusterName -Name $ClusterRole



# confirm role status
Get-ClusterGroup -Cluster $ClusterName -Name $ClusterRole