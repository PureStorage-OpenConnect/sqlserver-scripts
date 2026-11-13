# iSCSI Availability Group Seeding

This folder holds an example script that seeds an availability group replica from a FlashArray snapshot, when the database files on both replicas are on disks the guest reaches over iSCSI.

**Files:**
- `iSCSI Availability Group Seeding.ps1` - freeze, snapshot, clone to the secondary's host, new disk GUID, restore with `METADATA_ONLY`, bridge with one log backup, add to the group

---

## iSCSI Availability Group Seeding.ps1

**Scenario:**

Two SQL Server VMs, the primary and the secondary replica of an existing availability group, keep their database files on iSCSI disks, each its own FlashArray volume. You want to add a large database to the group without sending it over the network. The script freezes the databases on the primary with T-SQL snapshot backup, takes one snapshot of all the volumes that hold them, and releases the freeze with a metadata-only backup. Each snapshot is cloned as a new volume and connected to the secondary's host, with a new disk GUID and the same drive letter the primary uses. On the secondary the databases are restored `WITH METADATA_ONLY, NORECOVERY`, one log backup bridges the time since the snapshot, and the databases are added to the group.

The cloned volumes stay where they are. They become the secondary's database volumes.

**What you type in, and what the script looks up:**

You name the FlashArray, the two VMs, the two SQL Servers, the availability group, the databases and a share. Everything else is looked up: database files, to Windows drive, to Windows disk serial number, to FlashArray volume. The secondary's FlashArray host is found from the iSCSI initiator name (IQN) that the secondary reports.

**Prerequisites:**

1. PowerShell modules: `dbatools` and `PureStoragePowerShellSDK2`.
2. SQL Server 2022 or later on both replicas. The availability group exists and both instances are replicas. Each replica's login for the other's computer account has CONNECT on the Always On endpoint (without it the secondary stays Disconnected).
3. The databases are online on the primary in FULL recovery, not yet in the group and not on the secondary. Every database disk is a FlashArray volume presented with the Microsoft iSCSI initiator.
4. A share both SQL Servers can reach, for the metadata backups and one small log backup per database.
5. The secondary is already logged in to the array's iSCSI portals, is a host on the FlashArray identified by its IQN, and has the primary's drive letters free.

**What a DBA needs to know:**

- **The snapshot has to be application-consistent.** A crash-consistent snapshot has no metadata backup to restore with `METADATA_ONLY`, and attaching the copied files (`FOR ATTACH`) runs crash recovery and brings the database online. A database that is online cannot take a log restore or join the group, which both need it in the RESTORING state. A copy-only snapshot (`SUSPEND_FOR_SNAPSHOT_BACKUP = ON (MODE = COPY_ONLY)`) seeds the group the same way and leaves the differential base alone. Start the log chain with a regular full backup first.
- **The copy must get a new disk GUID before it is onlined.** The two replicas are nodes of one failover cluster, and a cluster node does not mount a disk whose identity matches a disk on another node. `diskpart` with `uniqueid disk id=<new GUID>` on the offline disk is enough.
- The metadata restore looks for the files at their original paths, so the script sets the copy's drive letters to the primary's.
- No database backup is needed. The metadata-only backup plus one log backup is the whole seed. The databases must be in FULL recovery or the log backup is not possible.
- The clones are named `<source volume>-seed`.
- **Windows disk changes use `diskpart`, not `Set-Disk`, on a failover cluster node.** The storage cmdlets work through the cluster's view of storage, and a copy has the same ID as the original on the other node, so `Set-Disk -IsOffline` on the copy can take the original's disk offline on the other node. The script also keeps only local disks (those with a disk number) when it looks a disk up from a drive letter.

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
