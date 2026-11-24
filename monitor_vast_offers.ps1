<#
.SYNOPSIS
Serves a local web UI to configure Vast.ai offer filters with sliders, edit the RUN CLI command,
preview matching offers, and auto-rent the cheapest one.

.DESCRIPTION
Replaces the old WinForms dialog. The script starts an HttpListener on http://localhost:<Port>/,
opens the default browser, and serves a single-page UI styled after the Vast.ai search page:
removable filter chips, dual-handle range sliders, an editable RUN CLI command, a live offer
preview table, and a monitor loop driven from the page (one search per interval; the tab must
stay open).

Auth: VAST_API_KEY is read from the process or User environment. A saved VAST_API_SESSION_KEY
(User environment) is validated at startup; when invalid, the UI asks for a fresh TOTP code and
saves the new session back to User environment. HF_TOKEN / CIVITAI_TOKEN placeholders inside the
RUN CLI command are substituted from the environment at rent time.

Settings (filters, interval, rental type, RUN CLI command) persist in
monitor_vast_settings.json next to this script.

.PARAMETER Port
Local TCP port for the web UI. Defaults to 8765; the script increments on conflict.

.PARAMETER IntervalSeconds
Initial search interval (seconds) when no saved settings exist. Defaults to 60.

.PARAMETER NoBrowser
Do not open the default browser automatically.

.EXAMPLE
.\monitor_vast_offers.ps1

.EXAMPLE
.\monitor_vast_offers.ps1 -Port 8800 -NoBrowser
#>
[CmdletBinding()]
param(
    [int]$Port = 8765,

    [ValidateRange(15, 3600)]
    [int]$IntervalSeconds = 60,

    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$script:baseUri = 'https://console.vast.ai/api/v0'
$script:authFailurePattern = '(?i)(auth_error|authorization error|requires login|two.factor|two factor|logged in using|invalid user key)'
$script:settingsPath = Join-Path $PSScriptRoot 'monitor_vast_settings.json'

$script:apiKey = $env:VAST_API_KEY
if ([string]::IsNullOrWhiteSpace($script:apiKey)) {
    $script:apiKey = [Environment]::GetEnvironmentVariable('VAST_API_KEY', 'User')
}
if ([string]::IsNullOrWhiteSpace($script:apiKey)) {
    throw 'VAST_API_KEY is not set. Define it as a user environment variable or in this PowerShell session.'
}

# ---------------------------------------------------------------------------
# Log ring buffer (returned to the web UI and echoed to the console)
# ---------------------------------------------------------------------------
$script:log = New-Object System.Collections.Generic.List[string]

function Add-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    $script:log.Add($line)
    while ($script:log.Count -gt 400) { $script:log.RemoveAt(0) }
    Write-Host $line
}

function Get-LogTail {
    $count = $script:log.Count
    if ($count -eq 0) { return @() }
    $take = [Math]::Min($count, 150)
    return $script:log.GetRange($count - $take, $take)
}

# ---------------------------------------------------------------------------
# Vast session handling (TOTP via web UI)
# ---------------------------------------------------------------------------
$script:sessionKey = $null
$script:headers = $null
$script:authOk = $false
$script:needsAuth = $true

function Set-VastSession {
    param([string]$Code)
    if ([string]::IsNullOrWhiteSpace($Code)) {
        throw 'Enter the current TOTP code from your authenticator app.'
    }
    $loginBody = @{ tfa_method = 'totp'; code = $Code } | ConvertTo-Json -Compress
    $login = Invoke-RestMethod -Method Post -Uri "$script:baseUri/tfa/" `
        -Headers @{ Authorization = "Bearer $script:apiKey" } `
        -ContentType 'application/json' -Body $loginBody -TimeoutSec 30
    if ([string]::IsNullOrWhiteSpace($login.session_key) -or -not $login.id) {
        throw 'Vast did not return an authenticated 2FA session. Confirm TOTP is enabled and retry.'
    }

    $script:sessionKey = $login.session_key
    $script:headers = @{ Authorization = "Bearer $script:sessionKey" }
    $script:authOk = $true
    $script:needsAuth = $false
    $env:VAST_API_SESSION_KEY = $script:sessionKey
    [Environment]::SetEnvironmentVariable('VAST_API_SESSION_KEY', $script:sessionKey, 'User')
    Add-Log 'Fresh 2FA session saved to this Windows user profile.'
}

function Invoke-VastApi {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Body
    )

    if (-not $script:headers) {
        throw 'Authorization error: no Vast session. Enter a fresh TOTP code in the web UI.'
    }

    $request = @{
        Method     = $Method
        Uri        = $Uri
        Headers    = $script:headers
        TimeoutSec = 30
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $request.Body = $Body
        $request.ContentType = 'application/json'
    }

    try {
        $result = Invoke-RestMethod @request
    }
    catch {
        $message = [string]$_.Exception.Message
        $detail = [string]$_.ErrorDetails.Message
        $statusCode = 0
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
        if (($detail -match $script:authFailurePattern) -or ($message -match $script:authFailurePattern) -or ($statusCode -in 401, 403)) {
            $script:authOk = $false
            $script:needsAuth = $true
            throw [System.UnauthorizedAccessException]::new("auth_error: Vast rejected the session ($message). Enter a fresh TOTP code in the web UI.")
        }
        throw
    }
    $responseMessage = [string]$result.msg
    if ($result.success -eq $false -and $responseMessage -match $script:authFailurePattern) {
        $script:authOk = $false
        $script:needsAuth = $true
        throw [System.UnauthorizedAccessException]::new($responseMessage)
    }
    return $result
}

# ---------------------------------------------------------------------------
# Settings (filters, interval, rental type, RUN CLI command)
# ---------------------------------------------------------------------------
$script:defaultCommand = 'vastai create instance <OFFER_ID> --image vastai/comfy:v0.37.0-cuda-12.9-py312 --env ''-p 1111:1111 -p 8080:8080 -p 8384:8384 -p 72299:72299 -p 8188:8188 -p 8288:8288 -p 10100:10100 -p 10200:10200 -e COMFYUI_ARGS="--disable-auto-launch --disable-xformers --port 18188 --enable-cors-header" -e COMFYUI_API_BASE="http://localhost:18188" -e PORTAL_CONFIG="localhost:1111:11111:/:Instance Portal|localhost:8188:18188:/:ComfyUI|localhost:8288:18288:/docs:API Wrapper|localhost:8188:18188:/:ComfyUI|localhost:8080:18080:/:Jupyter|localhost:8080:8080:/terminals/1:Jupyter Terminal|localhost:8384:18384:/:Syncthing" -e OPEN_BUTTON_PORT="1111" -e JUPYTER_DIR="/" -e DATA_DIRECTORY="/workspace/" -e OPEN_BUTTON_TOKEN="1" -e PROVISIONING_SCRIPT="https://raw.githubusercontent.com/Buraska/vast-ai-provision-scripts/main/minimax_h3.sh" -e HF_TOKEN="<HF_TOKEN>" -e CIVITAI_TOKEN="<CIVITAI_TOKEN>"'' --onstart-cmd ''entrypoint.sh'' --disk <DISK_GB> --jupyter --ssh --direct'

$script:defaultFilters = [ordered]@{
    gpu_mem_bw        = @{ min = 484.4;   max = 2000 }
    gpu_total_ram     = @{ min = 13.1;    max = 256 }
    disk_space        = @{ min = 140;     max = 8192 }
    direct_port_count = @{ min = 9;       max = 64 }
    reliability       = @{ min = 90.9;    max = 100 }
    cpu_ram           = @{ min = 13.5;    max = 512 }
    dph_total         = @{ min = 0;       max = 0.657 }
    cuda_max_good     = @{ min = 13;      max = 14 }
    inet_down_cost    = @{ min = 0;       max = 0.0004 }
    inet_up_cost      = @{ min = 0;       max = 0.0005 }
    inet_down         = @{ min = 0;       max = 10000 }
    inet_up           = @{ min = 0;       max = 10000 }
    duration          = @{ min = 0;       max = 2592000 }
}

$script:settings = @{
    command  = $script:defaultCommand
    interval = $IntervalSeconds
    type     = 'ondemand'
    filters  = @{}
}
foreach ($key in @($script:defaultFilters.Keys)) {
    $script:settings.filters[$key] = @{ min = $script:defaultFilters[$key].min; max = $script:defaultFilters[$key].max }
}

function ConvertTo-HashtableDeep {
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $hash = @{}
        foreach ($key in $Value.Keys) { $hash[$key] = ConvertTo-HashtableDeep $Value[$key] }
        return $hash
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $hash = @{}
        foreach ($property in $Value.PSObject.Properties) { $hash[$property.Name] = ConvertTo-HashtableDeep $property.Value }
        return $hash
    }
    return $Value
}

function Update-SettingsFromJson {
    param($Saved)
    if (-not $Saved) { return }
    if ($Saved.command -and -not [string]::IsNullOrWhiteSpace([string]$Saved.command)) {
        $script:settings.command = [string]$Saved.command
    }
    if ($Saved.interval -ge 15 -and $Saved.interval -le 3600) {
        $script:settings.interval = [int]$Saved.interval
    }
    if ($Saved.type -in @('ondemand', 'reserved', 'interruptible')) {
        $script:settings.type = [string]$Saved.type
    }
    if ($Saved.filters) {
        $savedFilters = ConvertTo-HashtableDeep $Saved.filters
        foreach ($key in @($script:defaultFilters.Keys)) {
            $f = $savedFilters[$key]
            if ($f -and $null -ne $f['min'] -and $null -ne $f['max']) {
                $min = [double]$f['min']
                $max = [double]$f['max']
                if ($min -le $max -and $min -ge 0) {
                    $script:settings.filters[$key] = @{ min = $min; max = $max }
                }
            }
        }
    }
}

try {
    if (Test-Path $script:settingsPath) {
        $saved = Get-Content -Raw -Path $script:settingsPath | ConvertFrom-Json
        Update-SettingsFromJson $saved
    }
}
catch {
    Write-Warning ("Could not load saved settings ({0}); defaults will be used." -f $_.Exception.Message)
}

function Save-Settings {
    try {
        $script:settings | ConvertTo-Json -Depth 10 | Set-Content -Path $script:settingsPath -Encoding UTF8
    }
    catch {
        Write-Warning ("Could not save settings: {0}" -f $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# Offer search / monitor iteration
# ---------------------------------------------------------------------------
function Normalize-Filters {
    param($Posted)
    $result = @{}
    foreach ($key in @($script:defaultFilters.Keys)) {
        $done = $false
        if ($Posted -is [System.Collections.IDictionary] -and $Posted.ContainsKey($key)) {
            $value = $Posted[$key]
            if ($value -is [System.Collections.IDictionary] -and $value.ContainsKey('min') -and $value.ContainsKey('max')) {
                try {
                    $min = [double]$value['min']
                    $max = [double]$value['max']
                    if ($min -ge 0 -and $max -ge $min) {
                        $result[$key] = @{ min = $min; max = $max }
                        $done = $true
                    }
                }
                catch {}
            }
        }
        if (-not $done) {
            $result[$key] = @{ min = $script:defaultFilters[$key].min; max = $script:defaultFilters[$key].max }
        }
    }
    return $result
}
function New-SearchBody {
    param([hashtable]$Filters, [string]$Type)

    $diskMin = [double]$Filters['disk_space']['min']
    $diskMax = [double]$Filters['disk_space']['max']

    $body = @{
        limit             = 1000
        type              = $Type
        rentable          = @{ eq = $true }
        rented            = @{ eq = $false }
        gpu_arch          = @{ eq = 'nvidia' }
        gpu_mem_bw        = @{ gte = [double]$Filters['gpu_mem_bw']['min']; lte = [double]$Filters['gpu_mem_bw']['max'] }
        gpu_total_ram     = @{
            gte = [int][math]::Round([double]$Filters['gpu_total_ram']['min'] * 1024)
            lte = [int][math]::Round([double]$Filters['gpu_total_ram']['max'] * 1024)
        }
        disk_space        = @{ gte = $diskMin; lte = $diskMax }
        allocated_storage = $diskMin
        direct_port_count = @{
            gte = [int][math]::Round([double]$Filters['direct_port_count']['min'])
            lte = [int][math]::Round([double]$Filters['direct_port_count']['max'])
        }
        reliability       = @{
            gte = [double]$Filters['reliability']['min'] / 100
            lte = [double]$Filters['reliability']['max'] / 100
        }
        cpu_ram           = @{
            gte = [int][math]::Round([double]$Filters['cpu_ram']['min'] * 1024)
            lte = [int][math]::Round([double]$Filters['cpu_ram']['max'] * 1024)
        }
        dph_total         = @{ gte = [double]$Filters['dph_total']['min']; lte = [double]$Filters['dph_total']['max'] }
        cuda_max_good     = @{ gte = [double]$Filters['cuda_max_good']['min']; lte = [double]$Filters['cuda_max_good']['max'] }
        inet_down_cost    = @{ gte = [double]$Filters['inet_down_cost']['min']; lte = [double]$Filters['inet_down_cost']['max'] }
        inet_up_cost      = @{ gte = [double]$Filters['inet_up_cost']['min']; lte = [double]$Filters['inet_up_cost']['max'] }
        inet_down         = @{ gte = [double]$Filters['inet_down']['min']; lte = [double]$Filters['inet_down']['max'] }
        inet_up           = @{ gte = [double]$Filters['inet_up']['min']; lte = [double]$Filters['inet_up']['max'] }
        # Duration: seconds the offer must stay available; only a lower bound is meaningful.
        duration          = @{ gte = [double]$Filters['duration']['min'] }
    }

    return $body | ConvertTo-Json -Depth 10
}

function Invoke-OfferSearch {
    param([hashtable]$Filters, [string]$Type)
    $body = New-SearchBody -Filters $Filters -Type $Type
    $response = Invoke-VastApi -Method Post -Uri "$script:baseUri/bundles/" -Body $body
    return @($response.offers)
}

$script:hasPrevIds = $false
$script:prevIds = @{}

function Invoke-OfferRent {
    param([string]$OfferId, [string]$GpuLabel, [hashtable]$Filters, [string]$Command)

    $result = @{ ran = $false; ranOk = $false; error = $null; logText = '' }

    if ([string]::IsNullOrWhiteSpace($Command)) {
        $result.error = 'RUN CLI command is empty.'
        Add-Log $result.error
        $result.logText = ((Get-LogTail) -join "`n")
        return $result
    }
    if (-not $Command.Contains('<OFFER_ID>')) {
        $result.error = 'RUN CLI command must contain the <OFFER_ID> placeholder.'
        Add-Log $result.error
        $result.logText = ((Get-LogTail) -join "`n")
        return $result
    }

    $commandText = $Command.Replace('<OFFER_ID>', $OfferId)
    $diskGb = [int][math]::Round([double]$Filters['disk_space']['min'])
    $commandText = $commandText.Replace('<DISK_GB>', [string]$diskGb)

    foreach ($tokenName in @('HF_TOKEN', 'CIVITAI_TOKEN')) {
        $placeholder = "<$tokenName>"
        if ($commandText.Contains($placeholder)) {
            $tokenValue = [Environment]::GetEnvironmentVariable($tokenName, 'Process')
            if ([string]::IsNullOrWhiteSpace($tokenValue)) {
                $tokenValue = [Environment]::GetEnvironmentVariable($tokenName, 'User')
            }
            if ([string]::IsNullOrWhiteSpace($tokenValue)) {
                $result.error = "$tokenName is not set. Set it as a Windows user environment variable or replace its placeholder in the RUN CLI command."
                Add-Log $result.error
                $result.logText = ((Get-LogTail) -join "`n")
                return $result
            }
            $commandText = $commandText.Replace($placeholder, $tokenValue)
        }
    }

    Add-Log ("Renting offer {0} ({1}) via RUN CLI command." -f $OfferId, $GpuLabel)
    $result.ran = $true

    # The stored CLI API key lacks 2FA privileges (accounts with 2FA get 401 on
    # privileged actions, and vastai 1.11.0 swallows that error and exits 0),
    # while the script's TOTP session key has full rights. Inject it per-call
    # without touching the CLI's saved key.
    if ($commandText -match '(?i)^vastai(\.exe)?\s') {
        if ($script:sessionKey) {
            $commandText = $commandText -replace '^(vastai(\.exe)?)\s', ('$1 --api-key ' + $script:sessionKey + ' ')
        }
        else {
            Add-Log 'WARNING: no active Vast session; the CLI key may lack 2FA privileges for renting.'
        }
    }

    try {
        # PS 5.1 does not escape embedded double quotes when passing arguments to
        # native executables, which splits the --env value at the first quote and
        # makes the CLI print a usage error. Pre-escape so quotes survive intact.
        $nativeCommand = $commandText.Replace('"', '\"')
        $previousEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = Invoke-Expression $nativeCommand 2>&1
        }
        finally {
            $ErrorActionPreference = $previousEap
        }
        $lines = @($output | ForEach-Object { "$_" }) | Where-Object { $_.Trim() }
        $shown = [Math]::Min($lines.Count, 40)
        for ($i = 0; $i -lt $shown; $i++) { Add-Log ("  " + $lines[$i]) }
        if ($lines.Count -gt $shown) { Add-Log ("  ... {0} more lines suppressed." -f ($lines.Count - $shown)) }
        if ($LASTEXITCODE -ne 0) {
            $result.error = "Configured CLI command exited with code $LASTEXITCODE."
            Add-Log $result.error
        }
        else {
            $result.ranOk = $true
            Add-Log "CLI command completed for offer $OfferId. Instance rented."
        }
    }
    catch {
        $result.error = "CLI rental failed for offer {0}: {1}" -f $OfferId, $_.Exception.Message
        Add-Log $result.error
    }

    $result.logText = ((Get-LogTail) -join "`n")
    return $result
}

function Invoke-MonitorIteration {
    param([hashtable]$Filters, [string]$Type, [string]$Command)

    $offers = Invoke-OfferSearch -Filters $Filters -Type $Type
    Add-Log ("Search: {0} matching unoccupied offers." -f $offers.Count)

    $result = @{
        found    = ($offers.Count -gt 0)
        ran      = $false
        ranOk    = $false
        count    = $offers.Count
        cheapest = $null
        error    = $null
        logText  = ''
    }

    $currentIds = @{}
    foreach ($offer in $offers) { $currentIds[[string]$offer.id] = $true }
    if ($script:hasPrevIds) {
        foreach ($id in $currentIds.Keys) {
            if (-not $script:prevIds.ContainsKey($id)) {
                $o = $offers | Where-Object { [string]$_.id -eq $id } | Select-Object -First 1
                Add-Log ("NEW AVAILABLE: id={0} gpu={1} price=`${2:N3}/h" -f $id, $o.gpu_name, [double]$o.dph_total)
            }
        }
        foreach ($id in @($script:prevIds.Keys)) {
            if (-not $currentIds.ContainsKey($id)) {
                Add-Log ("NO LONGER AVAILABLE: id={0}" -f $id)
            }
        }
    }
    $script:prevIds = $currentIds
    $script:hasPrevIds = $true

    if ($offers.Count -eq 0) {
        $result.logText = ((Get-LogTail) -join "`n")
        return $result
    }

    $cheapest = $offers | Sort-Object { [double]$_.dph_total } | Select-Object -First 1
    $result.cheapest = @{
        id    = [string]$cheapest.id
        gpu   = [string]$cheapest.gpu_name
        price = [math]::Round([double]$cheapest.dph_total, 3)
        disk  = [math]::Round([double]$cheapest.disk_space, 0)
    }
    Add-Log ("Cheapest match: offer={0}, GPU={1}, price=`${2:N3}/h, available disk={3:N0}GB" -f `
        $cheapest.id, $cheapest.gpu_name, [double]$cheapest.dph_total, [double]$cheapest.disk_space)

    $rent = Invoke-OfferRent -OfferId ([string]$cheapest.id) -GpuLabel ("GPU={0}, price=`${1:N3}/h" -f $cheapest.gpu_name, [double]$cheapest.dph_total) -Filters $Filters -Command $Command
    $result.ran = $rent.ran
    $result.ranOk = $rent.ranOk
    $result.error = $rent.error
    $result.logText = ((Get-LogTail) -join "`n")
    return $result
}

function Invoke-PreviewSearch {
    param([hashtable]$Filters, [string]$Type)

    $offers = Invoke-OfferSearch -Filters $Filters -Type $Type
    Add-Log ("Preview: {0} matching unoccupied offers." -f $offers.Count)

    $top = @($offers | Sort-Object { [double]$_.dph_total } | Select-Object -First 12 | ForEach-Object {
        @{
            id    = [string]$_.id
            gpu   = [string]$_.gpu_name
            gpus  = [int]$_.num_gpus
            price = [math]::Round([double]$_.dph_total, 3)
            rel   = [math]::Round([double]$_.reliability * 100, 1)
            vram  = [math]::Round([double]$_.gpu_total_ram / 1024, 1)
            bw    = [math]::Round([double]$_.gpu_mem_bw, 1)
            cpu   = [math]::Round([double]$_.cpu_ram / 1024, 1)
            disk  = [math]::Round([double]$_.disk_space, 0)
            netdown = [math]::Round([double]$_.inet_down, 0)
            netup   = [math]::Round([double]$_.inet_up, 0)
        }
    })

    return @{ count = $offers.Count; offers = $top; logText = ((Get-LogTail) -join "`n") }
}

# ---------------------------------------------------------------------------
# Web UI (single page, no external assets; __TOKEN__ is replaced at serve time)
# ---------------------------------------------------------------------------
$script:htmlTemplate = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Vast.ai offer monitor</title>
<style>
  * { box-sizing: border-box; }
  body { margin:0; font-family: system-ui, 'Segoe UI', sans-serif; background:#f5f6f8; color:#1a1d21; font-size:14px; }
  main { max-width: 1020px; margin: 0 auto; padding: 14px 16px 40px; }
  header { background:#fff; border-bottom:1px solid #e3e6ea; padding:10px 16px; display:flex; align-items:center; gap:12px; }
  .logo { display:inline-flex; width:26px; height:26px; border-radius:7px; background:#2f6fed; color:#fff; align-items:center; justify-content:center; font-weight:700; }
  .brand { font-weight:650; font-size:15px; display:flex; align-items:center; gap:8px; }
  .badge { font-size:11.5px; font-weight:600; border-radius:999px; padding:3px 10px; }
  .badge.ok { background:#e6f4ec; color:#166b3f; }
  .badge.bad { background:#fdecec; color:#b02a2a; }
  .hint { font-size:12px; color:#8a929c; margin-left:auto; }
  .panel { background:#fff; border:1px solid #e3e6ea; border-radius:12px; padding:14px 16px; margin-bottom:14px; }
  .panel-head { display:flex; align-items:baseline; gap:10px; margin-bottom:10px; }
  .panel-head h2 { font-size:14.5px; margin:0; font-weight:650; }
  .link { background:none; border:none; color:#2f6fed; cursor:pointer; font-size:12.5px; padding:2px 4px; margin-left:auto; }
  .link:hover { text-decoration:underline; }
  .muted { color:#8a929c; font-size:12.5px; font-weight:400; }
  .chips { display:flex; flex-wrap:wrap; gap:6px; margin-bottom:10px; min-height:22px; }
  .chip { display:inline-flex; align-items:center; gap:6px; background:#e6f4ec; color:#166b3f; border:1px solid #bfe3cd; border-radius:999px; padding:3px 8px 3px 10px; font-size:12.5px; }
  .chip button { background:none; border:none; color:#166b3f; cursor:pointer; font-size:12px; padding:0 1px; font-weight:700; opacity:.75; }
  .chip button:hover { opacity:1; }
  .fgrid { display:grid; grid-template-columns:1fr 1fr; gap:4px 30px; }
  @media (max-width: 760px) { .fgrid { grid-template-columns:1fr; } }
  .f-head { font-size:12.5px; font-weight:600; color:#3c4148; margin:6px 0 6px; }
  .f-io { display:flex; justify-content:space-between; margin-bottom:6px; }
  .f-box { display:inline-flex; align-items:center; border:1px solid #d4d9df; border-radius:8px; padding:4px 9px; background:#fff; width:158px; }
  .f-box input { border:none; outline:none; width:100%; font-size:13px; background:transparent; font-family:inherit; padding:0; }
  .f-unit { font-size:10.5px; color:#8a929c; white-space:nowrap; margin-left:5px; }
  .s-track { position:relative; height:26px; cursor:pointer; touch-action:none; }
  .s-track::before { content:''; position:absolute; left:0; right:0; top:11px; height:4px; background:#e1e5ea; border-radius:2px; }
  .s-fill { position:absolute; top:11px; height:4px; background:#3d7bff; border-radius:2px; }
  .s-h { position:absolute; top:5px; width:15px; height:15px; background:#fff; border:2px solid #3d7bff; border-radius:50%; transform:translateX(-50%); cursor:grab; }
  .s-h:focus-visible { outline:2px solid #9db9ff; outline-offset:2px; }
  .mrow { display:flex; gap:28px; margin-top:14px; flex-wrap:wrap; align-items:flex-end; }
  .mset label { display:block; font-size:12.5px; font-weight:600; color:#3c4148; margin-bottom:6px; }
  .mset select { border:1px solid #d4d9df; border-radius:8px; padding:6px 8px; font-size:13px; background:#fff; }
  .iwrap { display:inline-flex; align-items:center; border:1px solid #d4d9df; border-radius:8px; padding:4px 9px; background:#fff; }
  .iwrap input { border:none; outline:none; width:64px; font-size:13px; background:transparent; }
  .iunit { font-size:10.5px; color:#8a929c; margin-left:5px; }
  #intervalR { width:240px; accent-color:#3d7bff; vertical-align:middle; margin-left:12px; }
  textarea#cmd { width:100%; min-height:150px; font:12px/1.5 Consolas, 'Courier New', monospace; border:1px solid #d4d9df; border-radius:8px; padding:10px; resize:vertical; background:#fbfcfe; white-space:pre; overflow-x:auto; }
  .note { font-size:12px; color:#8a929c; margin-top:6px; }
  .note code { background:#f0f2f5; border-radius:4px; padding:1px 5px; font-size:11.5px; }
  .actions { display:flex; align-items:center; gap:10px; margin:16px 0; flex-wrap:wrap; }
  .btn { border:1px solid #c9cfd6; background:#fff; border-radius:8px; padding:9px 16px; font-size:13.5px; cursor:pointer; font-family:inherit; }
  .btn:hover:not(:disabled) { border-color:#9aa4af; }
  .btn.primary { background:#2f6fed; border-color:#2f6fed; color:#fff; }
  .btn.primary:hover:not(:disabled) { background:#2760cf; }
  .btn:disabled { opacity:.45; cursor:default; }
  .btn-xs { border:1px solid #c9cfd6; background:#fff; border-radius:6px; padding:2px 10px; font-size:11.5px; cursor:pointer; font-family:inherit; }
  .btn-xs:hover:not(:disabled) { border-color:#2f6fed; color:#2f6fed; }
  .btn-xs:disabled { opacity:.5; cursor:default; }
  .mstate { font-size:13px; font-weight:600; color:#166b3f; }
  .mstate.wait { color:#8a929c; font-weight:400; }
  .err { color:#c92a2a; font-size:12.5px; }
  .twrap { overflow-x:auto; }
  table { width:100%; border-collapse:collapse; font-size:12.5px; }
  th { text-align:left; color:#8a929c; font-weight:600; font-size:11.5px; padding:6px 10px; border-bottom:1px solid #e3e6ea; white-space:nowrap; }
  td { padding:6px 10px; border-bottom:1px solid #f0f2f5; white-space:nowrap; }
  tr:hover td { background:#f8faff; }
  .log { background:#101318; color:#c7d0da; font:11.5px/1.55 Consolas, monospace; padding:10px 12px; border-radius:8px; max-height:280px; overflow:auto; white-space:pre-wrap; margin:0; }
  .overlay { position:fixed; inset:0; background:rgba(15,18,24,.55); display:flex; align-items:center; justify-content:center; z-index:10; }
  .overlay.hidden { display:none; }
  .card { background:#fff; border-radius:12px; padding:20px 22px; width:360px; box-shadow:0 10px 40px rgba(0,0,0,.25); }
  .card h3 { margin:0 0 8px; font-size:15.5px; }
  .card p { font-size:13px; color:#3c4148; margin:0 0 12px; }
  .card input { width:100%; border:1px solid #d4d9df; border-radius:8px; padding:9px 12px; font-size:16px; letter-spacing:3px; text-align:center; }
  .card .row { margin-top:12px; display:flex; gap:10px; align-items:center; }
</style>
</head>
<body>
<header>
  <span class="brand"><span class="logo">V</span> Vast.ai offer monitor <span id="badge" class="badge ok">…</span></span>
  <span class="hint" id="srvHint"></span>
</header>
<main>
  <section class="panel">
    <div class="panel-head"><h2>Filters</h2><button id="resetBtn" class="link">Reset</button></div>
    <div id="chips" class="chips"></div>
    <div id="filters" class="fgrid"></div>
    <div class="mrow">
      <div class="mset">
        <label>Interval</label>
        <span class="iwrap"><input id="intervalN" type="number" min="15" max="3600" step="5"><span class="iunit">sec</span></span>
        <input id="intervalR" type="range" min="15" max="3600" step="5">
      </div>
      <div class="mset">
        <label>Rental type</label>
        <select id="typeSel">
          <option value="ondemand">ondemand</option>
          <option value="reserved">reserved</option>
          <option value="interruptible">interruptible</option>
        </select>
      </div>
    </div>
  </section>

  <section class="panel">
    <div class="panel-head"><h2>RUN CLI</h2></div>
    <textarea id="cmd" spellcheck="false"></textarea>
    <div class="note">Placeholders are substituted automatically: <code>&lt;OFFER_ID&gt;</code> — offer id, <code>&lt;DISK_GB&gt;</code> — minimum disk from the filter, <code>&lt;HF_TOKEN&gt;</code>, <code>&lt;CIVITAI_TOKEN&gt;</code> — from environment variables. For <code>vastai</code> commands the script also injects the current 2FA session as <code>--api-key</code> (the plain CLI key cannot rent on 2FA accounts). Settings are saved automatically.</div>
  </section>

  <section class="actions">
    <button id="checkBtn" class="btn">Check</button>
    <button id="startBtn" class="btn primary">Start monitoring</button>
    <button id="stopBtn" class="btn" disabled>Stop</button>
    <span id="monitorState" class="mstate wait"></span>
    <span id="errorLine" class="err"></span>
  </section>

  <section class="panel">
    <div class="panel-head"><h2>Offers <span id="count" class="muted"></span></h2></div>
    <div class="twrap">
      <table>
        <thead><tr><th>ID</th><th>GPU</th><th>$/h</th><th>Rel %</th><th>VRAM GB</th><th>BW GB/s</th><th>CPU GB</th><th>Disk GB</th><th>Net Down MB/s</th><th>Net Up MB/s</th><th></th></tr></thead>
        <tbody id="offerRows"></tbody>
      </table>
    </div>
  </section>

  <section class="panel">
    <div class="panel-head"><h2>Log</h2></div>
    <pre id="log" class="log"></pre>
  </section>
</main>

<div id="authOverlay" class="overlay hidden">
  <div class="card">
    <h3>2FA code required</h3>
    <p>The Vast.ai session is invalid. Enter the current code from your authenticator app — the new session will be saved to your Windows profile.</p>
    <input id="totp" inputmode="numeric" autocomplete="one-time-code" maxlength="8" placeholder="000000">
    <div class="row">
      <button id="totpBtn" class="btn primary">Sign in</button>
      <button id="totpCancel" class="btn">Later</button>
      <span id="totpErr" class="err"></span>
    </div>
  </div>
</div>

<noscript>JavaScript is required.</noscript>
<script>
'use strict';
const TOKEN = '__TOKEN__';
const CFG = [
  { k:'gpu_mem_bw',        label:'GPU Mem BW',  unit:'GB/s', min:0,    max:2000,  step:1,      dec:0, chip:'GPU Mem BW' },
  { k:'gpu_total_ram',     label:'GPU RAM',     unit:'GB',   min:0,    max:256,   step:0.1,    dec:1, chip:'GPU RAM' },
  { k:'disk_space',        label:'Disk Size',   unit:'GB',   min:1,    max:8192,  step:1,      dec:0, chip:'Disk Size' },
  { k:'direct_port_count', label:'Open Ports',  unit:'',     min:0,    max:64,    step:1,      dec:0, chip:'Open Ports' },
  { k:'reliability',       label:'Reliability', unit:'%',    min:0,    max:100,   step:0.1,    dec:1, chip:'Reliability' },
  { k:'cpu_ram',           label:'CPU RAM',     unit:'GB',   min:0,    max:512,   step:0.1,    dec:1, chip:'CPU RAM' },
  { k:'dph_total',         label:'Hourly Price',unit:'$/h',  min:0,    max:10,    step:0.01,   dec:3, chip:'Hourly Price', prefix:'$' },
  { k:'cuda_max_good',     label:'CUDA',        unit:'',     min:11,   max:14,    step:0.1,    dec:1, chip:'CUDA' },
  { k:'inet_down_cost',    label:'Download Cost',unit:'$/TB',min:0,    max:0.05,  step:0.0001, dec:2, chip:'Download Cost', prefix:'$', disp:1000 },
  { k:'inet_up_cost',      label:'Upload Cost', unit:'$/TB', min:0,    max:0.05,  step:0.0001, dec:2, chip:'Upload Cost', prefix:'$', disp:1000 },
  { k:'inet_down',         label:'Internet Down Speed',  unit:'MB/s', min:0, max:10000, step:10, dec:0, chip:'Internet Down' },
  { k:'inet_up',           label:'Internet Up Speed',    unit:'MB/s', min:0, max:10000, step:10, dec:0, chip:'Internet Up' },
  { k:'duration',          label:'Max Instance Duration', unit:'h',   min:0, max:2592000, step:3600, dec:0, disp:1/3600, chip:'Duration', minOnly:true }
];
const $ = id => document.getElementById(id);
const chipsEl = $('chips'), filtersEl = $('filters'), cmdEl = $('cmd'), typeSel = $('typeSel'),
      intervalN = $('intervalN'), intervalR = $('intervalR'), logEl = $('log'), badgeEl = $('badge'),
      errorLine = $('errorLine'), monitorState = $('monitorState'), countEl = $('count'),
      checkBtn = $('checkBtn'), startBtn = $('startBtn'), stopBtn = $('stopBtn'),
      overlay = $('authOverlay'), totp = $('totp'), totpErr = $('totpErr');

let authOk = false, vals = {}, filterUI = {};
let monitoring = false, timer = null, inFlight = false;

function esc(s) { const d = document.createElement('div'); d.textContent = String(s); return d.innerHTML.replace(/"/g, '&quot;'); }
function fmtN(v, c, withPrefix) { const d = v * (c.disp || 1); return (withPrefix && c.prefix ? c.prefix : '') + d.toFixed(c.dec); }
function clampV(c, v) { return Math.min(c.max, Math.max(c.min, +v || c.min)); }

async function api(path, body) {
  const res = await fetch('/api/' + path, {
    method: body ? 'POST' : 'GET',
    headers: { 'Content-Type': 'application/json', 'X-Auth': TOKEN },
    body: body ? JSON.stringify(body) : undefined
  });
  let data = {};
  try { data = await res.json(); } catch (e) { data = { error: 'Bad response' }; }
  if (!res.ok) {
    const err = new Error(data.error || ('HTTP ' + res.status));
    err.status = res.status; err.logText = data.logText;
    throw err;
  }
  return data;
}

// ---------------------------------------------------------------- sliders
function makeDual(c) {
  const root = document.createElement('div');
  root.className = 'filter';
  root.innerHTML =
    '<div class="f-head">' + esc(c.label) + '</div>' +
    '<div class="f-io">' +
      '<span class="f-box"><input class="f-min" inputmode="decimal"><span class="f-unit">' + esc(c.unit) + '</span></span>' +
      '<span class="f-box"><input class="f-max" inputmode="decimal"><span class="f-unit">' + esc(c.unit) + '</span></span>' +
    '</div>' +
    '<div class="s-track"><div class="s-fill"></div><div class="s-h" tabindex="0"></div><div class="s-h" tabindex="0"></div></div>';
  const track = root.querySelector('.s-track'), fill = root.querySelector('.s-fill'),
        handles = root.querySelectorAll('.s-h'),
        iMin = root.querySelector('.f-min'), iMax = root.querySelector('.f-max');
  if (c.minOnly) {
    handles[1].style.display = 'none';
    root.querySelectorAll('.f-box')[1].style.display = 'none';
  }
  const snap = v => {
    v = Math.round((v - c.min) / c.step) * c.step + c.min;
    return +Math.min(c.max, Math.max(c.min, v)).toFixed(6);
  };
  const pos2val = e => {
    const r = track.getBoundingClientRect();
    const t = Math.min(1, Math.max(0, (e.clientX - r.left) / r.width));
    return c.min + t * (c.max - c.min);
  };
  let drag = null;
  const get = () => vals[c.k];
  function render() {
    const [a, b] = get();
    const p = v => (v - c.min) / (c.max - c.min) * 100;
    fill.style.left = p(a) + '%';
    fill.style.width = (c.minOnly ? 100 - p(a) : p(b) - p(a)) + '%';
    handles[0].style.left = p(a) + '%';
    handles[1].style.left = p(b) + '%';
    iMin.value = fmtN(a, c);
    iMax.value = fmtN(b, c);
  }
  function move(e) {
    if (!drag) return;
    const v = snap(pos2val(e));
    let [a, b] = get();
    if (drag === 'l' && v > b) { vals[c.k] = [b, v]; drag = 'r'; }
    else if (drag === 'r' && v < a) { vals[c.k] = [v, a]; drag = 'l'; }
    else if (drag === 'l') vals[c.k] = [v, b];
    else vals[c.k] = [a, v];
    render(); renderChips(); onFilterChange();
    if (e.cancelable) e.preventDefault();
  }
  track.addEventListener('pointerdown', e => {
    const [a, b] = get(); const v = pos2val(e);
    drag = c.minOnly ? 'l' : (Math.abs(v - a) <= Math.abs(v - b) ? 'l' : 'r');
    track.setPointerCapture(e.pointerId);
    move(e);
  });
  handles[0].addEventListener('pointerdown', e => { e.stopPropagation(); drag = 'l'; track.setPointerCapture(e.pointerId); });
  handles[1].addEventListener('pointerdown', e => { e.stopPropagation(); drag = 'r'; track.setPointerCapture(e.pointerId); });
  track.addEventListener('pointermove', move);
  track.addEventListener('pointerup', () => drag = null);
  track.addEventListener('pointercancel', () => drag = null);
  function onKey(e, which) {
    const st = c.step * (e.shiftKey ? 10 : 1);
    let [a, b] = get();
    if (e.key === 'ArrowLeft' || e.key === 'ArrowDown') {
      if (which === 'l') vals[c.k] = [Math.max(snap(a - st), c.min), b]; else vals[c.k] = [a, Math.max(snap(b - st), a)];
    } else if (e.key === 'ArrowRight' || e.key === 'ArrowUp') {
      if (which === 'l') vals[c.k] = [Math.min(snap(a + st), b), b]; else vals[c.k] = [a, Math.min(snap(b + st), c.max)];
    } else return;
    render(); renderChips(); onFilterChange();
    e.preventDefault();
  }
  handles[0].addEventListener('keydown', e => onKey(e, 'l'));
  handles[1].addEventListener('keydown', e => onKey(e, 'r'));
  iMin.addEventListener('change', () => {
    const v = snap(parseFloat(String(iMin.value).replace(',', '.')) / (c.disp || 1));
    if (isNaN(v)) { render(); return; }
    const [a, b] = get();
    vals[c.k] = [Math.min(v, b), b];
    render(); renderChips(); onFilterChange();
  });
  iMax.addEventListener('change', () => {
    const v = snap(parseFloat(String(iMax.value).replace(',', '.')) / (c.disp || 1));
    if (isNaN(v)) { render(); return; }
    const [a, b] = get();
    vals[c.k] = [a, Math.max(v, a)];
    render(); renderChips(); onFilterChange();
  });
  render();
  return { root, render };
}

function renderChips() {
  chipsEl.innerHTML = '';
  let any = false;
  CFG.forEach(c => {
    const [a, b] = vals[c.k];
    const eps = 1e-9;
    if (a > c.min + eps && b < c.max - eps) any = addChip(c, fmtN(a, c, true) + ' – ' + fmtN(b, c, true)) || true;
    else if (a > c.min + eps) any = addChip(c, fmtN(a, c, true), ' Min') || true;
    else if (b < c.max - eps) any = addChip(c, fmtN(b, c, true), ' Max') || true;
  });
  if (!any) chipsEl.innerHTML = '<span class="muted">No active filters — searching all offers</span>';
}
function addChip(c, text, side) {
  const chip = document.createElement('span');
  chip.className = 'chip';
  chip.innerHTML = esc(c.chip + (side || '') + ': ' + text + (c.unit && !c.prefix ? ' ' + c.unit : '')) + ' <button title="Remove filter">✕</button>';
  chip.querySelector('button').addEventListener('click', () => {
    vals[c.k] = [c.min, c.max];
    filterUI[c.k].render(); renderChips(); onFilterChange();
  });
  chipsEl.appendChild(chip);
  return true;
}

// ---------------------------------------------------------------- settings sync
function packFilters() {
  const out = {};
  CFG.forEach(c => { out[c.k] = { min: vals[c.k][0], max: vals[c.k][1] }; });
  return out;
}
function intervalVal() { return Math.min(3600, Math.max(15, parseInt(intervalN.value, 10) || 60)); }
let saveT = null, searchT = null;
function queueSave() {
  clearTimeout(saveT);
  saveT = setTimeout(() => {
    api('save', { filters: packFilters(), type: typeSel.value, command: cmdEl.value, interval: intervalVal() }).catch(() => {});
  }, 700);
}
function onFilterChange() {
  queueSave();
  if (!monitoring && authOk) {
    clearTimeout(searchT);
    searchT = setTimeout(() => doSearch(), 700);
  }
}

// ---------------------------------------------------------------- offers / log
function renderOffers(r) {
  countEl.textContent = '(' + r.count + ')';
  const tbody = $('offerRows');
  tbody.innerHTML = '';
  (r.offers || []).forEach(o => {
    const tr = document.createElement('tr');
    tr.innerHTML = '<td>' + esc(o.id) + '</td><td>' + esc(o.gpu) + (o.gpus > 1 ? ' ×' + o.gpus : '') + '</td><td>$' + esc(o.price) +
      '</td><td>' + esc(o.rel) + '</td><td>' + esc(o.vram) + '</td><td>' + esc(o.bw) + '</td><td>' + esc(o.cpu) + '</td><td>' + esc(o.disk) +
      '</td><td>' + esc(o.netdown) + '</td><td>' + esc(o.netup) +
      '</td><td><button class="btn-xs rent-btn" data-id="' + esc(o.id) + '" data-gpu="' + esc(o.gpu) + '">Rent</button></td>';
    tbody.appendChild(tr);
  });
  if (!r.offers || !r.offers.length) {
    tbody.innerHTML = '<tr><td colspan="11" class="muted">No matches</td></tr>';
  }
}
function applyLog(lines) {
  if (typeof lines === 'string') lines = lines ? lines.split('\n') : [];
  else if (!Array.isArray(lines)) lines = lines == null ? [] : [String(lines)];
  logEl.textContent = lines.join('\n');
  logEl.scrollTop = logEl.scrollHeight;
}
function addLocalLine(text) {
  const d = new Date();
  logEl.textContent += '\n[' + d.toTimeString().slice(0, 8) + '] ' + text;
  logEl.scrollTop = logEl.scrollHeight;
}
function showError(text) { errorLine.textContent = text || ''; }

// ---------------------------------------------------------------- search / monitor
async function doSearch() {
  if (!authOk) { showAuth(); return; }
  checkBtn.disabled = true;
  showError('');
  try {
    const r = await api('search', { filters: packFilters(), type: typeSel.value });
    renderOffers(r);
    applyLog(r.logText);
  } catch (e) { handleApiError(e); }
  finally { checkBtn.disabled = false; }
}
function updateMonitorUI() {
  startBtn.disabled = monitoring;
  stopBtn.disabled = !monitoring;
  monitorState.className = monitoring ? 'mstate' : 'mstate wait';
  if (!monitoring && !monitorState.dataset.done) monitorState.textContent = '';
}
function stopMonitor() {
  monitoring = false;
  clearTimeout(timer);
  updateMonitorUI();
}
function scheduleNext() {
  clearTimeout(timer);
  timer = setTimeout(tick, intervalVal() * 1000);
}
function startMonitor() {
  if (!authOk) { showAuth(); return; }
  if (!cmdEl.value.includes('<OFFER_ID>')) { showError('Command must contain the <OFFER_ID> placeholder.'); return; }
  monitoring = true;
  delete monitorState.dataset.done;
  monitorState.textContent = 'Starting…';
  updateMonitorUI();
  showError('');
  addLocalLine('Monitoring started, interval ' + intervalVal() + ' s.');
  tick();
}
async function tick() {
  if (!monitoring || inFlight) return;
  inFlight = true;
  try {
    const r = await api('iterate', { filters: packFilters(), type: typeSel.value, command: cmdEl.value });
    applyLog(r.logText);
    if (r.error) {
      stopMonitor();
      showError(r.error);
    } else if (r.ran && r.ranOk) {
      stopMonitor();
      monitorState.dataset.done = '1';
      monitorState.textContent = 'Rented offer ' + r.cheapest.id + ' ($' + r.cheapest.price + '/h)';
    } else if (r.ran) {
      stopMonitor();
    } else {
      monitorState.textContent = 'No matches (' + r.count + '), waiting…';
      scheduleNext();
    }
  } catch (e) {
    handleApiError(e);
    if (monitoring && e.status !== 401) scheduleNext();
  } finally { inFlight = false; }
}
function handleApiError(e) {
  if (e.status === 401) {
    authOk = false;
    updateBadge();
    stopMonitor();
    showAuth();
  } else {
    showError(e.message);
    if (e.logText) applyLog(e.logText);
  }
}

// ---------------------------------------------------------------- auth
function showAuth() {
  overlay.classList.remove('hidden');
  totpErr.textContent = '';
  setTimeout(() => totp.focus(), 50);
}
function updateBadge() {
  if (authOk) { badgeEl.textContent = 'session OK'; badgeEl.className = 'badge ok'; }
  else { badgeEl.textContent = '2FA required'; badgeEl.className = 'badge bad'; }
}
async function submitTotp() {
  totpErr.textContent = '';
  try {
    await api('totp', { code: totp.value.trim() });
    totp.value = '';
    overlay.classList.add('hidden');
    const s = await api('state');
    authOk = s.authOk;
    updateBadge();
    doSearch();
  } catch (e) {
    totpErr.textContent = e.message;
  }
}
$('totpBtn').addEventListener('click', submitTotp);
totp.addEventListener('keydown', e => { if (e.key === 'Enter') submitTotp(); });
$('totpCancel').addEventListener('click', () => overlay.classList.add('hidden'));

// ---------------------------------------------------------------- wiring
checkBtn.addEventListener('click', doSearch);
startBtn.addEventListener('click', startMonitor);
stopBtn.addEventListener('click', () => { stopMonitor(); addLocalLine('Monitoring stopped.'); });
$('offerRows').addEventListener('click', async e => {
  const btn = e.target.closest('button.rent-btn');
  if (!btn || inFlight) return;
  inFlight = true;
  btn.disabled = true;
  btn.textContent = 'Renting…';
  showError('');
  try {
    const r = await api('rent', { id: btn.dataset.id, gpu: btn.dataset.gpu, command: cmdEl.value });
    applyLog(r.logText);
    if (r.ran && r.ranOk) addLocalLine('Rented offer ' + btn.dataset.id + '.');
    else if (r.error) showError(r.error);
  } catch (err) { handleApiError(err); }
  finally { inFlight = false; btn.disabled = false; btn.textContent = 'Rent'; }
});
$('resetBtn').addEventListener('click', () => {
  CFG.forEach(c => { vals[c.k] = [c.min, c.max]; filterUI[c.k].render(); });
  renderChips(); onFilterChange();
});
cmdEl.addEventListener('input', queueSave);
typeSel.addEventListener('change', () => { queueSave(); if (!monitoring && authOk) doSearch(); });
intervalN.addEventListener('change', () => { intervalR.value = intervalVal(); queueSave(); });
intervalR.addEventListener('input', () => { intervalN.value = intervalR.value; queueSave(); });

(async function init() {
  let S;
  try { S = await api('state'); }
  catch (e) {
    document.querySelector('main').innerHTML = '<p class="err">Server unavailable: ' + esc(e.message) + '</p>';
    return;
  }
  authOk = S.authOk;
  if (!S.cliFound) $('srvHint').textContent = 'vastai CLI not found in PATH — renting will fail';
  CFG.forEach(c => {
    const f = (S.settings.filters || {})[c.k];
    if (f) vals[c.k] = [clampV(c, f.min), clampV(c, f.max)];
    else vals[c.k] = [c.min, c.max];
  });
  cmdEl.value = S.settings.command || '';
  typeSel.value = S.settings.type || 'ondemand';
  intervalN.value = S.settings.interval || 60;
  intervalR.value = intervalVal();
  CFG.forEach(c => { filterUI[c.k] = makeDual(c); filtersEl.appendChild(filterUI[c.k].root); });
  renderChips();
  updateBadge();
  applyLog(S.logText);
  if (!authOk) showAuth();
  else doSearch();
})();
</script>
</body>
</html>
'@

# ---------------------------------------------------------------------------
# Startup: validate saved session, check CLI, start listener
# ---------------------------------------------------------------------------
$host.UI.RawUI.WindowTitle = 'Vast offer monitor'

$sessionKey = $env:VAST_API_SESSION_KEY
if ([string]::IsNullOrWhiteSpace($sessionKey)) {
    $sessionKey = [Environment]::GetEnvironmentVariable('VAST_API_SESSION_KEY', 'User')
}
if ([string]::IsNullOrWhiteSpace($sessionKey)) {
    Add-Log 'No saved Vast session; enter a TOTP code in the web UI.'
}
else {
    $script:sessionKey = $sessionKey
    $script:headers = @{ Authorization = "Bearer $script:sessionKey" }
    try {
        $null = Invoke-VastApi -Method Get -Uri "$script:baseUri/users/current/"
        $script:authOk = $true
        $script:needsAuth = $false
        Add-Log 'Saved Vast session is valid.'
    }
    catch {
        Write-Warning 'Saved Vast session is not valid; enter a fresh TOTP code in the web UI.'
    }
}

$script:cliFound = [bool](Get-Command vastai -ErrorAction SilentlyContinue)
if (-not $script:cliFound) {
    Write-Warning 'vastai CLI was not found in PATH; preview and monitoring work, renting will fail.'
}

$script:token = [guid]::NewGuid().ToString('N')

$listener = $null
$tryPort = $Port
while ($null -eq $listener -and $tryPort -lt ($Port + 20)) {
    try {
        $l = New-Object System.Net.HttpListener
        $l.Prefixes.Add("http://localhost:$tryPort/")
        $l.Start()
        $listener = $l
    }
    catch {
        $tryPort++
    }
}
if (-not $listener) {
    throw "Could not bind a local HTTP port in range $Port..$($Port + 19). Close the other instance or free the ports."
}
$Port = $tryPort
Add-Log "Monitoring UI: http://localhost:$Port/  (Ctrl+C to stop)"

if (-not $NoBrowser) {
    Start-Process "http://localhost:$Port/"
}

function Send-Json {
    param($Context, $Object, [int]$Status = 200)
    $json = $Object | ConvertTo-Json -Depth 12
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = $Status
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Send-Html {
    param($Context, $Html)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Html)
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = 'text/html; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Read-JsonBody {
    param($Context)
    $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, [System.Text.Encoding]::UTF8)
    $raw = $reader.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ConvertTo-HashtableDeep (ConvertFrom-Json $raw)
}

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
        $req = $ctx.Request
        $path = $req.Url.AbsolutePath

        if ($path -eq '/' -and $req.HttpMethod -eq 'GET') {
            Send-Html $ctx ($script:htmlTemplate.Replace('__TOKEN__', $script:token))
            continue
        }

        if (-not $path.StartsWith('/api/')) {
            Send-Json $ctx @{ error = 'Not found' } 404
            continue
        }

        $origin = $req.Headers['Origin']
        $expectedOrigin = "http://localhost:$Port"
        if ($origin -and $origin -ne $expectedOrigin) {
            Send-Json $ctx @{ error = 'Cross-origin requests are not allowed.' } 403
            continue
        }
        if ($req.Headers['X-Auth'] -ne $script:token) {
            Send-Json $ctx @{ error = 'Unauthorized UI request.' } 403
            continue
        }

        $body = $null
        if ($req.HttpMethod -eq 'POST') { $body = Read-JsonBody $ctx }

        switch ($path) {
            '/api/state' {
                Send-Json $ctx @{
                    authOk    = $script:authOk
                    needsAuth = $script:needsAuth
                    cliFound  = $script:cliFound
                    settings  = $script:settings
                    logText   = ((Get-LogTail) -join "`n")
                }
            }
            '/api/totp' {
                try {
                    Set-VastSession -Code ([string]$body['code'])
                    Send-Json $ctx @{ ok = $true; logText = ((Get-LogTail) -join "`n") }
                }
                catch {
                    Send-Json $ctx @{ ok = $false; error = $_.Exception.Message; logText = ((Get-LogTail) -join "`n") }
                }
            }
            '/api/search' {
                if ($body -and $body['filters']) { $script:settings.filters = Normalize-Filters $body['filters'] }
                if ($body -and $body['type'] -in @('ondemand', 'reserved', 'interruptible')) { $script:settings.type = [string]$body['type'] }
                Save-Settings
                $preview = Invoke-PreviewSearch -Filters $script:settings.filters -Type $script:settings.type
                Send-Json $ctx $preview
            }
            '/api/iterate' {
                if ($body -and $body['filters']) { $script:settings.filters = Normalize-Filters $body['filters'] }
                if ($body -and $body['type'] -in @('ondemand', 'reserved', 'interruptible')) { $script:settings.type = [string]$body['type'] }
                if ($body -and $body['command']) { $script:settings.command = [string]$body['command'] }
                Save-Settings
                $iteration = Invoke-MonitorIteration -Filters $script:settings.filters -Type $script:settings.type -Command $script:settings.command
                Send-Json $ctx $iteration
            }
            '/api/rent' {
                $offerId = [string]$body['id']
                if ([string]::IsNullOrWhiteSpace($offerId)) {
                    Send-Json $ctx @{ error = 'Offer id is required.'; logText = ((Get-LogTail) -join "`n") }
                }
                else {
                    if ($body['command']) { $script:settings.command = [string]$body['command'] }
                    Save-Settings
                    $rent = Invoke-OfferRent -OfferId $offerId -GpuLabel ([string]$body['gpu']) -Filters $script:settings.filters -Command $script:settings.command
                    Send-Json $ctx $rent
                }
            }
            '/api/save' {
                if ($body) {
                    if ($body['filters']) { $script:settings.filters = Normalize-Filters $body['filters'] }
                    if ($body['type'] -in @('ondemand', 'reserved', 'interruptible')) { $script:settings.type = [string]$body['type'] }
                    if ($null -ne $body['command']) { $script:settings.command = [string]$body['command'] }
                    if ($body['interval']) {
                        $interval = [int]$body['interval']
                        if ($interval -ge 15 -and $interval -le 3600) { $script:settings.interval = $interval }
                    }
                }
                Save-Settings
                Send-Json $ctx @{ ok = $true }
            }
            default {
                Send-Json $ctx @{ error = 'Not found' } 404
            }
        }
    }
    catch {
        $message = $_.Exception.Message
        $status = 500
        if ("$message" -match $script:authFailurePattern) {
            $script:authOk = $false
            $script:needsAuth = $true
            $status = 401
        }
        try { Send-Json $ctx @{ error = "$message"; logText = ((Get-LogTail) -join "`n") } $status } catch {}
    }
}
