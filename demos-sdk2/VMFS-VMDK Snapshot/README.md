**VMFS/VMDK + SQL Server Snapshot Scripts**
<p align="center"></p>
This folder contains VMFS/VMDK + SQL Server example snapshot scripts.

**Files:**
- VMFS-VMDK Snapshot.ps1

<!-- wp:separator -->
<hr class="wp-block-separator"/>
<!-- /wp:separator -->

**Scenario:**
<BR>This example script shows steps to snapshot a VMFS datastore that contains data & log VMDKs for a SQL Server.  The overall scenario is taking a snapshot of a production SQL Server's underlying datastore, and cloning the datastore to then overlay a pre-existing non-production datastore for a non-production SQL Server.  

All references to a "target" refer to the non-production side (VM, datastore, etc).

**Prerequisites:**
1. The production datastore must already be cloned and presented once, to the non-production side.  
2. This script assumes the database(s) are already attached on the target, non-production SQL Server.  

**Important Usage Notes:**
<BR>You must pre-setup the target VM with a cloned datastore from the source already.  You will ONLY be utilizing the specific VMDK(s) that contain the data/log files of interest, from the cloned datastore.  Also note that the VMFS datastore does not need to only exclusively contain VMDKs for the SQL Server in question. If other VMDKs are present in the datastore, used by the either the source SQL Server VM or other VMs, they do not need to be deleted or otherwise manipulated during this cloning process.  Remember FlashArray deduplicates data, thus a clone's set of additional, unused VMDKs will not have a negative impact.  

For the cloned datastore pre-setup, you can use subsets of the code below to clone the source datastore, present it to the target server, then attach the VMDK(s) containing the production databases that will be re-cloned with this script. Once "staged," you can then use this script fully to refresh the data files in the cloned datastore that is attached to the target server.

When cloning, note that the target datastore is dropped and replaced entirely.  This is because when cloning a datastore, it must be resignatured and the datastore will be renamed  with a non-deterministic naming scheme (snap-[[GUID chars]]-[[original DS name]]).  Thus it is not possible to know what the new datastore name will be until the resignature step is executed.  

This script also assumes that all database files (data and log) are on the same volume/single VMDK.  If multiple volumes/VMDKs are being used, you will have to adjust the code (ex: add additional foreach loops for manipulating multiple VMDKs).

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
