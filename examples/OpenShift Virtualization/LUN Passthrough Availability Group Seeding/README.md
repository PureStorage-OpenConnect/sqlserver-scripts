# LUN Passthrough Availability Group Seeding

This folder holds an example script that adds SQL Server databases to an availability group on OpenShift Virtualization by seeding the secondary replica from a FlashArray snapshot, when the database files are on block-mode PersistentVolumeClaims (each PVC is a FlashArray volume attached to the VM as a LUN passthrough disk, so the guest sees the FlashArray volume itself). No database is streamed over the network.

**Files:**
- `LUN Passthrough Availability Group Seeding.ps1` application-consistent snapshot of the primary's database volumes (using the T-SQL snapshot backup feature), cloned, imported into OpenShift as PVCs and hot-plugged into the secondary VM, then restored with `METADATA_ONLY` and added to the group

---

## LUN Passthrough Availability Group Seeding.ps1

**Scenario:**

Two SQL Server VMs (primary and secondary replica) each keep their database files on block-mode PVCs attached to the VM as LUN passthrough disks. You want to add a large database to an existing availability group without streaming it over the network. The script freezes the databases on the primary with the T-SQL snapshot backup feature, takes one FlashArray snapshot of every volume that holds them, and releases the freeze with a metadata-only backup. It clones each snapshot as a new volume, imports each clone as a PVC and hot-plugs it into the secondary VM. Each copy gets a new disk GUID before it is onlined, and the same drive letter the primary uses. The script restores the databases on the secondary with `METADATA_ONLY` and `NORECOVERY`, bridges the gap with one log backup per database, and adds the databases to the group. The cloned volumes stay in place as the secondary's database volumes.

**What you type in, and what the script looks up:**

You name the OpenShift API endpoint and project, the FlashArray, the storage class, the two VMs, the SQL Servers, the availability group, the databases and a share, and you give an OpenShift API token. Everything else is looked up. Database files lead to a Windows drive, then to the Windows disk serial number, which is the FlashArray volume's serial number, then to the FlashArray volume, then to its PVC.

**Prerequisites:**

1. PowerShell modules `dbatools` and `PureStoragePowerShellSDK2`.
2. SQL Server 2022 or later on both replicas. The availability group exists and both instances are replicas.
3. The databases are online on the primary in full recovery, and every database disk is a block-mode PVC from the Portworx FlashArray storage class (backend `pure_block`), attached to the VM as a LUN passthrough disk (a `lun` disk on the SCSI bus). The databases are not yet in the availability group and do not exist on the secondary.
4. A share both SQL Servers can reach, for the metadata backup files and one small log backup per database.
5. PowerShell remoting (WinRM) to both VMs, and an OpenShift API token for an account that can read and change VMs and PVCs in the project, for example the token that `oc login` uses.
6. The secondary VM can hot-plug disks and can use the same drive letters as the primary.

**What a DBA needs to know:**

- **The log chain.** Switching from simple to full recovery does not start a log chain until the first full backup. The metadata-only backup counts as that backup. The log backup after it lets the secondary catch up, so a snapshot seed still needs one log backup file per database even though no data is backed up.
- **Endpoint logins.** The replicas connect as their computer accounts. With the default virtual service account (`NT Service\MSSQLSERVER`), each replica needs a login for the other's computer account (for example `DOMAIN\SQL02$`) with `CONNECT` on the Always On endpoint. Otherwise the secondary stays Disconnected. `New-DbaAvailabilityGroup` does not create these logins.
- **Why the new disk GUID comes first.** The two replicas are nodes of one failover cluster, and a cluster node does not mount a disk whose identity matches a disk on another node. The script sets the new GUID with `diskpart` while the disk is still offline, then onlines it and gives it the primary's drive letter, because the metadata restore looks for the files at their original paths.
- **The freeze is tied to the SQL Server session.** The freeze and the metadata backup must run in the same session, so the script uses a persistent, non-pooled `Connect-DbaInstance` connection for the primary.
- **Keep the freeze short.** All databases are frozen first, then one snapshot, then all metadata backups. The array is not asked about the snapshots until the freeze is released. Measure the freeze under your own write load, and run a manual `CHECKPOINT` on each database just before the freeze.
- **The metadata file records the protection group snapshot.** `MEDIADESCRIPTION` holds the protection group snapshot name and the array. It holds at most 255 characters, and snapshot names are long, so the one group snapshot name is recorded, not one name for every volume.
- **The guest sees the FlashArray volume itself.** A LUN passthrough disk reports as `PURE FlashArray` with the volume's own serial number, so the script finds the volume from the Windows disk serial number and the VM disk needs no serial field.
- **Multipath I/O inside the VM must not claim a LUN passthrough disk.** The guest sees the array's real device identity, so a multipath claim for `PURE FlashArray` in the VM image would match a disk that has one path on a virtual bus, and Windows can hide it. Check the image for such a claim.
- **A clone becomes a PVC through an annotation.** A PVC with the annotation `pure_vol_name: <volume>` tells Portworx to use the existing FlashArray volume instead of creating an empty one. The PVC size has to match the size of the volume.
- The seeded disks end up as the secondary's own database PVCs, so the secondary does not depend on a clone that is removed later.

**Important Usage Notes:**

The script stops at the first error, because later steps remove and overwrite things. It is meant to be read and adapted, and the sections can be run one after the other. Do not run it unchanged against production.

---

**Disclaimer:**

This example script is provided AS-IS and is meant to be a building block to be adapted to fit an individual organization's infrastructure.
