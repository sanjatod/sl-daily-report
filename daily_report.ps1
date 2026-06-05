# SL Daily Scrum Master Report
# Runs on GitHub Actions (cloud) or locally via Windows Startup.
# GitHub Actions: set JIRA_API_TOKEN secret in repo settings.
# Local: runs as-is with hardcoded token fallback.

param(
    [string]$JiraApiToken = $(if ($env:JIRA_API_TOKEN) { $env:JIRA_API_TOKEN } else { "ATATT3xFfGF0wd2WKnfFyFefuUk_N67ILTsTqUIAUeUrps9SvC7ze1XuMw77H8YS40ZZ8IvYQIm48mZXyKHQ7uy2Ics4t-g50OIU0AEWDT4BAlxTu0720CdnIkGARBAUBCCbVh43iTtwh4euXWpeS1wpIRiHsgwLmWfj8BfqRauBv2R4O8NpujI=35CF59EA" }),
    [switch]$TestMode   # -TestMode: salje na Mobile kanal umesto Sales Leader
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# Proxy fix: samo na Windows (Task Scheduler / lokalno)
if ($IsWindows -ne $false) {
    [System.Net.WebRequest]::DefaultWebProxy = [System.Net.WebRequest]::GetSystemWebProxy()
    [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
}

# -- Config -------------------------------------------------------------------
$JIRA_EMAIL    = "sanja.todorovic@intelisale.com"
$JIRA_BASE     = "https://intelisale.atlassian.net"
$CLOUD_ID      = "8eb3dc28-7a71-4893-a9a3-71c026566ef9"
$WEBHOOK_PROD   = "https://default4b8aa2e8b91c4c9f864e9a227c90af.6b.environment.api.powerplatform.com:443/powerautomate/automations/direct/workflows/ff8e760fb4a44012ae8a475b966d7f38/triggers/manual/paths/invoke?api-version=1&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=GP041TA0L5M2WHM8ZeM4UaI8u5nsEuamtweRpYnx6hI"
$WEBHOOK_MOBILE = "https://intelisaledoo.webhook.office.com/webhookb2/ee71c70c-320b-423a-9a50-5e4145905196@4b8aa2e8-b91c-4c9f-864e-9a227c90af6b/IncomingWebhook/61f73bf4ecd14158916d5615bf8eea33/f9c5a9b1-bf15-46c9-9031-ee66fa1f906f/V2YStZZ6SCh-zS_SYzSsA-iV7z1Gezs_WixDpJ1alMy7E1"
$TEAMS_WEBHOOK  = if ($TestMode) { $WEBHOOK_MOBILE } else { $WEBHOOK_PROD }

$logFile = if ($IsWindows -eq $false) { "/tmp/sl-daily-report.log" } else { "C:\Users\sanja\AppData\Local\sl-daily-report\last_run.log" }
"Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | User: $env:USERNAME | TestMode: $TestMode" | Out-File $logFile -Encoding UTF8

# -- Emoji ---------------------------------------------------------------------
$eChart   = [char]::ConvertFromUtf32(0x1F4CA)
$eSupport = [char]::ConvertFromUtf32(0x1F198)
$eNew     = [char]::ConvertFromUtf32(0x1F195)
$eLock    = [char]::ConvertFromUtf32(0x1F6A8)

$today = (Get-Date).Date

# -- Serbian public holidays (skip report) -------------------------------------
$holidays = @("01-01","01-02","01-07","02-15","02-16","05-01","05-02","11-11")
$todayMMDD = (Get-Date).ToString("MM-dd")
if ($holidays -contains $todayMMDD) {
    "Skipped - public holiday $todayMMDD" | Add-Content $logFile -Encoding UTF8
    exit 0
}

# -- Lookback (Mon = -72h/-3d, else -24h/-1d) ---------------------------------
$dayOfWeek = (Get-Date).DayOfWeek
if ($dayOfWeek -eq "Monday") {
    $LOOKBACK = "-72h"; $LOOKBACK_D = "-3d"; $label = "od petka"
} else {
    $LOOKBACK = "-24h"; $LOOKBACK_D = "-1d"; $label = "juce"
}

# -- Format date in Serbian -----------------------------------------------------
$months = @("","januar","februar","mart","april","maj","jun","jul","avgust","septembar","oktobar","novembar","decembar")
$d = Get-Date
$datumSr = "$($d.Day). $($months[$d.Month]) $($d.Year)."

# -- Jira REST API helper ------------------------------------------------------
$authBytes = [System.Text.Encoding]::UTF8.GetBytes("${JIRA_EMAIL}:${JiraApiToken}")
$authB64   = [Convert]::ToBase64String($authBytes)
$headers   = @{ "Authorization" = "Basic $authB64"; "Accept" = "application/json" }

function JiraSearch($jql, $fields, $maxResults = 100) {
    $allIssues = @()
    $pageToken  = $null
    $page       = 0
    do {
        $url = "$JIRA_BASE/rest/api/3/search/jql?jql=" + [Uri]::EscapeDataString($jql) +
               "&maxResults=$maxResults&fields=" + ($fields -join ",")
        if ($pageToken) { $url += "&nextPageToken=" + [Uri]::EscapeDataString($pageToken) }
        try {
            $resp = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -ErrorAction Stop
        } catch {
            "ERROR Jira page $page : $($_.Exception.Message)" | Add-Content $logFile -Encoding UTF8
            break
        }
        $allIssues += $resp.issues
        $page++
        if ($resp.isLast -eq $true -or -not $resp.nextPageToken) { break }
        $pageToken = $resp.nextPageToken
    } while ($page -lt 20)
    return $allIssues
}

# -- Upit B - support tasks ----------------------------------------------------
"TLS+proxy set OK" | Add-Content $logFile -Encoding UTF8
Write-Host "Fetching Upit B..."
$allB = @(JiraSearch `
    "project = SLR AND `"Help Desk[Dropdown]`" = `"Support issue`" AND created >= `"$LOOKBACK`" ORDER BY created DESC" `
    @("summary","status","assignee","priority"))
Write-Host "  B: $($allB.Count)"

# -- Upit C - new in sprint ----------------------------------------------------
Write-Host "Fetching Upit C..."
$allC = @(JiraSearch `
    "project = SLR AND sprint in openSprints() AND fixVersion is not EMPTY AND created >= `"$LOOKBACK`" ORDER BY created DESC" `
    @("summary","status","issuetype"))
Write-Host "  C: $($allC.Count)"

# -- Upit E - blocked >7d ------------------------------------------------------
Write-Host "Fetching Upit E..."
$allE = @(JiraSearch `
    "project = SLR AND sprint in openSprints() AND issuetype in subTaskIssueTypes() AND status in (`"On Hold`",`"On Hold Dev`",`"On Hold - Development`",`"On Hold Testing`",`"On Hold - Testing`") AND updated <= `"-7d`" AND (`"Help Desk[Dropdown]`" is EMPTY OR NOT `"Help Desk[Dropdown]`" = `"Support issue`") ORDER BY updated ASC" `
    @("summary","status","assignee","updated"))
foreach ($e in $allE) { $e | Add-Member -NotePropertyName "days" -NotePropertyValue (($today - [datetime]$e.fields.updated).Days) -Force }
$allE = @($allE | Sort-Object { $_.days } -Descending)
Write-Host "  E: $($allE.Count)"

# -- Build Adaptive Card -------------------------------------------------------
$bodyItems = [System.Collections.ArrayList]@()
$null = $bodyItems.Add(@{ "type"="TextBlock";"size"="Large";"weight"="Bolder";"color"="Accent";"text"=($eChart + " SL Daily Snapshot - $datumSr") })
$null = $bodyItems.Add(@{ "type"="TextBlock";"text"="Podaci: $label";"wrap"=$true })

# DEO 1a - Support
$null = $bodyItems.Add(@{ "type"="TextBlock";"weight"="Bolder";"text"=($eSupport + " Support (Help Desk):");"spacing"="Medium" })
if ($allB.Count -eq 0) {
    $null = $bodyItems.Add(@{ "type"="TextBlock";"text"="Nema novih";"isSubtle"=$true })
} else {
    foreach ($t in $allB) {
        $u = "$JIRA_BASE/browse/$($t.key)"
        $s = $t.fields.summary.Trim()
        if ($s.Length -gt 80) { $s = $s.Substring(0,80) + "..." }
        $pri = $t.fields.priority.name
        $priTag = switch ($pri) {
            "Critical" { "🔴 Critical" }
            "High"     { "🟠 High" }
            "Medium"   { "🟡 Medium" }
            "Low"      { "🔵 Low" }
            "Trivial"  { "⚪ Trivial" }
            default    { $pri }
        }
        $null = $bodyItems.Add(@{ "type"="TextBlock";"wrap"=$true;"text"="* [$($t.key) - $s]($u) — $priTag" })
    }
}

# DEO 1b - Novi u sprintu
$null = $bodyItems.Add(@{ "type"="TextBlock";"weight"="Bolder";"text"=($eNew + " Novi u sprintu ($label):");"spacing"="Small" })
if ($allC.Count -eq 0) {
    $null = $bodyItems.Add(@{ "type"="TextBlock";"text"="Nema novih";"isSubtle"=$true })
} else {
    foreach ($t in $allC) {
        $u = "$JIRA_BASE/browse/$($t.key)"
        $s = $t.fields.summary.Trim()
        if ($s.Length -gt 80) { $s = $s.Substring(0,80) + "..." }
        $null = $bodyItems.Add(@{ "type"="TextBlock";"wrap"=$true;"text"="* [$($t.key) - $s]($u)" })
    }
}

# DEO 3 - Blokirano >7 dana
$totalE = $allE.Count
$null = $bodyItems.Add(@{ "type"="TextBlock";"weight"="Bolder";"text"=($eLock + " Blokirano >7 dana ($totalE subtaskova):");"spacing"="Medium" })
if ($totalE -eq 0) {
    $null = $bodyItems.Add(@{ "type"="TextBlock";"text"="Nema blokiranih";"isSubtle"=$true })
} else {
    foreach ($e in $allE) {
        $s = $e.fields.summary.Trim()
        if ($s.Length -gt 55) { $s = $s.Substring(0,55) + "..." }
        $stName = $e.fields.status.name
        $ohTag  = if ($stName -in @("On Hold Testing","On Hold - Testing")) { "OH-Test" } else { "OH-Dev" }
        $asgn   = if ($e.fields.assignee) { " @" + $e.fields.assignee.displayName } else { "" }
        $u      = "$JIRA_BASE/browse/$($e.key)"
        $null = $bodyItems.Add(@{ "type"="TextBlock";"wrap"=$true;"text"="* [$($e.key) - $s]($u) - $($e.days)d [$ohTag$asgn]" })
    }
}

# -- Send ----------------------------------------------------------------------
$card = @{
    "type"="message"
    "attachments"=@(@{
        "contentType"="application/vnd.microsoft.card.adaptive"
        "content"=@{
            "`$schema"="http://adaptivecards.io/schemas/adaptive-card.json"
            "type"="AdaptiveCard"; "version"="1.2"
            "body"=$bodyItems.ToArray()
        }
    })
}

$json  = $card | ConvertTo-Json -Depth 20 -Compress
$bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

try {
    $resp = Invoke-RestMethod -Uri $TEAMS_WEBHOOK -Method Post -Body $bytes -ContentType "application/json; charset=utf-8" -ErrorAction Stop
    $msg = "OK - support=$($allB.Count) novi=$($allC.Count) blocked=$totalE | Teams=$resp"
    Write-Host $msg
    $msg | Add-Content $logFile -Encoding UTF8
} catch {
    $err = "ERROR sending to Teams: $($_.Exception.Message)"
    Write-Host $err
    $err | Add-Content $logFile -Encoding UTF8
    exit 1
}
