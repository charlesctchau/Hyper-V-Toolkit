<#
.SYNOPSIS
  HVToolkit engine module: fleet scan, name-based selection, guarded remote execution.

.NOTES
  Design rules enforced by this module:
    1. Only hosts listed in hosts.txt can be touched, and each host must answer
       with the expected computer name before anything runs on it.
    2. Every Hyper-V cmdlet runs ON the target host (PSRemoting), so mixed
       2012 R2 / 2016 / 2019 hosts work regardless of the local module version.
    3. Every destructive step re-validates the live state on the host inside the
       same remote call that performs the change. If anything differs from the
       plan the operator approved, the step aborts before changing anything.
    4. No -Force switch and no silent mode. Destructive steps need a typed word.
  Remote script blocks are written for PowerShell 4.0 compatibility.
#>

Set-StrictMode -Off

$script:HVT = @{
    LogDir      = 'C:\HyperVLogs'
    HostsFile   = $null
    Hosts       = @()
    Fleet       = $null
    Verified    = @{}
    PreviewOnly = $false
}

# ---------------------------------------------------------------------------
# Helper functions that are shipped to every remote host as text
# ---------------------------------------------------------------------------
$script:RemoteHelpers = @'
function HvtShort($n) {
    if (-not $n) { return '' }
    return (("$n".Trim()) -split '\.')[0].ToUpperInvariant()
}
function HvtDate($d) {
    if ($d -is [datetime] -and $d.Year -gt 1601) { return $d.ToString('yyyy-MM-dd HH:mm') }
    return ''
}
function HvtRepl($vm) {
    # All replication relationships of a VM as plain hashtables
    $out = @()
    foreach ($r in @(Get-VMReplication -VM $vm -ErrorAction SilentlyContinue)) {
        if (-not $r) { continue }
        $t = $r.RelationshipType
        if (-not $t) { $t = $r.ReplicationRelationshipType }
        $out += @{
            Mode    = "$($r.Mode)"
            RelType = "$t"
            State   = "$($r.State)"
            Health  = "$($r.Health)"
            Primary = "$($r.PrimaryServer)"
            Replica = "$($r.ReplicaServer)"
            LastRep = (HvtDate $r.LastReplicationTime)
        }
    }
    return $out
}
function HvtChain($vm, $followAll) {
    # Every VHD file used by the VM: attached disks, checkpoint disks and the
    # parents of checkpoint (.avhd/.avhdx) disks. With $followAll the parents of
    # ordinary differencing disks are followed too (used for the shared check).
    $paths = New-Object System.Collections.ArrayList
    $warn  = New-Object System.Collections.ArrayList
    $start = @()
    foreach ($d in @($vm.HardDrives)) { if ($d -and $d.Path) { $start += $d.Path } }
    foreach ($s in @(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue)) {
        foreach ($d in @($s.HardDrives)) { if ($d -and $d.Path) { $start += $d.Path } }
    }
    foreach ($p in $start) {
        $curr = $p
        $guard = 0
        while ($curr -and $guard -lt 200) {
            $guard++
            # Skip pass-through disks and anything that is not a virtual disk file
            if ($curr -notmatch '\.(a?vhdx?|vhds)$') { break }
            $known = $false
            foreach ($k in $paths) { if ($k -ieq $curr) { $known = $true; break } }
            if ($known) { break }
            [void]$paths.Add($curr)
            if ($followAll -or ($curr -match '\.avhdx?$')) {
                try { $curr = (Get-VHD -Path $curr -ErrorAction Stop).ParentPath }
                catch {
                    if ($curr -match '\.avhdx?$') { [void]$warn.Add("Cannot read parent of $curr") }
                    $curr = $null
                }
            } else { $curr = $null }
        }
    }
    return @{ Paths = @($paths); Warnings = @($warn) }
}
function HvtFiles($paths) {
    $out = @()
    foreach ($p in @($paths)) {
        if (-not $p) { continue }
        $exists = Test-Path -LiteralPath $p
        $len = 0
        if ($exists) { $len = [double](Get-Item -LiteralPath $p).Length }
        $out += @{ Path = "$p"; Exists = [bool]$exists; Bytes = $len }
    }
    return $out
}
function HvtSharedRefs($vmId, $paths) {
    # Files in $paths that are also used by any OTHER VM registered on this host
    $hits = @()
    if (@($paths).Count -eq 0) { return $hits }
    $set = @{}
    foreach ($p in @($paths)) { $set["$p".ToLowerInvariant()] = $true }
    foreach ($o in @(Get-VM -ErrorAction SilentlyContinue)) {
        if ($o.Id.ToString() -eq "$vmId") { continue }
        $c = HvtChain $o $true
        foreach ($q in @($c.Paths)) {
            if ($set.ContainsKey("$q".ToLowerInvariant())) { $hits += ("{0}  (also used by VM '{1}')" -f $q, $o.Name) }
        }
    }
    return $hits
}
function HvtFree($path) {
    # Free bytes on the drive that holds $path, or -1 when unknown
    if (-not $path -or "$path".Length -lt 2) { return -1 }
    $drive = "$path".Substring(0, 2)
    if ($drive -notmatch '^[A-Za-z]:$') { return -1 }
    $ld = Get-WmiObject Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $drive) -ErrorAction SilentlyContinue
    if ($ld) { return [double]$ld.FreeSpace }
    return -1
}
function HvtGuardVm($A) {
    # Fetch the VM by Id and make sure it is still the VM the operator approved
    $vm = Get-VM -Id $A.VMId -ErrorAction Stop
    if ($A.ExpectName -and $vm.Name -ne $A.ExpectName) {
        throw "VM $($A.VMId) is now named '$($vm.Name)', expected '$($A.ExpectName)'. Aborted, nothing changed."
    }
    return $vm
}
function HvtWaitWmiJob($res) {
    # Wait for an asynchronous Hyper-V WMI job (ReturnValue 4096) to complete
    if ($res -and $res.ReturnValue -eq 4096 -and $res.Job) {
        try {
            $job = [wmi]$res.Job
            $w = 0
            while (($job.JobState -eq 3 -or $job.JobState -eq 4) -and $w -lt 120) {
                Start-Sleep -Seconds 1
                $w++
                $job.Get()
            }
            return $job
        } catch {
            return $null
        }
    }
    return $null
}
function HvtRemoveReplSafe($vmId) {
    # Safely remove replication relationship using cmdlet first, then WMI fallback
    # to bypass Microsoft.HyperV.PowerShell NullReferenceException on broken/resync states.
    $ns = 'root\virtualization\v2'
    $vmGuid = "$vmId".ToUpperInvariant()
    $vmWmi = Get-WmiObject -Namespace $ns -Class Msvm_ComputerSystem -Filter ("Name='{0}'" -f $vmGuid) -ErrorAction SilentlyContinue
    $repSvc = Get-WmiObject -Namespace $ns -Class Msvm_ReplicationService -ErrorAction SilentlyContinue

    # 1. Cancel any active resynchronization or replication job via WMI and cmdlet
    if ($vmWmi -and $repSvc) {
        try { [void](HvtWaitWmiJob ($repSvc.CancelResynchronize($vmWmi.__PATH))) } catch {}
        try { [void](HvtWaitWmiJob ($repSvc.StopReplication($vmWmi.__PATH))) } catch {}
    }
    try {
        $v0 = Get-VM -Id $vmId -ErrorAction SilentlyContinue
        if ($v0) { Stop-VMReplication -VMName $v0.Name -Confirm:$false -ErrorAction SilentlyContinue }
    } catch {}
    Start-Sleep -Seconds 2

    # 2. Attempt removal via standard cmdlet using a fresh VM instance
    $lastErr = ''
    for ($i = 0; $i -lt 2; $i++) {
        try {
            $freshVm = Get-VM -Id $vmId -ErrorAction Stop
            if (@(HvtRepl $freshVm).Count -eq 0) { return 'Removed' }
            Remove-VMReplication -VM $freshVm -Confirm:$false -ErrorAction Stop
        } catch {
            $lastErr = "$($_.Exception.Message)"
        }
        Start-Sleep -Seconds 1
        try {
            $checkVm = Get-VM -Id $vmId -ErrorAction Stop
            if (@(HvtRepl $checkVm).Count -eq 0) { return 'Removed' }
        } catch {}
    }

    # 3. Fallback to WMI Msvm_ReplicationService.RemoveReplicationRelationship
    if ($vmWmi -and $repSvc) {
        try {
            $res = $repSvc.RemoveReplicationRelationship($vmWmi.__PATH)
            $job = HvtWaitWmiJob $res
            if ($job -and $job.JobState -ne 7) {
                $lastErr = "WMI job failed (Code $($job.ErrorCode)): $($job.ErrorDescription)"
            }
        } catch {
            $lastErr = "$($_.Exception.Message)"
        }
        Start-Sleep -Seconds 1
        try {
            $checkVm = Get-VM -Id $vmId -ErrorAction Stop
            if (@(HvtRepl $checkVm).Count -eq 0) { return 'Removed' }
        } catch {}

        # 4. Extended fallback via RemoveReplicationRelationshipEx on Msvm_ReplicationRelationship
        try {
            $relWmiList = @($vmWmi.GetRelated('Msvm_ReplicationRelationship'))
            foreach ($relWmi in $relWmiList) {
                if (-not $relWmi) { continue }
                $exRes = $repSvc.RemoveReplicationRelationshipEx($vmWmi.__PATH, $relWmi.GetText(1))
                [void](HvtWaitWmiJob $exRes)
            }
        } catch {
            $lastErr = "$($_.Exception.Message)"
        }
        Start-Sleep -Seconds 2
        try {
            $checkVm = Get-VM -Id $vmId -ErrorAction Stop
            if (@(HvtRepl $checkVm).Count -eq 0) { return 'Removed' }
        } catch {}
    }

    throw "Remove-VMReplication failed: $lastErr"
}
'@

# ---------------------------------------------------------------------------
# Remote script blocks. Signature is always param($H, $A):
#   $H = helper source text, $A = hashtable of arguments.
# ---------------------------------------------------------------------------

# Read-only: one row per VM on the host
$script:SbScan = {
    param($H, $A)
    . ([scriptblock]::Create($H))
    try {
        $os = Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue
        $vms = @()
        foreach ($vm in @(Get-VM -ErrorAction Stop)) {
            $ck = @(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue | Where-Object { "$($_.SnapshotType)" -eq 'Standard' } | Sort-Object CreationTime)
            $oldest = -1
            if ($ck.Count -gt 0) { $oldest = [int]((Get-Date) - $ck[0].CreationTime).TotalDays }
            $vms += @{
                VMId         = $vm.Id.ToString()
                VMName       = "$($vm.Name)"
                State        = "$($vm.State)"
                Created      = (HvtDate $vm.CreationTime)
                MemGB        = [math]::Round(($vm.MemoryStartup / 1GB), 1)
                Rels         = @(HvtRepl $vm)
                CkCount      = $ck.Count
                CkOldestDays = $oldest
            }
        }
        $ver = ''
        if ($os) { $ver = "$($os.Version)" }
        return @{ HostName = $env:COMPUTERNAME; OsVersion = $ver; Error = ''; VMs = $vms }
    } catch {
        return @{ HostName = $env:COMPUTERNAME; OsVersion = ''; Error = "$($_.Exception.Message)"; VMs = @() }
    }
}

# Read-only: full detail of one VM (disk chain, sizes, replication, settings)
$script:SbVmDetail = {
    param($H, $A)
    . ([scriptblock]::Create($H))
    $vm = Get-VM -Id $A.VMId -ErrorAction SilentlyContinue
    if (-not $vm) {
        $def = ''
        $rs = Get-VMReplicationServer -ErrorAction SilentlyContinue
        if ($rs) { $def = "$($rs.DefaultStorageLocation)" }
        return @{ Found = $false; HostName = $env:COMPUTERNAME; FreeBytes = (HvtFree $def); StoragePath = $def }
    }
    $chain = HvtChain $vm $false
    $files = @(HvtFiles $chain.Paths)
    $total = 0
    foreach ($f in $files) { $total += $f.Bytes }
    $shared = @()
    if ($A.CheckShared) { $shared = @(HvtSharedRefs $A.VMId $chain.Paths) }
    $first = ''
    if ($files.Count -gt 0) { $first = $files[0].Path }
    $test = $false
    if (Get-VM -Name ($vm.Name + ' - Test') -ErrorAction SilentlyContinue) { $test = $true }

    $settings = $null
    $rel = @(Get-VMReplication -VM $vm -ErrorAction SilentlyContinue | Where-Object { "$($_.Mode)" -eq 'Primary' }) | Select-Object -First 1
    if ($rel) {
        $ex = @()
        if ($rel.ExcludedDisks) {
            foreach ($d in @($rel.ExcludedDisks)) { if ($d.Path) { $ex += "$($d.Path)" } }
        } elseif ($rel.ReplicatedDisks) {
            $rp = @($rel.ReplicatedDisks | ForEach-Object { $_.Path })
            foreach ($d in @($vm.HardDrives)) { if ($d.Path -and ($rp -notcontains $d.Path)) { $ex += "$($d.Path)" } }
        }
        $settings = @{
            ReplicaServer = "$($rel.ReplicaServer)"
            ReplicaPort   = [int]$rel.ReplicaPort
            Auth          = "$($rel.AuthenticationType)"
            FreqSec       = [int]$rel.ReplicationFrequencySec
            Thumbprint    = "$($rel.CertificateThumbprint)"
            Compression   = [bool]$rel.CompressionEnabled
            RecHist       = [int]$rel.RecoveryHistory
            VssHour       = [int]$rel.VSSSnapshotFrequencyHour
            Excluded      = @($ex)
            AutoResync    = [bool]$rel.AutoResynchronizeEnabled
        }
    }
    $disks = @()
    foreach ($d in @($vm.HardDrives)) { if ($d.Path) { $disks += "$($d.Path)" } }
    return @{
        Found         = $true
        HostName      = $env:COMPUTERNAME
        Name          = "$($vm.Name)"
        State         = "$($vm.State)"
        Generation    = [int]$vm.Generation
        Created       = (HvtDate $vm.CreationTime)
        MemGB         = [math]::Round(($vm.MemoryStartup / 1GB), 1)
        Cpu           = [int]$vm.ProcessorCount
        Rels          = @(HvtRepl $vm)
        Disks         = $disks
        Files         = $files
        TotalBytes    = $total
        ChainWarnings = @($chain.Warnings)
        Shared        = $shared
        TestVm        = $test
        FreeBytes     = (HvtFree $first)
        StoragePath   = $first
        Settings      = $settings
    }
}

# DESTRUCTIVE: remove a VM and exactly the approved disk files, after re-validation
$script:SbRemoveVmGuarded = {
    param($H, $A)
    . ([scriptblock]::Create($H))
    $vm = HvtGuardVm $A
    $rels = @(HvtRepl $vm)
    if ($A.ExpectMode -eq 'Replica') {
        if ($rels.Count -ne 1 -or $rels[0].Mode -ne 'Replica') {
            throw "VM '$($vm.Name)' on $env:COMPUTERNAME is no longer a plain Replica. Aborted, nothing changed."
        }
        if ($A.ExpectPrimary -and (HvtShort $rels[0].Primary) -ne $A.ExpectPrimary) {
            throw "Replica '$($vm.Name)' now points at primary '$($rels[0].Primary)', expected '$($A.ExpectPrimary)'. Aborted, nothing changed."
        }
    } elseif ($A.ExpectMode -eq 'None') {
        if ($rels.Count -ne 0) { throw "VM '$($vm.Name)' now has replication configured. Aborted, nothing changed." }
    } else {
        throw "Internal error: unknown ExpectMode '$($A.ExpectMode)'."
    }
    # A replica that is not Off may be failed over and serving production
    if ("$($vm.State)" -ne 'Off') { throw "VM '$($vm.Name)' is $($vm.State), not Off. Aborted, nothing changed." }

    $chain = HvtChain $vm $false
    $approved = @{}
    foreach ($p in @($A.Approved)) { $approved["$p".ToLowerInvariant()] = $true }
    foreach ($p in @($chain.Paths)) {
        if (-not $approved.ContainsKey("$p".ToLowerInvariant())) {
            throw "Disk set changed since the plan was shown (new file: $p). Aborted, nothing changed."
        }
    }
    $shared = @(HvtSharedRefs $A.VMId $chain.Paths)
    if ($shared.Count -gt 0) { throw ("Disk files are used by another VM: " + ($shared -join '; ') + ". Aborted, nothing changed.") }

    # Remove the VM registration first; files are only deleted once that succeeded
    $removed = $false
    try { Remove-VM -VM $vm -Force -Confirm:$false -ErrorAction Stop; $removed = $true } catch { $firstErr = "$($_.Exception.Message)" }
    if (-not $removed) {
        if ($rels.Count -gt 0) {
            try { [void](HvtRemoveReplSafe $A.VMId) } catch {}
        }
        for ($i = 0; $i -lt 12 -and -not $removed; $i++) {
            Start-Sleep -Seconds 5
            try { Remove-VM -VM (Get-VM -Id $A.VMId -ErrorAction Stop) -Force -Confirm:$false -ErrorAction Stop; $removed = $true } catch { $firstErr = "$($_.Exception.Message)" }
        }
    }
    if (-not $removed) { throw "Remove-VM failed: $firstErr. No disk file was deleted." }

    $deleted = @(); $failed = @(); $freed = 0
    foreach ($p in @($chain.Paths)) {
        foreach ($f in @($p, ($p + '.mrt'), ($p + '.rct'))) {
            if (-not (Test-Path -LiteralPath $f)) { continue }
            try {
                $len = [double](Get-Item -LiteralPath $f).Length
                Remove-Item -LiteralPath $f -Force -ErrorAction Stop
                $deleted += $f; $freed += $len
            } catch { $failed += ("{0}: {1}" -f $f, $_.Exception.Message) }
        }
    }
    return @{ Deleted = $deleted; Failed = $failed; FreedBytes = $freed }
}

# Remove the replication relationship on the PRIMARY side (VM itself is untouched)
$script:SbRemovePrimaryRepl = {
    param($H, $A)
    . ([scriptblock]::Create($H))
    $vm = HvtGuardVm $A
    $rels = @(HvtRepl $vm)
    if ($rels.Count -eq 0) { return 'AlreadyNone' }
    if ($rels.Count -ne 1 -or $rels[0].Mode -ne 'Primary') {
        throw "VM '$($vm.Name)' on $env:COMPUTERNAME is not a plain Primary (mode: $(@($rels | ForEach-Object { $_.Mode }) -join ',')). Aborted."
    }
    return (HvtRemoveReplSafe $A.VMId)
}

# Detach a replica VM from replication but keep the VM and its disks
$script:SbDetachReplica = {
    param($H, $A)
    . ([scriptblock]::Create($H))
    $vm = HvtGuardVm $A
    $rels = @(HvtRepl $vm)
    if ($rels.Count -ne 1 -or $rels[0].Mode -ne 'Replica') { throw "VM '$($vm.Name)' is not a plain Replica. Aborted." }
    if ("$($vm.State)" -ne 'Off') { throw "Replica '$($vm.Name)' is $($vm.State), not Off. Aborted." }
    [void](HvtRemoveReplSafe $A.VMId)
    return 'Detached'
}

# Enable replication on the primary with the given settings and start initial sync
$script:SbEnableRepl = {
    param($H, $A)
    . ([scriptblock]::Create($H))
    $vm = HvtGuardVm $A
    if (@(HvtRepl $vm).Count -gt 0) { throw "Replication is already configured on '$($vm.Name)'. Aborted." }
    $s = $A.Settings
    $known = (Get-Command Enable-VMReplication).Parameters
    $p = @{
        VM                 = $vm
        ReplicaServerName  = "$($s.ReplicaServer)"
        ReplicaServerPort  = [int]$s.ReplicaPort
        AuthenticationType = "$($s.Auth)"
        CompressionEnabled = [bool]$s.Compression
        RecoveryHistory    = [int]$s.RecHist
        ErrorAction        = 'Stop'
    }
    if ([int]$s.FreqSec -gt 0 -and $known.ContainsKey('ReplicationFrequencySec')) { $p.ReplicationFrequencySec = [int]$s.FreqSec }
    if ([int]$s.VssHour -gt 0 -and [int]$s.RecHist -gt 0) {
        if ($known.ContainsKey('VSSSnapshotFrequencyHour')) { $p.VSSSnapshotFrequencyHour = [int]$s.VssHour }
        elseif ($known.ContainsKey('VSSSnapshotFrequency')) { $p.VSSSnapshotFrequency = [int]$s.VssHour }
    }
    if ("$($s.Auth)" -eq 'Certificate' -and $s.Thumbprint) { $p.CertificateThumbprint = "$($s.Thumbprint)" }
    $ex = @($s.Excluded | Where-Object { $_ })
    if ($ex.Count -gt 0) { $p.ExcludedVhdPath = [string[]]$ex }
    if ($null -ne $s.AutoResync) { $p.AutoResynchronizeEnabled = [bool]$s.AutoResync }
    Enable-VMReplication @p
    $freshVm = Get-VM -Id $A.VMId -ErrorAction Stop
    if ($A.Start) { Start-VMInitialReplication -VM $freshVm -ErrorAction Stop }
    return @(HvtRepl (Get-VM -Id $A.VMId -ErrorAction Stop))
}

# Non-destructive: resume / start initial replication / resynchronize
$script:SbResumeRepl = {
    param($H, $A)
    . ([scriptblock]::Create($H))
    $vm = HvtGuardVm $A
    $rel = @(HvtRepl $vm) | Where-Object { $_.Mode -eq 'Primary' } | Select-Object -First 1
    if (-not $rel) { throw "VM '$($vm.Name)' is not in Primary mode on $env:COMPUTERNAME. Aborted." }
    if ($A.Resync) {
        Resume-VMReplication -VM $vm -Resynchronize -ErrorAction Stop
    } elseif ($rel.State -match 'InitialReplication' -and $rel.State -notmatch 'InProgress') {
        Start-VMInitialReplication -VM $vm -ErrorAction Stop
    } else {
        Resume-VMReplication -VM $vm -ErrorAction Stop
    }
    Start-Sleep -Seconds 3
    return @(HvtRepl $vm)
}

# Read-only: what a host offers as a replica server
$script:SbTargetInfo = {
    param($H, $A)
    . ([scriptblock]::Create($H))
    $rs = Get-VMReplicationServer -ErrorAction Stop
    $cs = Get-WmiObject Win32_ComputerSystem -ErrorAction SilentlyContinue
    $fqdn = $env:COMPUTERNAME
    if ($cs -and $cs.PartOfDomain) { $fqdn = ("{0}.{1}" -f $env:COMPUTERNAME, $cs.Domain) }
    $exists = $false
    if (Get-VM -Id $A.VMId -ErrorAction SilentlyContinue) { $exists = $true }
    return @{
        Enabled     = [bool]$rs.ReplicationEnabled
        AuthType    = "$($rs.AllowedAuthenticationType)"
        KerbPort    = [int]$rs.KerberosAuthenticationPort
        CertPort    = [int]$rs.CertificateAuthenticationPort
        Fqdn        = $fqdn.ToLowerInvariant()
        VmExists    = $exists
        StoragePath = "$($rs.DefaultStorageLocation)"
        FreeBytes   = (HvtFree "$($rs.DefaultStorageLocation)")
    }
}

# Read-only: copy settings from an existing primary relationship on this host
$script:SbTemplate = {
    param($H, $A)
    . ([scriptblock]::Create($H))
    $all = @(Get-VMReplication -ErrorAction SilentlyContinue | Where-Object { "$($_.Mode)" -eq 'Primary' })
    $same = @($all | Where-Object { (HvtShort $_.ReplicaServer) -eq $A.TargetShort }) | Select-Object -First 1
    $cert = @($all | Where-Object { "$($_.AuthenticationType)" -eq 'Certificate' -and $_.CertificateThumbprint }) | Select-Object -First 1
    $out = @{ Template = $null; AnyThumbprint = '' }
    if ($cert) { $out.AnyThumbprint = "$($cert.CertificateThumbprint)" }
    if ($same) {
        $vmName = ''
        $tv = Get-VM -Id $same.VMId -ErrorAction SilentlyContinue
        if ($tv) { $vmName = "$($tv.Name)" }
        $out.Template = @{
            FromVM        = $vmName
            ReplicaServer = "$($same.ReplicaServer)"
            ReplicaPort   = [int]$same.ReplicaPort
            Auth          = "$($same.AuthenticationType)"
            FreqSec       = [int]$same.ReplicationFrequencySec
            Thumbprint    = "$($same.CertificateThumbprint)"
            Compression   = [bool]$same.CompressionEnabled
            RecHist       = [int]$same.RecoveryHistory
            VssHour       = [int]$same.VSSSnapshotFrequencyHour
            AutoResync    = [bool]$same.AutoResynchronizeEnabled
        }
    }
    return $out
}

# Read-only: standard checkpoints of one VM older than N days
$script:SbCkList = {
    param($H, $A)
    . ([scriptblock]::Create($H))
    $vm = Get-VM -Id $A.VMId -ErrorAction Stop
    $limit = (Get-Date).AddDays(-[int]$A.Days)
    $snaps = @()
    foreach ($s in @(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue | Where-Object { "$($_.SnapshotType)" -eq 'Standard' -and $_.CreationTime -lt $limit } | Sort-Object CreationTime)) {
        $snaps += @{
            Id      = $s.Id.ToString()
            Name    = "$($s.Name)"
            Created = (HvtDate $s.CreationTime)
            AgeDays = [int]((Get-Date) - $s.CreationTime).TotalDays
        }
    }
    return @{ Name = "$($vm.Name)"; State = "$($vm.State)"; Rels = @(HvtRepl $vm); Snaps = $snaps }
}

# DESTRUCTIVE: remove the approved checkpoints by Id (merge runs in background)
$script:SbCkRemove = {
    param($H, $A)
    . ([scriptblock]::Create($H))
    $vm = HvtGuardVm $A
    foreach ($r in @(HvtRepl $vm)) {
        if ($r.Mode -ne 'Primary') { throw "VM '$($vm.Name)' is in $($r.Mode) mode; its checkpoints are not touched. Aborted." }
        if ($r.Health -ne 'Normal') { throw "Replication health of '$($vm.Name)' is $($r.Health). Fix replication first. Aborted." }
    }
    $done = @(); $failed = @()
    foreach ($want in @($A.Snaps)) {
        try {
            $s = @(Get-VMSnapshot -VM $vm -ErrorAction Stop | Where-Object { $_.Id.ToString() -eq "$($want.Id)" }) | Select-Object -First 1
            if (-not $s) { throw 'checkpoint no longer exists' }
            if ("$($s.SnapshotType)" -ne 'Standard') { throw "checkpoint type is $($s.SnapshotType)" }
            if ((HvtDate $s.CreationTime) -ne "$($want.Created)") { throw 'checkpoint creation time changed' }
            Remove-VMSnapshot -VMSnapshot $s -Confirm:$false -ErrorAction Stop
            $done += "$($want.Name)"
        } catch {
            $failed += ("{0}: {1}" -f $want.Name, $_.Exception.Message)
            break
        }
    }
    return @{ Removed = $done; Failed = $failed }
}

# Export a VM to a local folder on its host before deletion
$script:SbExport = {
    param($H, $A)
    . ([scriptblock]::Create($H))
    $vm = HvtGuardVm $A
    if (-not (Test-Path -LiteralPath $A.Path)) { throw "Export path '$($A.Path)' does not exist on $env:COMPUTERNAME." }
    $free = HvtFree $A.Path
    if ($free -ge 0 -and $free -lt ([double]$A.NeedBytes * 1.05)) { throw "Not enough free space on $($A.Path) for the export." }
    Export-VM -VM $vm -Path $A.Path -ErrorAction Stop
    $sum = (Get-ChildItem -LiteralPath (Join-Path $A.Path $vm.Name) -Recurse -File -ErrorAction Stop | Measure-Object -Property Length -Sum).Sum
    if (-not $sum -or [double]$sum -lt ([double]$A.NeedBytes * 0.5)) { throw "Export looks incomplete ($sum bytes). VM was NOT deleted." }
    return [double]$sum
}

# ---------------------------------------------------------------------------
# Local helpers
# ---------------------------------------------------------------------------
function Get-HVTShortName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    return (($Name.Trim()) -split '\.')[0].ToUpperInvariant()
}

function Test-HVTLocal {
    param([string]$Short)
    return ($Short -eq 'LOCALHOST' -or $Short -eq "$($env:COMPUTERNAME)".ToUpperInvariant())
}

function Format-HVTSize {
    param($Bytes)
    $b = [double]$Bytes
    if ($b -lt 0) { return 'unknown' }
    if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
    return ('{0:N0} MB' -f ($b / 1MB))
}

function Initialize-HVToolkit {
    param([string]$HostsFile, [string]$LogDir, [switch]$PreviewOnly)
    $script:HVT.HostsFile = $HostsFile
    if ($LogDir) { $script:HVT.LogDir = $LogDir }
    $script:HVT.PreviewOnly = [bool]$PreviewOnly
    $script:HVT.Fleet = $null
    $script:HVT.Verified = @{}
    Read-HVTHosts | Out-Null
}

function Read-HVTHosts {
    if (-not (Test-Path -LiteralPath $script:HVT.HostsFile)) { throw "hosts.txt not found: $($script:HVT.HostsFile)" }
    $list = @()
    foreach ($line in Get-Content -LiteralPath $script:HVT.HostsFile) {
        $t = "$line".Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $s = Get-HVTShortName $t
        if ($list -notcontains $s) { $list += $s }
    }
    $script:HVT.Hosts = $list
    $script:HVT.Fleet = $null
    return $list
}

function Get-HVTState { return $script:HVT }
function Set-HVTLogDir { param([string]$Path) $script:HVT.LogDir = $Path }
function Clear-HVTFleet { $script:HVT.Fleet = $null }

function Write-HVTLog {
    param($HostName, $VMName, $VMId, $Action, $Result, $Detail)
    try {
        $dir = $script:HVT.LogDir
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $row = New-Object PSObject -Property ([ordered]@{
            Time     = (Get-Date).ToString('s')
            Operator = ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
            From     = $env:COMPUTERNAME
            Host     = "$HostName"
            VM       = "$VMName"
            VMId     = "$VMId"
            Action   = "$Action"
            Result   = "$Result"
            Detail   = "$Detail"
        })
        $row | Export-Csv -LiteralPath (Join-Path $dir 'HVToolkit_Audit.csv') -Append -NoTypeInformation -Encoding UTF8
    } catch { Write-Warning "Could not write audit log: $($_.Exception.Message)" }
}

function Save-HVTPlan {
    # Persist a plan as JSON. Folder 'Pending' holds resets that are not finished.
    param($Plan, [string]$Folder = 'Plans', [string]$FileName)
    $dir = Join-Path $script:HVT.LogDir $Folder
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (-not $FileName) {
        $safe = ("$($Plan.VMName)" -replace '[^A-Za-z0-9_\-]', '_')
        $FileName = ('{0}_{1}_{2}.json' -f (Get-Date).ToString('yyyyMMdd_HHmmss'), $Plan.Action, $safe)
    }
    $path = Join-Path $dir $FileName
    ($Plan | ConvertTo-Json -Depth 8) | Out-File -LiteralPath $path -Encoding utf8
    return $path
}

function Invoke-HVT {
    # Single gateway for everything that runs on a host
    param([string]$HostName, [scriptblock]$ScriptBlock, [hashtable]$Arguments = @{})
    $short = Get-HVTShortName $HostName
    if ($script:HVT.Hosts -notcontains $short) {
        throw "Host '$HostName' is not listed in hosts.txt. The toolkit refuses to touch it."
    }
    if (Test-HVTLocal $short) { return (& $ScriptBlock $script:RemoteHelpers $Arguments) }
    if (-not $script:HVT.Verified[$short]) {
        $actual = Invoke-Command -ComputerName $short -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
        if ("$actual".ToUpperInvariant() -ne $short) {
            throw "Identity check failed: '$short' answered as '$actual'. Check DNS / hosts file. Nothing was run."
        }
        $script:HVT.Verified[$short] = $true
    }
    return (Invoke-Command -ComputerName $short -ScriptBlock $ScriptBlock -ArgumentList $script:RemoteHelpers, $Arguments -ErrorAction Stop)
}

# ---------------------------------------------------------------------------
# Fleet scan and cross-host correlation
# ---------------------------------------------------------------------------
function Update-HVTFleet {
    $hosts = @($script:HVT.Hosts)
    Write-Host ("Scanning {0} host(s) in parallel..." -f $hosts.Count) -ForegroundColor Cyan
    $results = @()
    $errs = @()
    $remote = @($hosts | Where-Object { -not (Test-HVTLocal $_) })
    foreach ($h in $hosts) {
        if (Test-HVTLocal $h) { $results += (& $script:SbScan $script:RemoteHelpers @{}) }
    }
    if ($remote.Count -gt 0) {
        $results += @(Invoke-Command -ComputerName $remote -ScriptBlock $script:SbScan -ArgumentList $script:RemoteHelpers, @{} -ErrorAction SilentlyContinue -ErrorVariable errs)
    }

    $fleet = @{ ScannedAt = Get-Date; Hosts = @{}; VMs = @(); AllOk = $true }
    foreach ($h in $hosts) { $fleet.Hosts[$h] = @{ Ok = $false; Error = 'No response (WinRM unreachable or access denied)'; OsVersion = ''; VMCount = 0 } }
    foreach ($e in @($errs)) {
        $t = Get-HVTShortName "$($e.TargetObject)"
        if ($t -and $fleet.Hosts.ContainsKey($t)) { $fleet.Hosts[$t].Error = "$($e.Exception.Message)".Split("`n")[0] }
    }

    $rows = New-Object System.Collections.ArrayList
    foreach ($res in $results) {
        if (-not $res) { continue }
        $h = Get-HVTShortName "$($res.HostName)"
        if (-not $fleet.Hosts.ContainsKey($h)) {
            Write-Warning "A host answered as '$h', which is not in hosts.txt. Its data is ignored."
            continue
        }
        if ($res.Error) { $fleet.Hosts[$h].Error = "$($res.Error)"; continue }
        $script:HVT.Verified[$h] = $true
        $fleet.Hosts[$h].Ok = $true
        $fleet.Hosts[$h].Error = ''
        $fleet.Hosts[$h].OsVersion = "$($res.OsVersion)"
        $fleet.Hosts[$h].VMCount = @($res.VMs).Count
        foreach ($v in @($res.VMs)) {
            if (-not $v) { continue }
            $rels = @($v.Rels | Where-Object { $_ })
            $main = $null
            foreach ($r in $rels) { if ($r.RelType -ne 'Extended') { $main = $r; break } }
            if (-not $main -and $rels.Count -gt 0) { $main = $rels[0] }
            $ext = ($rels.Count -gt 1)
            foreach ($r in $rels) { if ($r.RelType -eq 'Extended' -or $r.Mode -eq 'ExtendedReplica') { $ext = $true } }
            $row = New-Object PSObject -Property @{
                HostName     = $h
                VMId         = "$($v.VMId)"
                VMName       = "$($v.VMName)"
                State        = "$($v.State)"
                Created      = "$($v.Created)"
                MemGB        = $v.MemGB
                Mode         = $(if ($main) { "$($main.Mode)" } else { 'None' })
                Health       = $(if ($main) { "$($main.Health)" } else { '' })
                RepState     = $(if ($main) { "$($main.State)" } else { '' })
                PrimaryHost  = $(if ($main) { Get-HVTShortName $main.Primary } else { '' })
                ReplicaHost  = $(if ($main) { Get-HVTShortName $main.Replica } else { '' })
                LastRep      = $(if ($main) { "$($main.LastRep)" } else { '' })
                Rels         = $rels
                Extended     = $ext
                CkCount      = [int]$v.CkCount
                CkOldestDays = [int]$v.CkOldestDays
                Flag         = ''
                Issue        = ''
            }
            [void]$rows.Add($row)
        }
    }
    foreach ($h in $hosts) { if (-not $fleet.Hosts[$h].Ok) { $fleet.AllOk = $false } }

    # Index rows by VMId: the same Id on several hosts means primary/replica/stale copies
    $byId = @{}
    foreach ($r in $rows) {
        if (-not $byId.ContainsKey($r.VMId)) { $byId[$r.VMId] = New-Object System.Collections.ArrayList }
        [void]$byId[$r.VMId].Add($r)
    }
    foreach ($r in $rows) {
        $others = @($byId[$r.VMId] | Where-Object { $_.HostName -ne $r.HostName })
        if ($r.Extended) { $r.Flag = 'Extended'; $r.Issue = 'extended replication chain' }
        if ($r.Mode -eq 'Primary') {
            $rh = $r.ReplicaHost
            if (-not $fleet.Hosts.ContainsKey($rh)) { $r.Flag = 'ReplicaOutside'; $r.Issue = "replica host $rh not in hosts.txt" }
            elseif (-not $fleet.Hosts[$rh].Ok) { if (-not $r.Flag) { $r.Flag = 'ReplicaHostDown'; $r.Issue = "replica host $rh not reachable" } }
            else {
                $p = @($others | Where-Object { $_.HostName -eq $rh }) | Select-Object -First 1
                if (-not $p) { $r.Flag = 'ReplicaMissing'; $r.Issue = "replica VM missing on $rh" }
                elseif ($p.Mode -notmatch 'Replica' -and -not $r.Flag) { $r.Flag = 'ReplicaMismatch'; $r.Issue = "copy on $rh is in mode $($p.Mode)" }
            }
        } elseif ($r.Mode -eq 'Replica' -and -not $r.Extended) {
            $ph = $r.PrimaryHost
            # Is any scanned host a primary that replicates this VM to this host?
            $feeder = @($others | Where-Object {
                $hit = $false
                foreach ($x in @($_.Rels)) { if ($x.Mode -eq 'Primary' -and (Get-HVTShortName $x.Replica) -eq $r.HostName) { $hit = $true } }
                $hit
            }) | Select-Object -First 1
            if ($feeder) { }
            elseif (-not $fleet.Hosts.ContainsKey($ph)) { $r.Flag = 'Unverified'; $r.Issue = "primary host $ph not in hosts.txt - cannot verify" }
            elseif (-not $fleet.AllOk) { $r.Flag = 'Unverified'; $r.Issue = 'not every host was scanned - cannot verify' }
            else {
                $p = @($others | Where-Object { $_.HostName -eq $ph }) | Select-Object -First 1
                $r.Flag = 'Orphan'
                if (-not $p) { $r.Issue = "ORPHAN: VM not found on primary $ph" }
                elseif ($p.Mode -eq 'None') { $r.Issue = "ORPHAN: replication disabled on primary $ph" }
                else { $r.Issue = "ORPHAN: primary $ph replicates to $($p.ReplicaHost)" }
            }
        } elseif ($r.Mode -eq 'None' -and $others.Count -gt 0) {
            $r.Flag = 'Duplicate'
            $r.Issue = 'same VM Id also on ' + (@($others | ForEach-Object { $_.HostName }) -join ',')
        }
    }
    $fleet.VMs = @($rows)
    $script:HVT.Fleet = $fleet
    return $fleet
}

function Get-HVTFleet {
    param([switch]$Refresh, [int]$MaxAgeMinutes = 10)
    $f = $script:HVT.Fleet
    if ($Refresh -or -not $f -or ((Get-Date) - $f.ScannedAt).TotalMinutes -gt $MaxAgeMinutes) { $f = Update-HVTFleet }
    return $f
}

function Get-HVTVMDetail {
    # Read-only live detail of one VM (disk files, sizes, configuration)
    param($Row)
    return (Invoke-HVT $Row.HostName $script:SbVmDetail @{ VMId = $Row.VMId })
}

function Get-HVTCopies {
    # Other hosts that hold a VM with the same Id
    param($Row)
    $f = Get-HVTFleet
    return @($f.VMs | Where-Object { $_.VMId -eq $Row.VMId -and $_.HostName -ne $Row.HostName })
}

# ---------------------------------------------------------------------------
# Console UI helpers
# ---------------------------------------------------------------------------
function Format-HVTRow {
    param($Row)
    $route = ''
    if ($Row.Mode -eq 'Primary') { $route = '-> ' + $Row.ReplicaHost }
    elseif ($Row.Mode -match 'Replica') { $route = '<- ' + $Row.PrimaryHost }
    $name = $Row.VMName
    if ($name.Length -gt 34) { $name = $name.Substring(0, 33) + '~' }
    return ('{0,-34} {1,-12} {2,-8} {3,-8} {4,-8} {5,-15} {6}' -f $name, $Row.HostName, $Row.State, $Row.Mode, $Row.Health, $route, $Row.Issue)
}

function Get-HVTRowColor {
    param($Row)
    if ($Row.Health -eq 'Critical' -or $Row.Flag -eq 'Orphan') { return 'Red' }
    if ($Row.Health -eq 'Warning' -or $Row.Flag) { return 'Yellow' }
    if ($Row.Health -eq 'Normal') { return 'Green' }
    return 'Gray'
}

function ConvertTo-HVTIndex {
    param([string]$Text, [int]$Max)
    $out = @()
    foreach ($part in ($Text -split ',')) {
        $p = $part.Trim()
        if ($p -match '^(\d+)\s*-\s*(\d+)$') {
            $a = [int]$Matches[1]; $b = [Math]::Min([int]$Matches[2], $Max)
            for ($n = $a; $n -le $b; $n++) { if ($n -ge 1 -and $out -notcontains $n) { $out += $n } }
        } elseif ($p -match '^\d+$') {
            $n = [int]$p
            if ($n -ge 1 -and $n -le $Max -and $out -notcontains $n) { $out += $n }
        }
    }
    return ,$out
}

function Select-HVTItem {
    # Numbered list with type-to-search. Returns the chosen items (empty = cancelled).
    param(
        [object[]]$Items,
        [scriptblock]$Format,
        [scriptblock]$Color,
        [string]$Title,
        [string]$Header,
        [switch]$Single,
        [int]$PageSize = 40
    )
    $filter = ''
    while ($true) {
        $view = @($Items)
        if ($filter) { $view = @($Items | Where-Object { (& $Format $_) -like "*$filter*" }) }
        Write-Host ''
        Write-Host ("--- {0} ---" -f $Title) -ForegroundColor Cyan
        if ($filter) { Write-Host ("Search: '{0}'  ({1} match)" -f $filter, $view.Count) -ForegroundColor DarkCyan }
        if ($Header) { Write-Host ('      ' + $Header) -ForegroundColor DarkGray }
        $shown = [Math]::Min($view.Count, $PageSize)
        for ($i = 0; $i -lt $shown; $i++) {
            $c = 'Gray'
            if ($Color) { $c = (& $Color $view[$i]) }
            Write-Host ('[{0,3}] {1}' -f ($i + 1), (& $Format $view[$i])) -ForegroundColor $c
        }
        if ($view.Count -eq 0) { Write-Host '  (nothing matches)' -ForegroundColor DarkGray }
        if ($view.Count -gt $shown) { Write-Host ("  ... {0} more not shown. Type part of a name to narrow the list." -f ($view.Count - $shown)) -ForegroundColor DarkGray }
        $hint = 'Number(s) e.g. 1,3-5'
        if ($Single) { $hint = 'Number' }
        $ans = (Read-Host ("{0} | text = search | * = clear search | Enter = back" -f $hint)).Trim()
        if ($ans -eq '') { return @() }
        if ($ans -eq '*') { $filter = ''; continue }
        if ($ans -match '^[\d\s,\-]+$') {
            $idx = ConvertTo-HVTIndex $ans $shown
            if ($idx.Count -eq 0) { Write-Host 'No valid number.' -ForegroundColor Red; continue }
            if ($Single) { return @($view[$idx[0] - 1]) }
            return @($idx | ForEach-Object { $view[$_ - 1] })
        }
        $filter = $ans
    }
}

function Confirm-HVT {
    # Typed confirmation. In preview mode nothing is ever confirmed.
    param([string]$Word, [string]$What)
    if ($script:HVT.PreviewOnly) {
        Write-Host '[PREVIEW ONLY] Plan shown, nothing was changed.' -ForegroundColor Magenta
        return $false
    }
    Write-Host ''
    Write-Host $What -ForegroundColor Yellow
    $ans = (Read-Host ("Type {0} to proceed (anything else cancels)" -f $Word)).Trim()
    if ($Word.Length -eq 1) { $ok = ($ans -ieq $Word) } else { $ok = ($ans -ceq $Word) }
    if (-not $ok) { Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor DarkGray }
    return $ok
}

function Show-HVTFiles {
    param($Files, [string]$Label)
    $list = @($Files | Where-Object { $_ })
    $sum = 0
    foreach ($f in $list) { $sum += [double]$f.Bytes }
    Write-Host ("{0} ({1} file(s), {2}):" -f $Label, $list.Count, (Format-HVTSize $sum))
    foreach ($f in $list) {
        $note = ''
        if (-not $f.Exists) { $note = '  [file missing]' }
        Write-Host ("    {0}  ({1}){2}" -f $f.Path, (Format-HVTSize $f.Bytes), $note)
    }
}

function Show-HVTIssues {
    param($Plan)
    foreach ($w in @($Plan.Warnings)) { Write-Host ("  WARNING: {0}" -f $w) -ForegroundColor Yellow }
    if (@($Plan.Blockers).Count -gt 0) {
        Write-Host '  BLOCKED - this cannot be executed:' -ForegroundColor Red
        foreach ($b in @($Plan.Blockers)) { Write-Host ("    * {0}" -f $b) -ForegroundColor Red }
    }
}

function Invoke-HVTStep {
    # Run one step, print and log the outcome. Returns @{ Ok; Value }.
    param([string]$Label, [string]$HostName, $Plan, [scriptblock]$Action)
    Write-Host ("  > {0} ... " -f $Label) -NoNewline
    try {
        $v = & $Action
        Write-Host 'OK' -ForegroundColor Green
        Write-HVTLog -HostName $HostName -VMName $Plan.VMName -VMId $Plan.VMId -Action ("{0}: {1}" -f $Plan.Action, $Label) -Result 'Success' -Detail ''
        return @{ Ok = $true; Value = $v }
    } catch {
        Write-Host 'FAILED' -ForegroundColor Red
        Write-Host ("    {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-HVTLog -HostName $HostName -VMName $Plan.VMName -VMId $Plan.VMId -Action ("{0}: {1}" -f $Plan.Action, $Label) -Result 'Failed' -Detail $_.Exception.Message
        return @{ Ok = $false; Value = $null }
    }
}

# ---------------------------------------------------------------------------
# Replication: plan
# ---------------------------------------------------------------------------
$script:FailoverPattern = 'Failover|FailedOver|Failback|Recovery|Firedrill|Repurpose'

function Get-HVTReplPlan {
    # Live plan for a VM that is Primary on $Row.HostName
    param($Row)
    $plan = @{
        Action = 'Replication'; VMId = $Row.VMId; VMName = $Row.VMName
        PrimaryHost = $Row.HostName; ReplicaHost = ''
        Primary = $null; Replica = $null; Settings = $null
        Blockers = @(); Warnings = @(); CreatedAt = (Get-Date).ToString('s')
    }
    try { $pi = Invoke-HVT $Row.HostName $script:SbVmDetail @{ VMId = $Row.VMId } }
    catch { $plan.Blockers += "Cannot query primary host $($Row.HostName): $($_.Exception.Message)"; return $plan }
    $plan.Primary = $pi
    if (-not $pi.Found) { $plan.Blockers += "VM not found on $($Row.HostName) any more. Rescan."; return $plan }
    $rels = @($pi.Rels | Where-Object { $_ })
    if ($rels.Count -ne 1 -or $rels[0].Mode -ne 'Primary' -or $rels[0].RelType -eq 'Extended' -or -not $pi.Settings) {
        $plan.Blockers += ("VM is not a plain Primary on {0} (relationships: {1}). Extended chains must be handled manually." -f $Row.HostName, (@($rels | ForEach-Object { $_.Mode }) -join ','))
        return $plan
    }
    $plan.Settings = $pi.Settings
    $rh = Get-HVTShortName $pi.Settings.ReplicaServer
    $plan.ReplicaHost = $rh
    if ($rels[0].State -match $script:FailoverPattern) { $plan.Blockers += "Primary replication state is '$($rels[0].State)' (failover in progress). Finish or cancel the failover first." }
    if ($rh -eq $Row.HostName) { $plan.Blockers += 'Primary and replica resolve to the same host.' }
    if ($script:HVT.Hosts -notcontains $rh) { $plan.Blockers += "Replica host $rh is not in hosts.txt, so it cannot be verified or cleaned."; return $plan }
    try { $ri = Invoke-HVT $rh $script:SbVmDetail @{ VMId = $Row.VMId; CheckShared = $true } }
    catch { $plan.Blockers += "Cannot query replica host ${rh}: $($_.Exception.Message)"; return $plan }
    $plan.Replica = $ri
    if ($ri.Found) {
        $rr = @($ri.Rels | Where-Object { $_ })
        if ($rr.Count -ne 1 -or $rr[0].Mode -ne 'Replica') {
            $plan.Blockers += ("The copy on {0} is NOT a plain replica (mode: {1}). It will not be deleted." -f $rh, $(if ($rr.Count) { @($rr | ForEach-Object { $_.Mode }) -join ',' } else { 'None' }))
        } else {
            if ((Get-HVTShortName $rr[0].Primary) -ne $Row.HostName) { $plan.Blockers += "Replica on $rh points at primary '$($rr[0].Primary)', not $($Row.HostName)." }
            if ($rr[0].State -match $script:FailoverPattern) { $plan.Blockers += "Replica state is '$($rr[0].State)' (failover / test failover in progress)." }
        }
        if ($ri.State -ne 'Off') { $plan.Blockers += "Replica VM on $rh is $($ri.State), not Off. It may be failed over and live." }
        if ($ri.TestVm) { $plan.Blockers += "A test-failover VM ('$($ri.Name) - Test') exists on $rh. Stop the test failover first." }
        foreach ($s in @($ri.Shared)) { if ($s) { $plan.Blockers += "Replica disk shared with another VM: $s" } }
        foreach ($w in @($ri.ChainWarnings)) { if ($w) { $plan.Warnings += "$w (some checkpoint files may be left behind)" } }
        if ($ri.Name -ne $pi.Name) { $plan.Warnings += "Name differs: primary '$($pi.Name)' vs replica '$($ri.Name)' (same VM Id)." }
    }
    if ([double]$ri.FreeBytes -ge 0) {
        $avail = [double]$ri.FreeBytes
        if ($ri.Found) { $avail += [double]$ri.TotalBytes }
        if ($avail -lt ([double]$pi.TotalBytes * 1.05)) {
            $plan.Warnings += ("Replica storage may be too small for a full initial copy: need about {0}, available after cleanup {1}." -f (Format-HVTSize $pi.TotalBytes), (Format-HVTSize $avail))
        }
    }
    if (@($pi.Settings.Excluded | Where-Object { $_ }).Count -gt 0) { $plan.Warnings += 'Some disks are excluded from replication (listed above). They stay excluded.' }
    return $plan
}

function Show-HVTReplPlan {
    param($Plan)
    $pi = $Plan.Primary; $ri = $Plan.Replica; $s = $Plan.Settings
    Write-Host ''
    Write-Host ("=== {0} ===" -f $Plan.VMName) -ForegroundColor Cyan
    Write-Host ("  VM Id        : {0}" -f $Plan.VMId)
    if ($pi -and $pi.Found) {
        $rel = @($pi.Rels | Where-Object { $_ }) | Select-Object -First 1
        Write-Host ("  Primary      : {0}  (VM {1}, {2} on disk)" -f $Plan.PrimaryHost, $pi.State, (Format-HVTSize $pi.TotalBytes))
        if ($rel) {
            $c = 'Gray'
            if ($rel.Health -eq 'Critical') { $c = 'Red' } elseif ($rel.Health -eq 'Warning') { $c = 'Yellow' } elseif ($rel.Health -eq 'Normal') { $c = 'Green' }
            Write-Host ("  Replication  : {0} / {1}   last replicated: {2}" -f $rel.Health, $rel.State, $(if ($rel.LastRep) { $rel.LastRep } else { 'never' })) -ForegroundColor $c
        }
    }
    if ($s) {
        Write-Host ("  Settings     : to {0}:{1}, {2}, every {3}s, recovery points {4}, VSS {5}h, compression {6}" -f $s.ReplicaServer, $s.ReplicaPort, $s.Auth, $s.FreqSec, $s.RecHist, $s.VssHour, $s.Compression)
        foreach ($x in @($s.Excluded | Where-Object { $_ })) { Write-Host ("  Excluded disk: {0}" -f $x) }
    }
    if ($ri) {
        if ($ri.Found) {
            Write-Host ("  Replica      : {0}  (VM {1}, free space {2})" -f $Plan.ReplicaHost, $ri.State, (Format-HVTSize $ri.FreeBytes))
            Show-HVTFiles $ri.Files '  Replica files'
        } else {
            Write-Host ("  Replica      : no VM with this Id on {0} (nothing to delete there)" -f $Plan.ReplicaHost)
        }
    }
    Show-HVTIssues $Plan
}

# ---------------------------------------------------------------------------
# Replication: actions
# ---------------------------------------------------------------------------
function Invoke-HVTReplResume {
    param($Plan, [switch]$Resync)
    $label = 'Resume replication'
    if ($Resync) { $label = 'Resynchronize (compares both sides, no deletion)' }
    if (-not (Confirm-HVT 'Y' ("{0} for '{1}' on {2}?" -f $label, $Plan.VMName, $Plan.PrimaryHost))) { return $false }
    $Plan.Action = $(if ($Resync) { 'Repl-Resync' } else { 'Repl-Resume' })
    $r = Invoke-HVTStep $label $Plan.PrimaryHost $Plan { Invoke-HVT $Plan.PrimaryHost $script:SbResumeRepl @{ VMId = $Plan.VMId; ExpectName = $Plan.VMName; Resync = [bool]$Resync } }
    if ($r.Ok) {
        $rel = @($r.Value | Where-Object { $_ }) | Select-Object -First 1
        if ($rel) { Write-Host ("    Now: {0} / {1}" -f $rel.Health, $rel.State) }
    }
    return $r.Ok
}

function Invoke-HVTReplReset {
    # Delete the replica copy, remove the relationship, re-enable with the same settings
    param($Plan)
    if (@($Plan.Blockers).Count -gt 0) { return $false }
    $ri = $Plan.Replica
    Write-Host ''
    Write-Host '  FULL RESET will:' -ForegroundColor Yellow
    if ($ri.Found) { Write-Host ("    1. DELETE the replica VM and the files listed above on {0}" -f $Plan.ReplicaHost) -ForegroundColor Yellow }
    else { Write-Host '    1. (no replica VM to delete)' -ForegroundColor Yellow }
    Write-Host ("    2. Remove the replication relationship on {0} (the primary VM keeps running)" -f $Plan.PrimaryHost) -ForegroundColor Yellow
    Write-Host ("    3. Re-enable replication with the same settings and start a full initial copy ({0})" -f (Format-HVTSize $Plan.Primary.TotalBytes)) -ForegroundColor Yellow
    if (-not (Confirm-HVT 'DELETE' ("Reset replication of '{0}'  ({1} -> {2})?" -f $Plan.VMName, $Plan.PrimaryHost, $Plan.ReplicaHost))) { return $false }

    $Plan.Action = 'Repl-Reset'
    $pendingName = ('{0}_{1}.json' -f $Plan.VMId, $Plan.PrimaryHost)
    $pending = Save-HVTPlan -Plan $Plan -Folder 'Pending' -FileName $pendingName
    Save-HVTPlan -Plan $Plan | Out-Null

    if ($ri.Found) {
        $files = @($ri.Files | ForEach-Object { $_.Path })
        $r = Invoke-HVTStep ("Delete replica VM and disks on {0}" -f $Plan.ReplicaHost) $Plan.ReplicaHost $Plan {
            Invoke-HVT $Plan.ReplicaHost $script:SbRemoveVmGuarded @{ VMId = $Plan.VMId; ExpectName = $ri.Name; ExpectMode = 'Replica'; ExpectPrimary = $Plan.PrimaryHost; Approved = $files }
        }
        if (-not $r.Ok) {
            Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue
            Write-Host '  Stopped. The primary side was not touched.' -ForegroundColor Yellow
            return $false
        }
        Write-Host ("    Freed {0}" -f (Format-HVTSize $r.Value.FreedBytes))
        foreach ($f in @($r.Value.Failed)) { if ($f) { Write-Host ("    Could not delete: {0}" -f $f) -ForegroundColor Yellow } }
    }
    $r = Invoke-HVTStep ("Remove replication on {0}" -f $Plan.PrimaryHost) $Plan.PrimaryHost $Plan {
        Invoke-HVT $Plan.PrimaryHost $script:SbRemovePrimaryRepl @{ VMId = $Plan.VMId; ExpectName = $Plan.VMName }
    }
    if (-not $r.Ok) {
        $stillHasRepl = $false
        try {
            $piCheck = Invoke-HVT $Plan.PrimaryHost $script:SbVmDetail @{ VMId = $Plan.VMId }
            if (@($piCheck.Rels | Where-Object { $_ }).Count -gt 0) { $stillHasRepl = $true }
        } catch {}
        if ($stillHasRepl) {
            Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue
            Write-Host '  Stopped. Run the reset again for this VM; the replica is already gone, so it will only redo the remaining steps.' -ForegroundColor Yellow
        } else {
            Write-Host ("  Stopped, and primary replication was already removed. Use menu 8 (Finish interrupted reset) to re-enable.`n  Saved file: {0}" -f $pending) -ForegroundColor Red
        }
        return $false
    }
    $r = Invoke-HVTStep 'Enable replication and start initial copy' $Plan.PrimaryHost $Plan {
        Invoke-HVT $Plan.PrimaryHost $script:SbEnableRepl @{ VMId = $Plan.VMId; ExpectName = $Plan.VMName; Settings = $Plan.Settings; Start = $true }
    }
    if (-not $r.Ok) {
        Write-Host '  Replication is currently NOT configured for this VM.' -ForegroundColor Red
        Write-Host ("  The settings are saved. Use menu 8 (Finish interrupted reset) to re-enable.`n  Saved file: {0}" -f $pending) -ForegroundColor Red
        return $false
    }
    Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue
    Write-Host '  Done. Initial replication is running.' -ForegroundColor Green
    return $true
}

function Invoke-HVTReplRemove {
    # Stop replicating a VM. The replica copy is deleted or kept as a standalone VM.
    param($Plan, [switch]$KeepReplica)
    if (@($Plan.Blockers).Count -gt 0) { return $false }
    $ri = $Plan.Replica
    $word = 'DELETE'
    if ($KeepReplica -or -not $ri.Found) { $word = 'Y' }
    Write-Host ''
    Write-Host '  REMOVE REPLICATION will:' -ForegroundColor Yellow
    if ($ri.Found -and -not $KeepReplica) { Write-Host ("    1. DELETE the replica VM and the files listed above on {0}" -f $Plan.ReplicaHost) -ForegroundColor Yellow }
    elseif ($ri.Found) { Write-Host ("    1. Keep the copy on {0} as a normal powered-off VM (no longer updated)" -f $Plan.ReplicaHost) -ForegroundColor Yellow }
    Write-Host ("    2. Remove the replication relationship on {0}. The VM will have NO replica afterwards." -f $Plan.PrimaryHost) -ForegroundColor Yellow
    if (-not (Confirm-HVT $word ("Remove replication of '{0}'  ({1} -> {2})?" -f $Plan.VMName, $Plan.PrimaryHost, $Plan.ReplicaHost))) { return $false }
    $Plan.Action = 'Repl-Remove'
    Save-HVTPlan -Plan $Plan | Out-Null
    if ($ri.Found) {
        if ($KeepReplica) {
            $r = Invoke-HVTStep ("Detach copy on {0}" -f $Plan.ReplicaHost) $Plan.ReplicaHost $Plan {
                Invoke-HVT $Plan.ReplicaHost $script:SbDetachReplica @{ VMId = $Plan.VMId; ExpectName = $ri.Name }
            }
        } else {
            $files = @($ri.Files | ForEach-Object { $_.Path })
            $r = Invoke-HVTStep ("Delete replica VM and disks on {0}" -f $Plan.ReplicaHost) $Plan.ReplicaHost $Plan {
                Invoke-HVT $Plan.ReplicaHost $script:SbRemoveVmGuarded @{ VMId = $Plan.VMId; ExpectName = $ri.Name; ExpectMode = 'Replica'; ExpectPrimary = $Plan.PrimaryHost; Approved = $files }
            }
        }
        if (-not $r.Ok) { Write-Host '  Stopped. The primary side was not touched.' -ForegroundColor Yellow; return $false }
    }
    $r = Invoke-HVTStep ("Remove replication on {0}" -f $Plan.PrimaryHost) $Plan.PrimaryHost $Plan {
        Invoke-HVT $Plan.PrimaryHost $script:SbRemovePrimaryRepl @{ VMId = $Plan.VMId; ExpectName = $Plan.VMName }
    }
    return $r.Ok
}

# ---------------------------------------------------------------------------
# Replication: set up for a VM that has none
# ---------------------------------------------------------------------------
function Get-HVTSetupPlan {
    param($Row, [string]$TargetHost)
    $th = Get-HVTShortName $TargetHost
    $plan = @{
        Action = 'Repl-Setup'; VMId = $Row.VMId; VMName = $Row.VMName
        PrimaryHost = $Row.HostName; ReplicaHost = $th
        Primary = $null; Target = $null; Settings = $null; TemplateFrom = ''
        Blockers = @(); Warnings = @(); CreatedAt = (Get-Date).ToString('s')
    }
    if ($th -eq $Row.HostName) { $plan.Blockers += 'Source and target are the same host.'; return $plan }
    try {
        $pi = Invoke-HVT $Row.HostName $script:SbVmDetail @{ VMId = $Row.VMId }
        $ti = Invoke-HVT $th $script:SbTargetInfo @{ VMId = $Row.VMId }
        $tp = Invoke-HVT $Row.HostName $script:SbTemplate @{ TargetShort = $th }
    } catch { $plan.Blockers += "Query failed: $($_.Exception.Message)"; return $plan }
    $plan.Primary = $pi; $plan.Target = $ti
    if (-not $pi.Found) { $plan.Blockers += 'VM not found any more. Rescan.'; return $plan }
    if (@($pi.Rels | Where-Object { $_ }).Count -gt 0) { $plan.Blockers += 'Replication is already configured for this VM.' }
    if (-not $ti.Enabled) { $plan.Blockers += "$th is not enabled as a Replica server." }
    if ($ti.VmExists) { $plan.Blockers += "A VM with the same Id already exists on $th (old copy). Remove it first (menu 4 or 6)." }
    if ($tp.Template) {
        $t = $tp.Template
        $plan.TemplateFrom = "$($t.FromVM)"
        $plan.Settings = @{ ReplicaServer = $t.ReplicaServer; ReplicaPort = $t.ReplicaPort; Auth = $t.Auth; FreqSec = $t.FreqSec; Thumbprint = $t.Thumbprint; Compression = $t.Compression; RecHist = $t.RecHist; VssHour = $t.VssHour; Excluded = @(); AutoResync = $t.AutoResync }
    } elseif ($ti.AuthType -match 'Kerberos') {
        $plan.Settings = @{ ReplicaServer = $ti.Fqdn; ReplicaPort = $ti.KerbPort; Auth = 'Kerberos'; FreqSec = 300; Thumbprint = ''; Compression = $true; RecHist = 0; VssHour = 0; Excluded = @(); AutoResync = $true }
    } elseif ($tp.AnyThumbprint) {
        $plan.Settings = @{ ReplicaServer = $ti.Fqdn; ReplicaPort = $ti.CertPort; Auth = 'Certificate'; FreqSec = 300; Thumbprint = $tp.AnyThumbprint; Compression = $true; RecHist = 0; VssHour = 0; Excluded = @(); AutoResync = $true }
    } else {
        $plan.Blockers += "$th only accepts certificate authentication and no certificate is in use on $($Row.HostName) yet. Set up the first VM manually."
    }
    if ([double]$ti.FreeBytes -ge 0 -and [double]$ti.FreeBytes -lt ([double]$pi.TotalBytes * 1.05)) {
        $plan.Warnings += ("Target default storage has {0} free; the VM needs about {1}." -f (Format-HVTSize $ti.FreeBytes), (Format-HVTSize $pi.TotalBytes))
    }
    return $plan
}

function Invoke-HVTSetup {
    param($Plan)
    $s = $Plan.Settings
    Write-Host ''
    Write-Host ("=== Set up replication: {0} ===" -f $Plan.VMName) -ForegroundColor Cyan
    Write-Host ("  From         : {0}  ({1} on disk)" -f $Plan.PrimaryHost, (Format-HVTSize $Plan.Primary.TotalBytes))
    Write-Host ("  To           : {0}  (storage {1}, free {2})" -f $Plan.ReplicaHost, $Plan.Target.StoragePath, (Format-HVTSize $Plan.Target.FreeBytes))
    if ($s) {
        Write-Host ("  Settings     : {0}:{1}, {2}, every {3}s, recovery points {4}, compression {5}" -f $s.ReplicaServer, $s.ReplicaPort, $s.Auth, $s.FreqSec, $s.RecHist, $s.Compression)
        if ($Plan.TemplateFrom) { Write-Host ("  Copied from  : existing replication of '{0}'" -f $Plan.TemplateFrom) }
        else { Write-Host '  Copied from  : replica server defaults' }
    }
    Show-HVTIssues $Plan
    if (@($Plan.Blockers).Count -gt 0) { return $false }
    if (-not (Confirm-HVT 'Y' 'Enable replication and start the initial copy now?')) { return $false }
    Save-HVTPlan -Plan $Plan | Out-Null
    $r = Invoke-HVTStep 'Enable replication and start initial copy' $Plan.PrimaryHost $Plan {
        Invoke-HVT $Plan.PrimaryHost $script:SbEnableRepl @{ VMId = $Plan.VMId; ExpectName = $Plan.VMName; Settings = $Plan.Settings; Start = $true }
    }
    return $r.Ok
}

# ---------------------------------------------------------------------------
# Interrupted resets
# ---------------------------------------------------------------------------
function Get-HVTPending {
    $dir = Join-Path $script:HVT.LogDir 'Pending'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $out = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try {
            $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            $out += New-Object PSObject -Property @{ File = $f.FullName; VMId = "$($j.VMId)"; VMName = "$($j.VMName)"; PrimaryHost = "$($j.PrimaryHost)"; ReplicaHost = "$($j.ReplicaHost)"; CreatedAt = "$($j.CreatedAt)"; Settings = $j.Settings }
        } catch { Write-Warning "Unreadable pending file: $($f.FullName)" }
    }
    return $out
}

function Invoke-HVTPending {
    param($Item)
    $plan = @{ Action = 'Repl-Finish'; VMId = $Item.VMId; VMName = $Item.VMName; PrimaryHost = $Item.PrimaryHost; ReplicaHost = $Item.ReplicaHost }
    try {
        $pi = Invoke-HVT $Item.PrimaryHost $script:SbVmDetail @{ VMId = $Item.VMId }
        $ri = Invoke-HVT $Item.ReplicaHost $script:SbVmDetail @{ VMId = $Item.VMId }
    } catch { Write-Host ("Cannot query hosts: {0}" -f $_.Exception.Message) -ForegroundColor Red; return $false }
    if (-not $pi.Found) { Write-Host 'The VM no longer exists on the primary host. Pending entry removed.' -ForegroundColor Yellow; Remove-Item -LiteralPath $Item.File -Force; return $false }
    if (@($pi.Rels | Where-Object { $_ }).Count -gt 0) {
        Write-Host 'Replication is already configured for this VM. Pending entry removed. If it is unhealthy use menu 3.' -ForegroundColor Yellow
        Remove-Item -LiteralPath $Item.File -Force
        return $false
    }
    if ($ri.Found) { Write-Host ("A VM with this Id still exists on {0}. Remove it first (menu 4), then come back." -f $Item.ReplicaHost) -ForegroundColor Red; return $false }
    $s = @{}
    foreach ($p in $Item.Settings.PSObject.Properties) { $s[$p.Name] = $p.Value }
    $s.Excluded = @($s.Excluded | Where-Object { $_ })
    Write-Host ''
    Write-Host ("=== Finish reset: {0} ===" -f $Item.VMName) -ForegroundColor Cyan
    Write-Host ("  {0} -> {1}:{2}, {3}, every {4}s, recovery points {5}" -f $Item.PrimaryHost, $s.ReplicaServer, $s.ReplicaPort, $s.Auth, $s.FreqSec, $s.RecHist)
    if (-not (Confirm-HVT 'Y' 'Re-enable replication with the saved settings and start the initial copy?')) { return $false }
    $r = Invoke-HVTStep 'Enable replication and start initial copy' $Item.PrimaryHost $plan {
        Invoke-HVT $Item.PrimaryHost $script:SbEnableRepl @{ VMId = $Item.VMId; ExpectName = $Item.VMName; Settings = $s; Start = $true }
    }
    if ($r.Ok) { Remove-Item -LiteralPath $Item.File -Force -ErrorAction SilentlyContinue }
    return $r.Ok
}

# ---------------------------------------------------------------------------
# VM removal (orphan replicas and old VMs)
# ---------------------------------------------------------------------------
function Get-HVTRemovePlan {
    # $Kind = 'Orphan' (replica whose primary no longer feeds it) or 'OldVM'
    param($Row, [ValidateSet('Orphan', 'OldVM')][string]$Kind)
    $plan = @{
        Action = "Remove-$Kind"; Kind = $Kind; VMId = $Row.VMId; VMName = $Row.VMName; HostName = $Row.HostName
        PrimaryHost = $Row.PrimaryHost; Detail = $null; Reason = ''; Copies = @()
        Blockers = @(); Warnings = @(); CreatedAt = (Get-Date).ToString('s')
    }
    try { $d = Invoke-HVT $Row.HostName $script:SbVmDetail @{ VMId = $Row.VMId; CheckShared = $true } }
    catch { $plan.Blockers += "Cannot query $($Row.HostName): $($_.Exception.Message)"; return $plan }
    $plan.Detail = $d
    if (-not $d.Found) { $plan.Blockers += 'VM not found any more. Rescan.'; return $plan }
    $rels = @($d.Rels | Where-Object { $_ })
    if ($d.State -ne 'Off') { $plan.Blockers += "VM is $($d.State). Only powered-off VMs can be removed." }
    foreach ($s in @($d.Shared)) { if ($s) { $plan.Blockers += "Disk shared with another VM: $s" } }
    foreach ($w in @($d.ChainWarnings)) { if ($w) { $plan.Warnings += "$w (some checkpoint files may be left behind)" } }
    $plan.Copies = @(Get-HVTCopies $Row | ForEach-Object { "{0} ({1}, {2})" -f $_.HostName, $_.Mode, $_.State })

    if ($Kind -eq 'Orphan') {
        if ($rels.Count -ne 1 -or $rels[0].Mode -ne 'Replica') { $plan.Blockers += 'VM is not a plain Replica any more.'; return $plan }
        if ($rels[0].State -match $script:FailoverPattern) { $plan.Blockers += "Replica state is '$($rels[0].State)' (failover in progress)." }
        if ($d.TestVm) { $plan.Blockers += 'A test-failover VM exists for this replica.' }
        $ph = Get-HVTShortName $rels[0].Primary
        $plan.PrimaryHost = $ph
        # Live re-check: the primary host must be reachable and must NOT feed this replica
        if ($script:HVT.Hosts -notcontains $ph) { $plan.Blockers += "Primary host $ph is not in hosts.txt - cannot prove this replica is unused."; return $plan }
        try { $pi = Invoke-HVT $ph $script:SbVmDetail @{ VMId = $Row.VMId } }
        catch { $plan.Blockers += "Primary host $ph is not reachable. An unreachable primary does NOT make a replica an orphan - it may be your only good copy."; return $plan }
        if (-not $pi.Found) { $plan.Reason = "VM does not exist on primary host $ph" }
        else {
            $feeds = $false
            foreach ($x in @($pi.Rels | Where-Object { $_ })) { if ($x.Mode -eq 'Primary' -and (Get-HVTShortName $x.Replica) -eq $Row.HostName) { $feeds = $true } }
            if ($feeds) { $plan.Blockers += "Primary $ph IS replicating to this host. This is not an orphan." }
            else { $plan.Reason = "VM on $ph does not replicate to $($Row.HostName) (mode there: $(@($pi.Rels | ForEach-Object { $_.Mode }) -join ','))" }
        }
        $f = Get-HVTFleet
        if (-not $f.AllOk) { $plan.Blockers += 'Not every host in hosts.txt could be scanned, so the VM may have moved to a host that is down.' }
    } else {
        if ($rels.Count -gt 0) {
            $plan.Blockers += ("Replication is configured (mode {0}). Use menu 3 to remove replication first, or menu 4 for orphan replicas." -f (@($rels | ForEach-Object { $_.Mode }) -join ','))
        }
        if ($plan.Copies.Count -eq 0) { $plan.Warnings += 'This is the ONLY copy of this VM on all scanned hosts. Deletion is final.' }
    }
    return $plan
}

function Show-HVTRemovePlan {
    param($Plan)
    $d = $Plan.Detail
    Write-Host ''
    Write-Host ("=== {0}  on {1} ===" -f $Plan.VMName, $Plan.HostName) -ForegroundColor Cyan
    Write-Host ("  VM Id        : {0}" -f $Plan.VMId)
    if ($d -and $d.Found) {
        Write-Host ("  State        : {0}   created {1}   {2} vCPU / {3} GB RAM" -f $d.State, $d.Created, $d.Cpu, $d.MemGB)
        $rel = @($d.Rels | Where-Object { $_ }) | Select-Object -First 1
        if ($rel) { Write-Host ("  Replication  : {0}, primary {1}, last replicated {2}" -f $rel.Mode, $rel.Primary, $(if ($rel.LastRep) { $rel.LastRep } else { 'never' })) }
        if ($Plan.Reason) { Write-Host ("  Why orphan   : {0}" -f $Plan.Reason) -ForegroundColor Yellow }
        if (@($Plan.Copies).Count -gt 0) { Write-Host ("  Other copies : {0}" -f (@($Plan.Copies) -join '; ')) }
        else { Write-Host '  Other copies : none on scanned hosts' }
        Show-HVTFiles $d.Files '  Files to delete'
    }
    Show-HVTIssues $Plan
}

function Invoke-HVTRemove {
    # Executes an approved removal plan. Confirmation is done by the caller.
    param($Plan, [string]$ExportTo)
    if (@($Plan.Blockers).Count -gt 0) { return $false }
    $d = $Plan.Detail
    Save-HVTPlan -Plan $Plan | Out-Null
    if ($ExportTo) {
        $r = Invoke-HVTStep ("Export VM to {0}" -f $ExportTo) $Plan.HostName $Plan {
            Invoke-HVT $Plan.HostName $script:SbExport @{ VMId = $Plan.VMId; ExpectName = $d.Name; Path = $ExportTo; NeedBytes = $d.TotalBytes }
        }
        if (-not $r.Ok) { Write-Host '  Export failed, VM was NOT deleted.' -ForegroundColor Yellow; return $false }
    }
    $mode = 'None'
    if ($Plan.Kind -eq 'Orphan') { $mode = 'Replica' }
    $files = @($d.Files | ForEach-Object { $_.Path })
    $r = Invoke-HVTStep ("Delete VM and disks on {0}" -f $Plan.HostName) $Plan.HostName $Plan {
        Invoke-HVT $Plan.HostName $script:SbRemoveVmGuarded @{ VMId = $Plan.VMId; ExpectName = $d.Name; ExpectMode = $mode; ExpectPrimary = $(if ($mode -eq 'Replica') { $Plan.PrimaryHost } else { '' }); Approved = $files }
    }
    if ($r.Ok) {
        Write-Host ("    Freed {0}" -f (Format-HVTSize $r.Value.FreedBytes))
        foreach ($f in @($r.Value.Failed)) { if ($f) { Write-Host ("    Could not delete: {0}" -f $f) -ForegroundColor Yellow } }
    }
    return $r.Ok
}

# ---------------------------------------------------------------------------
# Checkpoints
# ---------------------------------------------------------------------------
function Get-HVTCheckpointPlan {
    param($Row, [int]$Days)
    $plan = @{
        Action = 'Remove-Checkpoint'; VMId = $Row.VMId; VMName = $Row.VMName; HostName = $Row.HostName
        Snaps = @(); Blockers = @(); Warnings = @(); CreatedAt = (Get-Date).ToString('s')
    }
    try { $c = Invoke-HVT $Row.HostName $script:SbCkList @{ VMId = $Row.VMId; Days = $Days } }
    catch { $plan.Blockers += "Cannot query $($Row.HostName): $($_.Exception.Message)"; return $plan }
    $plan.Snaps = @($c.Snaps | Where-Object { $_ })
    $plan.VMState = $c.State
    foreach ($r in @($c.Rels | Where-Object { $_ })) {
        if ($r.Mode -ne 'Primary') { $plan.Blockers += "VM is in $($r.Mode) mode. Checkpoints of replica VMs are not touched." }
        elseif ($r.Health -ne 'Normal') { $plan.Blockers += "Replication health is $($r.Health). Fix replication first (menu 3)." }
    }
    if ($c.State -eq 'Running') { $plan.Warnings += 'VM is running: the merge happens online and causes extra disk I/O.' }
    return $plan
}

function Invoke-HVTCheckpointRemove {
    param($Plan, $Snaps)
    Save-HVTPlan -Plan $Plan | Out-Null
    $r = Invoke-HVTStep ("Remove {0} checkpoint(s) of {1}" -f @($Snaps).Count, $Plan.VMName) $Plan.HostName $Plan {
        Invoke-HVT $Plan.HostName $script:SbCkRemove @{ VMId = $Plan.VMId; ExpectName = $Plan.VMName; Snaps = @($Snaps) }
    }
    if ($r.Ok) {
        foreach ($n in @($r.Value.Removed)) { if ($n) { Write-Host ("    removed: {0}" -f $n) } }
        foreach ($n in @($r.Value.Failed)) { if ($n) { Write-Host ("    FAILED : {0}" -f $n) -ForegroundColor Red } }
    }
    return $r.Ok
}

Export-ModuleMember -Function *-HVT*, Initialize-HVToolkit