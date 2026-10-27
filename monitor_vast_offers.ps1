<#
.SYNOPSIS
Lets you choose one of your Vast templates, then rents the cheapest matching offer.

.DESCRIPTION
Reads VAST_API_KEY from the process or current user's environment. It reuses
VAST_API_SESSION_KEY from User environment when valid; otherwise it prompts for TOTP,
creates a fresh session, and saves it to User environment. When Vast rejects the saved
session for authentication, it prompts for TOTP again and retries once.

.PARAMETER IntervalSeconds
Delay between searches when no offers are available. Defaults to 60 seconds.

.PARAMETER Preview
List matching offers once after template selection, without renting an instance.

.EXAMPLE
.\monitor_vast_offers.ps1

.EXAMPLE
.\monitor_vast_offers.ps1 -IntervalSeconds 30 -Preview
#>
[CmdletBinding()]
param(
    [ValidateRange(15, 3600)]
    [int]$IntervalSeconds = 60,

    [switch]$Preview
)

$ErrorActionPreference = 'Stop'
$script:baseUri = 'https://console.vast.ai/api/v0'
$script:authFailurePattern = '(?i)(auth_error|authorization error|requires login|two.factor|two factor|logged in using|invalid user key)'

$script:apiKey = $env:VAST_API_KEY
if ([string]::IsNullOrWhiteSpace($script:apiKey)) {
    $script:apiKey = [Environment]::GetEnvironmentVariable('VAST_API_KEY', 'User')
}
if ([string]::IsNullOrWhiteSpace($script:apiKey)) {
    throw 'VAST_API_KEY is not set. Define it as a user environment variable or in this PowerShell session.'
}


function Set-VastSession {
    $code = Read-Host 'Enter the current TOTP code from your authenticator app'
    $loginBody = @{ tfa_method = 'totp'; code = $code } | ConvertTo-Json -Compress
    $login = Invoke-RestMethod -Method Post -Uri "$script:baseUri/tfa/" `
        -Headers @{ Authorization = "Bearer $script:apiKey" } `
        -ContentType 'application/json' -Body $loginBody -TimeoutSec 30
    if ([string]::IsNullOrWhiteSpace($login.session_key) -or -not $login.id) {
        throw 'Vast did not return an authenticated 2FA session. Confirm TOTP is enabled and retry.'
    }

    $script:sessionKey = $login.session_key
    $script:creatorId = [int]$login.id
    $script:headers = @{ Authorization = "Bearer $script:sessionKey" }
    $env:VAST_API_SESSION_KEY = $script:sessionKey
    $env:VAST_ACCOUNT_ID = [string]$script:creatorId
    [Environment]::SetEnvironmentVariable('VAST_API_SESSION_KEY', $script:sessionKey, 'User')
    [Environment]::SetEnvironmentVariable('VAST_ACCOUNT_ID', [string]$script:creatorId, 'User')
    Write-Host 'Fresh 2FA session saved to this Windows user profile.'
}

function Invoke-VastApi {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Body
    )

    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
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

            $result = Invoke-RestMethod @request
            $responseMessage = [string]$result.msg
            if ($result.success -eq $false -and $responseMessage -match $script:authFailurePattern) {
                throw [System.UnauthorizedAccessException]::new($responseMessage)
            }
            return $result
        }
        catch {
            $message = $_.Exception.Message
            if ($_.ErrorDetails.Message) { $message += ' ' + $_.ErrorDetails.Message }
            if ($attempt -eq 0 -and $message -match $script:authFailurePattern) {
                Write-Warning 'Vast rejected the saved 2FA session; requesting a fresh TOTP code.'
                Set-VastSession
                continue
            }
            throw
        }
    }
}

$script:sessionKey = $env:VAST_API_SESSION_KEY
if ([string]::IsNullOrWhiteSpace($script:sessionKey)) {
    $script:sessionKey = [Environment]::GetEnvironmentVariable('VAST_API_SESSION_KEY', 'User')
}
$script:creatorId = $env:VAST_ACCOUNT_ID
if ([string]::IsNullOrWhiteSpace($script:creatorId)) {
    $script:creatorId = [Environment]::GetEnvironmentVariable('VAST_ACCOUNT_ID', 'User')
}

if ([string]::IsNullOrWhiteSpace($script:sessionKey) -or [string]::IsNullOrWhiteSpace($script:creatorId)) {
    Set-VastSession
}
else {
    $script:headers = @{ Authorization = "Bearer $script:sessionKey" }
    $currentUser = Invoke-VastApi -Method Get -Uri "$script:baseUri/users/current/"
    if (-not $currentUser.id) {
        throw 'Vast did not return the current account ID for the saved session.'
    }
    $script:creatorId = [int]$currentUser.id
    $env:VAST_ACCOUNT_ID = [string]$script:creatorId
    [Environment]::SetEnvironmentVariable('VAST_ACCOUNT_ID', [string]$script:creatorId, 'User')
}

$templateFilters = @{ creator_id = @{ eq = $script:creatorId } } | ConvertTo-Json -Compress
$templateUri = "$script:baseUri/template?select_filters=$([uri]::EscapeDataString($templateFilters))"
$templateResponse = Invoke-VastApi -Method Get -Uri $templateUri
$templates = @($templateResponse.templates)
if (-not $templateResponse.success -or $templates.Count -eq 0) {
    throw "No templates owned by Vast account $script:creatorId were returned. Save a template to this account or check that VAST_API_KEY belongs to the same account as the Vast website."
}

Write-Host "Your templates (account $script:creatorId):"
for ($index = 0; $index -lt $templates.Count; $index++) {
    $template = $templates[$index]
    $image = $template.image
    if ($template.tag) { $image = "$image`:$($template.tag)" }
    Write-Host ('{0}. {1} [template {2}] — {3}' -f ($index + 1), $template.name, $template.id, $image)
}

$selection = Read-Host 'Choose a template number'
if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $templates.Count) {
    throw 'Invalid template selection; no offer was rented.'
}
$selectedTemplate = $templates[[int]$selection - 1]
if ([string]::IsNullOrWhiteSpace($selectedTemplate.hash_id)) {
    throw 'Selected template has no hash_id; no offer was rented.'
}

$diskGb = 130.0
if ($selectedTemplate.recommended_disk_space) {
    $diskGb = [Math]::Max($diskGb, [double]$selectedTemplate.recommended_disk_space)
}
Write-Host "Selected template: $($selectedTemplate.name); disk allocation: $diskGb GB."

$searchFilters = @{
    limit             = 1000
    type              = 'ondemand'
    rentable           = @{ eq = $true }
    rented             = @{ eq = $false }
    gpu_arch           = @{ eq = 'nvidia' }
    gpu_mem_bw         = @{ gte = 484.38151512350566 }
    gpu_total_ram      = @{ gte = 13450 }
    disk_space         = @{ gte = $diskGb }
    allocated_storage  = $diskGb
    direct_port_count  = @{ gte = 9 }
    reliability        = @{ gte = 0.9092820467105875 }
    cpu_ram            = @{ gte = 13777.246867516858 }
    dph_total          = @{ lte = 0.6570158135746855 }
    cuda_max_good      = @{ gte = 13 }
    inet_down_cost     = @{ lte = 0.0004135116842216328 }
    inet_up_cost       = @{ lte = 0.0005097988414990953 }
}

# Include compatibility constraints saved in the chosen template.
$extraFilters = $selectedTemplate.extra_filters
if ($extraFilters -is [string] -and -not [string]::IsNullOrWhiteSpace($extraFilters)) {
    $extraFilters = $extraFilters | ConvertFrom-Json
}
if ($extraFilters) {
    foreach ($fieldProperty in $extraFilters.PSObject.Properties) {
        $fieldName = $fieldProperty.Name
        $templateCondition = $fieldProperty.Value
        if (-not $searchFilters.ContainsKey($fieldName)) {
            $searchFilters[$fieldName] = $templateCondition
            continue
        }

        $existingCondition = $searchFilters[$fieldName]
        foreach ($operatorProperty in $templateCondition.PSObject.Properties) {
            $operator = $operatorProperty.Name
            $value = $operatorProperty.Value
            if (-not $existingCondition.ContainsKey($operator)) {
                $existingCondition[$operator] = $value
                continue
            }

            switch ($operator) {
                { $_ -in @('gte', 'gt') } {
                    $existingCondition[$operator] = [Math]::Max([double]$existingCondition[$operator], [double]$value)
                }
                { $_ -in @('lte', 'lt') } {
                    $existingCondition[$operator] = [Math]::Min([double]$existingCondition[$operator], [double]$value)
                }
                default {
                    if ($existingCondition[$operator] -ne $value) {
                        throw "Template filter '$fieldName/$operator' conflicts with the search filter; no offer was rented."
                    }
                }
            }
        }
    }
}

$searchBody = $searchFilters | ConvertTo-Json -Depth 10
$offersUri = "$script:baseUri/bundles/"
$previousOffers = @{}
$hasBaseline = $false

Write-Host "Monitoring unoccupied offers every $IntervalSeconds seconds. Press Ctrl+C to stop."

while ($true) {
    try {
        $response = Invoke-VastApi -Method Post -Uri $offersUri -Body $searchBody
    }
    catch {
        Write-Warning ("Vast offer search failed: {0}" -f $_.Exception.Message)
        Start-Sleep -Seconds $IntervalSeconds
        continue
    }

    $offers = @($response.offers)
    $currentOffers = @{}
    foreach ($offer in $offers) {
        $currentOffers[[string]$offer.id] = $offer
    }

    if (-not $hasBaseline) {
        Write-Host "Baseline: $($currentOffers.Count) matching unoccupied offers."
        $hasBaseline = $true
    }
    else {
        foreach ($id in $currentOffers.Keys) {
            if (-not $previousOffers.ContainsKey($id)) {
                Write-Host "NEW AVAILABLE: id=$id gpu=$($currentOffers[$id].gpu_name) price=$($currentOffers[$id].dph_total)/h"
            }
        }
        foreach ($id in $previousOffers.Keys) {
            if (-not $currentOffers.ContainsKey($id)) {
                Write-Host "NO LONGER AVAILABLE: id=$id gpu=$($previousOffers[$id].gpu_name)"
            }
        }
    }

    $previousOffers = $currentOffers
    $cheapest = $offers | Sort-Object dph_total | Select-Object -First 1

    if ($cheapest) {
        Write-Host ('Cheapest match: offer={0}, GPU={1}, price=${2:N3}/h, available disk={3:N0}GB' -f `
            $cheapest.id, $cheapest.gpu_name, $cheapest.dph_total, $cheapest.disk_space)

        if ($Preview) {
            $offers | Sort-Object dph_total | Select-Object -First 10 id, gpu_name, dph_total, disk_space, reliability |
                Format-Table -AutoSize | Out-Host
            break
        }

        $createBody = @{
            template_hash_id = $selectedTemplate.hash_id
            disk             = $diskGb
            target_state     = 'running'
            cancel_unavail   = $true
            label            = "vast-auto-$($selectedTemplate.name)"
        } | ConvertTo-Json -Compress

        try {
            $created = Invoke-VastApi -Method Put -Uri "$script:baseUri/asks/$($cheapest.id)/" -Body $createBody
            if (-not $created.success -or -not $created.new_contract) {
                throw "Vast rejected offer $($cheapest.id): $($created.msg)"
            }
            Write-Host "Rental accepted: instance=$($created.new_contract), offer=$($cheapest.id), price=$($cheapest.dph_total)/h, template=$($selectedTemplate.name). Script exiting; the instance remains running."
            break
        }
        catch {
            Write-Error ("Rental failed for cheapest offer {0}; script is stopping without trying a more expensive offer. {1}" -f `
                $cheapest.id, $_.Exception.Message)
            exit 1
        }
    }

    if ($Preview) {
        Write-Host 'No matching offers currently available.'
        break
    }

    Write-Host ('[{0}] No matches; retrying in {1}s.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $IntervalSeconds)
    Start-Sleep -Seconds $IntervalSeconds
}
