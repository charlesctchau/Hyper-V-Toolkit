<#
.SYNOPSIS
  Interactive menu for the Hyper-V Maintenance Toolkit (v2).

.DESCRIPTION
  Pick VMs by name from a live fleet scan - no VM Ids or host names to look up.
  Every risky action shows a detailed plan first and needs a typed confirmation.

.PARAMETER PreviewOnly
  Show every plan but never execute anything. Recommended for the first run.

.EXAMPLE
  .\Start-HyperVMenu.ps1 -PreviewOnly
#>
param(
    [string]$LogDir = 'C:\HyperVLogs',
    [switch]$PreviewOnly
)

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$hostsFile = Join-Path $scriptPath 'hosts.txt'
if (-not (Test-Path -LiteralPath $hostsFile)) {
    Write-Host "hosts.txt not found in $scriptPath. Create it with one Hyper-V host name per line." -ForegroundColor Red
    return
}
Import-Module (Join-Path $scriptPath 'HVToolkit.psm1') -Force -DisableNameChecking
Initialize-HVToolkit -HostsFile $hostsFile -LogDir $LogDir -PreviewOnly:$PreviewOnly

$rowHeader = ('{0,-34} {1,-12} {2,-8} {3,-8} {4,-8} {5,-15} {6}' -f 'VM', 'Host', 'State', 'Mode', 'Health', 'Partner', 'Note')
$fmtRow = { param($r) Format-HVTRow $r }
$colRow = { param($r) Get-HVTRowColor $r }

function Wait-Key {
    Write-Host ''
    Read-Host 'Press Enter to continue' | Out-Null
}

function Get-HealthRank {
    param($r)
    if ($r.Health -eq 'Critical') { return 1 }
    if ($r.Health -eq 'Warning') { return 2 }
    if ($r.Flag) { return 3 }
    if ($r.Health -eq 'Normal') { return 4 }
    return 5
}

function Show-FleetWarning {
    param($Fleet)
    foreach ($h in ($Fleet.Hosts.Keys | Sort-Object)) {
        if (-not $Fleet.Hosts[$h].Ok) { Write-Host ("  ! {0} was NOT scanned: {1}" -f $h, $Fleet.Hosts[$h].Error) -ForegroundColor Red }
    }
}

function Show-Overview {
    $f = Get-HVTFleet
    Write-Host ''
    Write-Host ("--- Fleet overview (scanned {0}) ---" -f $f.ScannedAt.ToString('HH:mm:ss')) -ForegroundColor Cyan
    Write-Host ('{0,-14} {1,-8} {2,-12} {3,5} {4,8} {5,8} {6,9} {7,8}' -f 'Host', 'Status', 'OS', 'VMs', 'Primary', 'Replica', 'Critical', 'Warning') -ForegroundColor DarkGray
    foreach ($h in ($f.Hosts.Keys | Sort-Object)) {
        $hi = $f.Hosts[$h]
        $rows = @($f.VMs | Where-Object { $_.HostName -eq $h })
        if ($hi.Ok) {
            Write-Host ('{0,-14} {1,-8} {2,-12} {3,5} {4,8} {5,8} {6,9} {7,8}' -f $h, 'OK', $hi.OsVersion, $rows.Count,
                @($rows | Where-Object { $_.Mode -eq 'Primary' }).Count, @($rows | Where-Object { $_.Mode -match 'Replica' }).Count,
                @($rows | Where-Object { $_.Health -eq 'Critical' }).Count, @($rows | Where-Object { $_.Health -eq 'Warning' }).Count)
        } else {
            Write-Host ('{0,-14} {1,-8} {2}' -f $h, 'FAILED', $hi.Error) -ForegroundColor Red
        }
    }
    $attn = @($f.VMs | Where-Object { $_.Health -eq 'Critical' -or $_.Health -eq 'Warning' -or $_.Flag } | Sort-Object @{ Expression = { Get-HealthRank $_ } }, VMName)
    Write-Host ''
    Write-Host ("Needs attention: {0}" -f $attn.Count) -ForegroundColor Cyan
    if ($attn.Count -gt 0) { Write-Host $rowHeader -ForegroundColor DarkGray }
    foreach ($r in $attn) { Write-Host (Format-HVTRow $r) -ForegroundColor (Get-HVTRowColor $r) }
}

function Show-VMDetail {
    $f = Get-HVTFleet
    $pick = @(Select-HVTItem -Items @($f.VMs | Sort-Object VMName, HostName) -Format $fmtRow -Color $colRow -Title 'Find VM (type part of the name)' -Header $rowHeader -Single)
    if ($pick.Count -eq 0) { return }
    $r = $pick[0]
    Write-Host ''
    Write-Host ("=== {0} ===" -f $r.VMName) -ForegroundColor Cyan
    Write-Host ("  VM Id   : {0}" -f $r.VMId)
    foreach ($c in @($f.VMs | Where-Object { $_.VMId -eq $r.VMId } | Sort-Object HostName)) {
        Write-Host ("  On {0,-12}: {1}, mode {2}, health {3}, {4}, last replicated {5} {6}" -f $c.HostName, $c.State, $c.Mode, $(if ($c.Health) { $c.Health } else { '-' }), $(if ($c.RepState) { $c.RepState } else { '-' }), $(if ($c.LastRep) { $c.LastRep } else { '-' }), $c.Issue) -ForegroundColor (Get-HVTRowColor $c)
    }
    try { $d = Get-HVTVMDetail -Row $r }
    catch { Write-Host ("  Detail query failed: {0}" -f $_.Exception.Message) -ForegroundColor Red; return }
    if ($d.Found) {
        Write-Host ("  Config  : Gen {0}, {1} vCPU, {2} GB RAM, created {3}" -f $d.Generation, $d.Cpu, $d.MemGB, $d.Created)
        Write-Host ("  Checkpoints (standard): {0}" -f $r.CkCount)
        Show-HVTFiles $d.Files ("  Disk files on {0}" -f $r.HostName)
    }
}

function Invoke-ReplicationMenu {
    $f = Get-HVTFleet
    Show-FleetWarning $f
    $items = @($f.VMs | Sort-Object @{ Expression = { Get-HealthRank $_ } }, VMName, HostName)
    $picks = @(Select-HVTItem -Items $items -Format $fmtRow -Color $colRow -Title 'Replication: select VM(s) - problems are listed first' -Header $rowHeader)
    if ($picks.Count -eq 0) { return }
    $changed = $false
    $doneIds = @{}
    foreach ($sel in $picks) {
        if ($doneIds.ContainsKey($sel.VMId)) { continue }
        $doneIds[$sel.VMId] = $true
        $row = $sel
        if ($sel.Mode -match 'Replica') {
            # A replica was picked: work on its primary, found by VM Id across the fleet
            $row = @($f.VMs | Where-Object { $_.VMId -eq $sel.VMId -and $_.Mode -eq 'Primary' -and $_.ReplicaHost -eq $sel.HostName }) | Select-Object -First 1
            if (-not $row) {
                Write-Host ("`n{0} on {1}: no primary is replicating to this copy ({2}). Use menu 4 if it is an orphan." -f $sel.VMName, $sel.HostName, $(if ($sel.Issue) { $sel.Issue } else { 'not verified' })) -ForegroundColor Yellow
                continue
            }
            Write-Host ("`n{0}: replica on {1} selected, working on its primary on {2}." -f $sel.VMName, $sel.HostName, $row.HostName) -ForegroundColor DarkCyan
        }

        if ($row.Mode -eq 'None') {
            Write-Host ("`n{0} on {1} has no replication." -f $row.VMName, $row.HostName) -ForegroundColor Cyan
            if ($row.Flag -eq 'Duplicate') { Write-Host ("  Note: {0}" -f $row.Issue) -ForegroundColor Yellow }
            $targets = @($f.Hosts.Keys | Where-Object { $_ -ne $row.HostName -and $f.Hosts[$_].Ok } | Sort-Object)
            $t = @(Select-HVTItem -Items $targets -Format { param($x) $x } -Title 'Set up replication: choose the replica host (Enter = skip)' -Single)
            if ($t.Count -eq 0) { continue }
            $plan = Get-HVTSetupPlan -Row $row -TargetHost $t[0]
            if (Invoke-HVTSetup $plan) { $changed = $true }
            continue
        }

        $plan = Get-HVTReplPlan -Row $row
        Show-HVTReplPlan $plan
        $blocked = (@($plan.Blockers).Count -gt 0)
        $rel = $null
        if ($plan.Primary -and $plan.Primary.Found) { $rel = @($plan.Primary.Rels | Where-Object { $_ }) | Select-Object -First 1 }
        if (-not $rel) { continue }
        $rec = 0
        if ($rel.Health -ne 'Normal') { $rec = 1; if ($rel.State -match 'Resynchron') { $rec = 2 } }
        $mark = { param($n) if ($n -eq $rec) { '  <- try this first' } else { '' } }
        Write-Host ''
        Write-Host ("  [1] Resume / continue replication            (safe){0}" -f (& $mark 1))
        Write-Host ("  [2] Resynchronize                            (safe, heavy disk I/O){0}" -f (& $mark 2))
        if ($blocked) {
            Write-Host '  [3] Full reset                               (blocked, see above)' -ForegroundColor DarkGray
            Write-Host '  [4] Remove replication                       (blocked, see above)' -ForegroundColor DarkGray
        } else {
            Write-Host '  [3] Full reset: delete replica, re-create    (DESTRUCTIVE - use when 1 and 2 fail)'
            Write-Host '  [4] Remove replication, delete replica copy  (DESTRUCTIVE)'
            Write-Host '  [5] Remove replication, keep replica copy as a normal VM'
        }
        $a = (Read-Host 'Action (Enter = skip)').Trim()
        switch ($a) {
            '1' { if (Invoke-HVTReplResume $plan) { $changed = $true } }
            '2' { if (Invoke-HVTReplResume $plan -Resync) { $changed = $true } }
            '3' { if (-not $blocked) { if (Invoke-HVTReplReset $plan) { $changed = $true } } }
            '4' { if (-not $blocked) { if (Invoke-HVTReplRemove $plan) { $changed = $true } } }
            '5' { if (-not $blocked) { if (Invoke-HVTReplRemove $plan -KeepReplica) { $changed = $true } } }
            default { Write-Host '  Skipped.' -ForegroundColor DarkGray }
        }
    }
    if ($changed) { Clear-HVTFleet }
}

function Invoke-OrphanMenu {
    # Always rescan: orphan detection must never run on stale data
    $f = Get-HVTFleet -Refresh
    Show-FleetWarning $f
    $unv = @($f.VMs | Where-Object { $_.Flag -eq 'Unverified' })
    if ($unv.Count -gt 0) {
        Write-Host ("`n{0} replica(s) are PROTECTED because their primary could not be verified:" -f $unv.Count) -ForegroundColor Yellow
        foreach ($r in $unv) { Write-Host ('  ' + (Format-HVTRow $r)) -ForegroundColor Yellow }
    }
    $orph = @($f.VMs | Where-Object { $_.Flag -eq 'Orphan' } | Sort-Object HostName, VMName)
    if ($orph.Count -eq 0) { Write-Host "`nNo confirmed orphan replicas." -ForegroundColor Green; return }
    $picks = @(Select-HVTItem -Items $orph -Format $fmtRow -Color $colRow -Title 'Confirmed orphan replicas: select to remove' -Header $rowHeader)
    if ($picks.Count -eq 0) { return }
    $ready = @()
    foreach ($r in $picks) {
        $plan = Get-HVTRemovePlan -Row $r -Kind Orphan
        Show-HVTRemovePlan $plan
        if (@($plan.Blockers).Count -eq 0) { $ready += $plan }
    }
    if ($ready.Count -eq 0) { Write-Host "`nNothing can be removed." -ForegroundColor Yellow; return }
    $sum = 0
    foreach ($p in $ready) { $sum += [double]$p.Detail.TotalBytes }
    $word = 'DELETE'
    if ($ready.Count -gt 1) { $word = "DELETE $($ready.Count)" }
    if (-not (Confirm-HVT $word ("Permanently delete {0} orphan replica VM(s) and their disks ({1})?" -f $ready.Count, (Format-HVTSize $sum)))) { return }
    foreach ($p in $ready) {
        Write-Host ("`n{0} on {1}" -f $p.VMName, $p.HostName) -ForegroundColor Cyan
        if (-not (Invoke-HVTRemove $p)) { Write-Host 'Stopped at the first failure. Remaining VMs were not touched.' -ForegroundColor Yellow; break }
    }
    Clear-HVTFleet
}

function Invoke-CheckpointMenu {
    $f = Get-HVTFleet
    Show-FleetWarning $f
    $d = (Read-Host "`nShow standard checkpoints older than how many days? (default 30)").Trim()
    $days = 30
    if ($d -match '^\d+$') { $days = [int]$d }
    $cand = @($f.VMs | Where-Object { $_.CkCount -gt 0 -and $_.CkOldestDays -ge $days -and $_.Mode -notmatch 'Replica' } | Sort-Object @{ Expression = { $_.CkOldestDays }; Descending = $true })
    if ($cand.Count -eq 0) { Write-Host "No VM has a standard checkpoint older than $days days." -ForegroundColor Green; return }
    $fmtCk = { param($r) ('{0,-34} {1,-12} {2,-8} {3,3} checkpoint(s), oldest {4,4} days  {5}' -f $r.VMName, $r.HostName, $r.State, $r.CkCount, $r.CkOldestDays, $(if ($r.Health) { 'repl ' + $r.Health } else { '' })) }
    $picks = @(Select-HVTItem -Items $cand -Format $fmtCk -Color $colRow -Title "VMs with checkpoints older than $days days")
    if ($picks.Count -eq 0) { return }
    $jobs = @()
    foreach ($r in $picks) {
        $plan = Get-HVTCheckpointPlan -Row $r -Days $days
        Write-Host ("`n=== {0} on {1} ===" -f $r.VMName, $r.HostName) -ForegroundColor Cyan
        Show-HVTIssues $plan
        if (@($plan.Blockers).Count -gt 0 -or @($plan.Snaps).Count -eq 0) { continue }
        $fmtSnap = { param($s) ('{0,-50} created {1}  ({2} days)' -f $s.Name, $s.Created, $s.AgeDays) }
        $snaps = @(Select-HVTItem -Items @($plan.Snaps) -Format $fmtSnap -Title 'Checkpoints to remove (e.g. 1-3; Enter = none)')
        if ($snaps.Count -gt 0) { $jobs += @{ Plan = $plan; Snaps = $snaps } }
    }
    if ($jobs.Count -eq 0) { return }
    $total = 0
    Write-Host "`n--- Summary ---" -ForegroundColor Cyan
    foreach ($j in $jobs) {
        $total += @($j.Snaps).Count
        foreach ($s in @($j.Snaps)) { Write-Host ("  {0} / {1}: {2}  ({3})" -f $j.Plan.HostName, $j.Plan.VMName, $s.Name, $s.Created) }
    }
    $word = 'DELETE'
    if ($total -gt 1) { $word = "DELETE $total" }
    if (-not (Confirm-HVT $word ("Remove {0} checkpoint(s)? Their changes are merged into the VM; you can no longer roll back to them." -f $total))) { return }
    foreach ($j in $jobs) { Invoke-HVTCheckpointRemove $j.Plan $j.Snaps | Out-Null }
    Clear-HVTFleet
}

function Invoke-RemoveVMMenu {
    $f = Get-HVTFleet -Refresh
    Show-FleetWarning $f
    $cand = @($f.VMs | Where-Object { $_.State -eq 'Off' -and $_.Mode -eq 'None' } | Sort-Object VMName, HostName)
    Write-Host "`nOnly powered-off VMs without replication are listed. Replicas: menu 3 or 4." -ForegroundColor DarkGray
    if ($cand.Count -eq 0) { Write-Host 'No candidate VMs.' -ForegroundColor Green; return }
    $pick = @(Select-HVTItem -Items $cand -Format $fmtRow -Color $colRow -Title 'Remove old VM and its disks: select ONE VM' -Header $rowHeader -Single)
    if ($pick.Count -eq 0) { return }
    $plan = Get-HVTRemovePlan -Row $pick[0] -Kind OldVM
    Show-HVTRemovePlan $plan
    if (@($plan.Blockers).Count -gt 0) { return }
    $export = (Read-Host "`nExport the VM first? Enter a LOCAL folder on $($plan.HostName) (e.g. E:\Export), or Enter to skip").Trim()
    if (-not (Confirm-HVT $plan.VMName ("Permanently delete VM '{0}' on {1} and all files listed above. Type the VM NAME to confirm." -f $plan.VMName, $plan.HostName))) { return }
    Invoke-HVTRemove $plan -ExportTo $export | Out-Null
    Clear-HVTFleet
}

function Invoke-PendingMenu {
    $items = @(Get-HVTPending)
    if ($items.Count -eq 0) { Write-Host "`nNo interrupted resets." -ForegroundColor Green; return }
    $fmt = { param($p) ('{0,-34} {1} -> {2}   started {3}' -f $p.VMName, $p.PrimaryHost, $p.ReplicaHost, $p.CreatedAt) }
    $picks = @(Select-HVTItem -Items $items -Format $fmt -Title 'Interrupted resets (replication currently NOT configured)')
    foreach ($p in $picks) { if (Invoke-HVTPending $p) { Clear-HVTFleet } }
}

function Invoke-ReportMenu {
    $st = Get-HVTState
    Write-Host "`n  [1] Replication report (with disk sizes, slower)"
    Write-Host '  [2] Export full inventory to JSON'
    Write-Host '  [3] Export full inventory to CSV'
    $a = (Read-Host 'Choice (Enter = back)').Trim()
    switch ($a) {
        '1' { & (Join-Path $scriptPath 'Get-ReplicationReport.ps1') -Hosts $st.Hosts }
        '2' { & (Join-Path $scriptPath 'Get-VMInventory.ps1') -HostName $st.Hosts -ExportPath (Join-Path $scriptPath 'VMInventory.json') }
        '3' { & (Join-Path $scriptPath 'Get-VMInventory.ps1') -HostName $st.Hosts -ExportPath (Join-Path $scriptPath 'VMInventory.csv') }
    }
}

function Show-Menu {
    $st = Get-HVTState
    $f = $st.Fleet
    $pending = @(Get-HVTPending).Count
    Clear-Host
    Write-Host '====================================================' -ForegroundColor Cyan
    Write-Host '        Hyper-V Maintenance Toolkit  v2' -ForegroundColor Cyan
    Write-Host '====================================================' -ForegroundColor Cyan
    if ($st.PreviewOnly) { Write-Host ' PREVIEW ONLY - plans are shown, nothing is executed' -ForegroundColor Magenta }
    if ($f) {
        $bad = @($f.Hosts.Keys | Where-Object { -not $f.Hosts[$_].Ok })
        $line = (" {0} hosts, {1} VMs, scanned {2}" -f $f.Hosts.Count, @($f.VMs).Count, $f.ScannedAt.ToString('HH:mm'))
        if ($bad.Count -gt 0) { Write-Host ($line + ("  ({0} host(s) unreachable)" -f $bad.Count)) -ForegroundColor Red } else { Write-Host $line -ForegroundColor DarkGray }
        Write-Host (" Critical: {0}   Warning: {1}   Orphan replicas: {2}" -f @($f.VMs | Where-Object { $_.Health -eq 'Critical' }).Count, @($f.VMs | Where-Object { $_.Health -eq 'Warning' }).Count, @($f.VMs | Where-Object { $_.Flag -eq 'Orphan' }).Count) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host ' 1) Fleet overview / what needs attention'
    Write-Host ' 2) Find a VM (details, where its copies are)'
    Write-Host ' 3) Replication: fix, reset, remove or set up'
    Write-Host ' 4) Remove orphan replica VMs'
    Write-Host ' 5) Remove old checkpoints'
    Write-Host ' 6) Remove an old VM and its disks'
    Write-Host ' 7) Reports / export inventory'
    if ($pending -gt 0) { Write-Host (" 8) Finish interrupted reset  ({0} waiting!)" -f $pending) -ForegroundColor Red }
    else { Write-Host ' 8) Finish interrupted reset' }
    Write-Host ''
    Write-Host ' R) Rescan all hosts      H) Show / reload hosts.txt'
    Write-Host (" L) Log folder ({0})     Q) Quit" -f $st.LogDir)
    Write-Host '====================================================' -ForegroundColor Cyan
}

Get-HVTFleet -Refresh | Out-Null

while ($true) {
    Show-Menu
    $choice = (Read-Host 'Select option').Trim().ToUpperInvariant()
    try {
        switch ($choice) {
            '1' { Show-Overview; Wait-Key }
            '2' { Show-VMDetail; Wait-Key }
            '3' { Invoke-ReplicationMenu; Wait-Key }
            '4' { Invoke-OrphanMenu; Wait-Key }
            '5' { Invoke-CheckpointMenu; Wait-Key }
            '6' { Invoke-RemoveVMMenu; Wait-Key }
            '7' { Invoke-ReportMenu; Wait-Key }
            '8' { Invoke-PendingMenu; Wait-Key }
            'R' { Get-HVTFleet -Refresh | Out-Null; Show-Overview; Wait-Key }
            'H' {
                $list = Read-HVTHosts
                Write-Host ("`nhosts.txt reloaded: {0}" -f ($list -join ', ')) -ForegroundColor Green
                Write-Host 'Only these hosts can be touched by the toolkit.'
                Wait-Key
            }
            'L' {
                $n = (Read-Host "`nNew log folder (Enter = keep)").Trim()
                if ($n) { Set-HVTLogDir $n; Write-Host "Log folder is now $n" -ForegroundColor Green; Wait-Key }
            }
            'Q' { return }
            default { }
        }
    } catch {
        Write-Host ("`nUnexpected error: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host 'No further step was executed.' -ForegroundColor Red
        Wait-Key
    }
}
