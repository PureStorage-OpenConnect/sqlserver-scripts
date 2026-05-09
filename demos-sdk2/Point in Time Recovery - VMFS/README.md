# Point In Time Recovery - Using SQL Server 2022's T-SQL Snapshot Backup feature w. VMFS/VMDK datastore/files.


<!-- wp:separator -->
<hr class="wp-block-separator"/>
<!-- /wp:separator -->

# Scenario:
Perform a point in time restore using SQL Server 2022's T-SQL Snapshot Backup feature. This uses a FlashArray snapshot as the base of the restore, then restores a log backup.

# IMPORTANT NOTE:
This example script is built for 1 database spanned across two VMDK files/volumes from a single datastore. 

The granularity or unit of work for this workflow is a VMDK file(s) and the entirety of its contents. Therefore, everything in the VMDK file(s) including files for other databases will be impacted/overwritten. 

This example will need to be adapted if you wish to support multiple databases on the same set of VMDK(s).

# Prerequisites:
1. PowerShell Modules: dbatools & PureStoragePowerShellSDK2

# Usage Notes:
Each section of the script is meant to be run one after the other. The script is not meant to be executed all at once. 

<!-- wp:separator -->
<hr class="wp-block-separator"/>
<!-- /wp:separator -->

# Disclaimer:
This example script is provided AS-IS and is meant to be a building block to be adapted to fit an individual organization's  infrastructure.
<BR><BR>
_PLEASE_ do not save your passwords in cleartext here. 
Use NTFS secured, encrypted files or whatever else -- never cleartext!
<BR><BR>
We encourage the modification and expansion of these scripts by the community. Although not necessary, please issue a Pull Request (PR) if you wish to request merging your modified code in to this repository.

<!-- wp:separator -->
<hr class="wp-block-separator"/>
<!-- /wp:separator -->

_The contents of the repository are intended as examples only and should be modified to work in your individual environments. No script examples should be used in a production environment without fully testing them in a development or lab environment. There are no expressed or implied warranties or liability for the use of these example scripts and templates presented by Pure Storage and/or their creators._
