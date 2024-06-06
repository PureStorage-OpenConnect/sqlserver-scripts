# Protection Group Database Refresh
**Protection Group Database Refresh Scripts**
<p align="center"></p>
These examples demonstrate how to initially create a Volume Set. Additional examples demonstrate how to add or
subtrace volumes from a volume set. Remember that cmdlets involving Volume Sets will check to ensure all Volumes 
are members of the declared Protection Group. 
<BR><BR>


**Files:**
- VolumeSet-Example.ps1

<!-- wp:separator -->
<hr class="wp-block-separator"/>
<!-- /wp:separator -->

**Scenario:**
<BR>These examples demonstrate how to initially create a Volume Set. Additional examples demonstrate how to add or
subtrace volumes from a volume set. Remember that cmdlets involving Volume Sets will check to ensure all Volumes 
are members of the declared Protection Group. 

**Prerequisites:**
1. Administrator Credentials for a Windows Server and FlashArray.  
2. Install the PureStorage.FlashArray.Backup module.
3. (optional) If a VMware VM using RDM or vVol, an Administrator Credential for vCenter.

**Usage Notes:**
<BR>Each example is an independent example showing how to initially create a Volume Set, or to modify the members of a Volume Set.

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
