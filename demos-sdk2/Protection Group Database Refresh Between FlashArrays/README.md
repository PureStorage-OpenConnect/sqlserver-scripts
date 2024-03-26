# Protection Group Database Refresh Between FlashArrays
**Protection Group Database Refresh Between FlashArrays Scripts**
<p align="center"></p>
This folder contains an example script to take a Protection Group snapshot of a SQL Server database, whose files are split between two volumes (typically data & log volumes). 
<BR><BR>


**Files:**
- Protection Group Database Refresh Between FlashArrays.ps1

<!-- wp:separator -->
<hr class="wp-block-separator"/>
<!-- /wp:separator -->

**Scenario:**
<BR>This example script shows steps to snapshot a FlashArray Protection Group that contains the data and log volumes of a SQL Server database, and replicate that snapshot to a second FlashArray.  Then on the second FlashArray, it will then clone those two volumes, from the Protection Group snapshot, and overlay another pre-existing set of volumes on a different, non-production SQL Server.  

All references to a "source" refer to the production side, and "target" refer to the non-production side.

**Prerequisites:**
1. Two SQL Server instances with a single database, whose data file(s) are contained within 1 volume and log file(s) are contained within a 2nd volume.  
2. A Protection Group defined with the two volumes (data and log) as members
3. A replication Target Array is configured on the Protection Group.

**Usage Notes:**
<BR>This simple example assumes there is only one database residing on two different volumes (data & log).  If multiple databases are present, additional code must be added to offline/online all databases present on the affected volumes in the Protection Group.  Also note that the Protection Group use may include other volumes without negative impact.  Any extraneous volumes will simply not be utilized during the cloning step.  Finally, remember that snapshot replication between FlashArrays is asynchronous.  Thus it is possible at runtime, that the most recent snapshot is still in the middle of being replicated.  There is a step to validate the state of the snapshot, before the cloning step.

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
