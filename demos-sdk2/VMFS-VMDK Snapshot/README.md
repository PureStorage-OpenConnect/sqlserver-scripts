# VMFS-VMDK Snapshot Scripts for SQL Server

This folder contains scripts for managing SQL Server databases on VMware VMFS datastores using Pure Storage FlashArray snapshots.

**Files:**
- `VMFS-VMDK Snapshot.ps1` — repeatable database refresh from a FlashArray snapshot across two VMFS datastores
- `Point in Time Recovery - VMFS.ps1` — SQL Server 2022 T-SQL Snapshot Backup with point-in-time recovery on VMFS/VMDK

---

## VMFS-VMDK Snapshot.ps1

**Scenario:**

This script is for a repeatable refresh scenario, such as a nightly refresh of a production database onto a non-production SQL Server. Production SQL Server databases reside on a VMFS datastore on one FlashArray. The non-production SQL Server resides on a different VMFS datastore on a second FlashArray.

The workflow takes an on-demand snapshot of the production datastore and async replicates it to the second FlashArray. The snapshot is then cloned as a new temporary volume/datastore. The VMDKs containing the production database files are attached to the target SQL Server, replacing the prior VMDKs. Finally, Storage vMotion migrates the VMDKs to the non-production datastore and the temporary cloned datastore is discarded.

**Prerequisites:**

1. PowerShell Modules: `dbatools` & `PureStoragePowerShellSDK2`
2. VMware PowerCLI must be installed.
3. Async replication must be configured between the source and target FlashArrays.

---

## Point in Time Recovery - VMFS.ps1

**Scenario:**

This script performs a point-in-time restore using SQL Server 2022's T-SQL Snapshot Backup feature with a FlashArray snapshot as the base, followed by restoring a native SQL Server log backup.

**Important Note:**

This script is built for a single database spanned across two VMDK files from a single datastore. The granularity of this workflow is a VMDK file and the entirety of its contents — everything in the VMDK, including files for other databases, will be impacted and overwritten. This script will need to be adapted to support multiple databases on the same VMDK(s).

**Prerequisites:**

1. PowerShell Modules: `dbatools` & `PureStoragePowerShellSDK2`
2. VMware PowerCLI must be installed.
3. SQL Server 2022 or later is required for T-SQL Snapshot Backup support.

**Usage Notes:**

Each section of the script is meant to be run one after the other. The script is not meant to be executed all at once.

---

## Disclaimer

This example script is provided AS-IS and is meant to be a building block to be adapted to fit an individual organization's infrastructure.

We encourage the modification and expansion of these scripts by the community. Although not necessary, please issue a Pull Request (PR) if you wish to request merging your modified code in to this repository.

---

_The contents of the repository are intended as examples only and should be modified to work in your individual environments. No script examples should be used in a production environment without fully testing them in a development or lab environment. There are no expressed or implied warranties or liability for the use of these example scripts and templates presented by Pure Storage and/or their creators._





