# Refresh VMFS VMDK(s) with Snapshot Demo
<!-- wp:separator -->
<hr class="wp-block-separator"/>
<!-- /wp:separator -->

# Scenario:
Production SQL Server & database(s) reside on a VMFS datastore.  Non-production SQL Server resides on 
a different VMFS datastore.  User database(s) data and log files reside on two different VMDK disks 
in each datastore.
<BR><BR>
Each datastore also resides on a different FlashArray, to demonstrate use of async snapshot replication.
<BR><BR>
This example is for a repeatable refresh scenario, such as a nightly refresh of a production database on
another non-production SQL Server.
<BR><BR>
This example's workflow takes an on-demand snapshot of the Production datastore and async replicates it to
the second FlashArray.  Then the snapshot is cloned as a new temporary volume/datastore.  The VMDKs with the
production database files, residing on the temporary cloned datastore are attached to the target SQL Server,
replacing the prior VMDKs that stored the database files previously.  Finally Storage vMotion is used to
migrate the VMDKs to the non-production datastore, then the temporary cloned datastore is discarded.
<BR><BR>
This workflow is intended to only be impact select Windows Disks/VMDKs that contain user databases.  

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



