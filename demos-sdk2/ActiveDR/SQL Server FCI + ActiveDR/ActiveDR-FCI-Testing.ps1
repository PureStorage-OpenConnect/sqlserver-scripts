####################################################################################################################
####################################################################################################################
##
## ActiveDR failover testing for SQL Server Failover Cluster Instance
## 
## This demo script runs through two scenarios: -
## 1. Failover of clustered SQL Server role to node on same array
## 2. Failover of clustered SQL Server role to node on remote array
##
## The second test involves the following steps: -
###### Stop clustered SQL Server role in FCI
###### Demote source pod
###### Promote target pod
###### Move clustered role to node on target array
###### Start up clustered SQL Server role
##
## Author - Andrew Pruski
## apruski@purestorage.com
##
####################################################################################################################
####################################################################################################################



# import powershell modules
Import-Module FailoverClusters
Import-Module PureStoragePowershellSDK2



####################################################################################################################
#
# Performing failover to node on same storage array
#
####################################################################################################################



# set variables
$ClusterName    = "WindowsClusterName"
$ClusterRole    = "SQL Server (MSSQLSERVER)"
$NodeSameArray  = "NodeOnSameArray"



# confirm cluster
Get-Cluster $ClusterName



# confirm cluster nodes
Get-Cluster $ClusterName | Get-ClusterNode



# confirm clustered SQL Server service
Get-ClusterGroup -Cluster $ClusterName -Name $ClusterRole



# test failing over clustered service to node on same storage array
Move-ClusterGroup -Cluster $ClusterName -Name $ClusterRole -Node $NodeSameArray



# confirm clustered SQL Server service
Get-ClusterGroup -Cluster $ClusterName -Name $ClusterRole



################################################################################################################
#
# Performing failover to node on remote storage array
#
################################################################################################################



# set source array details
$SourceFlashArrayIp = "SourceFlashArrayIpAddress"
$SourcePodName      = "PodNameOnSourceArray"



# set Pure credentials
$PureCred = Get-Credentials



# connect to source flasharray
$SourceFlashArray = Connect-Pfa2Array -EndPoint $SourceFlashArrayIp -Credential $PureCred -IgnoreCertificateError



# confirm pod replication status
Get-Pfa2PodReplicaLink -Array $SourceFlashArray -LocalPodName $SourcePodName



# confirm clustered SQL Server service
Get-ClusterGroup -Cluster $ClusterName -Name $ClusterRole



# stop clustered service - taking volumes offline
Stop-ClusterGroup -Cluster $ClusterName -Name $ClusterRole



# confirm clustered service offline
Get-ClusterGroup -Cluster $ClusterName -Name $ClusterRole



# demote Production Pod with Quiesce
Update-Pfa2Pod -Array $SourceFlashArray -Name $SourcePodName -Quiesce $True -RequestedPromotionState "demoted"



# confirm Production Pod status - PromotionStatus : demoted
Get-Pfa2Pod -Array $SourceFlashArray -Name $SourcePodName



# set target array details
$TargetFlashArrayIp = "TargetFlashArrayIpAddress"
$TargetPodName      = "PodNameOnTargetArray"



# connect to target flasharray
$TargetFlashArray = Connect-Pfa2Array -EndPoint $TargetFlashArrayIp -Credential $PureCred -IgnoreCertificateError



# promote pod
Update-Pfa2Pod -Array $TargetFlashArray -Name $TargetPodName -RequestedPromotionState "promoted"



# confirm pod promoted - PromotionStatus : promoted
Get-Pfa2Pod -Array $FlashArray -Name $TargetPodName



# set node name on remote array
$NodeSameArray2 = "NodeOnRemoteArray"



# move clustered role to node on target array
Move-ClusterGroup -Cluster $ClusterName -Name $ClusterRole -Node $NodeSameArray2



# start the clustered role
Start-ClusterGroup -Cluster $ClusterName -Name $ClusterRole



# confirm role status
Get-ClusterGroup -Cluster $ClusterName -Name $ClusterRole