# RDM Same-VM Clone

This folder holds an example script that attaches a copy of SQL Server databases beside the live ones on the SAME VM, when the database files are on RDMs.

**Files:**
- `RDM Same-VM Clone.ps1` - crash-consistent snapshot, clone, new disk GUID, attach as <name>_copy on the same instance

---

## RDM Same-VM Clone.ps1

**Scenario:**

A SQL Server VM keeps its database files on RDMs. You want a copy on the same SQL Server instance, for example to test a change or recover a deleted table. The script snapshots the volumes together, clones them, adds the clones to the same VM as RDMs, gives each copy a new disk GUID while it is still offline, onlines it, and attaches the databases as `<name>_copy`.

**What you type in, and what the script looks up:**

You name the vCenter, the FlashArray, the VMs, the SQL Servers and the databases. Everything else is looked up: database files, to Windows drive, to Windows disk serial number, to FlashArray volume, to host group. For an RDM the Windows disk serial number is the FlashArray volume's serial number.

**Prerequisites:**

1. PowerShell modules: `dbatools`, `PureStoragePowerShellSDK2` and VMware PowerCLI.
2. PowerShell remoting (WinRM) to the VM, and a SQL Server login that can attach databases.
3. Every database disk is a FlashArray volume presented as an RDM.
4. Free SCSI slots and free drive letters on the VM.
5. Database files on drive letters, and the copies must not exist yet.

**What a DBA needs to know:**

- Three people usually own the steps: the storage admin (snapshot, volume, host connection), the VMware admin (rescan, add the RDM) and the DBA (bring the disks online, attach the databases). The script does all of them.
- An RDM copy is added in physical compatibility mode.
- The ESXi host needs a rescan before it sees a new volume, and the script rescans the host the target VM runs on. Each new volume is connected to the host group (all hosts that can run the VM), not to a single host, or vMotion and HA break.
- **The copy has the same disk GUID as the original, and Windows will not treat it as a normal disk.** It stays offline and write-protected (SAN policy), and at the next reboot Windows can take the production disk offline instead. The script runs `diskpart` with `uniqueid disk id=<new GUID>` while the copy is offline, then clears read-only and onlines it.
- With an RDM that is the only change needed, because the copy is a new FlashArray volume with its own serial number.
- `Set-Disk -Guid` is rejected with "Invalid Parameter". Use `diskpart`.

**Things learned the hard way, in every script in this repository:**

- **dbatools reports SQL errors as warnings.** `Invoke-DbaQuery` does not throw unless `-EnableException` is given, so every query here has it. Without it, "stop at the first error" does not cover SQL statements.
- **Do not pipe FlashArray cmdlets into `Select-Object -First`.** In Windows PowerShell 5.1 it can end a script silently. The scripts take the first item from an array instead.
- **Hot-added disks can take a while to appear.** The scripts say where to wait and give a command to check. Run it until every new disk is listed, then continue.
- The snapshot is a protection group snapshot, so the database disks (one FlashArray volume each) share one point in time. The script makes the protection group the first time and leaves it in place for the runs after. If you already have a group that holds these volumes, comment out the creation and set `$ProtectionGroupName`. Every volume in a group is snapshotted, not only the source volumes.

**Important Usage Notes:**

The script stops at the first error, because later steps remove and overwrite things. It is meant to be read and adapted, and the sections can be run one after the other. Do not run it unchanged against production.

---

**Disclaimer:**

This example script is provided AS-IS and is meant to be a building block to be adapted to fit an individual organization's infrastructure.
