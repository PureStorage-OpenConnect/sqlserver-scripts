# RDM App Consistent Clone

This folder holds an example script that copies SQL Server databases from one VM to another from an application-consistent FlashArray snapshot, when the database files are on RDMs.

**Files:**
- `RDM App Consistent Clone.ps1` - freeze with SQL Server 2022 T-SQL snapshot backup, snapshot, metadata backup, then clone and attach to a second VM

---

## RDM App Consistent Clone.ps1

**Scenario:**

The databases are frozen with `ALTER DATABASE ... SET SUSPEND_FOR_SNAPSHOT_BACKUP = ON` while a FlashArray snapshot of every volume that holds them is taken, and a `BACKUP DATABASE ... WITH METADATA_ONLY` releases the freeze and records the snapshot names. The snapshot is then cloned, the clones are added to a second VM as RDMs, and the databases are attached there under new names. The copies need no crash recovery.

**What you type in, and what the script looks up:**

You name the vCenter, the FlashArray, the VMs, the SQL Servers and the databases. Everything else is looked up: database files, to Windows drive, to Windows disk serial number, to FlashArray volume, to host group. For an RDM the Windows disk serial number is the FlashArray volume's serial number.

**Prerequisites:**

1. PowerShell modules: `dbatools`, `PureStoragePowerShellSDK2` and VMware PowerCLI.
2. SQL Server 2022 or later on the source.
3. PowerShell remoting (WinRM) to both VMs, and a SQL Server login that can attach databases on the target.
4. A share the source SQL Server can write to, for the small metadata backup files.
5. Every database disk is a FlashArray volume presented as an RDM.
6. A different target VM with free SCSI slots, and drive letters, not mount points.

**What a DBA needs to know:**

- Three people usually own the steps: the storage admin (snapshot, volume, host connection), the VMware admin (rescan, add the RDM) and the DBA (bring the disks online, attach the databases). The script does all of them.
- An RDM copy is added in physical compatibility mode.
- The ESXi host needs a rescan before it sees a new volume, and the script rescans the host the target VM runs on. Each new volume is connected to the host group (all hosts that can run the VM), not to a single host, or vMotion and HA break.
- The freeze is tied to the SQL Server session, so the script uses one persistent non-pooled connection for the freeze and the metadata backup. A pooled connection would thaw the databases before the snapshot.
- The script prints how long writes were frozen.

**Things learned the hard way, in every script in this repository:**

- **dbatools reports SQL errors as warnings.** `Invoke-DbaQuery` does not throw unless `-EnableException` is given, so every query here has it. Without it, "stop at the first error" does not cover SQL statements.
- **Do not pipe FlashArray cmdlets into `Select-Object -First`.** In Windows PowerShell 5.1 it can end a script silently. The scripts take the first item from an array instead.
- **Hot-added disks can take a while to appear.** The scripts say where to wait and give a command to check. Run it until every new disk is listed, then continue.
- The snapshot is a protection group snapshot, so the database disks (one FlashArray volume each) share one point in time. The script makes the protection group the first time and leaves it in place for the runs after. If you already have a group that holds these volumes, comment out the creation and set `$ProtectionGroupName`. Every volume in a group is snapshotted, not only the source volumes.

**Important Usage Notes:**

The script stops at the first error, because later steps remove and overwrite things. It is meant to be read and adapted, and the sections can be run one after the other. Do not run it unchanged against production.

---

**Disclaimer:**

This example script is provided AS-IS and is meant to be a building block to be adapted to fit an individual organization's infrastructure.
