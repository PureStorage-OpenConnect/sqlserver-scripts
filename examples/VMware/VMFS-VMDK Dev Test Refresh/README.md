# VMFS-VMDK Dev Test Refresh

This folder holds an example script that refreshes a copy of production SQL Server databases on a non-production SQL Server VM, on a schedule, when the database files are on VMDKs in a VMware VMFS datastore.

**Files:**
- `VMFS-VMDK Dev Test Refresh.ps1` - removes the copy the previous run made (if any), takes a crash-consistent snapshot of the source datastore's FlashArray volume, and attaches a clone of it to the target VM

---

## VMFS-VMDK Dev Test Refresh.ps1

**Scenario:**

A production SQL Server VM keeps its database files on VMDKs in a VMFS datastore, which is one FlashArray volume. A non-production SQL Server VM needs a fresh copy of those databases every night or on demand. The script can be run again and again. Each run removes the copy the previous run made and makes a new one. It takes a crash-consistent snapshot of the source volume, clones it, presents it to the ESXi host, resignatures the copy, hot-adds the VMDKs that hold the databases to the target VM and attaches the databases there. The source stays online, and SQL Server write IO is not frozen, so each database performs crash recovery when it is attached.

**Stable names make it repeatable:**

The previous copy is found by name, not by remembering anything between runs. The datastore is called `<source datastore>-devtest`, the databases are called `<database><suffix>` (`_dev` by default), and the snapshots have a `devtest-` suffix. The previous copy is removed in the reverse order of how it was made, which leaves no stale disk, datastore, path, volume or snapshot behind. On the first run there is nothing to remove. To remove the copy without making a new one, run only the "Remove the previous copy" section.

**What you type in, and what the script looks up:**

You name the vCenter, the FlashArray, the two VMs, the two SQL Servers and the databases. Everything else is looked up: the Windows drive of each database file, the disk serial number (the VMDK's UUID), the VMDK, the datastore, the FlashArray volume and its host group.

**Prerequisites:**

1. PowerShell modules: `dbatools`, `PureStoragePowerShellSDK2` and VMware PowerCLI.
2. PowerShell remoting (WinRM) to both VMs, and a SQL Server login that can attach and drop databases on the target.
3. All of the listed databases must be on VMDKs in one datastore.
4. The target VM must be a different VM from the source and have free SCSI slots for hot-adding disks.
5. Database files must be on drive letters, not mount points.

**What a DBA needs to know:**

- The target databases are dropped and recreated on every run, so anything changed in them is lost. Keep other databases on the target on different disks.
- The old clone volume and its snapshots are eradicated at once, not left for the array's eradication period, because a nightly refresh would otherwise pile up copies. If you want a safety net, remove the `-Eradicate` lines.
- The copied disks arrive in Windows offline and read-only, and are set online and writable with `Set-Disk`.
- Hot-added disks can take a while to show up in Windows. The script says where to wait and gives a command to check. Run it until every new disk is listed, then continue.
- The script stops at the first error, including SQL errors (`-EnableException` is set on every dbatools query).
- The snapshot is of one volume, the datastore's. If a server's database VMDKs are spread over several VMFS datastores, take the snapshot through a protection group so the volumes share one point in time. These scripts expect one datastore, so that case needs the lookups and the clone steps repeated for each datastore.

**Important Usage Notes:**

It is meant to be read and adapted. Do not run it unchanged against production.

---

**Disclaimer:**

This example script is provided AS-IS and is meant to be a building block to be adapted to fit an individual organization's infrastructure.

_The contents of this folder are intended as examples only and should be modified to work in your individual environments. No script examples should be used in a production environment without fully testing them in a development or lab environment._
