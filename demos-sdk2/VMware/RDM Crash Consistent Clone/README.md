# RDM Crash Consistent Clone

This folder holds an example script that copies SQL Server databases from one VM to another with a FlashArray snapshot, when the database files are on RDMs (each RDM is a FlashArray volume).

**Files:**
- `RDM Crash Consistent Clone.ps1` - crash-consistent snapshot of the database volumes, cloned and added to a second SQL Server VM as RDMs

---

## RDM Crash Consistent Clone.ps1

**Scenario:**

A source SQL Server VM keeps its database files on RDMs. A second SQL Server VM needs a copy of those databases, for example for dev/test. The script takes one crash-consistent snapshot of every volume that holds the databases, clones each as a new volume, presents the clones to the ESXi host, adds them to the target VM as RDMs, onlines the disks and attaches the databases under new names. The source stays online. Write IO is not frozen, so each database performs crash recovery when it is attached.

**What you type in, and what the script looks up:**

You name the vCenter, the FlashArray, the VMs, the SQL Servers and the databases. Everything else is looked up: database files, to Windows drive, to Windows disk serial number, to FlashArray volume, to host group. For an RDM the Windows disk serial number is the FlashArray volume's serial number.

**Prerequisites:**

1. PowerShell modules: `dbatools`, `PureStoragePowerShellSDK2` and VMware PowerCLI.
2. PowerShell remoting (WinRM) to both VMs, and a SQL Server login that can attach databases on the target.
3. Every disk that holds the listed databases is a FlashArray volume presented as an RDM.
4. The target VM must be a different VM from the source and have free SCSI slots.
5. Database files on drive letters, and the databases must not exist on the target yet.

**What a DBA needs to know:**

- Three people usually own the steps: the storage admin (snapshot, volume, host connection), the VMware admin (rescan, add the RDM) and the DBA (bring the disks online, attach the databases). The script does all of them.
- An RDM copy is added in physical compatibility mode.
- The ESXi host needs a rescan before it sees a new volume, and the script rescans the host the target VM runs on. Each new volume is connected to the host group (all hosts that can run the VM), not to a single host, or vMotion and HA break.
- The copies keep the drive letters of the originals on the target if those letters are free, otherwise Windows gives the next free letter. The script reads the letter back and uses it.

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
