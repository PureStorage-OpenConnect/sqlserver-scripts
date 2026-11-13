# iSCSI In-Place Restore

This folder holds an example script that rolls SQL Server databases back to an earlier FlashArray snapshot on the same VM, when the database files are on disks the guest reaches over iSCSI.

**Files:**
- `iSCSI In-Place Restore.ps1` - databases and disks offline, overwrite each volume from the protection group snapshot, disks and databases online

---

## iSCSI In-Place Restore.ps1

**Scenario:**

A SQL Server VM keeps its database files on iSCSI disks, each its own FlashArray volume. A snapshot of the protection group that holds those volumes was taken earlier (a restore point). The script takes the databases and disks offline, overwrites each volume from its member of that snapshot, and brings the disks and databases back online. Everything after the restore point is lost.

**What you type in, and what the script looks up:**

You name the FlashArray, the VM, the SQL Server, the databases and the protection group, and optionally a snapshot suffix (empty means the newest). Everything else is looked up: database files, to Windows drive, to Windows disk serial number, to FlashArray volume.

**Prerequisites:**

1. PowerShell modules: `dbatools` and `PureStoragePowerShellSDK2`.
2. PowerShell remoting (WinRM) to the VM, and a SQL Server login that can take the databases offline.
3. Every database disk is a FlashArray volume presented with the Microsoft iSCSI initiator, and those volumes are in a protection group. A restore point is a snapshot of that group, so every volume shares one point in time (for example `New-Pfa2ProtectionGroupSnapshot -SourceName <group> -Suffix before-upgrade`).
4. Nothing else uses those disks. Every database with files on them must be listed, or the restore fails.
5. Database files on drive letters.

**What a DBA needs to know:**

- **Nothing changes in the sessions.** The iSCSI sessions, the multipath devices, the serial numbers and the drive letters stay the same. The volume is overwritten with `New-Pfa2Volume -Overwrite`, and the array keeps the volume's name, serial number and connections.
- **A way back may exist.** When a volume is overwritten, the FlashArray can keep its previous contents as a destroyed snapshot named `<volume>.copy.<n>`. Confirm this on your array and Purity version before you rely on it.
- **Take restore points with a protection group snapshot,** so data and log share one point in time.
- The databases and disks are offline from the start of the overwrite until the databases are back online.

**Things learned the hard way, in every script in this repository:**

- **dbatools reports SQL errors as warnings.** `Invoke-DbaQuery` does not throw unless `-EnableException` is given, so every query here has it. Without it, "stop at the first error" does not cover SQL statements.
- **Do not pipe FlashArray cmdlets into `Select-Object -First`.** In Windows PowerShell 5.1 it can end a script silently. The scripts take the first item from an array instead.
- **New disks can take a while to appear.** The scripts say where to wait and give a command to check. Run it until every new disk is listed, then continue.

**Important Usage Notes:**

The script stops at the first error, because later steps remove and overwrite things. It is meant to be read and adapted, and the sections can be run one after the other. Do not run it unchanged against production.

---

**Disclaimer:**

This example script is provided AS-IS and is meant to be a building block to be adapted to fit an individual organization's infrastructure.
