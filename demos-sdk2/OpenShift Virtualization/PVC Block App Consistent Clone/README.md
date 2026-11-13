# PVC Block App Consistent Clone

This folder holds an example script that copies SQL Server databases from one OpenShift Virtualization VM to another with a FlashArray snapshot, when the database files are on block-mode PersistentVolumeClaims (each PVC is a FlashArray volume attached to the VM as a virtual disk).

**Files:**
- `PVC Block App Consistent Clone.ps1` application-consistent snapshot of the database volumes (using the T-SQL snapshot backup feature), cloned, imported into OpenShift as PVCs and hot-plugged into a second VM

---

## PVC Block App Consistent Clone.ps1

**Scenario:**

A source SQL Server VM keeps its database files on block-mode PVCs. A second VM needs a copy of those databases, for example for dev/test. The script freezes the databases using the T-SQL snapshot backup feature, takes one FlashArray snapshot of every volume that holds them, and releases the freeze with a metadata-only backup. It then clones each snapshot as a new FlashArray volume, imports each clone into OpenShift as a PVC, hot-plugs the PVCs into the target VM, onlines the disks in the guest and attaches the databases under new names. The source stays online except for the short write freeze.

**What you type in, and what the script looks up:**

You name the OpenShift API endpoint and project, the FlashArray, the storage class, the two VMs, the SQL Servers, the databases and a share for the metadata files, and you give an OpenShift API token. Everything else is looked up. Database files lead to a Windows drive, then to the Windows disk serial number, then to the PVC, then to the PVC's uid, then to the FlashArray volume. The disk serial number is a field on the VM disk, and the script expects it to be the PVC name.

**Prerequisites:**

1. PowerShell modules `dbatools` and `PureStoragePowerShellSDK2`.
2. SQL Server 2022 or later on the source (the T-SQL snapshot backup feature).
3. PowerShell remoting (WinRM) to both VMs, and a SQL Server login that can attach databases on the target.
4. An OpenShift API token for an account that can read and change VMs and PVCs in the project, for example the token that `oc login` uses.
5. A share that the source SQL Server can write to, for the small metadata backup files.
6. Every disk that holds the listed databases is a block-mode PVC from the Portworx FlashArray storage class (backend `pure_block`), attached to the VM as a virtual disk with the `serial` field set to the PVC name.
7. The target VM is a different VM from the source, in the same project, and can hot-plug disks.
8. Database files on drive letters, and the databases must not exist on the target yet.

**What a DBA needs to know:**

- Three people usually own the steps here. The storage admin owns the snapshot and the volume. The OpenShift admin owns the PVC and attaching the disk to the VM. The DBA owns the disks in Windows and the databases. The script does all three.
- **The freeze is tied to the SQL Server session.** The freeze and the metadata backup must run in the same session, so the script uses a persistent, non-pooled `Connect-DbaInstance` connection. A normal cmdlet disconnects at once and would release the freeze before the snapshot exists.
- **Keep the freeze short.** All databases are frozen first, then one snapshot, then all metadata backups, so the window is about as long as the snapshot. The script prints how long writes were frozen. It also runs a manual `CHECKPOINT` on each database just before the freeze, which leaves little for the freeze to flush. The array is not asked about the snapshots until the freeze is released, so the window does not include those calls.
- **The metadata file records the protection group snapshot.** `MEDIADESCRIPTION` holds the protection group snapshot name and the array, which is how you find the snapshots later. It holds at most 255 characters. Snapshot names are long, so the one group snapshot name is recorded, not one name for every volume.
- **The copies are a clean point in time, but SQL Server can still recover them.** The freeze does not remove transactions that were open at that moment. When SQL Server attaches a copy it can still log that it rolled transactions forward or back. This is normal.
- **Set a serial number on every database disk.** A virtual disk has no FlashArray identity of its own in the guest. The script finds a disk's volume through the `serial` field of the VM disk, which Windows reports as the disk's serial number, so set it to the PVC name when you define the VM. A virtio block device reports at most 20 characters of serial number, so keep the PVC names of database disks short.
- **A clone becomes a PVC through an annotation.** A PVC with the annotation `pure_vol_name: <volume>` tells Portworx to use the existing FlashArray volume instead of creating an empty one. The PVC size has to match the size of the volume. Portworx binds the PVC when the VM first uses it.
- **Deleting the PVC deletes the clone.** The storage class reclaims volumes on delete, so removing the clone PVC also deletes and eradicates the FlashArray volume behind it. The source is not touched.
- The snapshot is a protection group snapshot, so the database disks (one FlashArray volume each) share one point in time. The script makes the protection group the first time and keeps it for the runs after. If you already have a group that holds these volumes, comment out the creation and set the group name. Every volume in a group is snapshotted, not only the source volumes.
- The copies get the next free drive letters on the target. The script reads the letters back and uses them.
- The OpenShift token is short-lived. Get a fresh one with `oc login` shortly before you run the script.

**Things learned the hard way:**

- **dbatools reports SQL errors as warnings.** `Invoke-DbaQuery` does not throw unless `-EnableException` is given, so every query here has it.
- **Do not pipe FlashArray cmdlets into `Select-Object -First`.** In Windows PowerShell 5.1 it can end a script silently. The scripts take the first item from an array instead.
- **New disks can take a while to appear.** The scripts say where to wait and give a command to check. Run it until every new disk is listed, then continue.

**Important Usage Notes:**

The script stops at the first error, because later steps remove and overwrite things. It is meant to be read and adapted, and the sections can be run one after the other. Do not run it unchanged against production.

---

**Disclaimer:**

This example script is provided AS-IS and is meant to be a building block to be adapted to fit an individual organization's infrastructure.
