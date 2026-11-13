# iSCSI App Consistent Clone

This folder holds an example script that copies SQL Server databases to a second VM from an application-consistent FlashArray snapshot, when the database files are on disks the guest reaches over iSCSI.

**Files:**
- `iSCSI App Consistent Clone.ps1` - freeze with T-SQL snapshot backup, snapshot, release with a metadata-only backup, clone, connect, online, attach under new names

---

## iSCSI App Consistent Clone.ps1

**Scenario:**

The same copy as the crash-consistent script, with a clean snapshot. The script freezes every database with `ALTER DATABASE ... SET SUSPEND_FOR_SNAPSHOT_BACKUP = ON`, takes one snapshot of the volumes, and releases each database with `BACKUP DATABASE ... WITH METADATA_ONLY`, which also records the snapshot names. The clones are connected to the target VM's host and the databases are attached under new names. The copies need no crash recovery.

**What you type in, and what the script looks up:**

You name the FlashArray, the VMs, the SQL Servers and the databases. Everything else is looked up: database files, to Windows drive, to Windows disk serial number, to FlashArray volume. For an iSCSI disk the Windows disk serial number is the FlashArray volume's serial number. The target's FlashArray host is found from the iSCSI initiator name (IQN) that the target VM reports.

**Prerequisites:**

1. PowerShell modules: `dbatools` and `PureStoragePowerShellSDK2`.
2. SQL Server 2022 or later on the source (T-SQL snapshot backup).
3. PowerShell remoting (WinRM) to both VMs, and a SQL Server login that can attach databases on the target.
4. A share the source SQL Server can write to, for the small metadata backup files.
5. Every database disk is a FlashArray volume presented with the Microsoft iSCSI initiator.
6. The target VM is a different VM from the source, already logged in to the array's iSCSI portals, and a host on the FlashArray identified by its IQN.
7. Database files on drive letters, the databases not yet on the target, and the source's drive letters free on the target.

**What a DBA needs to know:**

- **The freeze is tied to the SQL Server session.** The script uses one persistent, non-pooled connection for the freeze and the metadata backup. A pooled connection would thaw the databases before the snapshot.
- **Keep the freeze short.** The script prints how long writes were frozen. Measure it under your own write load.
- **Run a manual `CHECKPOINT` on each database just before the freeze.** The freeze begins with a checkpoint that flushes dirty pages, and on a busy system that flush can be most of the time the databases are suspended.
- The target VM is already logged in to the array's iSCSI portals once (one session per portal, multipath enabled, sessions persistent), and is a host on the FlashArray that holds its IQN. After that, a new volume connected to that host only needs a storage rescan. The script does not log in.
- **Copied disks arrive offline and read-only.** The script sets them online and writable.

**Things learned the hard way, in every script in this repository:**

- **dbatools reports SQL errors as warnings.** `Invoke-DbaQuery` does not throw unless `-EnableException` is given, so every query here has it. Without it, "stop at the first error" does not cover SQL statements.
- **Do not pipe FlashArray cmdlets into `Select-Object -First`.** In Windows PowerShell 5.1 it can end a script silently. The scripts take the first item from an array instead.
- **New disks can take a while to appear.** The scripts say where to wait and give a command to check. Run it until every new disk is listed, then continue.
- The snapshot is a protection group snapshot, so the database disks (one FlashArray volume each) share one point in time. The script makes the protection group the first time it runs and keeps it for the runs after. If you already have a group that holds these volumes, comment out the creation and set `$ProtectionGroupName`. Every volume in a group is snapshotted, not only the source volumes.

**Important Usage Notes:**

The script stops at the first error, because later steps remove and overwrite things. It is meant to be read and adapted, and the sections can be run one after the other. Do not run it unchanged against production.

---

**Disclaimer:**

This example script is provided AS-IS and is meant to be a building block to be adapted to fit an individual organization's infrastructure.
