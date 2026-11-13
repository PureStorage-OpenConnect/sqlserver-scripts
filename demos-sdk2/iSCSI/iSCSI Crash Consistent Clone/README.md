# iSCSI Crash Consistent Clone

This folder holds an example script that copies SQL Server databases to a second VM from a crash-consistent FlashArray snapshot, when the database files are on disks the guest reaches over iSCSI.

**Files:**
- `iSCSI Crash Consistent Clone.ps1` - crash-consistent snapshot, clone, connect to the target's host, online, attach under new names

---

## iSCSI Crash Consistent Clone.ps1

**Scenario:**

A source SQL Server VM keeps its database files on disks that the guest operating system reaches itself with the Microsoft iSCSI initiator. Each disk is its own FlashArray volume. A second SQL Server VM needs a copy, for example for dev/test. The script takes one crash-consistent snapshot of every volume that holds the databases, clones each as a new volume, connects the clones to the target VM's FlashArray host, brings the disks online, and attaches the databases under new names. The source is not touched and stays online.

**What you type in, and what the script looks up:**

You name the FlashArray, the VMs, the SQL Servers and the databases. Everything else is looked up: database files, to Windows drive, to Windows disk serial number, to FlashArray volume. For an iSCSI disk the Windows disk serial number is the FlashArray volume's serial number. The target's FlashArray host is found from the iSCSI initiator name (IQN) that the target VM reports.

**Prerequisites:**

1. PowerShell modules: `dbatools` and `PureStoragePowerShellSDK2`.
2. PowerShell remoting (WinRM) to both VMs, and a SQL Server login that can attach databases on the target.
3. Every database disk is a FlashArray volume presented with the Microsoft iSCSI initiator.
4. The target VM is a different VM from the source, already logged in to the array's iSCSI portals, and a host on the FlashArray identified by its IQN.
5. Database files on drive letters, the databases not yet on the target, and the source's drive letters free on the target.

**What a DBA needs to know:**

- Two people usually own the steps: the storage admin (snapshot, clone, host connection) and the DBA or Windows admin (rescan, disks online, attach). The script does both.
- The target VM is already logged in to the array's iSCSI portals once (one session per portal, multipath enabled, sessions persistent), and is a host on the FlashArray that holds its IQN. After that, a new volume connected to that host only needs a storage rescan. The script does not log in.
- **Copied disks arrive offline and read-only** (the default SAN policy). The script sets them online and writable.
- A copy on another VM keeps the original's drive letter if it is free, otherwise Windows gives the next free one. The script reads the letter back and uses it.
- Each database performs crash recovery when it is attached, because writes were not frozen.

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
