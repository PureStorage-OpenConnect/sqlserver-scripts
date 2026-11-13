# VMFS-VMDK Crash Consistent Clone

This folder holds an example script that copies SQL Server databases from one VM to another with a FlashArray snapshot, when the database files are on VMDKs in a VMware VMFS datastore.

**Files:**
- `VMFS-VMDK Crash Consistent Clone.ps1` - crash-consistent snapshot of a datastore's FlashArray volume, cloned and attached to a second SQL Server VM

---

## VMFS-VMDK Crash Consistent Clone.ps1

**Scenario:**

A source SQL Server VM keeps its database files on VMDKs in a VMFS datastore, and that datastore is one FlashArray volume. A second SQL Server VM needs a copy of some of those databases, for example for dev/test. The script takes a crash-consistent snapshot of the source volume, clones it as a new volume, presents it to the ESXi host, resignatures the copy, hot-adds the VMDKs that hold the databases to the target VM, and attaches the databases there under new names.

The source SQL Server is not touched and stays online. SQL Server write IO is not frozen before the snapshot, so each database performs crash recovery when it is attached on the target, as it would after a power loss.

**What you type in, and what the script looks up:**

You name the vCenter, the FlashArray, the two VMs, the two SQL Servers and the databases. Everything else is looked up. The script follows the chain from the database files to the Windows drive, to the Windows disk serial number, to the VMDK, to the datastore, to the FlashArray volume and to its host group. The step that makes this possible is that the Windows disk serial number is the VMDK's UUID with the dashes removed.

**Prerequisites:**

1. PowerShell modules: `dbatools`, `PureStoragePowerShellSDK2` and VMware PowerCLI.
2. PowerShell remoting (WinRM) to both VMs, and a SQL Server login that can attach databases on the target.
3. All of the listed databases must be on VMDKs in one datastore. The snapshot covers everything in that datastore, and every VMDK that holds one of the listed databases is copied.
4. The target VM must be a different VM from the source VM and have free SCSI slots for hot-adding disks.
5. Database files must be on drive letters, not mount points, and the databases must not already exist on the target.

**What a DBA needs to know:**

- Three people usually own the steps: the storage admin (snapshot, volume, host connection), the VMware admin (rescan, resignature, add the disks) and the DBA (bring the disks online, attach the databases). The script does all of them, so it needs rights in all three places.
- The copied disks arrive in Windows offline and read-only, because of the Windows SAN policy. The script sets them online and writable.
- The copy of a VMFS datastore has the same label as the original. The resignature step names the exact label, because a host can show other unresolved volumes at the same time.
- A resignatured datastore is named `snap-<id>-<original name>`.

**Credentials:**

The script asks for one credential and uses it for vCenter, the FlashArray and both VMs. That only works if the same account name is accepted everywhere. If your FlashArray wants a different form of the user name than vCenter or Windows (for example `user` against `DOMAIN\user`), prompt for a second credential and pass it to `Connect-Pfa2Array`.

**Things learned the hard way, in every script in this repository:**

- **dbatools reports SQL errors as warnings.** `Invoke-DbaQuery` does not throw unless `-EnableException` is given, so every query here has it. Without it, "stop at the first error" does not cover SQL statements.
- **Do not pipe FlashArray cmdlets into `Select-Object -First`.** In Windows PowerShell 5.1 it can end a script silently. The scripts take the first item from an array instead.
- **Hot-added disks can take a while to appear.** The scripts say where to wait and give a command to check. Run it until every new disk is listed, then continue.
- The snapshot is of one volume, the datastore's. If a server's database VMDKs are spread over several VMFS datastores, take the snapshot through a protection group so the volumes share one point in time. These scripts expect one datastore, so that case needs the lookups and the clone steps repeated for each datastore.

**Important Usage Notes:**

The script stops at the first error, because later steps remove and overwrite things. It is meant to be read and adapted, and the sections can be run one after the other. Do not run it unchanged against production.

---

**Disclaimer:**

This example script is provided AS-IS and is meant to be a building block to be adapted to fit an individual organization's infrastructure.

_The contents of this folder are intended as examples only and should be modified to work in your individual environments. No script examples should be used in a production environment without fully testing them in a development or lab environment._
