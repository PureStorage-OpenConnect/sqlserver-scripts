**Hyper-V Cluster Shared Volume + SQL Server Snapshot Scripts**
<p align="center"></p>
This folder contains Hyper-V Cluster Shared Volume + SQL Server example snapshot scripts.

**Files:**
- Hyper-V CSV w SQL Server Snapshot.ps1

<!-- wp:separator -->
<hr class="wp-block-separator"/>
<!-- /wp:separator -->

**Scenario:**
<BR>This example script shows steps to snapshot a Hyper-V Cluster Shared Volume (CSV) that contains data & log VHDX/AVHDX files for a SQL Server. 

<BR>
<BR>
This scenario has a SQL Server Hyper-V VM (ex: Production) with at least two CSVs.  The first CSV is the primary, which will contain VHDX files for the VM itself, OS drive, SQL Server system files, tempdb, etc.  The second CSV, which is what this script will clone, will ONLY contain the data and log files for 1 or more user databases ONLY.  The data and log files can be on two different VHDX files or the same VHDX file - it only matters that they reside in this second CSV, not the first.  
<BR>
<BR>
The second SQL Server Hyper-V VM (ex: non-Production) will also be set up similarly, with two CSVs, so we can clone the Production CSV's user database(s) and refresh this second VM's second CSV with a clone of Production's database.
<BR>
<BR>
All references to a "source" refer to the production side (VM, CSV, etc).
All references to a "target" refer to the non-production side (VM, CSV, etc).

**Prerequisites:**
1. The production CSV must already be cloned and presented once, to the non-production side.  
2. This script assumes the database(s) are already attached on the target, non-production SQL Server.  

**Important Usage Notes:**
<BR>You must pre-setup the target VM with a cloned CSV from the source already.  You will ONLY be utilizing the specific VHDX(s) that contain the data/log files of interest, from the cloned CSV.  Also note that the CSV does not need to only exclusively contain VHDXs for the SQL Server in question. If other VHDXs are present in the CSV, used by the either the source SQL Server VM or other VMs, they do not need to be deleted or otherwise manipulated during this cloning process.  Remember FlashArray deduplicates data, thus a clone's set of additional, unused VHDXs will not have a negative impact.  

For the cloned CSV pre-setup, you can use subsets of the code below to clone the source CSV, present it to the target server, then attach the VHDX(s) containing the production databases that will be re-cloned with this script. Once "staged," you can then use this script fully to refresh the data files in the cloned CSV that is attached to the target server.

This script also assumes that all database files (data and log) are on the same volume/single VHDX.  If multiple volumes/VHDXs are being used, you will have to adjust the code (ex: add additional foreach loops for manipulating multiple VHDXs).

The staging server is needed because each CSV has a unique signature.  If the CSV is presented back to the Hyper-V host unaltered, a signature collision will be detected and the new CSV will not be able to be used by Windows. Hyper-V is unable to resignature in this state either.  Instead, the CSV must be presented to another machine (aka the staging server), resignatured there, then can be re-snapshotted and cloned back to the originating Hyper-V host.

This script may be adjusted to clone and present the CSV snapshot to a different Hyper-V host.  If this is done, then the staging server and resignature step is not required, since the new target Hyper-V host will not have two of the same CSV causing a signature conflict.

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