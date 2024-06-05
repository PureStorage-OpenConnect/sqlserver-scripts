<p align="center"></p>

# SQL Server Failover Cluster Instance and ActiveDR 

**Files:**
- ActiveDR-FCI-Testing.ps1


**Scenario:**

Testing failover of a 4 node SQL Server Failover Clustered Instance with nodes hosted on two separate FlashArrays.
Failover between nodes on the same cluster will provide high availabiliy and failover between nodes on separate arrays provides disaster recovery.
 
This demo script runs through two scenarios: -
1. Failover of the failover cluster instance between nodes on the same array (no ActiveDR involvement)
2. Failover of the cluster instance between nodes on separate arrays (requiring ActiveDR involvement)

**Prerequisites:**
1. Windows Cluster needs to be created, with four nodes...two on different FlashArrays
2. ActiveDR pod needs to be configured to replicate between the arrays
3. Volumes of the cluster hosting SQL Server databases (User and System) need to be added to the pod


**Recording**
A recording of this demo is available here: -
https://youtu.be/NgeDeOs-C_Y?si=ggYBpvCjI_xYXv8- 


These scripts are meant to be run in chunks. Each Part represents an independent workflow in the greater context of a DR manual failover and manual failback.  DO NOT run everything at once!

These examples are provided **AS-IS** and meant to be a building block examples to be adapted to fit an individual organization's infrastructure.

<!-- wp:separator -->
<hr class="wp-block-separator"/>
<!-- /wp:separator -->

We encourage the modification and expansion of these scripts by the community. Although not necessary, please issue a Pull Request (PR) if you wish to request merging your modified code in to this repository.

<!-- wp:separator -->
<hr class="wp-block-separator"/>
<!-- /wp:separator -->

_The contents of the repository are intended as examples only and should be modified to work in your individual environments. No script examples should be used in a production environment without fully testing them in a development or lab environment. There are no expressed or implied warranties or liability for the use of these example scripts and templates presented by Pure Storage and/or their creators._
