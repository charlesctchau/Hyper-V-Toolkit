<#
.SYNOPSIS
  Generates a consolidated replication report via PSRemoting.
#>
param(
    [string[]]$Hosts,
    [switch]$PassThruExitCode
)

function Invoke-HyperVAction {
    param(
        [string]$ComputerName,
        [scriptblock]$ScriptBlock,
        [array]$ArgumentList
    )
    if ($ComputerName -in @('localhost', '.', $env:COMPUTERNAME)) {
        & $ScriptBlock @ArgumentList
    } else {
        Invoke-Command -ComputerName $ComputerName -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
    }
}

$report = @()
$criticalFound = $false

foreach ($h in $Hosts) {
    try {
        $remoteData = Invoke-HyperVAction -ComputerName $h -ScriptBlock {
            $reps = @(Get-VMReplication -ErrorAction SilentlyContinue)
            $res = @()
            foreach ($rep in $reps) {
                $targetVm = Get-VM -Id $rep.VMId -ErrorAction SilentlyContinue
                if (-not $targetVm) { continue }
                
                $pathsToSum = @()
                $allVhdPaths = @($targetVm.HardDrives.Path)
                $snaps = Get-VMSnapshot -VM $targetVm -ErrorAction SilentlyContinue
                if ($snaps) {
                    foreach ($snap in $snaps) { $allVhdPaths += @($snap.HardDrives.Path) }
                }
                
                foreach ($vhdPath in $allVhdPaths) {
                    if (-not $vhdPath) { continue }
                    $curr = $vhdPath
                    while ($curr) {
                        if ($pathsToSum -notcontains $curr) { $pathsToSum += $curr }
                        if ($curr -match "\.avhdx?$") {
                            try { $curr = (Get-VHD -Path $curr -ErrorAction Stop).ParentPath } catch { $curr = $null }
                        } else { $curr = $null }
                    }
                }
                
                $sz = 0
                foreach ($p in $pathsToSum) {
                    if (Test-Path $p) { $sz += (Get-Item $p).Length }
                }
                
                $res += [PSCustomObject]@{
                    PrimaryServer = $rep.PrimaryServer
                    ReplicaServer = $rep.ReplicaServer
                    VMName = $targetVm.Name
                    State = $rep.State.ToString()
                    Health = $rep.Health.ToString()
                    LastReplicationTime = $rep.LastReplicationTime
                    SizeMB = [math]::Round(($sz / 1MB), 2)
                }
            }
            return $res
        }
        
        if ($remoteData) {
            foreach ($r in $remoteData) {
                if ($r.Health -eq 'Critical') { $criticalFound = $true }
                $report += $r
            }
        }
    } catch {
        Write-Warning "Could not retrieve replication data from host $($h): $_"
    }
}

$report | Format-Table -AutoSize
Write-Host "Report complete. VMs Scanned: $($report.Count), Critical Found: $criticalFound"

if ($criticalFound) {
    if ($PassThruExitCode) {
        exit 1
    } else {
        Write-Warning "Critical health detected. Exit code 1 suppressed for interactive context."
    }
}
