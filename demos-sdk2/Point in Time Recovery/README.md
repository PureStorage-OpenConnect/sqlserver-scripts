# Point In Time Recovery - Using SQL Server 2022's T-SQL Snapshot Backup feature 

# Scenario
Perform a point in time restore using SQL Server 2022's T-SQL Snapshot Backup feature. This uses a FlashArray snapshot as the base of the restore, then restores a log backup.

# Prerequisites
1. A SQL Server running SQL Server 2022 with a database having data files and a log file on two volumes that are each on different FlashArrays.

# Usage Notes:
Each section of the script is meant to be run one after the other. The script is not meant to be executed all at once. 

# Disclaimer
This example script is provided AS-IS and is meant to be a building block to be adapted to fit an individual organization's infrastructure.