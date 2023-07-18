<#
##############################################################################################################################
# Modification of Refresh-Dev-From-VMDK.ps1 by DBArgenis for use with VMware vmfs based SQL VMs                              #
# Previous: https://github.com/PureStorage-OpenConnect/sqlserver-scripts/blob/master/Refresh-Dev-From-VMDK.ps1               #
#                                                                                                                            #
# Updated by: Jase McCarty                                                                                                   #
# Twitter:    @jasemccarty                                                                                                   #
#                                                                                                                            #
# This script will:                                                                                                          #
# - Bring a SQL Database offline in a Target VM                                                                              #
# - Offline and detach the SQL data disks                                                                                    #
# - Clone a datastore that has the data disks from a similar SQL VM                                                          #
# - Attach the snapshotted datastore, and rename it to the previous datastore name                                           #
# - Rename the disks from the Source VM to that of the Target VM                                                             #
# - Attach the disks to the Target VM                                                                                        #
# - Bring the data disks and the SQL database online                                                                         #
#                                                                                                                            #
# This can be run directly from PowerCLI or from a standard PowerShell prompt.                                               #
# PowerCLI must be installed on the local host regardless.                                                                   #
#                                                                                                                            #
# Supports:                                                                                                                  #
# - FlashArray 400 Series, //m, //x, & //c                                                                                   #
# - vCenter 6.5 and later                                                                                                    #
# - PowerCLI 10 or later required                                                                                            #
# - PowerShell Core supported                                                                                                #
# - PowerShell Remote Sessions require WSMAN support (Such as PSWSMan 2.0 for Mac)                                           #
#                                                                                                                            #
# Assumptions:                                                                                                               #
# - Source SQL VM has the C: drive on any datastore                                                                          #
# - Source SQL VM has data disks on a dedicated vmfs datastore on FlashArray                                                 #
# - Target SQL VM has the C: drive on any datastore                                                                          #
# - Target SQL VM has data disks on a dedicated vmfs datastore on FlashArray                                                 #
# - The FlashArray where work is being performed on contains the volumes that both the Source & Target VM's data disks are on#
# - System executing this script is joined to the same Active Directory Domain as the Source and Target SQL VMs              #
#                                                                                                                            #
# Drives are taken offline by their serial number/UUID                                                                       #
# This scripts are offered "as is" with no warranty.  While this script is tested and working in my environment, it is       #
# it is recommended that you test this script in a test lab before using in a production environment. Everyone can use the   # 
# script/commands provided here without any written permission, I, Jase McCarty, and Pure Storage, will not be liable for    #
# any damage or loss to the system.                                                                                          #
##############################################################################################################################
#>

# Configuring the script to use parameters so it can be reused more easily
param (
    [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$Endpoint,
    [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$SourceVmName,
    [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$TargetVmName,
    [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$DatabaseName,
    [Parameter(Mandatory=$false)][boolean]$NonDomainMember
)

. $PSScriptRoot\Pfa2REST.ps1

If ($NonDomainMember -eq $True) {
    $AdCreds = Get-Credential -Message "AD credentials are required for PowerShell remoting"
}

# Check for VMware PowerCLI installation, required to facilitate VMware vSphere tasks
If (-Not (Get-Module -ListAvailable -Name "VMware.PowerCLI")) {
    Write-Host "Please install the VMware.PowerCLI Module and rerun this script to proceed" -ForegroundColor Yellow
    Write-Host "It can be installed using " -NoNewLine 
    Write-Host "'Install-Module -Name VMware.PowerCLI'" -ForegroundColor Green
    Write-Host
    exit
}

# Get the PowerCLI Version and ensure it is at least PowerCLI 10
$PowerCLIVersion = Get-Module -Name VMware.PowerCLI -ListAvailable | Select-Object -Property Version

# If the PowerCLI Version is not v10 or higher, recommend that the user install PowerCLI 10 or higher
If ($PowerCLIVersion.Version.Major -ge "10") {
    Write-Host "PowerCLI version 10 or higher present, " -NoNewLine
    Write-Host "proceeding" -ForegroundColor Green 
} else {
    Write-Host "PowerCLI version could not be determined or is less than version 10" -Foregroundcolor Red
    Write-Host "Please install PowerCLI 10 or higher and rerun this script" -Foregroundcolor Yellow
    Write-Host " "
    exit
}

# Set the PowerCLI configuration to ignore incd /self-signed certificates
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$False | Out-Null 

# Check to see if a current vCenter Server session is in place
If ($Global:DefaultVIServer) {
    Write-Host "Connected to " -NoNewline 
    Write-Host $Global:DefaultVIServer -ForegroundColor Green
} else {
    Write-Host "Not connected to vCenter Server" -ForegroundColor Red
    $VIFQDN = Read-Host "Please enter the vCenter Server FQDN"  
    $VICredentials = Get-Credential -Message "Enter credentials for vCenter Server" 
    try {
        Connect-VIServer -Server $VIFQDN -Credential $VICredentials -ErrorAction Stop | Out-Null
        Write-Host "Connected to $VIFQDN" -ForegroundColor Green 
    }
    catch {
        Write-Host "Failed to connect to $VIFQDN" -BackgroundColor Red
        Write-Host $Error
        Write-Host "Terminating the script " -BackgroundColor Red
        return
    }
}

# Setup our VM Objects & their extended objects we need to address
# Source VM 
    # See if the Source VM exists
    try { $SourceVM = Get-VM -Name $SourceVmName -ErrorAction Stop} 
    catch { Write-Host  "Could not find the VM $($SourceVmName)";exit}

    # Because the Source VM exists, retrieve all disks except for the 1st disk
    $SourceDisks = Get-HardDisk -VM $SourceVM | Where-Object {$_.Name -ne "Hard disk 1"}

    # If no data disks are present, exit.
    If ($SourceDisks.Count -eq 0) { Write-Host "The Source VM has no data disks configured. Exiting";exit}

    # Store the datastore of the 1st Source disk returned - Assuming that all data disks are on the same datastore
    $SourceDatastore = Get-Datastore -Id ($SourceDisks[0]).ExtensionData.Backing.Datastore

# Target VM
    # See if the Target VM exists    
    try { $TargetVM = Get-VM -Name $TargetVmName -ErrorAction Stop}
    catch { Write-Host "Could not find the VM: $($TargetVmName)";exit }

    # Because the Target VM exists, retrieve the disks
    $TargetDisks = Get-HardDisk -VM $TargetVM | Where-Object {$_.Name -ne "Hard disk 1"}

    # If no data disks are present, exit.
    If ($TargetDisks.Count -eq 0) { Write-Host "The Target VM has no data disks configured. Exiting";exit}
    
    # Store the datastore of the 1st Target disk returned - Assuming that all data disks are on the same datastore
    $TargetDatastore   = Get-Datastore -Id ($TargetDisks[0]).ExtensionData.Backing.Datastore

    # Grab the datastore name and have it ready for when the disks are renamed
    $TargetPSDriveDS   = $TargetDatastore.Name

Write-Host "Creating PowerShell Remote Sessions to the Source and Target VMs" -ForegroundColor Blue
# Create a PowerShell session to the Source VM
# Let's do a quick CHECKPOINT on the source database to minimize crash recovery time upon startup on target - optional of course
if ($AdCreds) {
    $SourceVMSession = New-PSSession -ComputerName $SourceVM.ExtensionData.Guest.Hostname -ErrorVariable $SourceSessionError -Credential $AdCreds -ErrorAction SilentlyContinue
    $TargetVMSession = New-PSSession -ComputerName $TargetVm.ExtensionData.Guest.Hostname -ErrorVariable $TargetSessionError -Credential $AdCreds -ErrorAction SilentlyContinue    
} else {
    $SourceVMSession = New-PSSession -ComputerName $SourceVM.ExtensionData.Guest.Hostname -ErrorVariable $SourceSessionError -ErrorAction SilentlyContinue
    $TargetVMSession = New-PSSession -ComputerName $TargetVm.ExtensionData.Guest.Hostname -ErrorVariable $TargetSessionError -ErrorAction SilentlyContinue
}

# Check the PsRemote Sessions
if ($SourceVMSession) {
    Write-Host "       $($SourceVM) remote session good" -ForegroundColor Green
    Write-Host "         Importing the SQLPS Module on $SourceVM"
    Import-Module SQLPS -PSSession $SourceVMSession -DisableNameChecking

    $PsRemoteSession = $True
} else { 
    Write-Host "       $($SourceVM) remote session not good" -ForegroundColor Red
    $PsRemoteSession = $False
}

if ($TargetVMSession) {
    Write-Host "       $($TargetVM) remote session good" -ForegroundColor Green
    Write-Host "         Importing the SQLPS Module on $TargetVM"
    Import-Module SQLPS -PSSession $TargetVMSession -DisableNameChecking
    $PsRemoteSession = $True
} else { 
    Write-Host "       $($TargetVM) remote session not good: $($TargetSessionError)" -ForegroundColor Red
    $PsRemoteSession = $False
}

if ($PsRemoteSession -eq $False) {
    Write-Host "       One or more remote sessions were not good, exiting" -ForegroundColor Red
    exit
}

Write-Host 

Write-Host "Source $($SourceVM) Task to ensure a clean snap" -ForegroundColor Blue
Write-Host "Forcing a CHECKPOINT on source database..." -ForegroundColor Yellow
Invoke-Command -Session $SourceVMSession -ScriptBlock {"Invoke-SqlCmd -ServerInstance . -Database $DatabaseName -Query 'CHECKPOINT'"} | Out-Null

Write-Host 
Write-Host "Target $($TargetVM) Tasks to ensure proper operation" -ForegroundColor Blue
# Offline the target database
Write-Host "     Taking the $($DatabaseName) Database offline" -ForegroundColor Red
Invoke-Command -Session $TargetVMSession -ScriptBlock {"Invoke-SqlCmd -ServerInstance . -Database master -Query 'ALTER DATABASE $DatabaseName SET OFFLINE WITH ROLLBACK IMMEDIATE'"} | Out-Null

# Offline the Guest Disks based on their serial numbers
foreach ($TargetDisk in $TargetDisks) {

    # Show the status
    Write-Host "     $($TargetVM) Disk $($TargetDisk.ExtensionData.Backing.UUid) - " -NoNewLine
    # Set the current VMware Hard Disk to Offline in the Guest OS
    Write-Host " Offline - " -NoNewline
    Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq $TargetDisk.ExtensionData.Backing.UUid } | Set-Disk -IsOffline $True } | Out-Null
    # Remove the hard disk from being attached to the VM
    Write-Host "Removing - " -NoNewline
    Remove-HardDisk -HardDisk $TargetDisk -Confirm:$False 
    Write-Host "Removed"
}

Write-Host 
Write-Host "Existing $($TargetVM) Datastore tasks" -ForegroundColor Blue
# Detach the Datastore that will be overwritten
Write-Host "     Detaching the $($TargetDatastore) datastore..." -ForegroundColor Red
Get-Datastore $TargetDatastore | Remove-Datastore -VMHost $TargetVM.VMHost -Confirm:$false

Write-Host
Write-Host "Array tasks" -ForegroundColor Blue

$sourceSerial = $SourceDatastore.ExtensionData.Info.Vmfs.Extent.DiskName | select -unique | % {$_.substring(12)}
$targetSerial = $TargetDatastore.ExtensionData.Info.Vmfs.Extent.DiskName | select -unique | % {$_.substring(12)}

Write-Host "Connecting to $endpoint FlashArray"
if ($PSEdition -ne 'core') {
    Set-Pfa2SkipCertificateCheck
}
try {
    $session = Open-Pfa2Session -endpoint $endpoint -credential (Get-Credential -Message "Enter your credentials to connect to $endpoint FlashArray.") -skipCertificateCheck -version '2.11'
}
catch {
    Write-Error "Failed to connect to $endpoint FlashArray. $($_.Exception.Message)"
    return
}

try {
    $res = Invoke-Pfa2Operation -session $session -method 'Get' -query "volumes?filter=serial='$sourceSerial'&limit=1"
    if ($res.items) {
        $sourceVolume = $res.items[0]
    } else {
        throw "Volume $sourceSerial not found."
    }
    $res = Invoke-Pfa2Operation -session $session -method 'Get' -query "volumes?filter=serial='$targetSerial'&limit=1"
    if ($res.items) {
        $targetVolume = $res.items[0]
    } else {
        throw "Volume $targetSerial not found."
    }

    Write-Host "Cloning the source volume"
    $src = @{'source'=@{'name'=$sourceVolume.name}} | ConvertTo-Json
    Invoke-Pfa2Operation -session $session -query "volumes?names=$($targetVolume.name)&overwrite=true" -rest @{'Body' = $src} | Out-Null
}
catch {
    Write-Error "Failed to clone source volume. $($_.Exception.Message)"
    return
}
finally {
    Close-Pfa2Session -session $session
}

Start-Sleep 5

Write-Host "vSphere Host Tasks" -ForegroundColor Blue
# Get the Host or Cluster that the Target VM is running on and perform a rescan
$VMParent = $TargetVM.VMHost.Parent 

# If the Host is part of a vSphere Cluster, initiate a rescan on all the hosts
If ($TargetVM.VMHost.Parent.GetType().Name -eq "ClusterImpl") {
    Write-Host "     Rescanning storage on Cluster"
    $ParentHosts = $VMParent | Get-VMHost
    Foreach ($ParentHost in $ParentHosts) {
        Write-Host "         Host: $($ParentHost)"
        Get-VMHostStorage -RescanAllHba -RescanVmfs -VMHost $ParentHost | Out-Null
    }
} else {
    # If the Host is not part of a vSphere Cluster, initiate a rescan on only the host
    $ParentHost = $TargetVM.VMhost
    Write-Host "     Rescanning Storage on Host $($ParentHost)"
    Get-VMHostStorage -RescanAllHba -RescanVmfs -VMHost $ParentHost | Out-Null
}

# Connect to the Host the TargetVM is running on
$esxcli = Get-EsxCli -VMhost $TargetVM.VMHost -v2  

# Retrieve a list of the snapshots that have been presented to the host (our cloned volume should be present)
Write-Host "     Retrieving snapshots presented to the vSphere Host that $($TargetVM) is registered on"
$FaVolumeSnaps = $Esxcli.storage.vmfs.snapshot.list.invoke()

# Enumerate any snapshots on that have been presented to the host from FlashArray
Foreach ($FaVolumeSnap in $FaVolumeSnaps) {
    Write-Host "     Resignaturing & mounting the snapshot of $($SourceDatastore)"
    # Resignature the cloned volume and mount it
    $EsxCli.storage.vmfs.snapshot.resignature.invoke(@{volumelabel=$($FaVolumeSnap.VolumeName)}) | Out-Null
    # Get the snapped datastore
    $CloneDS = (Get-Datastore | ? { $_.name -match 'snap' -and $_.name -match $SourceDatastore.Name })
    Write-Host "     Waiting for the snapshot to be mounted"
    # Wait until the datastore has been mounted
    while ($CloneDS -eq $null) { # We may have to wait a little bit before the datastore is fully operational
        $CloneDS = (Get-Datastore | ? { $_.name -match 'snap' -and $_.name -match $SourceDatastore.Name })
        Start-Sleep -Seconds 5
    }
    # When the datastore has been mounted, rename it to the name of the volume
    Write-Host "     Renaming the Datastore $($CloneDS) to $($TargetDatastore)"
    Get-Datastore | Where-Object {$_.Name -Like "snap-*-$($SourceDatastore)"} | Set-Datastore -Name $TargetDatastore | Out-Null
    $TargetDatastore = Get-Datastore -Name $TargetPSDriveDS -ErrorAction SilentlyContinue
    # Perform a rescan on the host
    Get-VMHostStorage -VMHost $TargetVM.VMhost -RescanAllHba -RescanVmfs | Out-Null 
}
Write-Host 
Write-Host "Datastore tasks to prep for mounting vmdks" -ForegroundColor Blue

# Create a new PowerShell Drive, so the TargetVM Folder and drives can be renamed appropriately
Write-Host "     Connecting to the datastore to rename the vmdks"
New-PSDrive -PSProvider VimDatastore -Location (Get-Datastore -Name $TargetPSDriveDS) -Root "/" -Name DS > $null

# Rename the SourceVM Folder Name on the Target Datastore
Write-Host "     Renaming the folder to match the $($TargetVM) name"
Rename-Item -Path "DS:$($SourceVmName)" -NewName $TargetVmName

# Enumerate the Source Disk names on the Target Datastore and rename them to match the Target VM
Write-Host "     Renaming the vmdks"

Foreach ($Item in $SourceDisks.Filename) {
    # Take the current Source Disk Name and return only the Folder and Filename
    $SourceFolderAndDisk = (($Item -split "] ")[1]) -replace "$($SourceVmName)/","$($TargetVmName)/"
    $SourceDiskName  = ($Item -split "/")[1]
    # Create the desitnation vmdk name
    $TargetDiskName  = $SourceDiskName -Replace "$($SourceVmName)","$($TargetVmName)"
    # Rename the cloned disk
    Write-Host "         Renaming Cloned Disk $($SourceFolderAndDisk) " -NoNewline
    Rename-Item -Path "DS:$SourceFolderAndDisk" -NewName $TargetDiskName
    # Attach the disk to the Target VM (with the matching name)
    Write-Host "& attaching disk to $($TargetVM)"
    New-HardDisk -VM $TargetVM -DiskPath "[$($TargetDatastore)] $($TargetVmName)/$($TargetDiskName)" | Out-Null
}

# Remove the PowerShell Drive that is used for the vmdk renaming process
Remove-PSDrive -Name DS -Confirm:$False

# Grab the newly attached disks and put them in a new variable
$NewTargetDisks       = Get-HardDisk -VM $TargetVM | Where-Object {$_.Name -ne "Hard disk 1"}

Write-Host ""
Write-Host "Final tasks being performed on $($TargetVM)" -ForegroundColor Blue
# Online the Guest Disks based on their serial numbers
Write-Host "     Bringing $TargetVM disks online: "
foreach ($TargetDisk in $NewTargetDisks) {

    Write-Host "          $($TargetDisk.ExtensionData.Backing.Uuid) " -NoNewline
    # Set the current VMware Hard Disk to Online in the Guest OS
    Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq $TargetDisk.ExtensionData.Backing.UUid } | Set-Disk -IsOffline $False }
    Write-Host " Online " -NoNewLine

    Invoke-Command -Session $TargetVMSession -ScriptBlock { Get-Disk | ? { $_.SerialNumber -eq $TargetDisk.ExtensionData.Backing.UUid } | Set-Disk -IsReadOnly $False } | Out-Null
    Write-Host " Read/Write"
}

# Online the database
Write-Host "     Bring the $($Database) database online"
Invoke-Command -Session $TargetVMSession -ScriptBlock {"Invoke-SqlCmd -ServerInstance . -Database master -Query 'ALTER DATABASE " + $DatabaseName + " SET ONLINE WITH ROLLBACK IMMEDIATE'"} | Out-Null

Write-Host "Complete" -ForegroundColor Blue

