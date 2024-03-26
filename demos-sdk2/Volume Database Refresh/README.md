# Volume Database Refresh

Scenario: <br>
    Script will refresh a database on the target server from a source database on a separate server<br>
<br>
Prerequisities:<br>
    sqlserver and PureStoragePowerShellSDK modules installed on client machine<br>
    Two SQL instances with a database that has its data and log files on one volume on both servers<br>
    Example here assumes vVols but RDMs will work as well<br>
<br>
Usage Notes:<br>
    Each section of the script is meant to be run one after the other. The script is not meant to be executed all at once.<br>
<br>
Disclaimer:<br>
    This example script is provided AS-IS and meant to be a building block to be adapted to fit an individual 
    organization's infrastructure.<br>
<br>
    THIS IS A SAMPLE SCRIPT WE USE FOR DEMOS! _PLEASE_ do not save your passwords in cleartext here. <br>
    Use NTFS secured, encrypted files or whatever else -- never cleartext!
