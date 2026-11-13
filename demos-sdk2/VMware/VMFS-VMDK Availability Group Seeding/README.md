# VMFS-VMDK Availability Group Seeding

This folder holds an example script that seeds a secondary replica of a SQL Server availability group from a FlashArray snapshot, when both replicas keep their database files on VMDKs in VMware VMFS datastores.

**Files:**
- `VMFS-VMDK Availability Group Seeding.ps1` - freezes the databases on the primary with the T-SQL snapshot backup, takes a snapshot of the datastore's FlashArray volume, attaches a clone of it to the secondary VM, restores the databases there with `METADATA_ONLY` and `NORECOVERY`, bridges the gap with one log backup per database, adds the databases to the group, and cleans up the temporary clone

---

## VMFS-VMDK Availability Group Seeding.ps1

**Scenario:**

Two SQL Server VMs are replicas in an availability group. You want to add large databases to the group without streaming them across the network. On the primary the script freezes the databases with SQL Server 2022's T-SQL Snapshot Backup, takes a snapshot of the datastore's FlashArray volume and releases the freeze with a metadata-only backup. It clones the snapshot and resignatures the copy. The copied VMDKs are given new IDs (a new VMDK UUID and a new GPT disk GUID, the latter on a helper VM that is not in the cluster), and are then attached to the secondary VM in place of any earlier copy, with the same drive letters the primary uses. The databases are restored on the secondary `WITH METADATA_ONLY, NORECOVERY`, one log backup per database bridges the time since the snapshot, and the databases are added to the group and joined on the secondary. Finally the VMDKs are Storage vMotioned onto the secondary's own datastore and the temporary clone is removed.

**What you type in, and what the script looks up:**

You name the vCenter, the FlashArray, the two VMs and their SQL Servers, the availability group, the databases, the secondary's own datastore and a share. On the primary the script follows the chain from the database files to the Windows drive, the disk serial number, the VMDK, the datastore, the FlashArray volume and its host group.

**Prerequisites:**

1. PowerShell modules: `dbatools`, `PureStoragePowerShellSDK2` and VMware PowerCLI.
2. SQL Server 2022 or later on both replicas, with the availability group already created and both instances joined as replicas.
3. The databases are online on the primary, in **full recovery**, not yet in the group, and all on VMDKs in one datastore.
4. A share both SQL Servers can reach, for the metadata backup files and one small log backup per database.
5. The secondary VM has free SCSI slots. **Any database of the same name on the secondary, and the VMDKs that hold it, are removed by the script.**
6. Database files are on drive letters, and the secondary must be able to use the same letters as the primary.
7. A helper VM: any Windows VM on the same ESXi host as the secondary that is **not** a node of the failover cluster, with free SCSI slots, VMware Tools running and a login that can run commands in it. It is reached through VMware Tools, so it needs no remoting or DNS setup.

**What a DBA needs to know:**

- **The snapshot has to be application-consistent.** A crash-consistent snapshot has no metadata backup to restore with `METADATA_ONLY`, and attaching the copied files (`FOR ATTACH`) runs crash recovery and brings the database online. A database that is online cannot take a log restore or join the group, which both need it in the RESTORING state. A copy-only snapshot (`SUSPEND_FOR_SNAPSHOT_BACKUP = ON (MODE = COPY_ONLY)`) seeds the group the same way and leaves the differential base alone. Start the log chain with a regular full backup first.
- **The log chain.** Switching a database from simple to full recovery does not start a log chain until the first full backup. The metadata-only backup counts as that full backup. The log backup after it is what lets the secondary catch up, so a snapshot-based seed still needs one log backup file per database, even though no data is backed up.
- **The replicas log in to each other as their computer accounts.** With the default virtual service account (`NT Service\MSSQLSERVER`), each replica needs a login for the other's computer account (for example `DOMAIN\SQL02$`) with `CONNECT` on the Always On endpoint, otherwise the secondary stays Disconnected with "does not have CONNECT permission on the endpoint" in the error log. Creating the group with `New-DbaAvailabilityGroup` does not create these logins.
- **Why a helper VM.** A copy of a disk has the same VMDK UUID (the Windows disk serial number) and the same GPT disk GUID as the original. The two replicas are nodes of one failover cluster, and a cluster node does not mount a disk whose identity matches a disk on another node: the disk attaches, but no volume appears, and its GPT GUID cannot be changed there. The IDs therefore have to be changed before the disk reaches the secondary. The UUID is changed with one vSphere API call, and the GPT GUID with `diskpart` on a machine where the copy is visible, which is the helper VM.
- **Same drive letters.** The metadata restore looks for the files at their original paths, so the copies on the secondary are given the primary's drive letters.
- **An earlier copy must go first.** A copy of a disk must never sit beside an earlier copy of it on the same VM, because both carry the same VMDK UUID and GPT disk GUID. The script finds and removes the secondary's old database disks before attaching the new ones.
- **The freeze is tied to the SQL Server session.** The primary uses a persistent, non-pooled `Connect-DbaInstance` connection so the freeze and the metadata backup share one session.
- **The freeze lasts as long as the snapshot plus the metadata backups.**
- **The seeded VMDKs end up on the secondary's own datastore**, and the temporary clone is removed, so the secondary does not depend on a clone volume.

**Things learned the hard way, in every script in this repository:**

- **Windows disk changes use `diskpart`, not `Set-Disk`.** On a failover cluster node the storage cmdlets work through the cluster's view of storage. A copy of a disk has the same ID as the original on the other node, so `Set-Disk -IsOffline` on the copy can take the original's disk offline on the other node. `diskpart` only touches the machine's own disks.
- **On a cluster node the storage cmdlets also list the other node's disks and volumes.** The scripts keep only local disks (those with a disk number) when they look a disk up from a drive letter.
- **dbatools reports SQL errors as warnings.** `Invoke-DbaQuery` does not throw unless `-EnableException` is given, so every query here has it. Without it, "stop at the first error" does not cover SQL statements.
- **Do not pipe FlashArray cmdlets into `Select-Object -First`.** In Windows PowerShell 5.1 it can end a script silently. The scripts take the first item from an array instead.
- **Hot-added disks can take a while to appear.** The scripts say where to wait and give a command to check. Run it until every new disk is listed, then continue.
- The snapshot is of one volume, the datastore's. If a server's database VMDKs are spread over several VMFS datastores, take the snapshot through a protection group so the volumes share one point in time. These scripts expect one datastore, so that case needs the lookups and the clone steps repeated for each datastore.

**Important Usage Notes:**

The script stops at the first error, because later steps delete and move real disks. It is meant to be read and adapted. Do not run it unchanged against production.

---

**Disclaimer:**

This example script is provided AS-IS and is meant to be a building block to be adapted to fit an individual organization's infrastructure.

_The contents of this folder are intended as examples only and should be modified to work in your individual environments. No script examples should be used in a production environment without fully testing them in a development or lab environment._
