# LUN Passthrough Same-VM Clone

This folder holds an example script that copies SQL Server databases to the same SQL Server instance with a FlashArray snapshot, when the database files are on block-mode PersistentVolumeClaims (each PVC is a FlashArray volume attached to the VM as a LUN passthrough disk, so the guest sees the FlashArray volume itself) on OpenShift Virtualization.

**Files:**
- `LUN Passthrough Same-VM Clone.ps1` crash-consistent snapshot of the database volumes, cloned, imported into OpenShift as PVCs and hot-plugged into the same VM

---

## LUN Passthrough Same-VM Clone.ps1

**Scenario:**

A SQL Server VM keeps its database files on block-mode PVCs attached to the VM as LUN passthrough disks. You want a copy of those databases on the same SQL Server instance, for example to test a change or to pull back a table that was deleted by mistake. The script takes one crash-consistent snapshot of every volume that holds the databases, clones each as a new FlashArray volume, imports each clone into OpenShift as a PVC, hot-plugs the PVCs into the same VM as new disks, gives each copy a new disk GUID while it is offline, onlines it and attaches the databases as `<name>_copy`. The originals stay online throughout. Write IO is not frozen, so each database performs crash recovery when it is attached.

**What you type in, and what the script looks up:**

You name the OpenShift API endpoint and project, the FlashArray, the storage class, the VM, the SQL Server and the databases, and you give an OpenShift API token. Everything else is looked up. Database files lead to a Windows drive, then to the Windows disk serial number, which is the FlashArray volume's serial number, then to the FlashArray volume, then to its PVC.

**Prerequisites:**

1. PowerShell modules `dbatools` and `PureStoragePowerShellSDK2`.
2. PowerShell remoting (WinRM) to the VM, and a SQL Server login that can attach databases.
3. An OpenShift API token for an account that can read and change VMs and PVCs in the project, for example the token that `oc login` uses.
4. Every disk that holds the listed databases is a block-mode PVC from the Portworx FlashArray storage class (backend `pure_block`), attached to the VM as a LUN passthrough disk (a `lun` disk on the SCSI bus).
5. The VM can hot-plug disks and has free drive letters for the copies.
6. Database files on drive letters, and the copies must not exist yet.

**What a DBA needs to know:**

- Three people usually own the steps here. The storage admin owns the snapshot and the volume. The OpenShift admin owns the PVC and attaching the disk to the VM. The DBA owns the disks in Windows and the databases. The script does all three.
- **A new disk GUID is the whole fix.** A copy of a disk has the same disk GUID as the original. Windows hides a copy like that, keeps it offline and write-protected, and at the next reboot it can take the production disk offline instead. The script gives each copy a new GUID with `diskpart` (`uniqueid disk id=<new GUID>`) before it is onlined. The copy is a new FlashArray volume and a new PVC, so it already has its own serial number.
- **The guest sees the FlashArray volume itself.** A LUN passthrough disk reports as `PURE FlashArray` with the volume's own serial number, so the script finds the volume from the Windows disk serial number and the VM disk needs no serial field.
- **Multipath I/O inside the VM must not claim a LUN passthrough disk.** The guest sees the array's real device identity, so a multipath claim for `PURE FlashArray` in the VM image would match a disk that has one path on a virtual bus, and Windows can hide it. Check the image for such a claim.
- **A clone becomes a PVC through an annotation.** A PVC with the annotation `pure_vol_name: <volume>` tells Portworx to use the existing FlashArray volume instead of creating an empty one. The PVC size has to match the size of the volume. Portworx binds the PVC when the VM first uses it.
- **Deleting the PVC deletes the clone.** The storage class reclaims volumes on delete, so removing the clone PVC also deletes and eradicates the FlashArray volume behind it. The originals are not touched.
- The snapshot is a protection group snapshot, so the database disks (one FlashArray volume each) share one point in time. The script makes the protection group the first time and keeps it for the runs after. If you already have a group that holds these volumes, comment out the creation and set the group name. Every volume in a group is snapshotted, not only the source volumes.
- The copies get the next free drive letters, because the originals keep theirs. The script reads the letters back and uses them.
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
