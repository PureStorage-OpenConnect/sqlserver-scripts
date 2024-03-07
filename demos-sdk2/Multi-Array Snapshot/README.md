# Multi-Array Snapshot

Multi-ArraySnapshot - Using SQL Server 2022's T-SQL Snapshot Backup feature 
to take a consistent snapshot across two arrays

# Scenario
    Single test database named "MultiArraySnapshot" which has data files and a log file on two volumes that are each on different FlashArrays.

# Prerequisites
1. This demo uses the dbatools cmdlet Connect-DbaInstance to build a persistent SMO session to the database instance.  This is required when using the T-SQL Snapshot feature because the session in which the database is frozen for IO must stay active. Other cmdlets disconnect immediately, which will thaw the database prematurely before the snapshot is taken.
2. The overall process is to freeze the database using TSQL Snapshot, then take a snapshot on each array, and then write the metadata file to a network share, which thaws the database.

# Usage Notes:
Each section of the script is meant to be run one after the other. The script is not meant to be executed all at once. 

# Disclaimer
This example script is provided AS-IS and is meant to be a building block to be adapted to fit an individual organization's infrastructure.
