<#
===============================================================================
 Fleming WiFi - Speedtest Logs Index Sync & Rollup Engine
 Compiles recent historical logs into logs_index.json and pushes to GitHub CDN
===============================================================================
#>

$envPaths = @(
    "c:\Users\normaluser\OneDrive\Documents\Github Workspace\.env",
    "c:\Users\normaluser\OneDrive\Documents\Github Workspace\Internet Business\.env",
    "$PSScriptRoot\..\.env",
    "$PSScriptRoot\.env"
)
$token = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { "" }
if (-not $token) {
    foreach ($ep in $envPaths) {
        if (Test-Path $ep) {
            $lines = Get-Content -Path $ep
            foreach ($line in $lines) {
                if ($line -match "^\s*GITHUB_TOKEN\s*=\s*(.*)$") {
                    $token = $matches[1].Trim().Trim('"').Trim("'")
                    break
                }
            }
            if ($token) { break }
        }
    }
}

$headers = @{
    "Authorization" = "Bearer $token"
    "User-Agent"    = "PowerShell-NOC"
    "Accept"        = "application/vnd.github.v3+json"
}

function Sync-Speedtest-Logs-Index {
    param(
        [int]$MaxEntriesPerDevice = 250
    )

    try {
        Write-Host "Fetching GitHub repository git tree..." -ForegroundColor Cyan
        $treeRes = Invoke-RestMethod -Uri "https://api.github.com/repos/flemin/Fleming-Wifi-Speedtest/git/trees/main?recursive=1" -Headers $headers -TimeoutSec 15

        $allFiles = $treeRes.tree | Where-Object { $_.path -like "Device Speedtest Logs/*/log_*.json" }
        Write-Host "Found $($allFiles.Count) total log files in repository."

        $coreFiles = $allFiles | Where-Object { $_.path -like "Device Speedtest Logs/CoreRouter/log_*.json" } | Sort-Object path -Descending | Select-Object -First $MaxEntriesPerDevice
        $homeFiles = $allFiles | Where-Object { $_.path -like "Device Speedtest Logs/HomeMikro/log_*.json" } | Sort-Object path -Descending | Select-Object -First $MaxEntriesPerDevice

        $selectedFiles = @($coreFiles) + @($homeFiles)
        Write-Host "Compiling $($selectedFiles.Count) recent log files..."

        $compiledLogs = [System.Collections.Generic.List[object]]::new()
        $fetchedCount = 0

        foreach ($f in $selectedFiles) {
            try {
                $rawUrl = "https://raw.githubusercontent.com/flemin/Fleming-Wifi-Speedtest/main/$($f.path)"
                $entry = Invoke-RestMethod -Uri $rawUrl -TimeoutSec 4
                if ($entry -and $entry.device) {
                    $compiledLogs.Add($entry)
                    $fetchedCount++
                }
            } catch {}
        }

        Write-Host "Compiled $fetchedCount speed test records!" -ForegroundColor Green

        $jsonStr = $compiledLogs | ConvertTo-Json -Depth 5
        $localPath = "c:\Users\normaluser\OneDrive\Documents\Github Workspace\Device Speedtest Logs\logs_index.json"
        [System.IO.File]::WriteAllText($localPath, $jsonStr, [System.Text.Encoding]::UTF8)

        # Push to GitHub
        $path = "Device Speedtest Logs/logs_index.json"
        $apiUrl = "https://api.github.com/repos/flemin/Fleming-Wifi-Speedtest/contents/$path"

        $sha = $null
        try {
            $existing = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 10
            $sha = $existing.sha
        } catch {}

        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($jsonStr))
        $bodyObj = @{
            message = "Auto-sync logs_index.json ($fetchedCount records)"
            content = $b64
        }
        if ($sha) { $bodyObj["sha"] = $sha }

        $putRes = Invoke-RestMethod -Uri $apiUrl -Method Put -Headers $headers -Body ($bodyObj | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 15
        Write-Host "Successfully synced logs_index.json to GitHub! Commit: $($putRes.commit.sha)" -ForegroundColor Green
    } catch {
        Write-Host "Sync failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Sync-Speedtest-Logs-Index
}
