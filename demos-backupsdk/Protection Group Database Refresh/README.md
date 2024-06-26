# Protection Group Database Refresh
**Protection Group Database Refresh Scripts**
<p align="center"></p>
This folder contains example scripts to take a Protection Group snapshot of a SQL Server database, whose files are split between two volumes (typically data & log volumes). 
<BR><BR>


**Files:**
- Protection Group Database Refresh physical BackupSDK.ps1
- Protection Group Database Refresh vVol BackupSDK.ps1

<!-- wp:separator -->
<hr class="wp-block-separator"/>
<!-- /wp:separator -->

**Scenario:**
<BR>This example script shows steps to snapshot a FlashArray Protection Group that contains the data and log volumes of a SQL Server database.  It will then dismount a prior clone of those two volumes on the non-production SQL Server. Finally it will create a new clone from the most recent Protection Group snapshot and mount it to the non-production SQL Server.  

All references to a "target" refer to the non-production side. If the source and target FlashArrays are the same FlashArray only one variable is required.

**Prerequisites:**
1. Two SQL Server instances with a single database, whose data file(s) are contained within 1 volume and log file(s) are contained within a 2nd volume.  
2. A Protection Group defined with the two volumes (data and log) as members
3. Install the PureStorage.FlashArray.Backup module.

**Usage Notes:**
<BR>This simple example assumes there is only one database residing on two different volumes (data & log).  If multiple databases are present, additional code must be added to offline/online all databases present on the affected volumes in the Protection Group.  Also note that the Protection Group use may include other volumes without negative impact.  Any extraneous volumes will simply not be utilized during the cloning step.  

<!-- wp:separator -->
<hr class="wp-block-separator"/>
<!-- /wp:separator -->

**Disclaimer:**
<BR>
This example script is provided AS-IS and meant to be a building block to be adapted to fit an individual organization's infrastructure.
<BR>
<BR>

We encourage the modification and expansion of these scripts by the community. Although not necessary, please issue a Pull Request (PR) if you wish to request merging your modified code in to this repository.

<!-- wp:separator -->
<hr class="wp-block-separator"/>
<!-- /wp:separator -->

_The contents of the repository are intended as examples only and should be modified to work in your individual environments. No script examples should be used in a production environment without fully testing them in a development or lab environment. There are no expressed or implied warranties or liability for the use of these example scripts and templates presented by Pure Storage and/or their creators._
