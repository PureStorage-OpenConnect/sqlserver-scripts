# SSMS Extension Database Attach

Scenario: <br>
   Script will mount a volume to a target server and attach a database<br>
<br>
Prerequisities:<br>
   SSMS extension installed<br>
   Backup configuration created in the SSMS extension<br>
   Source database data and log files on one volume<br>
<br>
Usage Notes:<br>
   Full details on configuring the SSMS extension can be found here: -
   https://support.purestorage.com/Solutions/Microsoft_Platform_Guide/bbb_Microsoft_Integration_Releases/Pure_Storage_FlashArray_Management_Extension_for_Microsoft_SQL_Server_Management_Studio
   
   Each section of the script is meant to be run one after the other. The script is not meant to be executed all at once.<br>
   The example here used the AdventureWorks database. The attach script will have to be updated if another database is used.<br>
<br>
Disclaimer:<br>
   This example script is provided AS-IS and meant to be a building block to be adapted to fit an individual <br>
   organization's infrastructure.<br>
