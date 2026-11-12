# VMFS-VMDK Same-VM Clone

This folder holds an example script that attaches a point-in-time copy of SQL Server databases **beside the live ones on the same SQL Server VM**, when the database files are on VMDKs in a VMware VMFS datastore. The typical reason is recovering data from an earlier point in time without overwriting current data.

**Files:**
- `VMFS-VMDK Same-VM Clone.ps1` - crash-consistent snapshot of the datastore's FlashArray volume, cloned, given new disk IDs and attached to the same VM

---

## VMFS-VMDK Same-VM Clone.ps1

**Scenario:**

A SQL Server VM keeps its database files on VMDKs in a VMFS datastore, and that datastore is one FlashArray volume. You want a copy of some of those databases attached next to the live ones, for example to read yesterday's rows. The script takes a crash-consistent snapshot of the volume, clones it, presents it to the ESXi host, resignatures the copy, changes the IDs that would otherwise collide, attaches the copied VMDKs to the same VM, and attaches the databases under new names.

The live databases stay online. SQL Server write IO is not frozen before the snapshot, so each copy performs crash recovery when it is attached.

**Why this is not just "attach the copy":**

A snapshot copy of a disk carries two identifiers that the VM already has:

1. **The VMDK UUID.** vSphere refuses to attach a second disk with the same UUID to the same VM ("Virtual disks ... have the same UUID"). The script gives each copy a new UUID with one vSphere API call (`VirtualDiskManager.SetVirtualDiskUuid`), so no SSH access to a host is needed.
2. **The GPT disk GUID inside the disk.** If two disks with the same GUID are attached to one Windows VM, Windows hides the duplicate from disk management, and after a restart it can keep the copy online and take the **production disk** offline instead. On a VM that holds the originals the copy cannot be repaired, because it is hidden and write-protected. The script therefore attaches the copies to a second VM first, where they are visible, changes the disk GUID with `diskpart` (`uniqueid disk`), and then attaches them to the source VM.

Changing only the disk GUID is enough. The partition GUIDs stay the same as the originals, and Windows still gave every volume its own volume GUID path.

**What you type in, and what the script looks up:**

You name the vCenter, the FlashArray, the SQL VM and its SQL Server, a helper VM, and the databases. Everything else is looked up: the Windows drive of each database file, the disk serial number (which is the VMDK's UUID), the VMDK, the datastore, the FlashArray volume and its host group.

**Prerequisites:**

1. PowerShell modules: `dbatools`, `PureStoragePowerShellSDK2` and VMware PowerCLI.
2. PowerShell remoting (WinRM) to the SQL VM, and a SQL Server login that can attach databases.
3. All of the listed databases must be on VMDKs in one datastore.
4. The helper VM is any other Windows VM on the same ESXi host. It never holds the originals. It is used only to change the GPT disk GUIDs, and both VMs need free SCSI slots for hot-adding disks. The helper is reached through VMware Tools, so it needs no remoting or DNS setup, only VMware Tools running and a login that can run commands in it.
5. Database files must be on drive letters, not mount points, and the copies must not already exist.

**What a DBA needs to know:**

- Several people usually own these steps: the storage admin (snapshot, volume, host connection), the VMware admin (rescan, resignature, UUIDs, add the disks) and the DBA or Windows admin (GUIDs, online the disks, attach the databases). The script does all of them.
- The copied disks arrive in Windows offline and read-only because of the Windows SAN policy, and are set online and writable.
- Drive letters of the copies are the next free ones, not the original letters. The script maps each file to its copy by disk serial number.
- SQL Server is often set to delayed automatic start, so after a restart the service can take a couple of minutes to appear.

**Things learned the hard way, in every script in this repository:**

- **dbatools reports SQL errors as warnings.** `Invoke-DbaQuery` does not throw unless `-EnableException` is given, so every query here has it. Without it, "stop at the first error" does not cover SQL statements.
- **Do not pipe FlashArray cmdlets into `Select-Object -First`.** In Windows PowerShell 5.1 it can end a script silently. The scripts take the first item from an array instead.
- **Hot-added disks can take a while to appear.** The scripts say where to wait and give a command to check. Run it until every new disk is listed, then continue.
- The snapshot is of one volume, the datastore's. If a server's database VMDKs are spread over several VMFS datastores, take the snapshot through a protection group so the volumes share one point in time. These scripts expect one datastore, so that case needs the lookups and the clone steps repeated for each datastore.

**Important Usage Notes:**

The script stops at the first error, because later steps change real disks. It is meant to be read and adapted. Do not run it unchanged against production. Do not attach a snapshot copy of a VMDK to the VM that holds the original without changing both IDs.

---

**Disclaimer:**

This example script is provided AS-IS and is meant to be a building block to be adapted to fit an individual organization's infrastructure.

_The contents of this folder are intended as examples only and should be modified to work in your individual environments. No script examples should be used in a production environment without fully testing them in a development or lab environment._
