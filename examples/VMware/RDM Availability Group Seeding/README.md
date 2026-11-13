# RDM Availability Group Seeding

This folder holds an example script that seeds an availability group replica from a FlashArray snapshot, when the database files on both replicas are on RDMs (each RDM is a FlashArray volume).

**Files:**
- `RDM Availability Group Seeding.ps1` - freeze, snapshot, clone to the secondary VM as RDMs, restore with `METADATA_ONLY`, bridge with one log backup, add to the group. Safe to run again: it removes the earlier seed first.

---

## RDM Availability Group Seeding.ps1

**Scenario:**

Two SQL Server VMs, the primary and the secondary replica of an existing availability group, keep their database files on RDMs. You want to add a large database to the group without sending it over the network. The script freezes the databases on the primary with SQL Server's T-SQL snapshot backup, takes one snapshot of all the volumes that hold them, and releases the freeze with a metadata-only backup. Each snapshot is cloned as a new volume and added to the secondary VM as an RDM, with a new disk GUID and the same drive letter the primary uses. On the secondary the databases are restored `WITH METADATA_ONLY, NORECOVERY`, one log backup bridges the time since the snapshot, and the databases are added to the group.

The cloned volumes stay where they are. They become the secondary's database volumes.

**What you type in, and what the script looks up:**

You name the vCenter, the FlashArray, the two VMs, the two SQL Servers, the availability group, the databases and a share. Everything else is looked up: database files, to Windows drive, to Windows disk serial number (the FlashArray volume's serial number for an RDM), to FlashArray volume, to host group.

**Prerequisites:**

1. PowerShell modules: `dbatools`, `PureStoragePowerShellSDK2` and VMware PowerCLI.
2. SQL Server 2022 or later on both replicas. The availability group exists and both instances are replicas. Each replica's login for the other's computer account has CONNECT on the Always On endpoint (without it the secondary stays Disconnected).
3. The databases are online on the primary in FULL recovery. Every database disk is a FlashArray volume presented to the VM as an RDM.
4. A share both SQL Servers can reach, for the metadata backups and one small log backup per database.
5. The secondary VM has free SCSI slots and the same drive letters free as the primary uses.
6. A database of the same name on the secondary is removed by the script, together with its volumes, but only volumes whose names end in `-seed`. Any other volume stops the script.

**What a DBA needs to know:**

- **The snapshot has to be application-consistent.** A crash-consistent snapshot has no metadata backup to restore with `METADATA_ONLY`, and attaching the copied files (`FOR ATTACH`) runs crash recovery and brings the database online. A database that is online cannot take a log restore or join the group, which both need it in the RESTORING state. A copy-only snapshot (`SUSPEND_FOR_SNAPSHOT_BACKUP = ON (MODE = COPY_ONLY)`) seeds the group the same way and leaves the differential base alone. Start the log chain with a regular full backup first.
- Three people usually own the steps: the storage admin (snapshot, clone, host connection), the VMware admin (rescan, add and remove the RDMs) and the DBA (freeze, disks online, restore, add to the group). The script does all of them.
- **The copy must get a new disk GUID before it is onlined.** The two replicas are nodes of one failover cluster, and a cluster node does not mount a disk whose identity matches a disk on another node. `diskpart` with `uniqueid disk id=<new GUID>` on the offline disk is enough for an RDM.
- The metadata restore looks for the files at their original paths, so the script sets the copy's drive letters to the primary's.
- No database backup is needed. The metadata-only backup plus one log backup is the whole seed. The databases must be in FULL recovery or the log backup is not possible.
- The clones are named `<source volume>-seed`. On a second run the script removes the earlier seed (databases, disks, RDMs, volumes) and makes a new one.

**Things learned the hard way, in every script in this repository:**

- **Windows disk changes use `diskpart`, not `Set-Disk`.** On a failover cluster node the storage cmdlets work through the cluster's view of storage. A copy of a disk has the same ID as the original on the other node, so `Set-Disk -IsOffline` on the copy can take the original's disk offline on the other node. `diskpart` only touches the machine's own disks.
- **On a cluster node the storage cmdlets also list the other node's disks and volumes.** The scripts keep only local disks (those with a disk number) when they look a disk up from a drive letter.
- **dbatools reports SQL errors as warnings.** `Invoke-DbaQuery` does not throw unless `-EnableException` is given, so every query here has it. Without it, "stop at the first error" does not cover SQL statements.
- **Do not pipe FlashArray cmdlets into `Select-Object -First`.** In Windows PowerShell 5.1 it can end a script silently. The scripts take the first item from an array instead.
- **Hot-added disks can take a while to appear.** The scripts say where to wait and give a command to check. Run it until every new disk is listed, then continue.
- The snapshot is a protection group snapshot, so the database disks (one FlashArray volume each) share one point in time. The script makes the protection group the first time it runs and keeps it for the runs after. If you already have a group that holds these volumes, comment out the creation and set `$ProtectionGroupName`. Every volume in a group is snapshotted, not only the source volumes.

**Important Usage Notes:**

The script stops at the first error, because later steps remove and overwrite things. It is meant to be read and adapted, and the sections can be run one after the other. Do not run it unchanged against production.

---

**Disclaimer:**

This example script is provided AS-IS and is meant to be a building block to be adapted to fit an individual organization's infrastructure.
