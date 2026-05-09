# Hyper-V Cluster Shared Volume + SQL Server Snapshot Scripts

This folder contains Hyper-V Cluster Shared Volume (CSV) + SQL Server example snapshot scripts using the Pure Storage FlashArray.

**Files:**
- `Hyper-V CSV w SQL Server Snapshot.ps1` - CSV clone with disk resignature; presents the clone back to the originating Hyper-V cluster as a second CSV
- `HyperV CrashConsistentClone.ps1` - crash-consistent snapshot clone from a production CSV to a dev/test SQL Server VM
- `HyperV-TSQL-SnapshotBackup.ps1` - SQL Server 2022 T-SQL Snapshot Backup with point-in-time recovery on a Hyper-V CSV

---

## Hyper-V CSV w SQL Server Snapshot.ps1

**Scenario:**

This script clones a Hyper-V Cluster Shared Volume (CSV) using a crash-consistent snapshot and presents it back to the originating Hyper-V cluster as a second CSV. The target VM spans two CSVs: the first holds the VM OS disk (untouched by this script) and the second holds the SQL Server user database VHDX. Only the database CSV is swapped - the database VHDX is hot-removed, the CSV is overwritten with a fresh clone from the FlashArray, and the VHDX is hot-added back to the running VM.

**Prerequisites:**

1. A pre-created target volume on the FlashArray, connected to the target Hyper-V host, must be the same size as the source CSV volume.
2. The Failover Cluster PowerShell module must be installed: `Add-WindowsFeature RSAT-Clustering-PowerShell`
3. PowerShell Remoting (WinRM) must be enabled on the Hyper-V host and inside the target VM guest.
4. The target VM must have a SCSI controller - hot-add/remove requires SCSI (not IDE).
5. The `SqlServer` module must be installed in the guest: `Install-Module SqlServer`
6. The credential used must have Administrator rights on the Hyper-V host, cluster nodes, and the VM guest, plus FlashArray array admin or storage admin role.

**Important Usage Notes:**

The clone carries the same disk signature as the source CSV, so it must be resignatured on the target host while offline before it can be used as a CSV. This is handled automatically via DISKPART before the cluster resource is started.

---

## HyperV CrashConsistentClone.ps1

**Scenario:**

This script clones a production SQL Server Hyper-V CSV to a dev/test SQL Server VM using a crash-consistent FlashArray snapshot. The source SQL Server remains running and unaffected throughout the entire operation. The target SQL Server performs automatic crash recovery (roll forward committed transactions, roll back uncommitted) when the database is brought online - equivalent to recovering after a power loss.

Storage topology:
- **Source**: `hyperv-csv-01-DATA-PROD` (CSV backing VM1 VHDXs) → SQL 01 (Production)
- **Target**: `hyperv-csv-01-DATA-DEV` (CSV backing VM2 VHDXs) → SQL 02 (Dev/Test)

**Prerequisites:**

1. Source and target volumes must be pre-configured on the FlashArray and the same size.
2. The Failover Cluster PowerShell module must be installed: `Add-WindowsFeature RSAT-Clustering-PowerShell`
3. PowerShell Remoting (WinRM) must be enabled on all Hyper-V cluster nodes.
4. The target VM must have a SCSI controller.
5. `PureStoragePowerShellSDK2` and `dbatools` modules must be installed.
6. Saved FlashArray credentials at `$HOME\FA_Cred.xml`.
7. The target database must already exist on the target SQL Server.

**Important Usage Notes:**

This is a crash-consistent snapshot - SQL Server write IO is not frozen before the snapshot is taken. No source downtime or quiescing is required. The VHDXs are detached from the target VM, the target CSV cluster resource is taken offline, the FlashArray volume is overwritten with the snapshot clone (a metadata-only operation on the array), and the CSV and VHDXs are brought back online before the database is recovered.

---

## HyperV-TSQL-SnapshotBackup.ps1

**Scenario:**

This script demonstrates SQL Server 2022 T-SQL Snapshot Backup on a Hyper-V cluster where database files reside on VHDXs stored on a Pure Storage FlashArray CSV. An application-consistent snapshot is taken while SQL Server is running on VM1 (SQL 01). The clone is then presented to VM2 (SQL 02) and restored with a log backup for point-in-time recovery.

Storage topology:
- **Source**: `hyperv-csv-01-DATA-PROD` (CSV backing VM1 VHDXs) → SQL 01 (Production)
- **Target**: `hyperv-csv-01-DATA-DEV` (CSV backing VM2 VHDXs) → SQL 02 (Dev/Test)

**Prerequisites:**

1. Source and target volumes must be pre-configured on the FlashArray and the same size.
2. The Failover Cluster PowerShell module must be installed: `Add-WindowsFeature RSAT-Clustering-PowerShell`
3. PowerShell Remoting (WinRM) must be enabled on all Hyper-V cluster nodes.
4. The target VM must have a SCSI controller.
5. SQL Server 2022 or later is required on both instances for T-SQL Snapshot Backup support.
6. `PureStoragePowerShellSDK2` and `dbatools` modules must be installed.
7. A backup share must be accessible from both SQL 01 and SQL 02 for metadata and log backup files.
8. Saved FlashArray credentials at `$HOME\FA_Cred.xml`.
9. The target database must already exist on the target SQL Server.

**Important Usage Notes:**

This script uses a volume snapshot (`New-Pfa2VolumeSnapshot`) rather than a Protection Group snapshot because the data and log VHDXs share a single CSV volume - a single volume snapshot captures both files consistently. The `SUSPEND_FOR_SNAPSHOT_BACKUP` and `BACKUP METADATA_ONLY` commands must share the same SQL Server session; this script uses a persistent, non-pooled dbatools connection (`-NonPooledConnection`) to satisfy that requirement. The snapshot name is embedded in the backup file's `MEDIADESCRIPTION` field so it can be retrieved later during restore.

---

**Disclaimer:**

This example script is provided AS-IS and meant to be a building block to be adapted to fit an individual organization's infrastructure.

We encourage the modification and expansion of these scripts by the community. Although not necessary, please issue a Pull Request (PR) if you wish to request merging your modified code in to this repository.

---

_The contents of the repository are intended as examples only and should be modified to work in your individual environments. No script examples should be used in a production environment without fully testing them in a development or lab environment. There are no expressed or implied warranties or liability for the use of these example scripts and templates presented by Pure Storage and/or their creators._