param(
    [ValidatePattern('^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$')][string]$StorageRepo,
    [ValidateSet('home','work')][string]$Device,
    [ValidatePattern('^[a-fA-F0-9]{32}$')][string]$GistId,
    [switch]$Publish,
    [switch]$UpdateOnly
)

$ErrorActionPreference = 'Stop'
$folder = Join-Path $env:LOCALAPPDATA 'AgentUsageGist'
$configPath = Join-Path $folder 'devices.json'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$gh = (Get-Command gh.exe).Source
$npx = (Get-Command npx.cmd).Source
if ($UpdateOnly) {
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $StorageRepo = $config.repo
    $Device = $config.device
    $Publish = [bool]$config.publish
    $GistId = $config.gist
}
if (-not $StorageRepo -or -not $Device) { throw 'Supply -StorageRepo and -Device home or work.' }

if ($Publish -and -not $GistId) { throw 'Supply -GistId when using -Publish.' }

function Invoke-GitHub($endpoint, $method = 'GET', $payload = $null, [switch]$AllowMissing) {
    $arguments = @('api', '--hostname', 'github.com', '--method', $method, $endpoint)
    $payloadPath = $null
    $errorPath = [IO.Path]::GetTempFileName()
    try {
        if ($null -ne $payload) {
            $payloadPath = [IO.Path]::GetTempFileName()
            [IO.File]::WriteAllText($payloadPath, ($payload | ConvertTo-Json -Depth 12 -Compress), $utf8)
            $arguments += @('--input', $payloadPath)
        }
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $result = & $gh @arguments 2> $errorPath
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        if ($code -ne 0) {
            $detail = Get-Content -LiteralPath $errorPath -Raw
            if ($AllowMissing -and $detail -match 'HTTP 404') { return $null }
            throw "GitHub request failed for ${endpoint}: $detail"
        }
        ($result -join "`n") | ConvertFrom-Json
    } finally {
        if ($payloadPath) { Remove-Item -LiteralPath $payloadPath -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $errorPath -ErrorAction SilentlyContinue
    }
}

function Read-DeviceFile($name) {
    $entry = Invoke-GitHub "repos/$StorageRepo/contents/devices/$name.json" -AllowMissing
    if ($null -eq $entry) { return $null }
    if ($entry.encoding -ne 'base64') { throw "Unexpected encoding for $name usage." }
    $record = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($entry.content)) | ConvertFrom-Json
    if ($record.schema -ne 1 -or $record.device -ne $name -or $null -eq $record.days) {
        throw "Invalid usage snapshot for $name."
    }
    @{ sha = $entry.sha; record = $record }
}

function Update-DeviceFile($today) {
    $raw = & $npx --yes --package=ccusage@20.0.51 -- ccusage daily --since 2000-01-01 --until $today --timezone Asia/Seoul --by-agent --no-cost --offline --json
    if ($LASTEXITCODE -ne 0) { throw 'Failed to read local usage.' }
    $report = ($raw -join "`n") | ConvertFrom-Json
    if ($null -eq $report.daily) { throw 'Invalid usage report.' }

    $existing = Read-DeviceFile $Device
    $byDate = @{}
    if ($existing) {
        foreach ($day in $existing.record.days) {
            $byDate[[string]$day.date] = @{ date = $day.date; claude = [long]$day.claude; codex = [long]$day.codex }
        }
    }
    foreach ($day in $report.daily) {
        $date = [string]$day.period
        if ($date -notmatch '^\d{4}-\d{2}-\d{2}$' -or $null -eq $day.agents) { throw 'Malformed usage day.' }
        foreach ($row in $day.agents) {
            $agent = [string]$row.agent
            if ($agent -notin @('claude','codex')) { continue }
            if ($null -eq $row.totalTokens -or $row.totalTokens -lt 0) { throw 'Invalid token count.' }
            if (-not $byDate.ContainsKey($date)) { $byDate[$date] = @{ date = $date; claude = 0L; codex = 0L } }
            $byDate[$date][$agent] = [Math]::Max([long]$byDate[$date][$agent], [long]$row.totalTokens)
        }
    }
    if ($byDate.Count -eq 0) { throw 'No Claude Code or Codex CLI records found on this device.' }
    $days = @($byDate.Values | Sort-Object { $_.date })
    $changed = -not $existing -or $existing.record.days.Count -ne $days.Count
    if (-not $changed) {
        for ($i = 0; $i -lt $days.Count; $i++) {
            $old = $existing.record.days[$i]
            $new = $days[$i]
            if ($old.date -ne $new.date -or $old.claude -ne $new.claude -or $old.codex -ne $new.codex) { $changed = $true; break }
        }
    }
    if ($changed) {
        $json = @{ schema = 1; device = $Device; days = $days } | ConvertTo-Json -Depth 6 -Compress
        $payload = @{
            message = 'chore: sync agent usage'
            content = [Convert]::ToBase64String($utf8.GetBytes($json))
        }
        if ($existing) { $payload.sha = $existing.sha }
        Invoke-GitHub "repos/$StorageRepo/contents/devices/$Device.json" 'PUT' $payload | Out-Null
    }
}

function Publish-Usage($today, $weekStart) {
    $totals = @{ claude = 0L; codex = 0L }
    $weekly = @{ claude = 0L; codex = 0L }
    $deviceCount = 0
    foreach ($name in @('home','work')) {
        $entry = Read-DeviceFile $name
        if (-not $entry) { continue }
        $deviceCount++
        foreach ($day in $entry.record.days) {
            if ($day.date -gt $today) { continue }
            $totals.claude += [long]$day.claude
            $totals.codex += [long]$day.codex
            if ($day.date -ge $weekStart) {
                $weekly.claude += [long]$day.claude
                $weekly.codex += [long]$day.codex
            }
        }
    }
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    $text = @(
        '{0,-11}{1,14}{2,14}' -f 'Agent','Weekly tokens','Total tokens'
        '{0,-11}{1,14}{2,14}' -f 'Claude Code',$weekly.claude.ToString('N0',$invariant),$totals.claude.ToString('N0',$invariant)
        '{0,-11}{1,14}{2,14}' -f 'Codex',$weekly.codex.ToString('N0',$invariant),$totals.codex.ToString('N0',$invariant)
        "Last 7 days (KST) | $deviceCount/2 devices"
    ) -join "`n"
    $endpoint = "gists/$gistId"
    $gist = Invoke-GitHub $endpoint
    if ($null -eq $gist.files.'Agent Usage.txt') { throw 'Agent Usage.txt is missing.' }
    if (([string]$gist.files.'Agent Usage.txt'.content).TrimEnd() -ne $text) {
        Invoke-GitHub $endpoint 'PATCH' @{ files = @{ 'Agent Usage.txt' = @{ content = $text + "`n" } } } | Out-Null
    }
}

$repo = Invoke-GitHub "repos/$StorageRepo"
if ($repo.visibility -ne 'private') { throw 'Usage storage must be a private repository.' }
$now = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTimeOffset]::UtcNow, 'Korea Standard Time').Date
Update-DeviceFile ($now.ToString('yyyy-MM-dd'))
if ($Publish) { Publish-Usage ($now.ToString('yyyy-MM-dd')) ($now.AddDays(-6).ToString('yyyy-MM-dd')) }
if ($UpdateOnly) { exit 0 }

New-Item -ItemType Directory -Path $folder -Force | Out-Null
$scriptPath = Join-Path $folder 'sync-usage.ps1'
if ($PSCommandPath -ne $scriptPath) { Copy-Item -LiteralPath $PSCommandPath -Destination $scriptPath -Force }
Unblock-File -LiteralPath $scriptPath
[IO.File]::WriteAllText($configPath, (@{ repo = $StorageRepo; device = $Device; publish = [bool]$Publish; gist = $GistId } | ConvertTo-Json), $utf8)
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument ('-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "{0}" -UpdateOnly' -f $scriptPath) -WorkingDirectory $folder
$triggers = @(
    New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours(9))
    New-ScheduledTaskTrigger -AtLogOn -User $user
)
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'Agent Usage Gist' -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
Write-Output "Configured device '$Device' for 09:00 and Windows logon. Gist publishing: $Publish."
