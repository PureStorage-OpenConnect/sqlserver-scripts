# PVC Block In-Place Restore

This folder holds an example script that puts SQL Server databases back to an earlier FlashArray snapshot on the same OpenShift Virtualization VM, when the database files are on block-mode PersistentVolumeClaims (each PVC is a FlashArray volume attached to the VM as a virtual disk).

**Files:**
- `PVC Block In-Place Restore.ps1` offlines the databases and disks, overwrites each FlashArray volume from its snapshot, and brings everything back online

---

## PVC Block In-Place Restore.ps1

**Scenario:**

A SQL Server VM keeps its database files on block-mode PVCs. A FlashArray snapshot of those volumes was taken earlier (a restore point). The databases have since been damaged or changed, and you want them back as they were at the restore point, on the same VM, under the same names. The script takes the databases offline, takes the disks offline in Windows, overwrites each FlashArray volume from its snapshot, and brings the disks and the databases back online. Everything after the restore point is lost.

**What you type in, and what the script looks up:**

You name the OpenShift API endpoint and project, the FlashArray, the VM, the SQL Server and the databases, you give an OpenShift API token, and optionally you name which restore point to use. Everything else is looked up. Database files lead to a Windows drive, then to the Windows disk serial number, then to the PVC, then to the PVC's uid, then to the FlashArray volume, then to its snapshots. The disk serial number is a field on the VM disk, and the script expects it to be the PVC name. By default the script restores the newest snapshot suffix that exists on every volume.

**Prerequisites:**

1. PowerShell modules `dbatools` and `PureStoragePowerShellSDK2`.
2. PowerShell remoting (WinRM) to the VM, and a SQL Server login that can take the databases offline.
3. An OpenShift API token for an account that can read PVCs and VMs in the project, for example the token that `oc login` uses.
4. Every disk that holds the listed databases is a block-mode PVC from the Portworx FlashArray storage class (backend `pure_block`), attached to the VM as a virtual disk with the `serial` field set to the PVC name, and those volumes are in a protection group. A restore point is a snapshot of that group, for example `New-Pfa2ProtectionGroupSnapshot -SourceName <group> -Suffix before-upgrade`.
5. Nothing else uses those disks. Every database with files on them must be listed in the script, or the restore fails.
6. Database files on drive letters.

**What a DBA needs to know:**

- **Nothing changes in OpenShift.** The PVCs, the VM disks, the serial numbers and the drive letters stay the same. The volume is overwritten with `New-Pfa2Volume -Overwrite`, and the array keeps the volume's name, serial number and connections. No OpenShift object is changed.
- **Take the disks offline in Windows first.** The overwrite replaces what the guest has read and cached. The script takes the databases offline and then the disks offline in Windows before it overwrites anything, and brings the disks back online afterwards so Windows reads the old contents.
- **There is a way back.** Before it overwrites a volume, the FlashArray can save the volume's previous contents as a destroyed snapshot named `<volume>.copy.<n>`. It stays for the eradication period, so confirm that on your Purity version before you rely on it.
- **The restore point is a protection group snapshot,** so the database disks (one FlashArray volume each) share one point in time. A snapshot of a protection group names its volume snapshots `<group>.<suffix>.<volume>`, and the script restores each volume from its member. By default the newest snapshot of the group is used. The group can hold other volumes too, but only the volumes behind the listed databases are restored.
- **Set a serial number on every database disk.** A virtual disk has no FlashArray identity of its own in the guest. The script finds a disk's volume through the `serial` field of the VM disk, which Windows reports as the disk's serial number, so set it to the PVC name when you define the VM. A virtio block device reports at most 20 characters of serial number, so keep the PVC names of database disks short.
- The databases are offline from the start of the restore until the disks are back online. Set the `$SnapshotSuffix` variable to choose a specific restore point, `$ProtectionGroupName` to name the group, and check the restore point the script prints.
- Destroyed FlashArray objects stay on the array until the eradication period ends.

**Important Usage Notes:**

The script stops at the first error, because it overwrites data. It is meant to be read and adapted, and the sections can be run one after the other. Do not run it unchanged against production.

---

**Disclaimer:**

This example script is provided AS-IS and is meant to be a building block to be adapted to fit an individual organization's infrastructure.
