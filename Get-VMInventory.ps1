<#
.SYNOPSIS
  Exports Hyper-V VM inventory to a CSV or JSON file across multiple hosts via PSRemoting.
#>
param(
    [string[]]$HostName = @($env:COMPUTERNAME),
    [string]$ExportPath = ".\VMInventory.csv"
)

function Get-UtcString {
    param($dt)
    if ($null -eq $dt) { return $null }
    if ($dt -is [string]) {
        if ([string]::IsNullOrWhiteSpace($dt)) { return $null }
        try { $dt = [datetime]::Parse($dt) } catch { return $null }
    }
    if ($dt -isnot [datetime]) { return $null }
    if ($dt.Year -le 1601) { return $null }
    return $dt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

try {
    $inventory = @()
    $collectedAt = Get-UtcString (Get-Date)
    
    foreach ($h in $HostName) {
        Write-Host "Querying host $h..." -ForegroundColor Cyan
        
        $isLocal = ($h -in @('localhost', '.', $env:COMPUTERNAME))
        $sb = {
            param($cAt)
            function Get-UtcStringLocal {
                param($dt)
                if ($null -eq $dt) { return $null }
                if ($dt -is [string]) {
                    if ([string]::IsNullOrWhiteSpace($dt)) { return $null }
                    try { $dt = [datetime]::Parse($dt) } catch { return $null }
                }
                if ($dt -isnot [datetime]) { return $null }
                if ($dt.Year -le 1601) { return $null }
                return $dt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
            
            # Helper to get the total and assigned memory in GB for VMs
            function Get-VMMemoryInfo {
                param($vm)
                $memTotalGB = 0
                $memAssignedGB = 0
                
                try {
                    $memTotalGB = [math]::Round(($vm.MemoryStartup / 1GB), 2)
                    $memAssignedGB = [math]::Round(($vm.MemoryAssigned / 1GB), 2)
                } catch {}
                
                return @{ Startup = $memTotalGB; Assigned = $memAssignedGB }
            }
            
            # Helper to determine disk type
            function Get-DiskType {
                param($vhdType)
                if ($vhdType -eq 2 -or $vhdType -eq 'Dynamic') { return 'Dynamic' }
                if ($vhdType -eq 3 -or $vhdType -eq 'Fixed') { return 'Fixed' }
                if ($vhdType -eq 4 -or $vhdType -eq 'Differencing') { return 'Differencing' }
                return $vhdType
            }

            try {
                $osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
                $cpuInfo = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue
                
                $hostCpuCores = 0
                if ($cpuInfo) { foreach ($cpu in $cpuInfo) { $hostCpuCores += $cpu.NumberOfCores } }
                
                $hostMemGB = 0
                if ($osInfo) { $hostMemGB = [math]::Round(($osInfo.TotalVisibleMemorySize / 1MB), 2) }
                $hostOsVersion = if ($osInfo) { $osInfo.Version } else { "" }
            } catch {}

            $vms = Get-VM -ErrorAction Stop
            $vmList = @()
            
            foreach ($vm in $vms) {
                # A VM in an extended chain has two relationships; report the first one
                $rep = @(Get-VMReplication -VM $vm -ErrorAction SilentlyContinue) | Select-Object -First 1
                $snaps = @(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue)
                
                $disks = @()
                $allVhds = @($vm.HardDrives.Path)
                if ($snaps) { foreach ($snap in $snaps) { $allVhds += @($snap.HardDrives.Path) } }
                
                foreach ($vhdPath in $allVhds) {
                    if (-not $vhdPath -or -not (Test-Path $vhdPath)) { continue }
                    try {
                        $vObj = Get-VHD -Path $vhdPath -ErrorAction Stop
                        $fSize = [math]::Round(($vObj.FileSize / 1GB), 2)
                        $sSize = [math]::Round(($vObj.Size / 1GB), 2)
                        $dType = Get-DiskType $vObj.VhdType
                        
                        $disks += @{
                            path = $vhdPath
                            sizeGB = $sSize
                            type = $dType
                            fileSizeGB = $fSize
                        }
                    } catch {}
                }
                
                $nics = @()
                $vmNics = Get-VMNetworkAdapter -VM $vm -ErrorAction SilentlyContinue
                if ($vmNics) {
                    foreach ($nic in $vmNics) {
                        $ips = if ($nic.IPAddresses) { $nic.IPAddresses -join ',' } else { "" }
                        $vlan = 0
                        try {
                            $vlanObj = Get-VMNetworkAdapterVlan -VMNetworkAdapter $nic -ErrorAction SilentlyContinue
                            if ($vlanObj -and $vlanObj.AccessVlanId) { $vlan = $vlanObj.AccessVlanId }
                        } catch {}
                        
                        $nics += @{
                            ipAddresses = $ips
                            switchName = $nic.SwitchName
                            vlanId = $vlan
                            macAddress = $nic.MacAddress
                        }
                    }
                }
                
                $guestOsName = ""
                $guestOsVer = ""
                $integrationState = ""
                if ($vm.State -eq 'Running') {
                    $intSvc = Get-VMIntegrationService -VM $vm -Name "Key-Value Pair Exchange" -ErrorAction SilentlyContinue
                    if ($intSvc -and $intSvc.PrimaryStatusDescription -eq 'OK') {
                        $integrationState = $intSvc.PrimaryStatusDescription
                    }
                }
                
                $memInfo = Get-VMMemoryInfo $vm

                $repData = @{
                    mode = if ($rep) { $rep.Mode.ToString() } else { "None" }
                    lastReplicationTime = if ($rep) { Get-UtcStringLocal $rep.LastReplicationTime } else { $null }
                    primaryServer = if ($rep) { $rep.PrimaryServer } else { $null }
                    state = if ($rep) { $rep.State.ToString() } else { $null }
                    health = if ($rep) { $rep.Health.ToString() } else { $null }
                    replicaServer = if ($rep) { $rep.ReplicaServer } else { $null }
                }

                $vmList += @{
                    vmId = $vm.Id.ToString()
                    automaticStartAction = $vm.AutomaticStartAction.ToString()
                    integrationServicesState = $integrationState
                    cpuCount = $vm.ProcessorCount
                    generation = $vm.Generation
                    memoryStartupGB = $memInfo.Startup
                    memoryAssignedGB = $memInfo.Assigned
                    notes = $vm.Notes
                    replication = $repData
                    uptime = if ($vm.Uptime.TotalSeconds) { [math]::Round($vm.Uptime.TotalSeconds, 0) } else { 0 }
                    configVersion = $vm.Version.ToString()
                    dynamicMemory = $vm.DynamicMemoryEnabled
                    hostName = $vm.ComputerName
                    checkpointCount = $snaps.Count
                    disks = $disks
                    state = $vm.State.ToString()
                    isReplica = if ($rep -and $rep.Mode -eq 'Replica') { $true } else { $false }
                    creationTime = Get-UtcStringLocal $vm.CreationTime
                    networkAdapters = $nics
                    guestOS = @{ OSName = $guestOsName; OSVersion = $guestOsVer }
                    vmName = $vm.Name
                }
            }
            
            return @{
                cpuCores = $hostCpuCores
                collectedAt = $cAt
                osVersion = $hostOsVersion
                error = $null
                hostName = $env:COMPUTERNAME
                memoryTotalGB = $hostMemGB
                vms = $vmList
            }
        }
        
        try {
            $hostInv = if ($isLocal) { & $sb $collectedAt } else { Invoke-Command -ComputerName $h -ScriptBlock $sb -ArgumentList $collectedAt -ErrorAction Stop }
            if ($hostInv) {
                $formattedVMs = @()
                foreach ($vm in $hostInv.vms) {
                    $formattedDisks = @()
                    if ($vm.disks) { foreach ($d in $vm.disks) { $formattedDisks += @{ path=$d.path; sizeGB=$d.sizeGB; type=$d.type; fileSizeGB=$d.fileSizeGB } } }
                    
                    $formattedNics = @()
                    if ($vm.networkAdapters) { foreach ($n in $vm.networkAdapters) { $formattedNics += @{ ipAddresses=$n.ipAddresses; switchName=$n.switchName; vlanId=$n.vlanId; macAddress=$n.macAddress } } }
                    
                    $formattedVMs += @{
                        vmId = $vm.vmId
                        automaticStartAction = $vm.automaticStartAction
                        integrationServicesState = $vm.integrationServicesState
                        cpuCount = $vm.cpuCount
                        generation = $vm.generation
                        memoryStartupGB = $vm.memoryStartupGB
                        memoryAssignedGB = $vm.memoryAssignedGB
                        notes = $vm.notes
                        replication = @{ mode=$vm.replication.mode; lastReplicationTime=$vm.replication.lastReplicationTime; primaryServer=$vm.replication.primaryServer; state=$vm.replication.state; health=$vm.replication.health; replicaServer=$vm.replication.replicaServer }
                        uptime = $vm.uptime
                        configVersion = $vm.configVersion
                        dynamicMemory = $vm.dynamicMemory
                        hostName = $vm.hostName
                        checkpointCount = $vm.checkpointCount
                        disks = $formattedDisks
                        state = $vm.state
                        isReplica = $vm.isReplica
                        creationTime = $vm.creationTime
                        networkAdapters = $formattedNics
                        guestOS = @{ OSName=$vm.guestOS.OSName; OSVersion=$vm.guestOS.OSVersion }
                        vmName = $vm.vmName
                    }
                }
                
                $inventory += @{
                    cpuCores = $hostInv.cpuCores
                    collectedAt = $hostInv.collectedAt
                    osVersion = $hostInv.osVersion
                    error = $hostInv.error
                    hostName = if ($hostInv.hostName) { $hostInv.hostName } else { $h }
                    memoryTotalGB = $hostInv.memoryTotalGB
                    vms = $formattedVMs
                }
            }
        } catch { 
            Write-Warning "Failed to query host $($h): $_" 
            $inventory += @{
                cpuCores = 0
                collectedAt = $collectedAt
                osVersion = ""
                error = $_.Exception.Message
                hostName = $h
                memoryTotalGB = 0
                vms = @()
            }
        }
    }
    
    if ($ExportPath -match '\.csv$') {
        # Flat one-row-per-VM summary
        $rows = @()
        foreach ($hostInv in $inventory) {
            foreach ($vm in $hostInv.vms) {
                $diskGB = 0
                foreach ($d in $vm.disks) { $diskGB += $d.fileSizeGB }
                $rows += New-Object PSObject -Property ([ordered]@{
                    HostName            = $hostInv.hostName
                    VMName              = $vm.vmName
                    VMId                = $vm.vmId
                    State               = $vm.state
                    Generation          = $vm.generation
                    CpuCount            = $vm.cpuCount
                    MemoryStartupGB     = $vm.memoryStartupGB
                    DiskFileGB          = [math]::Round($diskGB, 2)
                    DiskCount           = @($vm.disks).Count
                    CheckpointCount     = $vm.checkpointCount
                    ReplicationMode     = $vm.replication.mode
                    ReplicationHealth   = $vm.replication.health
                    ReplicationState    = $vm.replication.state
                    PrimaryServer       = $vm.replication.primaryServer
                    ReplicaServer       = $vm.replication.replicaServer
                    LastReplicationTime = $vm.replication.lastReplicationTime
                    IPAddresses         = (@($vm.networkAdapters | ForEach-Object { $_.ipAddresses }) -join ';')
                    CreationTime        = $vm.creationTime
                    Notes               = $vm.notes
                })
            }
        }
        $rows | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
        Write-Host "Inventory exported to CSV: $ExportPath ($($rows.Count) VMs)" -ForegroundColor Green
    } else {
        $jsonOut = ConvertTo-Json @($inventory) -Depth 10
        if ($inventory.Count -eq 1 -and -not $jsonOut.TrimStart().StartsWith("[")) { $jsonOut = "[$jsonOut]" }
        $jsonOut | Out-File -FilePath $ExportPath -Encoding utf8
        Write-Host "Inventory exported to JSON: $ExportPath" -ForegroundColor Green
    }
    
} catch { Write-Warning "Failed to export inventory: $_" }
