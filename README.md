![](graphics/purestorage.png)

# Pure Storage OpenConnect SQL Server Scripts

# About this Repository

Welcome to the SQL Server Pure Storage [PowerShell SDK2](https://support.purestorage.com/Solutions/Microsoft_Platform_Guide/a_Windows_PowerShell/Pure_Storage_PowerShell_SDK) script repository. In this repository, you will learn how to make the most of your Pure Storage platform for your SQL Server environment. You will learn how to leverage snapshots, enabling you to dramatically reduce the time it takes data to move between SQL Server instances. 

The focus of this repository is to understand where storage lives in your data platform and learn how to use modern storage techniques to reduce the overhead and complexity of managing data in your environment.


# Business Applications of Snapshots

Array-based snapshots are used to decouple database operations from the size of the data. Using array-based snapshots, you can accelerate access to data in several common database scenarios:

* Instant data + ransomware protection
* Dev/Test refreshes in seconds
* In-place application and database upgrades
* Intra-Instance ETL
* Offload database maintenance


# Technical Requirements

* The code in this repository is implemented using the [Pure Storage PowerShell SDK2 Module](https://support.purestorage.com/Solutions/Microsoft_Platform_Guide/a_Windows_PowerShell/Pure_Storage_PowerShell_SDK). Follow this link for release notes and installation guidance.

# Demo Inventory


## Using Snapshots for Databases on for vVols, RDMs, and Physical FlashArray Volumes

| Demo | Description |  |   |
| ----------- | ----------- |  ----------- |  ----------- | 
| **Volume Database Refresh** | Refresh a database from a Volume snapshot where all the databases' files are on the same Volume on the same FlashArray. | [More Info](./demos-sdk2/Volume%20Database%20Refresh/) | [Sample Code](./demos-sdk2/Volume%20Database%20Refresh/Volume%20Database%20Refresh.ps1) |
| **Protection Group Database Refresh** | Refresh a database from a Protection Group snapshot where the databases's files are on two separate volumes on the same FlashArray. | [More Info](./demos-sdk2/Protection%20Group%20Database%20Refresh/) | [Sample Code](./demos-sdk2/Protection%20Group%20Database%20Refresh/Protection%20Group%20Database%20Refresh.ps1)
| **Protection Group Database Refresh Between FlashArrays** | Refresh a database from a Protection Group snapshot replicated from one FlashArray to another FlashArray. | [More Info](./demos-sdk2/Protection%20Group%20Database%20Refresh%20Between%20FlashArrays/) | [Sample Code](./demos-sdk2/Protection%20Group%20Database%20Refresh%20Between%20FlashArrays/Protection%20Group%20Database%20Refresh%20Between%20FlashArrays.ps1) |
| **Point in Time Recovery** | Combine a Protection Group snapshot with native SQL Server log backups using SQL Server 2022's TSQL Based Snapshot feature for point-in-time database recovery. | [More Info](./demos-sdk2/Point%20in%20Time%20Recovery/) | [Sample Code](./demos-sdk2/Point%20in%20Time%20Recovery/Point%20in%20Time%20Recovery.ps1) |
| **Seeding an Availability Group** | Seed an Availability Group Secondary Replica using snapshots and SQL Server 2022's TSQL Based Snapshot Feature | [More Info](./demos-sdk2/Seeding%20an%20Availability%20Group/) | [Sample Code](./demos-sdk2/Seeding%20an%20Availability%20Group/Seeding%20an%20Availability%20Group.ps1) |
| **Multi-Array Snapshot** | Restore a database from a Protection Group snapshot where the databases' files are on two volumes on two separate FlashArrays. | [More Info](./demos-sdk2/Multi-Array%20Snapshot/) | [Sample Code](./demos-sdk2/Multi-Array%20Snapshot/Multi-Array%20Snapshot.ps1) |


## Using Snapshots for Databases on VMFS Datastores

| Demo | Description |  |   |
| ----------- | ----------- |  ----------- |  ----------- | 
| **Volume Database Refresh on VMDK Virtual Disks** | Refresh a database from Volume snapshot where all of the databases's files are using a VMware VMDK Virtual Disk type on a single VMFS Datastore on the same Volume on the same FlashArray. | [More Info](./demos-sdk2/VMFS-VMDK%20Snapshot/) | [Sample Code](./demos-sdk2/VMFS-VMDK%20Snapshot/VMFS-VMDK%20Snapshot.ps1) |


## Using ActiveDR

| Demo | Description |  |   |
| ----------- | ----------- | ----------- | ----------- |
| **Database Test Failover** | Perform a test failover of a database between two FlashArrays using ActiveDR | [More Info](./demos-sdk2/ActiveDR/) | [Sample Code](./demos-sdk2/ActiveDR/ActiveDR%20Failover%20Test.ps1) | 
| **Database Full Failover** | Perform a test failover and failback of a database between two FlashArrays using ActiveDR | [More Info](./demos-sdk2/ActiveDR/) | [Sample Code](./demos-sdk2/ActiveDR/ActiveDR%20Full%20Failover.ps1) | 
| **SQL Server FCI + ActiveDR** | Perform a test failover and failback of a SQL Server Failover Cluster Instance between two FlashArrays using ActiveDR | [More Info](./demos-sdk2/ActiveDR/SQL%Server%FCI%+%ActiveDR) | [Sample Code](./demos-sdk2/ActiveDR/SQL%Server%FCI%+%ActiveDR/ActiveDR-FCI-Testing.ps1) | 


**Examples from the previous PowerShell SDK repository are available in this repository's [demos-archive](./demos-archive/) folder.**

---

_The contents of the repository are intended as examples only and should be modified to work in your individual environments. No script examples should be used in a production environment without fully testing them in a development or lab environment. There are no expressed or implied warranties or liability for the use of these example scripts and templates presented by Pure Storage and/or their creators._

