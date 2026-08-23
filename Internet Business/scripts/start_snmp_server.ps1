<#
===============================================================================
 Fleming WiFi — Local SNMP NOC Server & Secure Authenticated Daemon
 Port: 8080 (http://localhost:8080 / http://192.168.0.101:8080)
===============================================================================
#>

param(
    [int]$Port = 8080,
    [int]$PollIntervalMinutes = 5
)

# 1. Load .env Configuration
$envPaths = @(
    "c:\Users\normaluser\OneDrive\Documents\Github Workspace\.env",
    "c:\Users\normaluser\OneDrive\Documents\Github Workspace\Internet Business\.env",
    "$PSScriptRoot\..\.env",
    "$PSScriptRoot\.env"
)

# Dot-source Omada & Voucher Business Service
$omadaServicePaths = @(
    "$PSScriptRoot\omada_voucher_service.ps1",
    "c:\Users\normaluser\OneDrive\Documents\Github Workspace\Internet Business\scripts\omada_voucher_service.ps1"
)
foreach ($sp in $omadaServicePaths) {
    if (Test-Path $sp) {
        . $sp
        break
    }
}

$backupUtilityPaths = @(
    "$PSScriptRoot\backup_oc200_config.ps1",
    "c:\Users\normaluser\OneDrive\Documents\Github Workspace\Internet Business\scripts\backup_oc200_config.ps1"
)
foreach ($bp in $backupUtilityPaths) {
    if (Test-Path $bp) {
        . $bp
        break
    }
}


$global:AuthConfig = @{
    users           = @("admin", "cfleming")
    password_hash   = "d04d6afe3c8501a5b07f8a5073b969d63e87ab4816c4bce3a06d70234eb16773"
    noc_password    = ""
    router_password = ""
    github_token    = ""
    timeout_hours   = 24
}

foreach ($ep in $envPaths) {
    if (Test-Path $ep) {
        $lines = Get-Content -Path $ep
        foreach ($line in $lines) {
            if ($line -match "^\s*NOC_AUTH_USERS\s*=\s*(.*)$") {
                $global:AuthConfig.users = $matches[1].Trim().Split(",") | ForEach-Object { $_.Trim() }
            }
            if ($line -match "^\s*NOC_AUTH_PASSWORD_HASH\s*=\s*(.*)$") {
                $global:AuthConfig.password_hash = $matches[1].Trim()
            }
            if ($line -match "^\s*NOC_AUTH_PASSWORD\s*=\s*(.*)$") {
                $global:AuthConfig.noc_password = $matches[1].Trim()
            }
            if ($line -match "^\s*ROUTER_PASSWORD\s*=\s*(.*)$") {
                $global:AuthConfig.router_password = $matches[1].Trim()
            }
            if ($line -match "^\s*GITHUB_TOKEN\s*=\s*(.*)$") {
                $global:AuthConfig.github_token = $matches[1].Trim()
            }
        }
        break
    }
}

function Get-SHA256Hash([string]$inputStr) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($inputStr)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha.ComputeHash($bytes)
    return [BitConverter]::ToString($hashBytes).Replace("-", "").ToLower()
}

$global:ActiveSessions = [System.Collections.Hashtable]::Synchronized(@{})

$logFilePath = "c:\Users\normaluser\OneDrive\Documents\Github Workspace\Internet Business\data\noc_incident_log.json"

function Get-Incident-Log {
    if (Test-Path $logFilePath) {
        try {
            $raw = Get-Content -Path $logFilePath -Raw -Encoding UTF8
            if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Trim() -eq "[]") { return @() }
            $parsed = $raw | ConvertFrom-Json
            if ($parsed -is [System.Array]) { return $parsed }
            return @($parsed)
        } catch {}
    }
    return @()
}

function Save-Incident-Log {
    param($logList)
    try {
        $arr = [System.Collections.Generic.List[object]]::new()
        if ($logList) {
            foreach ($item in $logList) { 
                if ($item) { $arr.Add($item) }
            }
        }
        if ($arr.Count -eq 0) {
            [System.IO.File]::WriteAllText($logFilePath, "[]", [System.Text.Encoding]::UTF8)
            return
        }
        $json = $arr | ConvertTo-Json -Depth 4
        if ($json.Trim().StartsWith("{")) { $json = "[$json]" }
        [System.IO.File]::WriteAllText($logFilePath, $json, [System.Text.Encoding]::UTF8)
    } catch {}
}

$global:DeviceTelemetry = @{
    mikrotiks = [System.Collections.Generic.List[PSCustomObject]]::new()
    switches  = [System.Collections.Generic.List[PSCustomObject]]::new()
}

# 1. CoreMikro
$global:DeviceTelemetry.mikrotiks.Add([PSCustomObject]@{
    name           = "CoreMikro"
    ip             = "10.0.0.254"
    role           = "Core ISP WAN Gateway"
    type           = "MikroTik hEX S (ARM)"
    category       = "mikrotik"
    status         = "Online"
    uptime         = "2w 21h 39m"
    cpu_load       = "7%"
    cpu_val        = 7
    used_ram       = "76.0 MiB / 512.0 MiB (14.8%)"
    ram_val        = 15
    used_storage   = "24.0 MiB / 128.0 MiB (18.8%)"
    storage_val    = 19
    temp_voltage   = "43 C | 23.7V"
    traffic_volume = "6.54 TB Rx / 592.6 GB Tx"
    active_clients = "Core Backbone Gateway"
    latest_speed   = "168 Mbps (ISP WAN)"
    speed_val      = 168
    version        = "RouterOS v7.20.7"
    ports          = @(
        @{ name = "P1-WAN";  status = "up";   speed = "1 Gbps"; desc = "ISP1 WAN Gateway (Internet Ingest)" },
        @{ name = "P2";      status = "down"; speed = "--";     desc = "ISP2 (Standby / Backup)" },
        @{ name = "P3";      status = "down"; speed = "--";     desc = "Gigabit Port 3 (Unused)" },
        @{ name = "P4";      status = "down"; speed = "--";     desc = "Gigabit Port 4 (Unused)" },
        @{ name = "P5";      status = "down"; speed = "--";     desc = "Gigabit Port 5 (Unused)" },
        @{ name = "SFP1";    status = "up";   speed = "10 Gbps";desc = "SFP+ Backbone Trunk to PawaSwitch" }
    )
    last_poll      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
})

# 2. HomeMikro
$global:DeviceTelemetry.mikrotiks.Add([PSCustomObject]@{
    name           = "HomeMikro"
    ip             = "192.168.0.1"
    role           = "Bridge LAN / Backbone Router"
    type           = "MikroTik hEX (ARM)"
    category       = "mikrotik"
    status         = "Online"
    uptime         = "5h 21m"
    cpu_load       = "7%"
    cpu_val        = 7
    used_ram       = "67.6 MiB / 512.0 MiB (13.2%)"
    ram_val        = 13
    used_storage   = "22.8 MiB / 128.0 MiB (17.8%)"
    storage_val    = 18
    temp_voltage   = "42 C (CPU: 59 C) | 24.0V"
    traffic_volume = "106.2 GB Rx / 8.68 GB Tx"
    active_clients = "95 Connected Clients | 5 VPN Sites"
    latest_speed   = "179 Mbps (Backbone Transit)"
    speed_val      = 179
    version        = "RouterOS v7.15.3"
    ports          = @(
        @{ name = "P1-Trk";   status = "up";   speed = "1 Gbps"; desc = "Backbone Uplink (HomeSwitch Port 7)" },
        @{ name = "P2";       status = "down"; speed = "--";     desc = "Gigabit Port 2 (Unused)" },
        @{ name = "P3-AP/SW"; status = "up";   speed = "1 Gbps"; desc = "Omada 16-Port Switch & Wi-Fi AP Cluster" },
        @{ name = "P4";       status = "down"; speed = "--";     desc = "Gigabit Port 4 (Unused)" },
        @{ name = "P5";       status = "down"; speed = "--";     desc = "Gigabit Port 5 (Unused)" }
    )
    last_poll      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
})

# 3. AnasMikro
$global:DeviceTelemetry.mikrotiks.Add([PSCustomObject]@{
    name           = "AnasMikro"
    ip             = "10.0.0.5"
    vpn_ip         = "10.255.255.3"
    role           = "Anas Remote Branch Router"
    type           = "MikroTik hEX S (ARM)"
    category       = "mikrotik"
    status         = "Offline"
    uptime         = "Offline (Last seen: Aug 14)"
    cpu_load       = "--"
    cpu_val        = 0
    used_ram       = "--"
    ram_val        = 0
    used_storage   = "--"
    storage_val    = 0
    temp_voltage   = "No Sensor Feed"
    traffic_volume = "Awaiting Uplink"
    active_clients = "Subnet 192.168.4.0/23"
    latest_speed   = "Tunnel Inactive"
    speed_val      = 0
    version        = "RouterOS v7"
    ports          = @(
        @{ name = "P1"; status = "down"; speed = "--"; desc = "LAN Port 1" },
        @{ name = "P2"; status = "down"; speed = "--"; desc = "LAN Port 2" },
        @{ name = "P3"; status = "down"; speed = "--"; desc = "LAN Port 3" },
        @{ name = "P4"; status = "down"; speed = "--"; desc = "LAN Port 4" },
        @{ name = "SFP1"; status = "down"; speed = "--"; desc = "SFP WAN / Backbone Link" }
    )
    last_poll      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
})

# 4. BititongMikro
$global:DeviceTelemetry.mikrotiks.Add([PSCustomObject]@{
    name           = "BititongMikro"
    ip             = "10.0.0.6"
    vpn_ip         = "10.255.255.4"
    role           = "Bititong Remote Branch Router"
    type           = "MikroTik hEX (ARM)"
    category       = "mikrotik"
    status         = "Offline"
    uptime         = "Offline (Last seen: Aug 03)"
    cpu_load       = "--"
    cpu_val        = 0
    used_ram       = "--"
    ram_val        = 0
    used_storage   = "--"
    storage_val    = 0
    temp_voltage   = "No Sensor Feed"
    traffic_volume = "Awaiting Uplink"
    active_clients = "Subnet 192.168.6.0/23"
    latest_speed   = "Tunnel Inactive"
    speed_val      = 0
    version        = "RouterOS v7"
    ports          = @(
        @{ name = "P1"; status = "down"; speed = "--"; desc = "Port 1" },
        @{ name = "P2"; status = "down"; speed = "--"; desc = "Port 2" },
        @{ name = "P3"; status = "down"; speed = "--"; desc = "Port 3" },
        @{ name = "P4"; status = "down"; speed = "--"; desc = "Port 4" },
        @{ name = "P5"; status = "down"; speed = "--"; desc = "Port 5" }
    )
    last_poll      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
})

# 5. BoloMikro
$global:DeviceTelemetry.mikrotiks.Add([PSCustomObject]@{
    name           = "BoloMikro"
    ip             = "10.0.0.4"
    vpn_ip         = "10.255.255.2"
    role           = "Bolo Remote Branch Router"
    type           = "MikroTik hEX (ARM)"
    category       = "mikrotik"
    status         = "Offline"
    uptime         = "Down since 12:34 PM PHT (Aug 18)"
    cpu_load       = "--"
    cpu_val        = 0
    used_ram       = "--"
    ram_val        = 0
    used_storage   = "--"
    storage_val    = 0
    temp_voltage   = "Site Power Lost / Disconnected"
    traffic_volume = "1.2 MB Session Volume"
    active_clients = "Subnet 192.168.12.0/23"
    latest_speed   = "Tunnel Timeout (1h 33m ago)"
    speed_val      = 0
    version        = "RouterOS v7"
    ports          = @(
        @{ name = "P1"; status = "down"; speed = "--"; desc = "Uplink Port" },
        @{ name = "P2"; status = "down"; speed = "--"; desc = "LAN Port 2" },
        @{ name = "P3"; status = "down"; speed = "--"; desc = "LAN Port 3" },
        @{ name = "P4"; status = "down"; speed = "--"; desc = "LAN Port 4" },
        @{ name = "P5"; status = "down"; speed = "--"; desc = "LAN Port 5" }
    )
    last_poll      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
})

# 6. MagdalenaMikro
$global:DeviceTelemetry.mikrotiks.Add([PSCustomObject]@{
    name           = "MagdalenaMikro"
    ip             = "10.0.0.8"
    vpn_ip         = "10.255.255.6"
    role           = "Magdalena Remote Branch Router"
    type           = "MikroTik hEX (ARM)"
    category       = "mikrotik"
    status         = "Offline"
    uptime         = "Offline (Last seen: Aug 03)"
    cpu_load       = "--"
    cpu_val        = 0
    used_ram       = "--"
    ram_val        = 0
    used_storage   = "--"
    storage_val    = 0
    temp_voltage   = "No Sensor Feed"
    traffic_volume = "Awaiting Uplink"
    active_clients = "Subnet 192.168.10.0/23"
    latest_speed   = "Tunnel Inactive"
    speed_val      = 0
    version        = "RouterOS v7"
    ports          = @(
        @{ name = "P1"; status = "down"; speed = "--"; desc = "Port 1" },
        @{ name = "P2"; status = "down"; speed = "--"; desc = "Port 2" },
        @{ name = "P3"; status = "down"; speed = "--"; desc = "Port 3" },
        @{ name = "P4"; status = "down"; speed = "--"; desc = "Port 4" },
        @{ name = "P5"; status = "down"; speed = "--"; desc = "Port 5" }
    )
    last_poll      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
})

# 7. UbunganMikro
$global:DeviceTelemetry.mikrotiks.Add([PSCustomObject]@{
    name           = "UbunganMikro"
    ip             = "10.0.0.7"
    vpn_ip         = "10.255.255.5"
    role           = "Ubungan Remote Branch Router"
    type           = "MikroTik hEX (ARM)"
    category       = "mikrotik"
    status         = "Offline"
    uptime         = "Offline (Last seen: Aug 03)"
    cpu_load       = "--"
    cpu_val        = 0
    used_ram       = "--"
    ram_val        = 0
    used_storage   = "--"
    storage_val    = 0
    temp_voltage   = "No Sensor Feed"
    traffic_volume = "Awaiting Uplink"
    active_clients = "Subnet 192.168.8.0/23"
    latest_speed   = "Tunnel Inactive"
    speed_val      = 0
    version        = "RouterOS v7"
    ports          = @(
        @{ name = "P1"; status = "down"; speed = "--"; desc = "Port 1" },
        @{ name = "P2"; status = "down"; speed = "--"; desc = "Port 2" },
        @{ name = "P3"; status = "down"; speed = "--"; desc = "Port 3" },
        @{ name = "P4"; status = "down"; speed = "--"; desc = "Port 4" },
        @{ name = "P5"; status = "down"; speed = "--"; desc = "Port 5" }
    )
    last_poll      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
})

# --- SWITCHES ---

# 8. BoloSwitch
$global:DeviceTelemetry.switches.Add([PSCustomObject]@{
    name           = "BoloSwitch"
    ip             = "192.168.2.12"
    role           = "Bolo Remote Distribution Switch"
    type           = "10G L3 Managed Switch"
    category       = "switch"
    status         = "Offline"
    uptime         = "Site Down (Unreachable)"
    cpu_load       = "--"
    cpu_val        = 0
    used_ram       = "--"
    ram_val        = 0
    used_storage   = "--"
    storage_val    = 0
    temp_voltage   = "No Power / Offline"
    traffic_volume = "Awaiting Link"
    active_clients = "Bolo Substation"
    latest_speed   = "Link Down"
    speed_val      = 0
    version        = "Managed L3 OS"
    ports          = @(
        @{ name = "P1"; status = "down"; speed = "--"; desc = "Port 1" },
        @{ name = "P2"; status = "down"; speed = "--"; desc = "Port 2" },
        @{ name = "P3"; status = "down"; speed = "--"; desc = "Port 3" },
        @{ name = "P4"; status = "down"; speed = "--"; desc = "Port 4" },
        @{ name = "P5"; status = "down"; speed = "--"; desc = "Port 5" },
        @{ name = "P6"; status = "down"; speed = "--"; desc = "Port 6" },
        @{ name = "P7"; status = "down"; speed = "--"; desc = "Port 7" },
        @{ name = "P8"; status = "down"; speed = "--"; desc = "Port 8" }
    )
    last_poll      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
})

# 9. HomeSwitch
$global:DeviceTelemetry.switches.Add([PSCustomObject]@{
    name           = "HomeSwitch"
    ip             = "192.168.2.3"
    role           = "Home Aggregation Switch"
    type           = "10G L3 Managed Switch"
    category       = "switch"
    status         = "Online"
    uptime         = "5h 21m (Uptime)"
    cpu_load       = "< 10%"
    cpu_val        = 8
    used_ram       = "Optimal Operating Range"
    ram_val        = 22
    used_storage   = "Flash Clean"
    storage_val    = 12
    temp_voltage   = "Normal Thermal Range"
    traffic_volume = "10G High-Speed Trunk"
    active_clients = "8 Switch Ports Active"
    latest_speed   = "10G SFP+ Link (Backbone Trunk)"
    speed_val      = 1000
    version        = "V300SP10251021"
    ports          = @(
        @{ name = "P1"; status = "up";   speed = "10G SFP+"; desc = "Uplink to PawaSwitch (VLAN 1/20/100)" },
        @{ name = "P2"; status = "down"; speed = "--";      desc = "Port 2 (Unused)" },
        @{ name = "P3"; status = "down"; speed = "--";      desc = "Port 3 (Unused)" },
        @{ name = "P4"; status = "down"; speed = "--";      desc = "Port 4 (Unused)" },
        @{ name = "P5"; status = "down"; speed = "--";      desc = "Port 5 (Unused)" },
        @{ name = "P6"; status = "down"; speed = "--";      desc = "Port 6 (Unused)" },
        @{ name = "P7"; status = "up";   speed = "1 Gbps";   desc = "HomeMikro Router ether1 Uplink" },
        @{ name = "P8"; status = "up";   speed = "1 Gbps";   desc = "Laptop Admin / NOC Maintenance Link" }
    )
    last_poll      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
})

# 10. PawaSwitch
$global:DeviceTelemetry.switches.Add([PSCustomObject]@{
    name           = "PawaSwitch"
    ip             = "192.168.2.2"
    role           = "Core Distribution Switch"
    type           = "10G L3 Managed Switch"
    category       = "switch"
    status         = "Online"
    uptime         = "Active"
    cpu_load       = "< 10%"
    cpu_val        = 8
    used_ram       = "Optimal Operating Range"
    ram_val        = 20
    used_storage   = "Flash Clean"
    storage_val    = 12
    temp_voltage   = "Normal Thermal Range"
    traffic_volume = "10G High-Speed Trunk"
    active_clients = "8 Switch Ports Active"
    latest_speed   = "10G SFP+ Link (Fiber to Core)"
    speed_val      = 1000
    version        = "V300SP10251021"
    ports          = @(
        @{ name = "P1"; status = "up";   speed = "10G SFP+"; desc = "Direct Fiber to CoreMikro SFP1" },
        @{ name = "P2"; status = "down"; speed = "--";      desc = "Port 2 (Unused)" },
        @{ name = "P3"; status = "down"; speed = "--";      desc = "Port 3 (Dead SFP Unplugged)" },
        @{ name = "P4"; status = "up";   speed = "10G SFP+"; desc = "Trunk to HomeSwitch" },
        @{ name = "P5"; status = "down"; speed = "--";      desc = "Port 5 (Unused)" },
        @{ name = "P6"; status = "down"; speed = "--";      desc = "Port 6 (Unused)" },
        @{ name = "P7"; status = "down"; speed = "--";      desc = "Port 7 (Unused)" },
        @{ name = "P8"; status = "up";   speed = "10G SFP+"; desc = "Alternate Uplink to HomeSwitch" }
    )
    last_poll      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
})

function Update-Device-Metrics {

    $rPw = $global:AuthConfig.router_password
    if (-not $rPw) { return }

    # Update CoreMikro (10.0.0.254)
    try {
        $rawCore = plink -ssh -hostkey "SHA256:PVpNH133hldLd3xQKBCsTBNVF5K1RIjJqJrnS8XmwP8" -l admin -pw "$rPw" -batch 10.0.0.254 '/system resource print; /interface ethernet print'
        if ($rawCore) {
            $map = @{}
            $rawCore -split "`n" | ForEach-Object {
                if ($_ -match "^\s*([a-zA-Z0-9\-]+):\s*(.*)$") { $map[$matches[1].Trim()] = $matches[2].Trim() }
            }
            $cpu = if ($map["cpu-load"]) { [int]($map["cpu-load"].Replace("%","")) } else { 7 }
            $totMem = 512.0
            $freeMem = if ($map["free-memory"]) { [double]($map["free-memory"].Replace("MiB","").Replace("MB","")) } else { 436.0 }
            $usedMem = [Math]::Round(($totMem - $freeMem), 1)
            $memPct = [Math]::Round(($usedMem / $totMem) * 100, 1)

            $totHdd = 128.0
            $freeHdd = if ($map["free-hdd-space"]) { [double]($map["free-hdd-space"].Replace("MiB","").Replace("MB","")) } else { 104.0 }
            $usedHdd = [Math]::Round(($totHdd - $freeHdd), 1)
            $hddPct = [Math]::Round(($usedHdd / $totHdd) * 100, 1)

            $idx = 0
            $global:DeviceTelemetry.mikrotiks[$idx].uptime = $map["uptime"]
            $global:DeviceTelemetry.mikrotiks[$idx].cpu_load = "$cpu%"
            $global:DeviceTelemetry.mikrotiks[$idx].cpu_val = $cpu
            $global:DeviceTelemetry.mikrotiks[$idx].used_ram = "$usedMem MiB / $totMem MiB ($memPct%)"
            $global:DeviceTelemetry.mikrotiks[$idx].ram_val = $memPct
            $global:DeviceTelemetry.mikrotiks[$idx].used_storage = "$usedHdd MiB / $totHdd MiB ($hddPct%)"
            $global:DeviceTelemetry.mikrotiks[$idx].storage_val = $hddPct
            $global:DeviceTelemetry.mikrotiks[$idx].last_poll = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            $global:DeviceTelemetry.mikrotiks[$idx].status = "Online"

            if ($rawCore -match '0\s+R.*ether1') { $global:DeviceTelemetry.mikrotiks[$idx].ports[0].status = 'up' } else { $global:DeviceTelemetry.mikrotiks[$idx].ports[0].status = 'down' }
            if ($rawCore -match '1\s+R.*ether2') { $global:DeviceTelemetry.mikrotiks[$idx].ports[1].status = 'up' } else { $global:DeviceTelemetry.mikrotiks[$idx].ports[1].status = 'down' }
            if ($rawCore -match '2\s+R.*ether3') { $global:DeviceTelemetry.mikrotiks[$idx].ports[2].status = 'up' } else { $global:DeviceTelemetry.mikrotiks[$idx].ports[2].status = 'down' }
            if ($rawCore -match '3\s+R.*ether4') { $global:DeviceTelemetry.mikrotiks[$idx].ports[3].status = 'up' } else { $global:DeviceTelemetry.mikrotiks[$idx].ports[3].status = 'down' }
            if ($rawCore -match '4\s+R.*ether5') { $global:DeviceTelemetry.mikrotiks[$idx].ports[4].status = 'up' } else { $global:DeviceTelemetry.mikrotiks[$idx].ports[4].status = 'down' }
            if ($rawCore -match '5\s+R.*sfp1')   { $global:DeviceTelemetry.mikrotiks[$idx].ports[5].status = 'up' } else { $global:DeviceTelemetry.mikrotiks[$idx].ports[5].status = 'down' }
        }
    } catch {}

    # Update HomeMikro (192.168.0.1)
    try {
        $rawHome = plink -ssh -hostkey "SHA256:kog3bKf60ypW6+lcSOAN+8NTcINp1l3YC8mtX0auMaE" -l admin -pw "$rPw" -batch 192.168.0.1 '/system resource print; /interface ethernet print; :put ("Leases: " . [/ip dhcp-server lease print count-only])'
        if ($rawHome) {
            $map = @{}
            $rawHome -split "`n" | ForEach-Object {
                if ($_ -match "^\s*([a-zA-Z0-9\-]+):\s*(.*)$") { $map[$matches[1].Trim()] = $matches[2].Trim() }
            }
            $cpu = if ($map["cpu-load"]) { [int]($map["cpu-load"].Replace("%","")) } else { 7 }
            $totMem = 512.0
            $freeMem = if ($map["free-memory"]) { [double]($map["free-memory"].Replace("MiB","").Replace("MB","")) } else { 444.4 }
            $usedMem = [Math]::Round(($totMem - $freeMem), 1)
            $memPct = [Math]::Round(($usedMem / $totMem) * 100, 1)

            $totHdd = 128.0
            $freeHdd = if ($map["free-hdd-space"]) { [double]($map["free-hdd-space"].Replace("MiB","").Replace("MB","")) } else { 105.2 }
            $usedHdd = [Math]::Round(($totHdd - $freeHdd), 1)
            $hddPct = [Math]::Round(($usedHdd / $totHdd) * 100, 1)

            $idx = 1
            $global:DeviceTelemetry.mikrotiks[$idx].uptime = $map["uptime"]
            $global:DeviceTelemetry.mikrotiks[$idx].cpu_load = "$cpu%"
            $global:DeviceTelemetry.mikrotiks[$idx].cpu_val = $cpu
            $global:DeviceTelemetry.mikrotiks[$idx].used_ram = "$usedMem MiB / $totMem MiB ($memPct%)"
            $global:DeviceTelemetry.mikrotiks[$idx].ram_val = $memPct
            $global:DeviceTelemetry.mikrotiks[$idx].used_storage = "$usedHdd MiB / $totHdd MiB ($hddPct%)"
            $global:DeviceTelemetry.mikrotiks[$idx].storage_val = $hddPct
            $global:DeviceTelemetry.mikrotiks[$idx].last_poll = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            $global:DeviceTelemetry.mikrotiks[$idx].status = "Online"

            if ($rawHome -match '0\s+R.*ether1') { $global:DeviceTelemetry.mikrotiks[$idx].ports[0].status = 'up' } else { $global:DeviceTelemetry.mikrotiks[$idx].ports[0].status = 'down' }
            if ($rawHome -match '1\s+R.*ether2') { $global:DeviceTelemetry.mikrotiks[$idx].ports[1].status = 'up' } else { $global:DeviceTelemetry.mikrotiks[$idx].ports[1].status = 'down' }
            if ($rawHome -match '2\s+R.*ether3') { $global:DeviceTelemetry.mikrotiks[$idx].ports[2].status = 'up' } else { $global:DeviceTelemetry.mikrotiks[$idx].ports[2].status = 'down' }
            if ($rawHome -match '3\s+R.*ether4') { $global:DeviceTelemetry.mikrotiks[$idx].ports[3].status = 'up' } else { $global:DeviceTelemetry.mikrotiks[$idx].ports[3].status = 'down' }
            if ($rawHome -match '4\s+R.*ether5') { $global:DeviceTelemetry.mikrotiks[$idx].ports[4].status = 'up' } else { $global:DeviceTelemetry.mikrotiks[$idx].ports[4].status = 'down' }
        }
    } catch {}

    # Update Omada Telemetry (Isolated & Non-blocking)
    try {
        $global:DeviceTelemetry.omada = Get-Omada-Telemetry-Summary
    } catch {
        $global:DeviceTelemetry.omada = @{ status = "Offline"; error = "Unreachable" }
    }
}

function Publish-Encrypted-NOC-Mirror {
    try {
        $token = $global:AuthConfig.github_token
        $pass = $global:AuthConfig.noc_password
        if (-not $token -or -not $pass) { return }

        $ghHeaders = @{
            "Authorization" = "Bearer $token"
            "Accept"        = "application/vnd.github.v3+json"
            "User-Agent"    = "Antigravity-NOC-Publisher"
        }

        # 1. Package Payload
        $payloadObj = @{
            timestamp     = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            devices       = $global:DeviceTelemetry.devices
            omada         = $global:DeviceTelemetry.omada
            incidents     = (Get-Incident-Log)
            activeClients = (Get-Active-Clients-Report)
        }
        $plainText = $payloadObj | ConvertTo-Json -Depth 6

        # 2. Encrypt AES-256-CBC with PBKDF2
        $salt = New-Object byte[] 16
        $iv = New-Object byte[] 16
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($salt)
        $rng.GetBytes($iv)

        $derive = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pass, $salt, 10000, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        $key = $derive.GetBytes(32)

        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.KeySize = 256
        $aes.Key = $key
        $aes.IV = $iv
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7

        $encryptor = $aes.CreateEncryptor()
        $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($plainText)
        $cipherBytes = $encryptor.TransformFinalBlock($plainBytes, 0, $plainBytes.Length)

        $encryptedObj = @{
            salt       = [Convert]::ToBase64String($salt)
            iv         = [Convert]::ToBase64String($iv)
            data       = [Convert]::ToBase64String($cipherBytes)
            updated_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }

        $jsonEncrypted = $encryptedObj | ConvertTo-Json
        $b64Content = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($jsonEncrypted))

        # 3. Push to Fleming-Wifi-Speedtest repo
        $url = "https://api.github.com/repos/flemin/Fleming-Wifi-Speedtest/contents/noc_fleet_encrypted.json"
        $sha = $null
        try {
            $getRes = Invoke-RestMethod -Uri $url -Headers $ghHeaders -Method Get -ErrorAction Stop
            $sha = $getRes.sha
        } catch {}

        $bodyObj = @{
            message = "Update encrypted NOC fleet mirror snapshot"
            content = $b64Content
        }
        if ($sha) { $bodyObj["sha"] = $sha }

        $jsonBody = $bodyObj | ConvertTo-Json
        $putRes = Invoke-RestMethod -Uri $url -Headers $ghHeaders -Method Put -Body $jsonBody -ContentType "application/json"
    } catch {}
}

# Start HTTP Listener (Listening across 192.168.0.0/23 and all interfaces)
$listener = New-Object System.Net.HttpListener
try {
    $listener.Prefixes.Add("http://+:$Port/")
    $listener.Start()
    Write-Host "Server listening on http://+:$Port (All Interfaces)"
} catch {
    try {
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://*:$Port/")
        $listener.Start()
        Write-Host "Server listening on http://*:$Port (Wildcard Mode)"
    } catch {
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://localhost:$Port/")
        $listener.Prefixes.Add("http://127.0.0.1:$Port/")
        $listener.Prefixes.Add("http://192.168.0.101:$Port/")
        $listener.Start()
        Write-Host "Server listening on http://192.168.0.101:$Port"
    }
}

$dashboardPath = "c:\Users\normaluser\OneDrive\Documents\Github Workspace\Internet Business\snmp_dashboard.html"
$loginPath = "c:\Users\normaluser\OneDrive\Documents\Github Workspace\Internet Business\login.html"

$lastPollTime = [DateTime]::Now
Publish-Encrypted-NOC-Mirror

while ($listener.IsListening) {
    try {
        if (([DateTime]::Now - $lastPollTime).TotalMinutes -ge $PollIntervalMinutes) {
            Update-Device-Metrics
            Publish-Encrypted-NOC-Mirror
            $lastPollTime = [DateTime]::Now
        }

        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        # Auth check helper
        $sessionToken = $null
        if ($request.Cookies["noc_session"]) {
            $sessionToken = $request.Cookies["noc_session"].Value
        }
        if (-not $sessionToken -and $request.Headers["Authorization"]) {
            $authHdr = $request.Headers["Authorization"]
            if ($authHdr -match "^Bearer\s+(.*)$") { $sessionToken = $matches[1].Trim() }
        }

        $isAuthenticated = $false
        $currentUser = $null
        if ($sessionToken -and $global:ActiveSessions.ContainsKey($sessionToken)) {
            $sess = $global:ActiveSessions[$sessionToken]
            if ($sess.expiry -gt [DateTime]::Now) {
                $isAuthenticated = $true
                $currentUser = $sess.user
            } else {
                $global:ActiveSessions.Remove($sessionToken)
            }
        }

        # 1. API: Login (POST)
        if ($request.Url.AbsolutePath -eq "/api/login" -and $request.HttpMethod -eq "POST") {
            $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
            $body = $reader.ReadToEnd()
            $reader.Close()

            $reqObj = $null
            try { $reqObj = $body | ConvertFrom-Json } catch {}

            $inUser = if ($reqObj.username) { $reqObj.username.Trim().ToLower() } else { "" }
            $inPass = if ($reqObj.password) { $reqObj.password } else { "" }
            $inHash = Get-SHA256Hash -inputStr $inPass

            $userAllowed = $false
            foreach ($u in $global:AuthConfig.users) {
                if ($u.ToLower() -eq $inUser) { $userAllowed = $true; break }
            }

            if ($userAllowed -and $inHash -eq $global:AuthConfig.password_hash) {
                $newToken = [System.Guid]::NewGuid().ToString("N") + [System.Guid]::NewGuid().ToString("N")
                $expiry = [DateTime]::Now.AddHours($global:AuthConfig.timeout_hours)
                $global:ActiveSessions[$newToken] = @{ user = $inUser; expiry = $expiry }

                # Set Cookie
                $cookieHeader = "noc_session=$newToken; Path=/; Max-Age=86400; SameSite=Lax"
                $response.Headers.Add("Set-Cookie", $cookieHeader)

                $resObj = @{ status = "success"; token = $newToken; user = $inUser }
                $resJson = $resObj | ConvertTo-Json
                $buf = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $buf.Length
                $response.OutputStream.Write($buf, 0, $buf.Length)
                $response.Close()
                continue
            } else {
                $response.StatusCode = 401
                $resJson = '{"status":"error","message":"Invalid operator username or password."}'
                $buf = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $buf.Length
                $response.OutputStream.Write($buf, 0, $buf.Length)
                $response.Close()
                continue
            }
        }

        # 2. API: Logout (POST)
        if ($request.Url.AbsolutePath -eq "/api/logout" -and $request.HttpMethod -eq "POST") {
            if ($sessionToken) { $global:ActiveSessions.Remove($sessionToken) }
            $cookieHeader = "noc_session=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT"
            $response.Headers.Add("Set-Cookie", $cookieHeader)

            $resJson = '{"status":"success","message":"Logged out"}'
            $buf = [System.Text.Encoding]::UTF8.GetBytes($resJson)
            $response.ContentType = "application/json; charset=utf-8"
            $response.ContentLength64 = $buf.Length
            $response.OutputStream.Write($buf, 0, $buf.Length)
            $response.Close()
            continue
        }

        # 3. API: Session Verification (GET)
        if ($request.Url.AbsolutePath -eq "/api/session" -and $request.HttpMethod -eq "GET") {
            if ($isAuthenticated) {
                $resJson = ("{""authenticated"":true,""user"":""$currentUser""}")
                $buf = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $buf.Length
                $response.OutputStream.Write($buf, 0, $buf.Length)
                $response.Close()
            } else {
                $response.StatusCode = 401
                $resJson = '{"authenticated":false}'
                $buf = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $buf.Length
                $response.OutputStream.Write($buf, 0, $buf.Length)
                $response.Close()
            }
            continue
        }

        # 4. Protected API: Telemetry
        if ($request.Url.AbsolutePath -eq "/api/telemetry") {
            if (-not $isAuthenticated) {
                $response.StatusCode = 401
                $resJson = '{"error":"Unauthorized"}'
                $buf = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $buf.Length
                $response.OutputStream.Write($buf, 0, $buf.Length)
                $response.Close()
                continue
            }

            if (-not $global:DeviceTelemetry.omada) {
                try { $global:DeviceTelemetry.omada = Get-Omada-Telemetry-Summary } catch {}
            }

            $jsonStr = $global:DeviceTelemetry | ConvertTo-Json -Depth 5
            $buf = [System.Text.Encoding]::UTF8.GetBytes($jsonStr)
            $response.ContentType = "application/json; charset=utf-8"
            $response.ContentLength64 = $buf.Length
            $response.OutputStream.Write($buf, 0, $buf.Length)
            $response.Close()
            continue
        }

        # 5. Protected API: Incident Events Log (GET)
        if ($request.Url.AbsolutePath -eq "/api/events" -and $request.HttpMethod -eq "GET") {
            if (-not $isAuthenticated) {
                $response.StatusCode = 401
                $resJson = '{"error":"Unauthorized"}'
                $buf = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $buf.Length
                $response.OutputStream.Write($buf, 0, $buf.Length)
                $response.Close()
                continue
            }

            $events = Get-Incident-Log
            $jsonStr = $events | ConvertTo-Json -Depth 4
            if (-not $jsonStr) { $jsonStr = "[]" }
            $buf = [System.Text.Encoding]::UTF8.GetBytes($jsonStr)
            $response.ContentType = "application/json; charset=utf-8"
            $response.ContentLength64 = $buf.Length
            $response.OutputStream.Write($buf, 0, $buf.Length)
            $response.Close()
            continue
        }

        # 6. Protected API: Clear Incident Events (POST)
        if ($request.Url.AbsolutePath -eq "/api/events/clear" -and $request.HttpMethod -eq "POST") {
            if (-not $isAuthenticated) {
                $response.StatusCode = 401
                $resJson = '{"error":"Unauthorized"}'
                $buf = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $buf.Length
                $response.OutputStream.Write($buf, 0, $buf.Length)
                $response.Close()
                continue
            }

            $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
            $body = $reader.ReadToEnd()
            $reader.Close()

            $reqObj = $null
            try { $reqObj = $body | ConvertFrom-Json } catch {}

            $currentEvents = [System.Collections.ArrayList]@(Get-Incident-Log)
            
            if ($reqObj.id) {
                $toKeep = @()
                foreach ($e in $currentEvents) {
                    if ($e.id -ne $reqObj.id) { $toKeep += $e }
                }
                Save-Incident-Log -logList $toKeep
            } elseif ($reqObj.clearAll -eq $true) {
                Save-Incident-Log -logList @()
            }

            $resJson = '{"status":"success","message":"Incident events updated"}'
            $buf = [System.Text.Encoding]::UTF8.GetBytes($resJson)
            $response.ContentType = "application/json; charset=utf-8"
            $response.ContentLength64 = $buf.Length
            $response.OutputStream.Write($buf, 0, $buf.Length)
            $response.Close()
            continue
        }

        # 7. Protected API: Omada Telemetry Summary (GET)
        if ($request.Url.AbsolutePath -eq "/api/omada/summary" -and $request.HttpMethod -eq "GET") {
            if (-not $isAuthenticated) {
                $response.StatusCode = 401
                $resJson = '{"error":"Unauthorized"}'
                $buf = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $buf.Length
                $response.OutputStream.Write($buf, 0, $buf.Length)
                $response.Close()
                continue
            }

            $omadaSummary = if ($global:DeviceTelemetry.omada) { $global:DeviceTelemetry.omada } else { Get-Omada-Telemetry-Summary }
            $jsonStr = $omadaSummary | ConvertTo-Json -Depth 5
            $buf = [System.Text.Encoding]::UTF8.GetBytes($jsonStr)
            $response.ContentType = "application/json; charset=utf-8"
            $response.ContentLength64 = $buf.Length
            $response.OutputStream.Write($buf, 0, $buf.Length)
            $response.Close()
            continue
        }

        # 8. Protected API: All Voucher Groups (GET)
        if ($request.Url.AbsolutePath -eq "/api/vouchers/groups" -and $request.HttpMethod -eq "GET") {
            if (-not $isAuthenticated) {
                $response.StatusCode = 401
                $resJson = '{"error":"Unauthorized"}'
                $buf = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $buf.Length
                $response.OutputStream.Write($buf, 0, $buf.Length)
                $response.Close()
                continue
            }

            $groups = Get-All-Voucher-Groups-Data
            $jsonStr = $groups | ConvertTo-Json -Depth 5
            if (-not $jsonStr) { $jsonStr = "[]" }
            $buf = [System.Text.Encoding]::UTF8.GetBytes($jsonStr)
            $response.ContentType = "application/json; charset=utf-8"
            $response.ContentLength64 = $buf.Length
            $response.OutputStream.Write($buf, 0, $buf.Length)
            $response.Close()
            continue
        }

        # 9. Protected API: Voucher Group Codes Details (GET)
        if ($request.Url.AbsolutePath -eq "/api/vouchers/group-details" -and $request.HttpMethod -eq "GET") {
            if (-not $isAuthenticated) {
                $response.StatusCode = 401
                $resJson = '{"error":"Unauthorized"}'
                $buf = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $buf.Length
                $response.OutputStream.Write($buf, 0, $buf.Length)
                $response.Close()
                continue
            }

            $groupId = $request.QueryString["groupId"]
            if (-not $groupId) {
                $response.StatusCode = 400
                $resJson = '{"error":"Missing groupId parameter"}'
                $buf = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $buf.Length
                $response.OutputStream.Write($buf, 0, $buf.Length)
                $response.Close()
                continue
            }

            $groupDetails = Get-Voucher-Group-Codes-Data -groupId $groupId
            $jsonStr = if ($groupDetails) { $groupDetails | ConvertTo-Json -Depth 6 } else { '{"error":"Group not found"}' }
            $buf = [System.Text.Encoding]::UTF8.GetBytes($jsonStr)
            $response.ContentType = "application/json; charset=utf-8"
            $response.ContentLength64 = $buf.Length
            $response.OutputStream.Write($buf, 0, $buf.Length)
            $response.Close()
            continue
        }

        # 10. Protected API: Generate Voucher Batch & Send Email (POST)
        if ($request.Url.AbsolutePath -eq "/api/vouchers/generate" -and $request.HttpMethod -eq "POST") {
            if (-not $isAuthenticated) {
                $response.StatusCode = 401
                $resJson = '{"error":"Unauthorized"}'
                $buf = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $buf.Length
                $response.OutputStream.Write($buf, 0, $buf.Length)
                $response.Close()
                continue
            }

            $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
            $body = $reader.ReadToEnd()
            $reader.Close()

            $reqObj = $null
            try { $reqObj = $body | ConvertFrom-Json } catch {}

            $portal   = if ($reqObj.portal) { $reqObj.portal } else { "Fleming WiFi" }
            $seller   = if ($reqObj.seller) { $reqObj.seller } else { "General" }
            $price    = if ($reqObj.price) { [double]$reqObj.price } else { 20 }
            $duration = if ($reqObj.duration) { [int]$reqObj.duration } else { 1440 }
            $amount   = if ($reqObj.amount) { [int]$reqObj.amount } else { 50 }
            $down     = if ($reqObj.downLimit) { [int]$reqObj.downLimit } else { 10240 }
            $up       = if ($reqObj.upLimit) { [int]$reqObj.upLimit } else { 5120 }
            $note     = if ($reqObj.note) { $reqObj.note } else { "" }

            $batchResult = Create-Voucher-Batch-Service -Portal $portal -Seller $seller -Price $price -DurationMins $duration -Amount $amount -DownLimitKbps $down -UpLimitKbps $up -Note $note
            $jsonStr = $batchResult | ConvertTo-Json -Depth 6
            $buf = [System.Text.Encoding]::UTF8.GetBytes($jsonStr)
            $response.ContentType = "application/json; charset=utf-8"
            $response.ContentLength64 = $buf.Length
            $response.OutputStream.Write($buf, 0, $buf.Length)
            $response.Close()
            continue
        }

        # 11. Protected API: Clear Expired/Invalid Vouchers (POST)
        if ($request.Url.AbsolutePath -eq "/api/vouchers/clear-expired" -and $request.HttpMethod -eq "POST") {
            if (-not $isAuthenticated) {
                $response.StatusCode = 401
                $resJson = '{"error":"Unauthorized"}'
                $buf = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $buf.Length
                $response.OutputStream.Write($buf, 0, $buf.Length)
                $response.Close()
                continue
            }

            $clearResult = Clear-Invalid-Vouchers-Service
            $jsonStr = $clearResult | ConvertTo-Json -Depth 4
            $buf = [System.Text.Encoding]::UTF8.GetBytes($jsonStr)
            $response.ContentType = "application/json; charset=utf-8"
            $response.ContentLength64 = $buf.Length
            $response.OutputStream.Write($buf, 0, $buf.Length)
            $response.Close()
            continue
        }

        # 12. Protected API: Sales Summary & Reconciliation (GET)
        if ($request.Url.AbsolutePath -eq "/api/sales/summary" -and $request.HttpMethod -eq "GET") {
            if (-not $isAuthenticated) {
                $response.StatusCode = 401
                $resJson = '{"error":"Unauthorized"}'
                $buf = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $buf.Length
                $response.OutputStream.Write($buf, 0, $buf.Length)
                $response.Close()
                continue
            }

            $monthFilter = $request.QueryString["month"]
            if (-not $monthFilter) { $monthFilter = "all" }
            $salesData = Get-Sales-Summary-Report -MonthFilter $monthFilter
            $jsonStr = $salesData | ConvertTo-Json -Depth 6
            $buf = [System.Text.Encoding]::UTF8.GetBytes($jsonStr)
            $response.ContentType = "application/json; charset=utf-8"
            $response.ContentLength64 = $buf.Length
            $response.OutputStream.Write($buf, 0, $buf.Length)
            $response.Close()
            continue
        }

        # 13. Protected API: Record Cash Collection Event (POST)
        if ($request.Url.AbsolutePath -eq "/api/sales/collect" -and $request.HttpMethod -eq "POST") {
            if (-not $isAuthenticated) {
                $response.StatusCode = 401
                $resJson = '{"error":"Unauthorized"}'
                $buf = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $buf.Length
                $response.OutputStream.Write($buf, 0, $buf.Length)
                $response.Close()
                continue
            }

            $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
            $body = $reader.ReadToEnd()
            $reader.Close()

            $reqObj = $null
            try { $reqObj = $body | ConvertFrom-Json } catch {}

            $seller = if ($reqObj.seller) { $reqObj.seller } else { "General" }
            $amount = if ($reqObj.amount) { [double]$reqObj.amount } else { 0.0 }
            $collector = if ($reqObj.collector) { $reqObj.collector } else { $currentUser }
            $notes = if ($reqObj.notes) { $reqObj.notes } else { "Cash collection acknowledged" }

            $journal = [System.Collections.ArrayList]@(Get-Sales-Journal)
            $entry = [PSCustomObject]@{
                id              = [System.Guid]::NewGuid().ToString("N")
                timestamp       = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                seller          = $seller
                amountCollected = $amount
                collector       = $collector
                notes           = $notes
            }
            $journal.Add($entry)
            Save-Sales-Journal -journalList $journal

            $resJson = '{"status":"success","message":"Collection recorded successfully"}'
            $buf = [System.Text.Encoding]::UTF8.GetBytes($resJson)
            $response.ContentType = "application/json; charset=utf-8"
            $response.ContentLength64 = $buf.Length
            $response.OutputStream.Write($buf, 0, $buf.Length)
            $response.Close()
            continue
        }

        # 14. Protected API: Sales Journal History (GET)
        if ($request.Url.AbsolutePath -eq "/api/sales/journal" -and $request.HttpMethod -eq "GET") {
            if (-not $isAuthenticated) {
                $response.StatusCode = 401
                $resJson = '{"error":"Unauthorized"}'
                $buf = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $buf.Length
                $response.OutputStream.Write($buf, 0, $buf.Length)
                $response.Close()
                continue
            }

            $journal = Get-Sales-Journal
            $jsonStr = $journal | ConvertTo-Json -Depth 5
            if (-not $jsonStr) { $jsonStr = "[]" }
            $buf = [System.Text.Encoding]::UTF8.GetBytes($jsonStr)
            $response.ContentType = "application/json; charset=utf-8"
            $response.ContentLength64 = $buf.Length
            $response.OutputStream.Write($buf, 0, $buf.Length)
            $response.Close()
            continue
        }

        # 15. Protected API: Trigger Full OC200 Configuration Backup (POST)
        if ($request.Url.AbsolutePath -eq "/api/omada/backup" -and $request.HttpMethod -eq "POST") {
            if (-not $isAuthenticated) {
                $response.StatusCode = 401
                $resJson = '{"error":"Unauthorized"}'
                $buf = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $buf.Length
                $response.OutputStream.Write($buf, 0, $buf.Length)
                $response.Close()
                continue
            }

            $backupRes = Export-OC200-Full-Backup
            $jsonStr = $backupRes | ConvertTo-Json -Depth 5
            $buf = [System.Text.Encoding]::UTF8.GetBytes($jsonStr)
            $response.ContentType = "application/json; charset=utf-8"
            $response.ContentLength64 = $buf.Length
            $response.OutputStream.Write($buf, 0, $buf.Length)
            $response.Close()
            continue
        }

        # 16. Protected API: Active Online Clients by Location (GET)
        if ($request.Url.AbsolutePath -eq "/api/clients/active" -and $request.HttpMethod -eq "GET") {
            if (-not $isAuthenticated) {
                $response.StatusCode = 401
                $resJson = '{"error":"Unauthorized"}'
                $buf = [System.Text.Encoding]::UTF8.GetBytes($resJson)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $buf.Length
                $response.OutputStream.Write($buf, 0, $buf.Length)
                $response.Close()
                continue
            }

            $clientsReport = Get-Active-Clients-Report
            $jsonStr = $clientsReport | ConvertTo-Json -Depth 6
            $buf = [System.Text.Encoding]::UTF8.GetBytes($jsonStr)
            $response.ContentType = "application/json; charset=utf-8"
            $response.ContentLength64 = $buf.Length
            $response.OutputStream.Write($buf, 0, $buf.Length)
            $response.Close()
            continue
        }


        # Static Assets Serving (e.g. /assets/fleming_wifi_logo.png)
        if ($request.Url.AbsolutePath -like "/assets/*") {
            $relPath = $request.Url.AbsolutePath.TrimStart("/").Replace("/", "\")
            $fullAssetPath = Join-Path "c:\Users\normaluser\OneDrive\Documents\Github Workspace\Internet Business" $relPath
            if (Test-Path $fullAssetPath) {
                $ext = [System.IO.Path]::GetExtension($fullAssetPath).ToLower()
                $mime = switch ($ext) {
                    ".png"  { "image/png" }
                    ".jpg"  { "image/jpeg" }
                    ".jpeg" { "image/jpeg" }
                    ".svg"  { "image/svg+xml" }
                    ".webp" { "image/webp" }
                    ".css"  { "text/css" }
                    ".js"   { "application/javascript" }
                    default { "application/octet-stream" }
                }
                $fileBytes = [System.IO.File]::ReadAllBytes($fullAssetPath)
                $response.ContentType = $mime
                $response.ContentLength64 = $fileBytes.Length
                $response.OutputStream.Write($fileBytes, 0, $fileBytes.Length)
                $response.Close()
                continue
            }
        }


        # 7. Serve /login Page Explicitly
        if ($request.Url.AbsolutePath -eq "/login" -or $request.Url.AbsolutePath -eq "/login.html") {
            if (Test-Path $loginPath) {
                $htmlContent = [System.IO.File]::ReadAllText($loginPath, [System.Text.Encoding]::UTF8)
                $buf = [System.Text.Encoding]::UTF8.GetBytes($htmlContent)
                $response.ContentType = "text/html; charset=utf-8"
                $response.ContentLength64 = $buf.Length
                $response.OutputStream.Write($buf, 0, $buf.Length)
                $response.Close()
                continue
            }
        }

        # 8. Serve Root / Page or /snmp_dashboard.html
        if ($request.Url.AbsolutePath -eq "/" -or $request.Url.AbsolutePath -eq "/index.html" -or $request.Url.AbsolutePath -eq "/snmp_dashboard.html") {
            if ($isAuthenticated) {
                if (Test-Path $dashboardPath) {
                    $htmlContent = [System.IO.File]::ReadAllText($dashboardPath, [System.Text.Encoding]::UTF8)
                    $buf = [System.Text.Encoding]::UTF8.GetBytes($htmlContent)
                    $response.ContentType = "text/html; charset=utf-8"
                    $response.ContentLength64 = $buf.Length
                    $response.OutputStream.Write($buf, 0, $buf.Length)
                    $response.Close()
                    continue
                }
            } else {
                # Unauthenticated: Serve Login page directly
                if (Test-Path $loginPath) {
                    $htmlContent = [System.IO.File]::ReadAllText($loginPath, [System.Text.Encoding]::UTF8)
                    $buf = [System.Text.Encoding]::UTF8.GetBytes($htmlContent)
                    $response.ContentType = "text/html; charset=utf-8"
                    $response.ContentLength64 = $buf.Length
                    $response.OutputStream.Write($buf, 0, $buf.Length)
                    $response.Close()
                    continue
                }
            }
        }

        $response.StatusCode = 404
        $msg = [System.Text.Encoding]::UTF8.GetBytes("Page not found.")
        $response.OutputStream.Write($msg, 0, $msg.Length)
        $response.Close()
    } catch {
        try { $response.Close() } catch {}
    }
}
