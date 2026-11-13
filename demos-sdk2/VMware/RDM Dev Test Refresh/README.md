# RDM Dev Test Refresh

This folder holds an example script that refreshes a non-production copy of SQL Server databases on a schedule, when the source database files are on RDMs (each RDM is a FlashArray volume).

**Files:**
- `RDM Dev Test Refresh.ps1` - removes the previous copy, then makes a new crash-consistent copy on a target VM. Safe to run again and again.

---

## RDM Dev Test Refresh.ps1

**Scenario:**

A production SQL Server VM keeps its database files on RDMs. A dev/test SQL Server VM needs a fresh copy every night, say. Each run finds the copy the previous run made, removes it completely, and makes a new one from a new snapshot. The source stays online. Write IO is not frozen, so each database performs crash recovery when it is attached.

The copy has stable names so the next run can find it: each clone volume is called `<source volume>-devtest`, the databases are `<database>_dev`, and the snapshots have a `devtest-` suffix.

**What you type in, and what the script looks up:**

You name the vCenter, the FlashArray, the two VMs, the two SQL Servers and the databases. Everything else is looked up: database files, to Windows drive, to Windows disk serial number (which is the FlashArray volume's serial number for an RDM), to FlashArray volume, to host group.

**Prerequisites:**

1. PowerShell modules: `dbatools`, `PureStoragePowerShellSDK2` and VMware PowerCLI.
2. PowerShell remoting (WinRM) to both VMs, and a SQL Server login that can attach and drop databases on the target.
3. Every database disk is a FlashArray volume presented to the source VM as an RDM.
4. The target is a different VM, with free SCSI slots, and it is NOT in the source's failover cluster (a copy has the same disk identity as the original, and a cluster refuses it).
5. Database files on drive letters, not mount points.

**What a DBA needs to know:**

- The previous copy is removed in a fixed order: drop the dev databases, offline the disks in Windows, remove the RDMs from the VM, detach the LUNs from the host, then disconnect and destroy the clone volumes and their snapshots. The script eradicates the old clone volumes and snapshots at once, because a nightly refresh that waited for the eradication period would keep several old copies on the array.
- The first run has nothing to remove. A run that fails halfway leaves some of a copy behind. The next run removes whatever it finds by the stable names.
- Three people usually own the steps: the storage admin (snapshot, volume, host connection), the VMware admin (rescan, add and remove the RDMs) and the DBA (disks online, attach, drop). The script does all of them.

**Things learned the hard way, in every script in this repository:**

- **dbatools reports SQL errors as warnings.** `Invoke-DbaQuery` does not throw unless `-EnableException` is given, so every query here has it. Without it, "stop at the first error" does not cover SQL statements.
- **Do not pipe FlashArray cmdlets into `Select-Object -First`.** In Windows PowerShell 5.1 it can end a script silently. The scripts take the first item from an array instead.
- **Hot-added disks can take a while to appear.** The scripts say where to wait and give a command to check. Run it until every new disk is listed, then continue.
- The snapshot is a protection group snapshot, so the database disks (one FlashArray volume each) share one point in time. The script makes the protection group the first time it runs and keeps it for the runs after. If you already have a group that holds these volumes, comment out the creation and set `$ProtectionGroupName`. Every volume in a group is snapshotted, not only the source volumes.

**Important Usage Notes:**

The script stops at the first error, because later steps remove and overwrite things. It is meant to be read and adapted, and the sections can be run one after the other. Do not run it unchanged against production.

---

**Disclaimer:**

This example script is provided AS-IS and is meant to be a building block to be adapted to fit an individual organization's infrastructure.
