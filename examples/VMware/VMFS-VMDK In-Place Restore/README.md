# VMFS-VMDK In-Place Restore

This folder holds an example script that rolls a SQL Server VM's databases back to an earlier FlashArray snapshot, when the database files are on VMDKs in a VMware VMFS datastore.

**Files:**
- `VMFS-VMDK In-Place Restore.ps1` - clones a snapshot of the datastore's FlashArray volume, swaps the database VMDKs on the VM for the copies, Storage vMotions them back onto the original datastore and removes the temporary clone

---

## VMFS-VMDK In-Place Restore.ps1

**Scenario:**

A SQL Server VM keeps its database files on VMDKs in a VMFS datastore, which is one FlashArray volume. Something went wrong, for example corruption, a bad release or a mistaken delete, and you want the databases back as they were when an earlier snapshot of the volume was taken.

**Why the script does not unmount the datastore:**

The obvious way is to unmount the datastore, overwrite the FlashArray volume from the snapshot and mount it again. That can fail. A datastore that vSphere HA uses for heartbeating cannot be unmounted (`Volume ... cannot be unmounted. Reason: Busy`), and neither can one that other VMDKs or VMs are still using, for example a tempdb VMDK that stays on the datastore. Whether it fails depends on how HA heartbeat datastores are configured in your cluster, and changing the HA settings of a shared cluster is not something a restore script should do. The script does not unmount anything, so it does not depend on that.

Instead the script clones the snapshot as a temporary volume and datastore, takes the databases offline, deletes the current database VMDKs, attaches the copies (they have the same UUIDs as the ones just removed, so Windows sees the same disks coming back and the volumes keep their drive letters), brings the databases online, Storage vMotions the VMDKs back onto the original datastore, and removes the temporary clone. The original datastore, its name and its FlashArray volume stay as they were, and other VMDKs on it (for example tempdb) are untouched.

**The current database VMDKs are deleted.** If you might want today's data back, take a FlashArray snapshot of the volume first.

**What you type in, and what the script looks up:**

You name the vCenter, the FlashArray, the VM, the SQL Server and the databases. The script follows the chain from the database files to the Windows drive, the disk serial number, the VMDK, the datastore, the FlashArray volume and its host group. By default it restores the newest snapshot of that volume. Set `$SnapshotName` to choose another.

**Prerequisites:**

1. PowerShell modules: `dbatools`, `PureStoragePowerShellSDK2` and VMware PowerCLI.
2. PowerShell remoting (WinRM) to the VM, and a SQL Server login that can take databases offline and online.
3. All of the listed databases must be on VMDKs in one datastore.
4. At least one FlashArray snapshot of the volume exists.

**What a DBA needs to know:**

- A crash-consistent snapshot means each database performs crash recovery when it comes online.
- The databases are offline from the moment the swap starts until the restored copies are online. Plan for that downtime, which is the clone, resignature and attach, not the Storage vMotion.
- The Storage vMotion at the end runs while the databases are online. File names on the datastore can change (for example `_4.vmdk`), because Storage vMotion renames a file when the name is already taken.
- The snapshot you restored from is kept on the array. Any snapshot taken later also stays and still works.

**Things learned the hard way, in every script in this repository:**

- **dbatools reports SQL errors as warnings.** `Invoke-DbaQuery` does not throw unless `-EnableException` is given, so every query here has it. Without it, "stop at the first error" does not cover SQL statements.
- **Do not pipe FlashArray cmdlets into `Select-Object -First`.** In Windows PowerShell 5.1 it can end a script silently. The scripts take the first item from an array instead.
- **Hot-added disks can take a while to appear.** The scripts say where to wait and give a command to check. Run it until every new disk is listed, then continue.

**Important Usage Notes:**

This script deletes data. It stops at the first error, but it cannot tell whether the snapshot you chose is the one you meant. Check the snapshot list it prints. Do not run it unchanged against production.

---

**Disclaimer:**

This example script is provided AS-IS and is meant to be a building block to be adapted to fit an individual organization's infrastructure.

_The contents of this folder are intended as examples only and should be modified to work in your individual environments. No script examples should be used in a production environment without fully testing them in a development or lab environment._
