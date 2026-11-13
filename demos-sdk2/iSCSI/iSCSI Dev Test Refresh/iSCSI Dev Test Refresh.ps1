##############################################################################################################################
# iSCSI Dev Test Refresh
#
# Scenario:
#    A production SQL Server VM (the source) keeps its database files on disks that the guest operating system reaches itself
#    with the Microsoft iSCSI initiator.  Each disk is its own FlashArray volume.  A non-production SQL Server VM (the target)
#    needs a fresh copy of those databases on a schedule, for example every night.  This script can be run again and again.
#    Each run removes the copy the previous run made and makes a new one.
#
#    A run takes one crash-consistent snapshot of every source volume, clones each as a new volume, connects the clones to the
#    target VM's FlashArray host and attaches the databases there.  The target already has iSCSI sessions to the array, so the
#    new volumes appear in Windows after a storage rescan.  The source stays online.  SQL Server write IO is NOT frozen, so each
#    database on the target performs crash recovery when it is attached.
#
#    The copy is easy to find next time because it has stable names: each clone volume is called <source volume>-devtest, the
#    databases are called <database><suffix>, and the snapshots have a "devtest-" suffix.  The previous copy is removed first, in an
#    order that leaves no stale disk, path, volume or snapshot behind.
#
#    You only name the VMs, the databases and the FlashArray.  The script works out the rest by lookup:
#    database files -> Windows drive -> Windows disk serial number (it is the FlashArray volume's serial number)
#    -> FlashArray volume.  The target's FlashArray host is found from the target's iSCSI initiator name (IQN).
#
# Prerequisites:
#    1. PowerShell modules: dbatools and PureStoragePowerShellSDK2.
#    2. PowerShell remoting (WinRM) to both VMs, and a SQL Server login that can attach and drop databases on the target.
#    3. Every disk that holds the listed databases is a FlashArray volume presented to the source VM with the Microsoft iSCSI
#       initiator.
#    4. The target VM is a different VM from the source VM.  It is already logged in to the array's iSCSI portals
#       (persistent sessions, multipath enabled), and it is a host on the FlashArray, identified by its IQN.
#    5. Database files must be on drive letters (this script is written for drive letters and does not handle mount points).
#
# To remove the copy without making a new one, run only the section "Remove the previous copy".
#
# Disclaimer:
#    This example script is provided AS-IS and meant to be a building block to be adapted to fit an individual
#    organization's infrastructure.
#
#    _PLEASE_ do not save your passwords in cleartext here.
#    Use NTFS secured, encrypted files or whatever else -- never cleartext!
#
##############################################################################################################################

# Stop at the first error.  Several steps below remove or overwrite things, so never carry on after a failure.
$ErrorActionPreference = 'Stop'



# Import powershell modules
Import-Module PureStoragePowerShellSDK2
Import-Module dbatools



# Declare all variables
$ArrayName         = 'flasharray1.example.com'        # FlashArray FQDN

$SourceVM          = 'source_vm'                      # Not FQDN
$TargetVM          = 'target_vm'                      # Not FQDN
$SourceSQLServer   = 'source_vm.example.com'
$TargetSQLServer   = 'target_vm.example.com'
$Databases         = @('AdventureWorks', 'WideWorldImporters')
$ProtectionGroupName = 'sql-devtest-pg'              # Made by this script the first run and reused, see "Protection group"
$NewNameSuffix     = '_dev'                           # Databases are attached on the target as AdventureWorks_dev, ...



# Get Credentials - this example assumes the same credential for the FlashArray and both VMs
$Credential = Get-Credential -UserName "$env:USERNAME" -Message 'Enter your credential information...'



# Connect to everything
$FlashArray    = Connect-Pfa2Array -Endpoint $ArrayName -Credential $Credential -IgnoreCertificateError
$SourceSql     = Connect-DbaInstance -SqlInstance $SourceSQLServer -TrustServerCertificate
$TargetSql     = Connect-DbaInstance -SqlInstance $TargetSQLServer -TrustServerCertificate



###
# Look up where the database files live

# Every data and log file of the databases, as SQL Server sees them
$DbFiles = Get-DbaDbFile -SqlInstance $SourceSql -Database $Databases
$DbFiles | Select-Object Database, TypeDescription, PhysicalName



# For each drive letter in use, ask Windows on the source VM which disk it is on.
# For an iSCSI disk from a FlashArray the disk serial number is the FlashArray volume's serial number.
$DriveLetters = $DbFiles.PhysicalName | ForEach-Object { $_.Substring(0, 1).ToUpper() } | Select-Object -Unique

$SerialByDrive = Invoke-Command -ComputerName $SourceVM -Credential $Credential -ArgumentList (, $DriveLetters) -ScriptBlock {
    param($letters)
    $map = @{}
    foreach ($letter in $letters) {
        $map[$letter] = (Get-Partition -DriveLetter $letter | Get-Disk).SerialNumber.ToUpper()
    }
    $map
}
$SerialByDrive



# Look up the FlashArray volumes
$SourceVolumes = @(Get-Pfa2Volume -Array $FlashArray | Where-Object { $SerialByDrive.Values -contains $_.Serial })
if ($SourceVolumes.Count -ne @($SerialByDrive.Values | Select-Object -Unique).Count) { throw 'A database disk is not a FlashArray volume.  This script is for FlashArray volumes.' }
"Source volumes: $($SourceVolumes.Name -join ', ')"



# Look up the target's FlashArray host.  The target VM tells us its iSCSI initiator name, and the array knows which host owns it.
$TargetIqn = Invoke-Command -ComputerName $TargetVM -Credential $Credential -ScriptBlock {
    (Get-InitiatorPort | Where-Object { $_.ConnectionType -eq 'iSCSI' }).NodeAddress
}
$TargetHost = @(Get-Pfa2Host -Array $FlashArray | Where-Object { $_.Iqns -contains $TargetIqn })
if ($TargetHost.Count -ne 1) { throw "Expected one FlashArray host with the IQN $TargetIqn, found $($TargetHost.Count)." }
$FAHost = $TargetHost[0].Name
"Target FlashArray host: $FAHost"



###
# Remove the previous copy
# The copy from the previous run is the volumes called <source volume>-devtest.  If they are there, they are removed in the reverse order
# of how they were made.  On the first run there is nothing to remove.

$Previous = @(Get-Pfa2Volume -Array $FlashArray | Where-Object { $_.Name -in ($SourceVolumes.Name | ForEach-Object { "$_-devtest" }) -and -not $_.Destroyed })

if ($Previous.Count -gt 0) {
    # Drop the databases on the target.  Remove-DbaDatabase closes any open sessions first.
    Get-DbaDatabase -SqlInstance $TargetSql -Database ($Databases | ForEach-Object { "$_$NewNameSuffix" }) | Remove-DbaDatabase -Confirm:$false -EnableException

    # Offline the copied disks in Windows.
    Invoke-Command -ComputerName $TargetVM -Credential $Credential -ArgumentList (, @($Previous.Serial)) -ScriptBlock {
        param($serials)
        foreach ($disk in (Get-Disk | Where-Object { $serials -contains "$($_.SerialNumber)".ToUpper() })) {
            Set-Disk -Number $disk.Number -IsOffline $true
        }
    }

    foreach ($Old in $Previous) {
        # On the FlashArray, disconnect and destroy the old clone.  It is eradicated at once, because a refresh that left every
        # old copy for the eradication period would keep a lot of space in use.
        Remove-Pfa2Connection -Array $FlashArray -HostNames $FAHost -VolumeNames $Old.Name
        Remove-Pfa2Volume -Array $FlashArray -Name $Old.Name
        Remove-Pfa2Volume -Array $FlashArray -Name $Old.Name -Eradicate -Confirm:$false
    }

    # The previous run's protection group snapshots.  The protection group itself stays, the next run reuses it.
    foreach ($OldSnapshot in @(Get-Pfa2ProtectionGroupSnapshot -Array $FlashArray -SourceName $ProtectionGroupName | Where-Object { $_.Suffix -like 'devtest-*' -and -not $_.Destroyed })) {
        Remove-Pfa2ProtectionGroupSnapshot -Array $FlashArray -Name $OldSnapshot.Name
        Remove-Pfa2ProtectionGroupSnapshot -Array $FlashArray -Name $OldSnapshot.Name -Eradicate -Confirm:$false
    }

    # Rescan in the target VM so Windows forgets the disconnected disks
    Invoke-Command -ComputerName $TargetVM -Credential $Credential -ScriptBlock { Update-HostStorageCache }
}



###
# Protection group
# A protection group snapshot snapshots every volume in the group at the same moment.  That is how the database disks, one volume
# each, get one shared point in time.  This section makes the group the first time and leaves it in place for the runs after.
# If you already have a protection group that holds these volumes, comment out this section and set $ProtectionGroupName to that group.
# Every volume in the group is snapshotted, not only the source volumes.

if (-not @(Get-Pfa2ProtectionGroup -Array $FlashArray -Filter "name='$ProtectionGroupName'")) {
    New-Pfa2ProtectionGroup -Array $FlashArray -Name $ProtectionGroupName
    New-Pfa2ProtectionGroupVolume -Array $FlashArray -GroupName $ProtectionGroupName -MemberName $SourceVolumes.Name
}



###
# Snapshot and clone

# Take a crash-consistent snapshot of the protection group, so every source volume shares the same point in time.
# The source database stays online.
$Stamp      = (Get-Date).ToString('yyyyMMdd-HHmmss')
$PgSnapshot = New-Pfa2ProtectionGroupSnapshot -Array $FlashArray -SourceName $ProtectionGroupName -Suffix "devtest-$Stamp"

# The protection group snapshot holds one snapshot per volume, named <group>.<suffix>.<volume>.  Pick out the source volumes' snapshots.
# This stops with an error if the group does not hold one of the source volumes.
$Snapshots  = @(foreach ($Volume in $SourceVolumes) { Get-Pfa2VolumeSnapshot -Array $FlashArray -Name "$($PgSnapshot.Name).$($Volume.Name)" })
$Snapshots | Select-Object Name, Created



# Create a new volume from each snapshot and connect it to the target's FlashArray host
$Clones = @()
foreach ($Snapshot in $Snapshots) {
    $CloneName = ($Snapshot.Name -split '\.')[-1] + '-devtest'
    $Clones   += New-Pfa2Volume -Array $FlashArray -Name $CloneName -SourceName $Snapshot.Name
    New-Pfa2Connection -Array $FlashArray -HostNames $FAHost -VolumeNames $CloneName
}



###
# Bring the clones online on the target VM

# The copies arrive in Windows offline.  A storage rescan makes the new volumes appear, and multipath claims them.
# Find them by serial number (the clones' serials, not the originals'), online them and make them writable.
# They keep the drive letters of the originals if those letters are free.
$CloneSerials = @($Clones.Serial)

# The new disks can take a while to appear in Windows.  Wait until every new disk is listed, running this until it is, then continue.
Invoke-Command -ComputerName $TargetVM -Credential $Credential -ScriptBlock { Update-HostStorageCache; Get-Disk | Select-Object Number, SerialNumber, IsOffline, Size }

$TargetDriveBySerial = Invoke-Command -ComputerName $TargetVM -Credential $Credential -ArgumentList (, $CloneSerials) -ScriptBlock {
    param($serials)
    Update-HostStorageCache
    $found = @(Get-Disk | Where-Object { $serials -contains "$($_.SerialNumber)".ToUpper() })
    $result = @{}
    foreach ($disk in $found) {
        Set-Disk -Number $disk.Number -IsOffline $false
        Set-Disk -Number $disk.Number -IsReadOnly $false
        $partition = Get-Partition -DiskNumber $disk.Number | Where-Object Type -eq 'Basic' | Select-Object -First 1
        if (-not $partition.DriveLetter) {
            Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -AssignDriveLetter
            $partition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber
        }
        $result[$disk.SerialNumber.ToUpper()] = "$($partition.DriveLetter)"
    }
    $result
}
$TargetDriveBySerial



###
# Attach the databases on the target SQL Server

# Each source volume has a clone.  Match them up by name: the clone's name starts with the source volume's name.
$CloneSerialBySourceSerial = @{}
foreach ($Source in $SourceVolumes) { $CloneSerialBySourceSerial[$Source.Serial] = ($Clones | Where-Object { $_.Name -eq "$($Source.Name)-devtest" }).Serial }

# Each file keeps its path, with the drive letter swapped for the letter the copy got on the target VM
foreach ($Database in $Databases) {
    $Files = $DbFiles | Where-Object { $_.Database -eq $Database } | ForEach-Object {
        $OldLetter = $_.PhysicalName.Substring(0, 1).ToUpper()
        $NewLetter = $TargetDriveBySerial[$CloneSerialBySourceSerial[$SerialByDrive[$OldLetter]]]
        "(FILENAME = N'$NewLetter$($_.PhysicalName.Substring(1))')"
    }
    $Query = "CREATE DATABASE [$Database$NewNameSuffix] ON $($Files -join ', ') FOR ATTACH"
    Invoke-DbaQuery -EnableException -SqlInstance $TargetSql -Database master -Query $Query
}



###
# The databases are online on the target after crash recovery.  Check them.
Get-DbaDbState -SqlInstance $TargetSql -Database ($Databases | ForEach-Object { "$_$NewNameSuffix" })



Disconnect-Pfa2Array -Array $FlashArray
