<#
===============================================================================
 Fleming WiFi - TP-Link Omada OC200 & Voucher Business Service
 Handles non-blocking telemetry, voucher batch generation, email dispatch,
 scissor-ready printable formatting, sales reconciliation, and expired cleanup.
===============================================================================
#>

[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13

$global:OmadaTokenCache = @{
    token = ""
    expiresAt = [DateTime]::MinValue
}

function Load-Omada-Configs {
    $envPaths = @(
        "c:\Users\normaluser\OneDrive\Documents\Github Workspace\.env",
        "c:\Users\normaluser\OneDrive\Documents\Github Workspace\Internet Business\.env",
        "$PSScriptRoot\..\.env",
        "$PSScriptRoot\.env"
    )

    $global:OmadaConfig = @{
        baseUrl      = "https://192.168.0.3:443"
        clientId     = "2591f928c534475b94733c0c7e0a125c"
        clientSecret = "0284ee26d5af40bf824fea4fb0562fcf"
        omadacId     = "1b4af1e434f85ae002fcd6869d517067"
        siteId       = "68638f2eb648976e8e52db09"
        strictSsl    = $false
    }

    $global:SmtpConfig = @{
        server     = "smtp.gmail.com"
        port       = 587
        user       = "amishguy222000@gmail.com"
        pass       = "otlditoklxywwuiv"
        recipients = @("amishguy222000@gmail.com", "hazeltorres0725@gmail.com", "torresruel176@gmail.com")
    }

    foreach ($ep in $envPaths) {
        if (Test-Path $ep) {
            $lines = Get-Content -Path $ep
            foreach ($line in $lines) {
                if ($line -match "^\s*OMADA_BASE_URL\s*=\s*(.*)$")      { $global:OmadaConfig.baseUrl = $matches[1].Trim() }
                if ($line -match "^\s*OMADA_CLIENT_ID\s*=\s*(.*)$")     { $global:OmadaConfig.clientId = $matches[1].Trim() }
                if ($line -match "^\s*OMADA_CLIENT_SECRET\s*=\s*(.*)$") { $global:OmadaConfig.clientSecret = $matches[1].Trim() }
                if ($line -match "^\s*OMADA_OMADAC_ID\s*=\s*(.*)$")     { $global:OmadaConfig.omadacId = $matches[1].Trim() }
                if ($line -match "^\s*OMADA_SITE_ID\s*=\s*(.*)$")       { $global:OmadaConfig.siteId = $matches[1].Trim() }
                if ($line -match "^\s*SMTP_SERVER\s*=\s*(.*)$")          { $global:SmtpConfig.server = $matches[1].Trim() }
                if ($line -match "^\s*SMTP_PORT\s*=\s*(.*)$")            { $global:SmtpConfig.port = [int]$matches[1].Trim() }
                if ($line -match "^\s*SMTP_USER\s*=\s*(.*)$")            { $global:SmtpConfig.user = $matches[1].Trim() }
                if ($line -match "^\s*SMTP_PASS\s*=\s*(.*)$")            { $global:SmtpConfig.pass = $matches[1].Trim() }
                if ($line -match "^\s*VOUCHER_ALERT_EMAILS\s*=\s*(.*)$") {
                    $global:SmtpConfig.recipients = $matches[1].Trim().Split(",") | ForEach-Object { $_.Trim() }
                }
            }
            break
        }
    }
}

Load-Omada-Configs

function Get-Omada-Token {
    if ($global:OmadaTokenCache.token -and ([DateTime]::Now -lt $global:OmadaTokenCache.expiresAt)) {
        return $global:OmadaTokenCache.token
    }

    try {
        $body = @{
            client_id     = $global:OmadaConfig.clientId
            client_secret = $global:OmadaConfig.clientSecret
            omadacId      = $global:OmadaConfig.omadacId
        } | ConvertTo-Json

        $url = "$($global:OmadaConfig.baseUrl)/openapi/authorize/token?grant_type=client_credentials"
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Method = "POST"
        $req.ContentType = "application/json"
        $req.Timeout = 3000
        $req.ServerCertificateValidationCallback = { $true }

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $req.ContentLength = $bytes.Length
        $st = $req.GetRequestStream()
        $st.Write($bytes, 0, $bytes.Length)
        $st.Close()

        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $respJson = $sr.ReadToEnd()
        $sr.Close()
        $resp.Close()

        $parsed = $respJson | ConvertFrom-Json
        if ($parsed.errorCode -eq 0) {
            $token = if ($parsed.result.accessToken) { $parsed.result.accessToken } else { $parsed.result.access_token }
            $expiresIn = if ($parsed.result.expiresIn) { [int]$parsed.result.expiresIn } else { 7200 }
            $global:OmadaTokenCache.token = $token
            $global:OmadaTokenCache.expiresAt = [DateTime]::Now.AddSeconds($expiresIn - 60)
            return $token
        }
    } catch {}

    return $null
}

function Invoke-Omada-API {
    param(
        [string]$Path,
        [string]$Method = "GET",
        [object]$Body = $null,
        [int]$TimeoutMs = 4000
    )

    $token = Get-Omada-Token
    if (-not $token) { return $null }

    try {
        $url = "$($global:OmadaConfig.baseUrl)$Path"
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Method = $Method
        $req.ContentType = "application/json"
        $req.Headers.Add("Authorization", "AccessToken=$token")
        $req.Timeout = $TimeoutMs
        $req.ServerCertificateValidationCallback = { $true }

        if ($Body -and ($Method -eq "POST" -or $Method -eq "PUT" -or $Method -eq "PATCH")) {
            $jsonBody = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 6 }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
            $req.ContentLength = $bytes.Length
            $st = $req.GetRequestStream()
            $st.Write($bytes, 0, $bytes.Length)
            $st.Close()
        }

        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $respJson = $sr.ReadToEnd()
        $sr.Close()
        $resp.Close()

        return ($respJson | ConvertFrom-Json)
    } catch {
        return $null
    }
}

# 1. Non-Blocking Omada Telemetry (Safe for NOC dashboard)
function Get-Omada-Telemetry-Summary {
    try {
        $omadacId = $global:OmadaConfig.omadacId
        $siteId = $global:OmadaConfig.siteId

        # Query Devices
        $devRes = Invoke-Omada-API -Path "/openapi/v1/$omadacId/sites/$siteId/devices?page=1&pageSize=200" -TimeoutMs 2500
        # Query Clients
        $cliRes = Invoke-Omada-API -Path "/openapi/v1/$omadacId/sites/$siteId/clients?page=1&pageSize=200" -TimeoutMs 2500
        # Query Vouchers
        $vgRes = Invoke-Omada-API -Path "/openapi/v1/$omadacId/sites/$siteId/hotspot/voucher-groups?page=1&pageSize=200" -TimeoutMs 2500

        if ($devRes -and $devRes.errorCode -eq 0) {
            $devices = $devRes.result.data
            $aps = @($devices | Where-Object { $_.type -eq "ap" })
            $switches = @($devices | Where-Object { $_.type -eq "switch" })
            $apOnline = @($aps | Where-Object { $_.status -eq 1 -or $_.status -eq 0 }).Count
            $swOnline = @($switches | Where-Object { $_.status -eq 1 -or $_.status -eq 0 }).Count

            $activeClients = if ($cliRes -and $cliRes.errorCode -eq 0) { $cliRes.result.data.Count } else { 0 }
            
            $totalVouchers = 0
            if ($vgRes -and $vgRes.errorCode -eq 0) {
                foreach ($g in $vgRes.result.data) {
                    $totalVouchers += if ($g.amount) { [int]$g.amount } else { 0 }
                }
            }

            return @{
                status         = "Online"
                site_name      = "San Isidro"
                total_aps      = $aps.Count
                online_aps     = $apOnline
                total_switches = $switches.Count
                active_clients = $activeClients
                total_vouchers = $totalVouchers
                last_seen      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            }
        }
    } catch {}

    return @{
        status    = "Offline"
        error     = "OC200 Unreachable"
        last_seen = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
}

# 2. Extract Seller & Portal from Group Name
function Parse-Voucher-Group-Meta([string]$name) {
    $seller = "General"
    $portal = "Fleming WiFi"

    if ($name -match "\[(.*?)\]") {
        $seller = $matches[1].Trim()
    } elseif ($name -match "(?i)\b(Danilo|Ruel|Merlita|Chairah|Shairah|Bobs|Bob|Jerome|Natural|Zaragoza|Annica|Jelan|Home|Torres)\b") {
        $seller = $matches[1].Trim()
    }

    if ($name -match "(?i)annica") {
        $portal = "Annica Resort"
    } elseif ($name -match "(?i)jelan") {
        $portal = "Jelan Resort"
    } else {
        $portal = "Fleming WiFi"
    }

    return @{ seller = $seller; portal = $portal }
}

# 3. Retrieve All Voucher Groups with Rich Metadata & Resilient Caching
$global:VoucherGroupsCache = $null
$global:VoucherGroupsCacheTime = [DateTime]::MinValue

function Get-All-Voucher-Groups-Data([bool]$ForceRefresh = $false) {
    $now = Get-Date
    if (-not $ForceRefresh -and $global:VoucherGroupsCache -and ($now - $global:VoucherGroupsCacheTime).TotalSeconds -lt 25) {
        return $global:VoucherGroupsCache
    }

    $omadacId = $global:OmadaConfig.omadacId
    $siteId = $global:OmadaConfig.siteId

    $res = Invoke-Omada-API -Path "/openapi/v1/$omadacId/sites/$siteId/hotspot/voucher-groups?page=1&pageSize=200" -TimeoutMs 8000
    if (-not $res -or $res.errorCode -ne 0 -or -not $res.result -or -not $res.result.data) {
        if ($global:VoucherGroupsCache) { return $global:VoucherGroupsCache }
        return @()
    }

    $list = @()
    foreach ($g in $res.result.data) {
        $meta = Parse-Voucher-Group-Meta -name $g.name
        $amount = if ($g.totalCount) { [int]$g.totalCount } elseif ($g.amount) { [int]$g.amount } else { 0 }
        $unused = if ($g.unusedCount) { [int]$g.unusedCount } else { 0 }
        $used = if ($g.usedCount) { [int]$g.usedCount } else { 0 }
        $durMins = if ($g.duration) { [int]$g.duration } else { 0 }

        # Determine price
        $price = 0.0
        if ($g.unitPrice) {
            $price = [double]$g.unitPrice
        } elseif ($g.name -match "(?i)\b(\d+)\s*(?:pesos?|php|p)\b") {
            $price = [double]$matches[1]
        } elseif ($durMins -eq 120) {
            $price = 5.0
        } elseif ($durMins -eq 240) {
            $price = 10.0
        } elseif ($durMins -eq 1440) {
            $price = if ($meta.portal -match "Annica") { 25.0 } else { 20.0 }
        } elseif ($durMins -eq 10080) {
            $price = 100.0
        } elseif ($durMins -ge 43200) {
            $price = 350.0
        }

        # Determine Duration Label
        $durLabel = if ($durMins -ge 43200) { "$([Math]::Round($durMins/43200)) Month(s)" }
                    elseif ($durMins -ge 10080) { "$([Math]::Round($durMins/10080)) Week(s)" }
                    elseif ($durMins -ge 1440) { "$([Math]::Round($durMins/1440)) Day(s)" }
                    elseif ($durMins -ge 60) { "$([Math]::Round($durMins/60)) Hour(s)" }
                    else { "$durMins Mins" }

        $cTime = if ($g.createdTime) { $g.createdTime } elseif ($g.createTime) { $g.createTime } else { 0 }
        $cDateStr = "-"
        if ($cTime -gt 0) {
            try {
                $dto = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$cTime)
                $pht = $dto.ToOffset([TimeSpan]::FromHours(8))
                $cDateStr = $pht.ToString('yyyy-MM-dd HH:mm')
            } catch {}
        }


        $list += [PSCustomObject]@{
            id             = $g.id
            name           = $g.name
            seller         = $meta.seller
            portal         = $meta.portal
            unitPrice      = $price
            amount         = $amount
            unusedCount    = $unused
            usedCount      = $used
            durationMins   = $durMins
            durationLabel  = $durLabel
            totalValue     = ($price * $amount)
            unusedValue    = ($price * $unused)
            usedValue      = ($price * $used)
            createTime     = [int64]$cTime
            createdDateStr = $cDateStr
        }
    }

    # Sort Newest First by default
    $list = @($list | Sort-Object createTime -Descending)

    if ($list.Count -gt 0) {
        $global:VoucherGroupsCache = $list
        $global:VoucherGroupsCacheTime = $now
    }

    return $list
}

# 4. Retrieve Voucher Codes for a Specific Group
function Get-Voucher-Group-Codes-Data([string]$groupId) {
    $omadacId = $global:OmadaConfig.omadacId
    $siteId = $global:OmadaConfig.siteId

    $url = "/openapi/v1/$omadacId/sites/$siteId/hotspot/voucher-groups/$groupId" + "?page=1&pageSize=500&currentPage=1&currentSize=500"
    $res = Invoke-Omada-API -Path $url -TimeoutMs 4000


    if (-not $res -or $res.errorCode -ne 0) { return $null }

    $vouchers = @()
    foreach ($v in $res.result.data) {
        $statusText = switch ($v.status) {
            0 { "Unused" }
            1 { "In Use" }
            2 { "Expired" }
            default { "Unknown" }
        }

        $vouchers += [PSCustomObject]@{
            id          = $v.id
            code        = $v.code
            status      = $v.status
            statusText  = $statusText
            downLimit   = $v.downLimit
            upLimit     = $v.upLimit
            startTime   = $v.startTime
            endTime     = $v.endTime
            timeUsedSec = $v.timeUsedSec
            timeLeftSec = $v.timeLeftSec
        }
    }

    return @{
        groupId      = $groupId
        totalCount   = $res.result.totalCount
        unusedCount  = $res.result.unusedCount
        inUseCount   = $res.result.inUseCount
        expiredCount = $res.result.expiredCount
        unusedAmount = $res.result.unusedAmount
        usedAmount   = $res.result.usedAmount
        totalAmount  = $res.result.totalAmount
        vouchers     = $vouchers
    }
}

# 5. Batch Create Vouchers on OC200 & Dispatch Email
function Create-Voucher-Batch-Service {
    param(
        [string]$Portal = "Fleming WiFi",
        [string]$Seller = "General",
        [double]$Price = 20,
        [int]$DurationMins = 1440,
        [int]$Amount = 50,
        [int]$DownLimitKbps = 10240,
        [int]$UpLimitKbps = 10240,
        [string]$Note = ""
    )

    $omadacId = $global:OmadaConfig.omadacId
    $siteId = $global:OmadaConfig.siteId

    $portalMap = @{
        "Fleming WiFi"  = "68639a70b648976e8e52dcc1"
        "Annica Resort" = "68b9ff162d5466776637b1f1"
        "Jelan Resort"  = "6a86ca0d86cf8447c1e974d8"
    }

    $portalId = if ($portalMap.ContainsKey($Portal)) { $portalMap[$Portal] } else { "68639a70b648976e8e52dcc1" }

    $durLabel = if ($DurationMins -ge 43200) { "$([Math]::Round($DurationMins/43200))M" }
                elseif ($DurationMins -ge 10080) { "$([Math]::Round($DurationMins/10080))W" }
                elseif ($DurationMins -ge 1440) { "$([Math]::Round($DurationMins/1440))D" }
                elseif ($DurationMins -ge 60) { "$([Math]::Round($DurationMins/60))H" }
                else { "${DurationMins}m" }

    $dateStr = (Get-Date).ToString("yyyy-MM-dd")
    $groupName = "[$Seller] $Portal P$Price ($durLabel) - ${Amount}pcs - $dateStr"

    $payload = @{
        name              = $groupName
        amount            = $Amount
        codeType          = 0 # Numbers
        codeLength        = 6
        duration          = $DurationMins
        unit              = 1 # Minutes
        maxUsage          = 1
        unitPrice         = $Price
        applyToAllPortals = $false
        portals           = @($portalId)
        rateLimit         = @{
            downLimitEnable = $true
            downLimit       = $DownLimitKbps
            upLimitEnable   = $true
            upLimit         = $UpLimitKbps
        }
        trafficLimit      = @{
            enable          = $false
            trafficLimit    = 0
        }
        note              = if ($Note) { $Note } else { "Created via Fleming NOC Voucher Studio" }
    }

    $createRes = Invoke-Omada-API -Path "/openapi/v1/$omadacId/sites/$siteId/hotspot/voucher-groups" -Method "POST" -Body $payload -TimeoutMs 5000


    if (-not $createRes -or $createRes.errorCode -ne 0) {
        $msg = if ($createRes.msg) { $createRes.msg } else { "Failed to create voucher group" }
        return @{ success = $false; error = $msg }
    }

    $newGroupId = $createRes.result.id

    # Retrieve created codes
    Start-Sleep -Milliseconds 800
    $codesData = Get-Voucher-Group-Codes-Data -groupId $newGroupId
    $vouchers = if ($codesData) { $codesData.vouchers } else { @() }

    # Send Email Notification
    $emailStatus = Send-Voucher-Batch-Email -GroupName $groupName -Portal $Portal -Seller $Seller -Price $Price -DurationMins $DurationMins -Amount $Amount -Vouchers $vouchers

    return @{
        success     = $true
        groupId     = $newGroupId
        groupName   = $groupName
        portal      = $Portal
        seller      = $Seller
        price       = $Price
        amount      = $Amount
        totalValue  = ($Price * $Amount)
        vouchers    = $vouchers
        emailSent   = $emailStatus
    }
}

# 6. Automatic Email Dispatch (Gmail SMTP Relay)
function Send-Voucher-Batch-Email {
    param(
        [string]$GroupName,
        [string]$Portal,
        [string]$Seller,
        [double]$Price,
        [int]$DurationMins,
        [int]$Amount,
        [array]$Vouchers
    )

    try {
        $smtpServer = $global:SmtpConfig.server
        $smtpPort   = $global:SmtpConfig.port
        $user       = $global:SmtpConfig.user
        $pass       = $global:SmtpConfig.pass
        $recipients = $global:SmtpConfig.recipients

        if (-not $user -or -not $pass -or -not $recipients) { return $false }

        $totalFaceValue = ($Price * $Amount)
        $durLabel = if ($DurationMins -ge 1440) { "$([Math]::Round($DurationMins/1440)) Day(s)" }
                    elseif ($DurationMins -ge 60) { "$([Math]::Round($DurationMins/60)) Hour(s)" }
                    else { "$DurationMins Minutes" }

        $subject = "[Voucher Batch] " + $Seller + " - " + $Portal + " (" + $Amount + " pcs - P" + $Price + " = P" + $totalFaceValue + ")"

        $codeRowsBuilder = [System.Text.StringBuilder]::new()
        $count = 0
        foreach ($v in $Vouchers) {
            $count++
            $codeStr = $v.code
            $rowHtml = "<tr><td style='padding:6px 12px;border:1px solid #ddd;font-family:monospace;font-weight:bold;font-size:15px;color:#1e293b;'>" + $codeStr + "</td><td style='padding:6px 12px;border:1px solid #ddd;color:#64748b;'>#" + $count + "</td><td style='padding:6px 12px;border:1px solid #ddd;'>P" + $Price + " (" + $durLabel + ")</td></tr>"
            [void]$codeRowsBuilder.Append($rowHtml)
        }
        $codeRows = $codeRowsBuilder.ToString()


        $nowStr = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $bodyBuilder = [System.Text.StringBuilder]::new()
        [void]$bodyBuilder.Append("<!DOCTYPE html><html><head><style>")
        [void]$bodyBuilder.Append("body { font-family: 'Segoe UI', Arial, sans-serif; color: #1e293b; background: #f8fafc; margin: 0; padding: 20px; }")
        [void]$bodyBuilder.Append(".card { background: #ffffff; border-radius: 12px; border: 1px solid #e2e8f0; padding: 24px; max-width: 650px; margin: 0 auto; box-shadow: 0 4px 12px rgba(0,0,0,0.05); }")
        [void]$bodyBuilder.Append(".header { border-bottom: 2px solid #3b82f6; padding-bottom: 12px; margin-bottom: 16px; }")
        [void]$bodyBuilder.Append(".title { font-size: 20px; font-weight: bold; color: #0f172a; margin: 0; }")
        [void]$bodyBuilder.Append(".meta-table { width: 100%; border-collapse: collapse; margin-bottom: 20px; }")
        [void]$bodyBuilder.Append(".meta-table td { padding: 6px 0; font-size: 14px; }")
        [void]$bodyBuilder.Append(".badge { display: inline-block; padding: 3px 8px; border-radius: 6px; font-weight: bold; font-size: 12px; background: #e0f2fe; color: #0369a1; }")
        [void]$bodyBuilder.Append("</style></head><body><div class='card'><div class='header'>")
        [void]$bodyBuilder.Append("<div class='title'>Fleming WiFi - Voucher Batch Generated</div>")
        [void]$bodyBuilder.Append("<div style='font-size:12px;color:#64748b;'>$nowStr (Manila PHT)</div></div>")
        [void]$bodyBuilder.Append("<table class='meta-table'>")
        [void]$bodyBuilder.Append("<tr><td style='color:#64748b;width:140px;'>Batch Group:</td><td style='font-weight:bold;'>$GroupName</td></tr>")
        [void]$bodyBuilder.Append("<tr><td style='color:#64748b;'>Hotspot Portal:</td><td style='font-weight:bold;'>$Portal</td></tr>")
        [void]$bodyBuilder.Append("<tr><td style='color:#64748b;'>Seller / Location:</td><td><span class='badge'>$Seller</span></td></tr>")
        [void]$bodyBuilder.Append("<tr><td style='color:#64748b;'>Rate &amp; Duration:</td><td style='font-weight:bold;'>P$Price ($durLabel)</td></tr>")
        [void]$bodyBuilder.Append("<tr><td style='color:#64748b;'>Quantity:</td><td style='font-weight:bold;'>$Amount Tickets</td></tr>")
        [void]$bodyBuilder.Append("<tr><td style='color:#64748b;'>Total Face Value:</td><td style='font-weight:bold;color:#059669;font-size:16px;'>P$totalFaceValue.00</td></tr>")
        [void]$bodyBuilder.Append("</table>")
        [void]$bodyBuilder.Append("<div style='font-weight:bold;font-size:14px;margin-bottom:8px;'>Generated Voucher Codes:</div>")
        [void]$bodyBuilder.Append("<table style='width:100%;border-collapse:collapse;font-size:13px;'>")
        [void]$bodyBuilder.Append("<thead><tr style='background:#f1f5f9;'><th style='padding:6px 12px;border:1px solid #ddd;text-align:left;'>Code</th><th style='padding:6px 12px;border:1px solid #ddd;text-align:left;'>#</th><th style='padding:6px 12px;border:1px solid #ddd;text-align:left;'>Rate</th></tr></thead>")
        [void]$bodyBuilder.Append("<tbody>$codeRows</tbody></table>")
        [void]$bodyBuilder.Append("<div style='margin-top:20px;font-size:12px;color:#94a3b8;text-align:center;'>Automated NOC Alert - Fleming WiFi Operations Center</div>")
        [void]$bodyBuilder.Append("</div></body></html>")
        $htmlBody = $bodyBuilder.ToString()


        $smtp = New-Object System.Net.Mail.SmtpClient($smtpServer, $smtpPort)
        $smtp.EnableSsl = $true
        $smtp.Credentials = New-Object System.Net.NetworkCredential($user, $pass)

        $mail = New-Object System.Net.Mail.MailMessage
        $mail.From = New-Object System.Net.Mail.MailAddress($user, "Fleming WiFi Voucher Hub")
        foreach ($r in $recipients) { $mail.To.Add($r) }
        $mail.Subject = $subject
        $mail.Body = $htmlBody
        $mail.IsBodyHtml = $true

        $smtp.Send($mail)
        $mail.Dispose()
        $smtp.Dispose()
        return $true
    } catch {
        return $false
    }
}

# 7. Clear Expired/Invalid Vouchers (Safely leaves unused & active intact)
function Clear-Invalid-Vouchers-Service {
    $omadacId = $global:OmadaConfig.omadacId
    $siteId = $global:OmadaConfig.siteId

    $payload = @{ type = 0 }
    $res = Invoke-Omada-API -Path "/openapi/v1/$omadacId/sites/$siteId/hotspot/voucher-groups/batch/clear-invalid" -Method "POST" -Body $payload -TimeoutMs 5000

    if ($res -and $res.errorCode -eq 0) {
        return @{ success = $true; message = "Expired and invalid vouchers successfully purged." }
    } else {
        $msg = if ($res.msg) { $res.msg } else { "Failed to clear invalid vouchers" }
        return @{ success = $false; error = $msg }
    }
}

# 8. Sales Journal & Collection Tracking Persistence
$salesJournalPath = "c:\Users\normaluser\OneDrive\Documents\Github Workspace\Internet Business\data\sales\voucher_sales_journal.json"

function Get-Sales-Journal {
    if (Test-Path $salesJournalPath) {
        try {
            $raw = Get-Content -Path $salesJournalPath -Raw -Encoding UTF8
            if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Trim() -eq "[]") { return @() }
            $parsed = $raw | ConvertFrom-Json
            if ($parsed -is [System.Array]) { return $parsed }
            return @($parsed)
        } catch {}
    }
    return @()
}

function Save-Sales-Journal($journalList) {
    try {
        $dir = Split-Path -Path $salesJournalPath -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

        $arr = [System.Collections.Generic.List[object]]::new()
        if ($journalList) {
            foreach ($item in $journalList) { if ($item) { $arr.Add($item) } }
        }
        $json = if ($arr.Count -eq 0) { "[]" } else { $arr | ConvertTo-Json -Depth 5 }
        if ($json.Trim().StartsWith("{")) { $json = "[$json]" }
        [System.IO.File]::WriteAllText($salesJournalPath, $json, [System.Text.Encoding]::UTF8)
    } catch {}
}

# 9. Calculate Full Sales Summary by Seller with Monthly Timeline & Collection Reconciliation
function Get-Sales-Summary-Report {
    param(
        [string]$MonthFilter = "all"
    )

    $allGroups = Get-All-Voucher-Groups-Data
    $journal = Get-Sales-Journal

    # Extract all unique timeline months from groups
    $monthsMap = [System.Collections.Generic.SortedDictionary[string, int]]::new()
    foreach ($g in $allGroups) {
        $cTime = if ($g.createTime) { $g.createTime } else { $g.createdTime }
        if ($cTime) {
            try {
                $mKey = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$cTime).ToOffset([TimeSpan]::FromHours(8)).ToString("yyyy-MM")
                if (-not $monthsMap.ContainsKey($mKey)) { $monthsMap[$mKey] = 0 }
                $monthsMap[$mKey] += 1
            } catch {}
        }
    }

    $availableMonths = [System.Collections.Generic.List[object]]::new()
    foreach ($mKey in ($monthsMap.Keys | Sort-Object -Descending)) {
        $label = $mKey
        try {
            $dt = [DateTime]::ParseExact("$mKey-01", "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
            $label = $dt.ToString("MMMM yyyy")
        } catch {}
        $availableMonths.Add([PSCustomObject]@{
            id    = $mKey
            label = $label
            count = $monthsMap[$mKey]
        })
    }


    # Filter groups by selected month if requested
    $groups = if ($MonthFilter -and $MonthFilter -ne "all") {
        @($allGroups | Where-Object {
            $cTime = if ($_.createTime) { $_.createTime } else { $_.createdTime }
            if ($cTime) {
                try {
                    $gMonth = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$cTime).ToOffset([TimeSpan]::FromHours(8)).ToString("yyyy-MM")
                    $gMonth -eq $MonthFilter
                } catch { $false }
            } else { $false }
        })
    } else {
        $allGroups
    }


    # Total collected per seller from journal (filtered by month if active)
    $collectedPerSeller = @{}
    foreach ($j in $journal) {
        $sName = $j.seller
        $jTimestamp = $j.timestamp
        $includeJ = $true
        if ($MonthFilter -and $MonthFilter -ne "all") {
            if ($jTimestamp -and -not $jTimestamp.StartsWith($MonthFilter)) {
                $includeJ = $false
            }
        }
        if ($includeJ) {
            $amt = if ($j.amountCollected) { [double]$j.amountCollected } else { 0 }
            if (-not $collectedPerSeller.ContainsKey($sName)) { $collectedPerSeller[$sName] = 0.0 }
            $collectedPerSeller[$sName] += $amt
        }
    }

    # Aggregate by seller
    $sellerMap = @{}
    foreach ($g in $groups) {
        $sName = $g.seller
        if (-not $sellerMap.ContainsKey($sName)) {
            $sellerMap[$sName] = @{
                seller        = $sName
                totalTickets  = 0
                unusedTickets = 0
                usedTickets   = 0
                totalIssuedPhp= 0.0
                usedValuePhp  = 0.0
                unusedValuePhp= 0.0
                tickets5Php   = 0
                tickets10Php  = 0
                tickets20Php  = 0
                tickets25Php  = 0
                tickets100Php = 0
                tickets350Php = 0
                otherTickets  = 0
                groupsCount   = 0
            }
        }

        $entry = $sellerMap[$sName]
        $entry.totalTickets += $g.amount
        $entry.unusedTickets += $g.unusedCount
        $entry.usedTickets += $g.usedCount
        $entry.totalIssuedPhp += $g.totalValue
        $entry.usedValuePhp += $g.usedValue
        $entry.unusedValuePhp += $g.unusedValue
        $entry.groupsCount += 1

        switch ($g.unitPrice) {
            5   { $entry.tickets5Php += $g.amount }
            10  { $entry.tickets10Php += $g.amount }
            20  { $entry.tickets20Php += $g.amount }
            25  { $entry.tickets25Php += $g.amount }
            100 { $entry.tickets100Php += $g.amount }
            350 { $entry.tickets350Php += $g.amount }
            default { $entry.otherTickets += $g.amount }
        }
    }

    $summaryList = @()
    $grandTotalIssued = 0.0
    $grandTotalUsedSold = 0.0
    $grandTotalCollected = 0.0

    foreach ($kv in $sellerMap.GetEnumerator()) {
        $s = $kv.Value
        $alreadyCollected = if ($collectedPerSeller.ContainsKey($s.seller)) { $collectedPerSeller[$s.seller] } else { 0.0 }
        $netToCollect = [Math]::Max(0.0, ($s.totalIssuedPhp - $alreadyCollected))

        $grandTotalIssued += $s.totalIssuedPhp
        $grandTotalUsedSold += $s.usedValuePhp
        $grandTotalCollected += $alreadyCollected

        $summaryList += [PSCustomObject]@{
            seller             = $s.seller
            groupsCount        = $s.groupsCount
            totalTickets       = $s.totalTickets
            unusedTickets      = $s.unusedTickets
            usedTickets        = $s.usedTickets
            totalIssuedPhp     = $s.totalIssuedPhp
            usedValuePhp       = $s.usedValuePhp
            unusedValuePhp     = $s.unusedValuePhp
            tickets5Php        = $s.tickets5Php
            tickets10Php       = $s.tickets10Php
            tickets20Php       = $s.tickets20Php
            tickets25Php       = $s.tickets25Php
            tickets100Php      = $s.tickets100Php
            tickets350Php      = $s.tickets350Php
            alreadyCollectedPhp= $alreadyCollected
            uncollectedCashPhp = $netToCollect
        }
    }

    # Sort descending by uncollected cash
    $summaryList = @($summaryList | Sort-Object uncollectedCashPhp -Descending)

    return @{
        selectedMonth        = $MonthFilter
        availableMonths      = $availableMonths
        sellers              = $summaryList
        grandTotalIssuedPhp  = $grandTotalIssued
        grandTotalUsedSoldPhp= $grandTotalUsedSold
        grandTotalCollected  = $grandTotalCollected
        grandNetToCollect    = [Math]::Max(0.0, ($grandTotalIssued - $grandTotalCollected))
        journalHistory       = @($journal | Select-Object -Last 50)
    }
}

function Get-Active-Clients-Report {
    $omadacId = $global:OmadaConfig.omadacId
    $siteId = $global:OmadaConfig.siteId

    $cliRes = Invoke-Omada-API -Path "/openapi/v1/$omadacId/sites/$siteId/clients?page=1&pageSize=500" -TimeoutMs 8000
    if (-not $cliRes -or -not $cliRes.result -or -not $cliRes.result.data) {
        return @{
            timestampPht   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            totalClients   = 0
            totalTrafficGb = 0.0
            totalVouchers  = 0
            totalPrivate   = 0
            locations      = @()
            clients        = @()
        }
    }

    $rawClients = $cliRes.result.data

    # Map of known batch rates
    $vGroups = Get-All-Voucher-Groups-Data
    $batchRateMap = @{}
    foreach ($g in $vGroups) {
        if ($g.name) {
            $p = 0.0
            if ($g.name -match "(?:₱|P|PHP)\s*([0-9]+)") {
                $p = [double]$matches[1]
            } elseif ($g.name -match "4hr") { $p = 10.0 }
            elseif ($g.name -match "1day|24hr") { $p = 20.0 }
            elseif ($g.name -match "2hr") { $p = 5.0 }
            elseif ($g.name -match "7day") { $p = 100.0 }
            elseif ($g.name -match "30day|1month") { $p = 350.0 }
            $batchRateMap[$g.name] = @{
                price = $p
                duration = if ($g.duration) { $g.duration } else { 0 }
                unit = if ($g.unit) { $g.unit } else { 0 }
            }
        }
    }

    $clientList = @()
    $locationMap = @{}
    $totalDownBytes = [int64]0
    $totalUpBytes = [int64]0
    $totalVoucherUsers = 0
    $totalPrivateUsers = 0
    $totalActiveVoucherValue = 0.0

    foreach ($c in $rawClients) {
        $ap = if ($c.apName) { $c.apName } else { "General AP" }
        $ssid = if ($c.ssid) { $c.ssid } else { "LAN / Direct" }
        
        # Extract location prefix (e.g. Danilo, Ruel, Jelan Resort, Bobs, Home, Chairah, Merlita, Natural)
        $loc = "General"
        if ($ap -match "^([^-]+)\s*-") {
            $loc = $matches[1].Trim()
        } elseif ($ssid -match "^([^-]+)\s*-") {
            $loc = $matches[1].Trim()
        } elseif ($ssid -like "*Jelan*") {
            $loc = "Jelan Resort"
        } elseif ($ssid -like "*Annica*") {
            $loc = "Annica Resort"
        }

        # Auth & Voucher Code extraction
        $vCode = ""
        $authType = "Voucher"
        $planPrice = 0.0
        $planText = "Voucher Ticket"
        
        if ($c.authInfo -and $c.authInfo.Count -gt 0) {
            foreach ($ai in $c.authInfo) {
                if ($ai.info) { $vCode = $ai.info.ToString() }
            }
        }

        if ($ssid -like "*Private*" -or $ssid -like "*Home Wifi*") {
            $authType = "Private WPA2"
            $planText = "Private / Unrestricted"
            $totalPrivateUsers++
        } elseif ($vCode) {
            $authType = "Voucher"
            $totalVoucherUsers++
            # Approximate price from common ticket patterns
            $planText = "Voucher Code: $vCode"
        } elseif ($c.guest -eq $false -and $c.authStatus -eq 2) {
            $authType = "Authorized"
            $planText = "MAC Authenticated"
            $totalPrivateUsers++
        } else {
            $authType = "Voucher Guest"
            $totalVoucherUsers++
            $planText = "Hotspot Portal"
        }

        # Format traffic
        $downBytes = if ($c.trafficDown) { [int64]$c.trafficDown } else { [int64]0 }
        $upBytes = if ($c.trafficUp) { [int64]$c.trafficUp } else { [int64]0 }
        $totalDownBytes += $downBytes
        $totalUpBytes += $upBytes

        $downMb = [Math]::Round($downBytes / 1048576, 1)
        $upMb = [Math]::Round($upBytes / 1048576, 1)
        $totalMb = [Math]::Round(($downBytes + $upBytes) / 1048576, 1)

        # Uptime formatting
        $uptimeSec = if ($c.uptime) { [int]$c.uptime } else { 0 }
        $uptimeStr = ""
        if ($uptimeSec -ge 86400) {
            $days = [Math]::Floor($uptimeSec / 86400)
            $hrs = [Math]::Floor(($uptimeSec % 86400) / 3600)
            $uptimeStr = "${days}d ${hrs}h"
        } elseif ($uptimeSec -ge 3600) {
            $hrs = [Math]::Floor($uptimeSec / 3600)
            $mins = [Math]::Floor(($uptimeSec % 3600) / 60)
            $uptimeStr = "${hrs}h ${mins}m"
        } else {
            $mins = [Math]::Floor($uptimeSec / 60)
            $uptimeStr = "${mins}m"
        }

        # Signal Quality
        $rssi = if ($c.rssi) { [int]$c.rssi } else { -75 }
        $signalLabel = "Good"
        $signalColor = "#38bdf8"
        if ($rssi -gt -65) { $signalLabel = "Excellent"; $signalColor = "#34d399" }
        elseif ($rssi -gt -75) { $signalLabel = "Good"; $signalColor = "#38bdf8" }
        elseif ($rssi -gt -85) { $signalLabel = "Fair"; $signalColor = "#f59e0b" }
        else { $signalLabel = "Weak"; $signalColor = "#ef4444" }

        # Device display name
        $devName = if ($c.name) { $c.name } elseif ($c.hostName) { $c.hostName } else { "Wireless Device" }
        if ($c.osName -and $c.osName -ne "Unknown") {
            $devName += " ($($c.osName))"
        }

        $clientObj = [PSCustomObject]@{
            mac           = $c.mac
            ip            = $c.ip
            name          = $devName
            rawName       = if ($c.name) { $c.name } else { $c.hostName }
            location      = $loc
            apName        = $ap
            ssid          = $ssid
            authType      = $authType
            voucherCode   = $vCode
            planText      = $planText
            downMb        = $downMb
            upMb          = $upMb
            totalMb       = $totalMb
            uptimeSec     = $uptimeSec
            uptimeStr     = $uptimeStr
            rssi          = $rssi
            signalLabel   = $signalLabel
            signalColor   = $signalColor
            activity      = if ($c.activity) { [int]$c.activity } else { 0 }
            wifiMode      = if ($c.wifiMode) { $c.wifiMode } else { 0 }
            channel       = if ($c.channel) { $c.channel } else { 0 }
        }

        $clientList += $clientObj

        # Location Aggregation
        if (-not $locationMap.ContainsKey($loc)) {
            $locationMap[$loc] = @{
                location     = $loc
                activeCount  = 0
                voucherCount = 0
                privateCount = 0
                totalDownMb  = 0.0
                totalUpMb    = 0.0
                topAps       = @{}
            }
        }

        $locationMap[$loc].activeCount++
        if ($authType -like "*Private*" -or $authType -like "*Authorized*") {
            $locationMap[$loc].privateCount++
        } else {
            $locationMap[$loc].voucherCount++
        }
        $locationMap[$loc].totalDownMb += $downMb
        $locationMap[$loc].totalUpMb += $upMb
        
        if (-not $locationMap[$loc].topAps.ContainsKey($ap)) {
            $locationMap[$loc].topAps[$ap] = 0
        }
        $locationMap[$loc].topAps[$ap]++
    }

    # Format locations array
    $locationsList = @()
    foreach ($k in $locationMap.Keys) {
        $l = $locationMap[$k]
        $topApStr = ($l.topAps.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 2 | ForEach-Object { "$($_.Key) ($($_.Value))" }) -join ", "
        $locationsList += [PSCustomObject]@{
            location     = $l.location
            activeCount  = $l.activeCount
            voucherCount = $l.voucherCount
            privateCount = $l.privateCount
            totalDownMb  = [Math]::Round($l.totalDownMb, 1)
            totalUpMb    = [Math]::Round($l.totalUpMb, 1)
            totalGb      = [Math]::Round(($l.totalDownMb + $l.totalUpMb) / 1024, 2)
            topApSummary = $topApStr
        }
    }

    $locationsList = @($locationsList | Sort-Object activeCount -Descending)
    $clientList = @($clientList | Sort-Object totalMb -Descending)

    $totalTrafficGb = [Math]::Round(($totalDownBytes + $totalUpBytes) / 1073741824, 2)

    return @{
        timestampPht    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        totalClients    = $clientList.Count
        totalTrafficGb  = $totalTrafficGb
        totalVouchers   = $totalVoucherUsers
        totalPrivate    = $totalPrivateUsers
        locations       = $locationsList
        clients         = $clientList
    }
}

