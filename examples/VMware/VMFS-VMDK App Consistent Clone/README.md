# VMFS-VMDK App Consistent Clone

This folder holds an example script that copies SQL Server databases from one VM to another with an **application-consistent** FlashArray snapshot, when the database files are on VMDKs in a VMware VMFS datastore.

**Files:**
- `VMFS-VMDK App Consistent Clone.ps1` - freezes the databases with SQL Server's T-SQL snapshot backup, takes a snapshot of the datastore's FlashArray volume, releases the freeze with a metadata-only backup, then clones and attaches the copy to a second SQL Server VM

---

## VMFS-VMDK App Consistent Clone.ps1

**Scenario:**

A source SQL Server VM keeps its database files on VMDKs in a VMFS datastore, and that datastore is one FlashArray volume. A second SQL Server VM needs a copy of those databases, for example for dev/test or to seed an availability group. The script uses SQL Server 2022 and later T-SQL Snapshot Backup to make the snapshot application consistent. The databases are frozen for write IO, the FlashArray snapshot is taken, and a metadata-only backup releases the freeze. The snapshot is then cloned, presented to the ESXi host, resignatured, and the VMDKs are hot-added to the target VM, where the databases are attached under new names.

Writes to the source are held only for the moments between the freeze and the metadata backup. The script prints how long that was. Because the databases were frozen cleanly, the copies do not need crash recovery.

**What you type in, and what the script looks up:**

You name the vCenter, the FlashArray, the two VMs, the two SQL Servers, the databases and a share for the metadata files. Everything else is looked up: the Windows drive of each database file, the disk serial number (the VMDK's UUID), the VMDK, the datastore, the FlashArray volume and its host group.

**Prerequisites:**

1. PowerShell modules: `dbatools`, `PureStoragePowerShellSDK2` and VMware PowerCLI.
2. SQL Server 2022 or later on the source.
3. PowerShell remoting (WinRM) to both VMs, and a SQL Server login that can attach databases on the target.
4. All of the listed databases must be on VMDKs in one datastore.
5. A share the source SQL Server can write to, for the small metadata backup files.
6. The target VM must be a different VM from the source and have free SCSI slots for hot-adding disks.
7. Database files must be on drive letters, not mount points, and the databases must not exist on the target yet.

**What a DBA needs to know:**

- The freeze is tied to the SQL Server session. The freeze and the metadata backup must use the same session, so the script uses a persistent, non-pooled `Connect-DbaInstance` connection for them. A normal cmdlet disconnects at once and would release the freeze before the snapshot is taken.
- Every database you list is frozen until its own metadata backup runs. All the freezes are taken first, then the snapshot, then all the backups, so the window is as short as the snapshot.
- The metadata file records which snapshot belongs to it (in `MEDIADESCRIPTION`). That is what you would use later to find the snapshot again.
- The copied disks arrive in Windows offline and read-only. The script sets them online and writable.

**Things learned the hard way, in every script in this repository:**

- **dbatools reports SQL errors as warnings.** `Invoke-DbaQuery` does not throw unless `-EnableException` is given, so every query here has it. Without it, "stop at the first error" does not cover SQL statements.
- **Do not pipe FlashArray cmdlets into `Select-Object -First`.** In Windows PowerShell 5.1 it can end a script silently. The scripts take the first item from an array instead.
- **Hot-added disks can take a while to appear.** The scripts say where to wait and give a command to check. Run it until every new disk is listed, then continue.
- The snapshot is of one volume, the datastore's. If a server's database VMDKs are spread over several VMFS datastores, take the snapshot through a protection group so the volumes share one point in time. These scripts expect one datastore, so that case needs the lookups and the clone steps repeated for each datastore.

**Important Usage Notes:**

The script stops at the first error, because later steps change real disks. It is meant to be read and adapted. Do not run it unchanged against production.

---

**Disclaimer:**

This example script is provided AS-IS and is meant to be a building block to be adapted to fit an individual organization's infrastructure.

_The contents of this folder are intended as examples only and should be modified to work in your individual environments. No script examples should be used in a production environment without fully testing them in a development or lab environment._
