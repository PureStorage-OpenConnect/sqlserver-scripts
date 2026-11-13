# PVC Block Dev Test Refresh

This folder holds an example script that refreshes a non-production SQL Server VM with a copy of production databases from a FlashArray snapshot, when the database files are on block-mode PersistentVolumeClaims (each PVC is a FlashArray volume attached to the VM as a virtual disk) on OpenShift Virtualization. It is meant to be run on a schedule.

**Files:**
- `PVC Block Dev Test Refresh.ps1` removes the previous copy, takes a crash-consistent snapshot of the database volumes, clones it, imports the clones as PVCs, hot-plugs them into the target VM and attaches the databases

---

## PVC Block Dev Test Refresh.ps1

**Scenario:**

A production SQL Server VM (the source) keeps its database files on block-mode PVCs. A non-production VM (the target) needs a fresh copy of those databases on a schedule, for example every night. The script can be run again and again. Each run removes the copy the previous run made and makes a new one from a new snapshot. The source stays online. Write IO is not frozen, so each database on the target performs crash recovery when it is attached.

**What you type in, and what the script looks up:**

You name the OpenShift API endpoint and project, the FlashArray, the storage class, the two VMs, the SQL Servers and the databases, and you give an OpenShift API token. Everything else is looked up. Database files lead to a Windows drive, then to the Windows disk serial number, then to the PVC, then to the PVC's uid, then to the FlashArray volume. The disk serial number is a field on the VM disk, and the script expects it to be the PVC name.

**Prerequisites:**

1. PowerShell modules `dbatools` and `PureStoragePowerShellSDK2`.
2. PowerShell remoting (WinRM) to both VMs, and a SQL Server login that can attach and drop databases on the target.
3. An OpenShift API token for an account that can read and change VMs and PVCs in the project, for example the token that `oc login` uses.
4. Every disk that holds the listed databases is a block-mode PVC from the Portworx FlashArray storage class (backend `pure_block`), attached to the source VM as a virtual disk with the `serial` field set to the PVC name.
5. The target VM is a different VM from the source, in the same project, and can hot-plug disks.
6. Database files on drive letters.

**What a DBA needs to know:**

- **Stable names make it repeatable.** Each clone PVC and FlashArray volume is called `<source PVC>-devtest`, the disks in the target VM have the serial numbers `devtest0`, `devtest1` and so on, the databases are called `<database>_dev`, and the protection group snapshots carry a `devtest-` suffix. The script finds the previous copy by the serial numbers on the target VM's disks.
- **Removing the previous copy comes first.** The script drops the dev databases, offlines the copied disks in Windows, detaches them from the running VM, deletes their PVCs and then deletes the previous run's protection group snapshot. To remove the copy without making a new one, run only the "Remove the previous copy" section.
- **Deleting a PVC deletes its FlashArray volume.** The storage class reclaims volumes on delete and the volume is eradicated at once, so a nightly refresh does not pile up copies on the array.
- The target databases are dropped and recreated on every run, so anything changed in them is lost. Keep other databases on the target on different disks.
- **Set a serial number on every database disk.** A virtual disk has no FlashArray identity of its own in the guest. The script finds a disk's volume through the `serial` field of the VM disk, which Windows reports as the disk's serial number, so set it to the PVC name when you define the VM. A virtio block device reports at most 20 characters of serial number, so keep the PVC names of database disks short.
- **A clone becomes a PVC through an annotation.** A PVC with the annotation `pure_vol_name: <volume>` tells Portworx to use the existing FlashArray volume instead of creating an empty one. The PVC size has to match the size of the volume.
- The copy is crash consistent. If you need it application consistent, use the freeze from the App Consistent Clone.
- The OpenShift token is short-lived. When the script runs on a schedule, give it a token for a service account.

**Important Usage Notes:**

The script stops at the first error, because later steps remove and overwrite things. It is meant to be read and adapted, and the sections can be run one after the other. Do not run it unchanged against production.

---

**Disclaimer:**

This example script is provided AS-IS and is meant to be a building block to be adapted to fit an individual organization's infrastructure.
