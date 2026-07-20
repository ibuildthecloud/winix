param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.PluginSdk.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.RegistrySettings.psm1') -Force
$request = Read-WinixRequest
$scope = "$($request.context.scope)"
$diagnostics = [System.Collections.Generic.List[object]]::new()

if ($scope -eq 'system') {
    if (Test-WinixPropertyPresent $request.configuration 'highlights') {
        $diagnostics.Add(@{ severity = 'error'; code = 'windows.search.scope.invalid'; path = "$($request.path).highlights"; message = 'windows.search.highlights is user-scoped; place it under users.current.windows.search.' })
    }
    if (-not (Test-WinixPropertyPresent $request.configuration 'web_suggestions')) {
        $diagnostics.Add(@{ severity = 'error'; code = 'windows.search.system.configuration.empty'; path = $request.path; message = 'System-scoped windows.search requires web_suggestions.' })
    }
    $sid = if ($null -ne $request.context.PSObject.Properties['user_sid']) { "$($request.context.user_sid)" } else { '' }
    if ($sid -notmatch '^S-1-(?:\d+-)+\d+$') {
        $diagnostics.Add(@{ severity = 'error'; code = 'windows.search.user_sid.invalid'; path = $request.path; message = 'The original interactive user SID is unavailable; the user Search policy cannot be targeted safely.' })
    }
} elseif ($scope -eq 'user') {
    if (Test-WinixPropertyPresent $request.configuration 'web_suggestions') {
        $diagnostics.Add(@{ severity = 'error'; code = 'windows.search.scope.invalid'; path = "$($request.path).web_suggestions"; message = 'windows.search.web_suggestions requires administrative policy access; place it under system.windows.search.' })
    }
    if (-not (Test-WinixPropertyPresent $request.configuration 'highlights')) {
        $diagnostics.Add(@{ severity = 'error'; code = 'windows.search.user.configuration.empty'; path = $request.path; message = 'User-scoped windows.search requires highlights.' })
    }
} else {
    throw "Unsupported windows.search scope '$scope'."
}

if ($Operation -eq 'validate') {
    Write-WinixResponse @{ protocol_version = 2; valid = ($diagnostics.Count -eq 0); diagnostics = $diagnostics }
    exit
}
if ($diagnostics.Count -gt 0) {
    if ($Operation -eq 'plan') {
        Write-WinixResponse @{ protocol_version = 2; success = $false; changed = $false; state = @{}; operations = @(); diagnostics = $diagnostics; error = @{ code = 'windows.search.plan.failed'; message = 'Windows Search could not produce a valid plan.' }; restart_required = @{ explorer = $false; system = $false } }
        exit
    }
    throw $diagnostics[0].message
}

$definitions = [System.Collections.Generic.List[object]]::new()
if ($scope -eq 'system') {
    $desired = [bool]$request.configuration.web_suggestions
    $path = "Registry::HKEY_USERS\$sid\Software\Policies\Microsoft\Windows\Explorer"
    $definitions.Add(@{ id = 'web_suggestions'; path = $path; name = 'DisableSearchBoxSuggestions'; property_type = 'DWord'; desired_raw = $(if ($desired) { 0 } else { 1 }); decode = { param($value) $value -ne 1 } })
    Invoke-WinixRegistrySettingsPlugin -Operation $Operation -Request $request -Scope system -ResourceType 'windows.search.setting' -Definitions @($definitions) -RestartExplorer $true
    exit
}

$desired = [bool]$request.configuration.highlights
$definitions.Add(@{ id = 'highlights'; path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings'; name = 'IsDynamicSearchBoxEnabled'; property_type = 'DWord'; desired_raw = $(if ($desired) { 1 } else { 0 }); decode = { param($value) $value -ne 0 } })
Invoke-WinixRegistrySettingsPlugin -Operation $Operation -Request $request -Scope user -ResourceType 'windows.search.setting' -Definitions @($definitions) -RestartExplorer $true
