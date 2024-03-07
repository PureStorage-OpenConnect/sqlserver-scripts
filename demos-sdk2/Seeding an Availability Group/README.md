 Seeding an Availability Group - Using SQL Server 2022's T-SQL Snapshot Backup feature 

# Scenario
Seeding an Availability Group (AG) from SQL Server 2022's T-SQL Snapshot Backup

# Prerequisites
1. This demo uses the dbatools cmdlet Connect-DbaInstance to build a persistent SMO session to the database instance.  This is required when using the T-SQL Snapshot feature because the session in which the database is frozen for IO must stay active. Other cmdlets disconnect immediately, which will thaw the database prematurely before the snapshot is taken.
2. Two SQL Servers running SQL Server 2022 with a database prepared to join an AG; this database is on volumes on one FlashArray and are contained in a Protection Group, and the soon-to-be secondary replica has volumes provisioned matching the primary in size and drive lettering.
3. Async snapshot replication between two FlashArrays replicating the Protection Group.
4. You've disabled or are, in some other way, accounting for log backups during the seeding process.
5. You already have the AG up and running, with both instances configured as replicas,
6. The database you want to seed is online on the primary but not the secondary.

# Usage Notes:
Each section of the script is meant to be run one after the other. The script is not meant to be executed all at once. 

# Disclaimer
This example script is provided AS-IS and is meant to be a building block to be adapted to fit an individual organization's infrastructure.