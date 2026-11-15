<img width="446" height="394" alt="Clipboarder 2026 11 16" src="https://github.com/user-attachments/assets/88a5d2d5-0e7d-4f2d-9277-13711186d4f1" />

# Hyper-V Maintenance Toolkit v2

Run on a management machine (or any listed host) as a domain account that is
local administrator on every Hyper-V host. Requires Windows PowerShell 5.1 locally
and WinRM (PSRemoting) to the hosts.

    .\Start-HyperVMenu.ps1 -PreviewOnly     # first run: shows plans, executes nothing
    .\Start-HyperVMenu.ps1

## Files

| File | Purpose |
|---|---|
| Start-HyperVMenu.ps1 | Interactive menu |
| HVToolkit.psm1 | Engine: fleet scan, guards, all remote actions |
| Get-VMInventory.ps1 | Full inventory export (JSON or CSV), read-only |
| Get-ReplicationReport.ps1 | Replication report with sizes, read-only, usable from Task Scheduler |
| hosts.txt | The ONLY hosts the toolkit may touch (copy from hosts.example.txt; not committed) |

The old Repair-VMReplication / Remove-OldVM / Remove-OrphanReplica / Remove-OldCheckpoint
scripts are replaced by the module. Delete them from the folder.

## How selection works

On start the toolkit scans all hosts in parallel and links copies of the same VM
across hosts by VM Id. In every list: type a number (1,3-5) to select, or type part
of a VM name to search. Picking a replica automatically resolves to its primary.

## Safety rules

- Hosts not in hosts.txt are refused. Each host must answer with its expected name.
- All Hyper-V cmdlets run on the target host, so mixed 2012 R2 / 2016 / 2019 works.
- Before any change a plan is shown: both hosts, state, every file and its size.
- Each destructive step re-checks the live state on the host; if the VM name, role,
  primary, power state or disk set differs from the plan, it aborts without changes.
- Only the files shown in the plan can be deleted. Files used by another VM block the action.
- A replica that is not Off, or in failover / test failover, is never deleted.
- A replica whose primary host is unreachable is PROTECTED, not an orphan.
- Extended replication chains are blocked (handle manually).
- Confirmation words: Y (safe), DELETE or DELETE n (destructive), VM name (remove VM).
- There is no -Force switch.

## Logs (default C:\HyperVLogs)

- HVToolkit_Audit.csv - every step with operator, host, VM, result
- Plans\*.json - the approved plan of each action
- Pending\*.json - resets that stopped before replication was re-enabled (menu 8 finishes them)

## Disclaimer

This toolkit deletes VMs, disk files and replication relationships. Run it with
-PreviewOnly first and test on non-production VMs. Use at your own risk.

## License

MIT - see LICENSE.
