param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.PluginSdk.psm1') -Force
$request = Read-WinixRequest
$policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
$forceListPath = Join-Path $policyPath 'ExtensionInstallForcelist'
$settings = [System.Collections.Generic.List[object]]::new()

function Get-ForceInstallEntries {
    $entries = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $forceListPath)) { return @() }
    $key = Get-Item -LiteralPath $forceListPath -ErrorAction Stop
    foreach ($name in @($key.GetValueNames() | Where-Object { $_ -match '^\d+$' } | Sort-Object { [int64]$_ })) {
        $entries.Add([ordered]@{ name = "$name"; value = "$($key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))" })
    }
    return @($entries)
}

function Get-ForceInstallFingerprint([object[]] $Entries) {
    $text = (@($Entries | ForEach-Object { "$($_.name)=$($_.value)" }) -join "`n")
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-NextForceInstallName([object[]] $Entries) {
    $used = @{}
    foreach ($entry in $Entries) { $used["$($entry.name)"] = $true }
    for ($index = 1; $index -lt [int]::MaxValue; $index++) {
        if (-not $used.ContainsKey("$index")) { return "$index" }
    }
    throw 'Microsoft Edge ExtensionInstallForcelist has no available numeric value name.'
}

function Get-DesiredExtensions {
    if (-not (Test-WinixPropertyPresent $request.configuration 'extensions')) { return @() }
    return @($request.configuration.extensions.PSObject.Properties.Name | Sort-Object)
}

function Get-SettingById([string] $Id) {
    foreach ($setting in $settings) {
        if ("$($setting.id)" -ceq $Id) { return $setting }
    }
    return $null
}

if (Test-WinixPropertyPresent $request.configuration 'new_tab_page') {
    $settings.Add(@{ id = 'new_tab_page'; name = 'NewTabPageLocation'; property_type = 'String'; desired_raw = 'about:blank'; decode = { param($value) "$value" } })
}
if (Test-WinixPropertyPresent $request.configuration 'show_first_run') {
    $desired = [bool]$request.configuration.show_first_run
    $settings.Add(@{ id = 'show_first_run'; name = 'HideFirstRunExperience'; property_type = 'DWord'; desired_raw = $(if ($desired) { 0 } else { 1 }); decode = { param($value) $value -ne 1 } })
}
$desiredExtensions = @(Get-DesiredExtensions)

if ("$($request.context.scope)" -cne 'system') { throw "Unsupported applications.microsoft_edge scope '$($request.context.scope)'." }
if ($Operation -eq 'validate') {
    Write-WinixResponse @{ protocol_version = 2; valid = $true; diagnostics = @() }
    return
}

if ($Operation -eq 'plan') {
    $state = [ordered]@{}
    $operations = [System.Collections.Generic.List[object]]::new()
    foreach ($setting in $settings) {
        $currentRaw = Get-WinixProperty $policyPath $setting.name
        $state[$setting.id] = & $setting.decode $currentRaw
        if (Test-WinixJsonEqual $currentRaw $setting.desired_raw) { continue }
        $operationItem = [ordered]@{
            id = "applications.microsoft_edge.policy.$($setting.id).set"
            action = 'set_registry_value'
            resource = @{ type = 'applications.microsoft_edge.policy'; id = "$($setting.id)" }
            before = $currentRaw
            after = $setting.desired_raw
            data = @{ path = $policyPath; name = "$($setting.name)"; property_type = "$($setting.property_type)" }
        }
        $operations.Add($operationItem)
        Write-WinixEvent -Kind 'resource_status' -ResourceType 'applications.microsoft_edge.policy' -ResourceId "$($setting.id)" -Data @{ status = 'change_required'; operation = $operationItem }
    }

    $entries = @(Get-ForceInstallEntries)
    $extensionState = [ordered]@{}
    foreach ($extensionId in $desiredExtensions) {
        $installed = @($entries | Where-Object { $_.value -ceq $extensionId }).Count -gt 0
        $extensionState[$extensionId] = @{ state = $(if ($installed) { 'required' } else { 'unmanaged' }) }
        if ($installed) { continue }
        $valueName = Get-NextForceInstallName $entries
        $operationItem = [ordered]@{
            id = "applications.microsoft_edge.extension.$extensionId.require"
            action = 'require_extension'
            resource = @{ type = 'applications.microsoft_edge.extension'; id = $extensionId }
            before = Get-ForceInstallFingerprint $entries
            after = @{ state = 'required' }
            data = @{ path = $forceListPath; name = $valueName; property_type = 'String'; value = $extensionId }
        }
        $operations.Add($operationItem)
        $entries += [ordered]@{ name = $valueName; value = $extensionId }
        Write-WinixEvent -Kind 'resource_status' -ResourceType 'applications.microsoft_edge.extension' -ResourceId $extensionId -Data @{ status = 'change_required'; operation = $operationItem }
    }
    if ($desiredExtensions.Count -gt 0) { $state.extensions = $extensionState }
    Write-WinixResponse @{ protocol_version = 2; success = $true; changed = $false; state = $state; operations = $operations; diagnostics = @(); error = $null; restart_required = @{ explorer = $false; system = $false } }
    return
}

if (-not (Test-WinixAdministrator)) { throw 'Microsoft Edge system settings require an elevated token.' }
if (-not (Test-WinixPropertyPresent $request 'operations')) { throw 'Apply request is missing its planned operations.' }
$planned = @($request.operations)
$preflightEntries = @(Get-ForceInstallEntries)
foreach ($operationItem in $planned) {
    $resourceType = "$($operationItem.resource.type)"
    $resourceId = "$($operationItem.resource.id)"
    if ($resourceType -ceq 'applications.microsoft_edge.policy') {
        $setting = Get-SettingById $resourceId
        if ($null -eq $setting -or $operationItem.action -ne 'set_registry_value' -or "$($operationItem.data.path)" -cne $policyPath -or "$($operationItem.data.name)" -cne "$($setting.name)" -or "$($operationItem.data.property_type)" -cne "$($setting.property_type)" -or -not (Test-WinixJsonEqual $operationItem.after $setting.desired_raw)) {
            throw "Unsupported planned Microsoft Edge policy operation '$($operationItem.id)'."
        }
        $current = Get-WinixProperty $policyPath $setting.name
        if (-not (Test-WinixJsonEqual $current $operationItem.before)) { throw "Plan is stale for '$($operationItem.id)': the registry value changed after planning." }
        continue
    }
    if ($resourceType -cne 'applications.microsoft_edge.extension' -or $operationItem.action -ne 'require_extension' -or $resourceId -notin $desiredExtensions -or "$($operationItem.data.path)" -cne $forceListPath -or "$($operationItem.data.name)" -notmatch '^\d+$' -or "$($operationItem.data.property_type)" -cne 'String' -or "$($operationItem.data.value)" -cne $resourceId -or -not (Test-WinixJsonEqual $operationItem.after @{ state = 'required' })) {
        throw "Unsupported planned Microsoft Edge extension operation '$($operationItem.id)'."
    }
    if ((Get-ForceInstallFingerprint $preflightEntries) -cne "$($operationItem.before)") { throw "Plan is stale for '$($operationItem.id)': the Edge extension policy list changed after planning." }
    $preflightEntries += [ordered]@{ name = "$($operationItem.data.name)"; value = $resourceId }
}

$applied = [System.Collections.Generic.List[string]]::new()
foreach ($operationItem in $planned) {
    $resourceType = "$($operationItem.resource.type)"
    $resourceId = "$($operationItem.resource.id)"
    Write-WinixEvent -Kind 'resource_change_started' -ResourceType $resourceType -ResourceId $resourceId -Data @{ operation_id = $operationItem.id; action = $operationItem.action; before = $operationItem.before; after = $operationItem.after }
    if ($resourceType -ceq 'applications.microsoft_edge.policy') {
        $setting = Get-SettingById $resourceId
        Set-WinixProperty $policyPath $setting.name $setting.desired_raw $setting.property_type | Out-Null
        $observed = Get-WinixProperty $policyPath $setting.name
        if (-not (Test-WinixJsonEqual $observed $setting.desired_raw)) { throw "Microsoft Edge policy '$resourceId' did not reach its planned postcondition." }
    } else {
        Set-WinixProperty $forceListPath "$($operationItem.data.name)" $resourceId 'String' | Out-Null
        $observedEntries = @(Get-ForceInstallEntries)
        if (@($observedEntries | Where-Object { $_.value -ceq $resourceId }).Count -eq 0) { throw "Microsoft Edge extension '$resourceId' was not added to the force-install policy." }
    }
    $applied.Add("$($operationItem.id)")
    Write-WinixEvent -Kind 'resource_change_completed' -ResourceType $resourceType -ResourceId $resourceId -Data @{ operation_id = $operationItem.id; changed = $true }
}
Write-WinixResponse @{ protocol_version = 2; success = $true; changed = ($applied.Count -gt 0); operations = $planned; applied_operation_ids = $applied; diagnostics = @(); error = $null; restart_required = @{ explorer = $false; system = $false } }
