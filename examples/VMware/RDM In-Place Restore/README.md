# RDM In-Place Restore

This folder holds an example script that rolls SQL Server databases on RDMs back to an earlier FlashArray snapshot, on the same VM.

**Files:**
- `RDM In-Place Restore.ps1` - offline the databases and disks, overwrite each volume from its snapshot, bring everything back online

---

## RDM In-Place Restore.ps1

**Scenario:**

A SQL Server VM keeps its database files on RDMs. A snapshot of the protection group that holds those volumes (a restore point) exists. The script takes the databases and disks offline, overwrites each volume from its snapshot, and brings the disks and databases back online. Everything after the restore point is lost.

**What you type in, and what the script looks up:**

You name the FlashArray, the VM, the SQL Server, the databases and the protection group. Everything else is looked up: database files, to Windows drive, to Windows disk serial number, to FlashArray volume, to host group. For an RDM the Windows disk serial number is the FlashArray volume's serial number.

**Prerequisites:**

1. PowerShell modules: `dbatools` and `PureStoragePowerShellSDK2`.
2. PowerShell remoting (WinRM) to the VM, and a SQL Server login that can take the databases offline.
3. Every database disk is a FlashArray volume presented as an RDM, and those volumes are in a protection group that has at least one snapshot.
4. Every database that has files on those disks is listed in the script.

**What a DBA needs to know:**

- Two people usually own the steps: the storage admin (overwrite the volume) and the DBA (databases and disks offline and online). The script does both.
- A restore point is a protection group snapshot, so the database disks (one FlashArray volume each) share one point in time. By default the newest snapshot of the group is used, or set the suffix to restore another. The group can hold other volumes too, but only the volumes behind the listed databases are restored.
- Nothing changes on the vSphere side: the RDMs, serial numbers and drive letters stay the same.
- The volume is overwritten with `New-Pfa2Volume -Overwrite`. The array keeps the volume's name, serial number and connections. Before it overwrites, the FlashArray saves the volume's previous contents as a destroyed snapshot named `<volume>.copy.<n>` (seen on Purity 6.9.5). It stays for the eradication period and is the way back if you restored the wrong restore point.

**Things learned the hard way, in every script in this repository:**

- **dbatools reports SQL errors as warnings.** `Invoke-DbaQuery` does not throw unless `-EnableException` is given, so every query here has it. Without it, "stop at the first error" does not cover SQL statements.
- **Do not pipe FlashArray cmdlets into `Select-Object -First`.** In Windows PowerShell 5.1 it can end a script silently. The scripts take the first item from an array instead.
- **Hot-added disks can take a while to appear.** The scripts say where to wait and give a command to check. Run it until every new disk is listed, then continue.

**Important Usage Notes:**

The script stops at the first error, because later steps remove and overwrite things. It is meant to be read and adapted, and the sections can be run one after the other. Do not run it unchanged against production.

---

**Disclaimer:**

This example script is provided AS-IS and is meant to be a building block to be adapted to fit an individual organization's infrastructure.