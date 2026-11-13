# iSCSI Dev Test Refresh

This folder holds an example script that refreshes a non-production copy of SQL Server databases on a schedule, when the database files are on disks the guest reaches over iSCSI.

**Files:**
- `iSCSI Dev Test Refresh.ps1` - remove the previous copy, crash-consistent snapshot, clone, connect, online, attach under stable names

---

## iSCSI Dev Test Refresh.ps1

**Scenario:**

A production SQL Server VM keeps its database files on iSCSI disks, each its own FlashArray volume. A non-production VM needs a fresh copy on a schedule. Each run finds the copy the previous run made, removes it completely (databases, disks, clone volumes and snapshots), takes a new crash-consistent snapshot, clones it, connects the clones to the target's host and attaches the databases.

**What you type in, and what the script looks up:**

You name the FlashArray, the VMs, the SQL Servers and the databases. Everything else is looked up: database files, to Windows drive, to Windows disk serial number, to FlashArray volume. For an iSCSI disk the Windows disk serial number is the FlashArray volume's serial number. The target's FlashArray host is found from the iSCSI initiator name (IQN) that the target VM reports.

**Prerequisites:**

1. PowerShell modules: `dbatools` and `PureStoragePowerShellSDK2`.
2. PowerShell remoting (WinRM) to both VMs, and a SQL Server login that can attach and drop databases on the target.
3. Every database disk is a FlashArray volume presented with the Microsoft iSCSI initiator.
4. The target VM is a different VM from the source, already logged in to the array's iSCSI portals, and a host on the FlashArray identified by its IQN.
5. Database files on drive letters.

**What a DBA needs to know:**

- **Stable names make it repeatable.** Each clone volume is `<source volume>-devtest`, the databases are `<database>_dev`, and the snapshots carry a `devtest-` suffix.
- **Removal order.** Drop the dev databases, take the disks offline in Windows, then disconnect and destroy the clone volumes and their snapshots, then rescan.
- **Old copies are eradicated at once.** A nightly refresh that waited for the eradication period would keep several old copies on the array.
- The first run has nothing to remove. A run that fails halfway leaves some of a copy behind, and the next run removes whatever it finds by the stable names.
- The target databases are dropped and recreated on every run, so anything changed in them is lost.
- To retire the copy without making a new one, run only the "Remove the previous copy" section.

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
