param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.PluginSdk.psm1') -Force
Add-Type -Path (Join-Path $PSScriptRoot 'PowerSettingsApi.cs')
$request = Read-WinixRequest

$settingDefinitions = @(
    [ordered]@{ section = 'display_off_after'; property = $null; setting = 'display_idle'; id = 'display_off_after' },
    [ordered]@{ section = 'presence_sensing'; property = 'inattentive_dim_after'; setting = 'presence_inattentive_dim'; id = 'presence_sensing.inattentive_dim_after' },
    [ordered]@{ section = 'presence_sensing'; property = 'inattentive_display_off_after'; setting = 'presence_inattentive_display'; id = 'presence_sensing.inattentive_display_off_after' },
    [ordered]@{ section = 'presence_sensing'; property = 'away_dim_after'; setting = 'presence_away_dim'; id = 'presence_sensing.away_dim_after' },
    [ordered]@{ section = 'presence_sensing'; property = 'away_display_off_after'; setting = 'presence_away_display'; id = 'presence_sensing.away_display_off_after' }
)

function Get-ConfiguredLeaf($Definition) {
    if (-not (Test-WinixPropertyPresent $request.configuration $Definition.section)) { return $null }
    $section = $request.configuration.PSObject.Properties[$Definition.section].Value
    if ($null -eq $Definition.property) { return $section }
    if (-not (Test-WinixPropertyPresent $section $Definition.property)) { return $null }
    return $section.PSObject.Properties[$Definition.property].Value
}

function Get-ActiveSchemeState {
    $scheme = [WinixPowerSettingsApi]::GetActiveScheme()
    return [ordered]@{ scheme = $scheme; scheme_id = $scheme.ToString().ToLowerInvariant() }
}

function Get-Timeout([Guid] $Scheme, [string] $Setting, [bool] $OnBattery) {
    return [uint64][WinixPowerSettingsApi]::ReadTimeout($Scheme, $Setting, $OnBattery)
}

function Get-ManagedState {
    $power = Get-ActiveSchemeState
    $state = [ordered]@{}
    foreach ($definition in $settingDefinitions) {
        $leaf = Get-ConfiguredLeaf $definition
        if ($null -eq $leaf) { continue }
        $observed = [ordered]@{ scheme_id = $power.scheme_id }
        if (Test-WinixPropertyPresent $leaf 'plugged_in_seconds') {
            $observed.plugged_in_seconds = Get-Timeout $power.scheme $definition.setting $false
        }
        if (Test-WinixPropertyPresent $leaf 'on_battery_seconds') {
            $observed.on_battery_seconds = Get-Timeout $power.scheme $definition.setting $true
        }
        if ($null -eq $definition.property) {
            $state[$definition.section] = $observed
        } else {
            if (-not $state.Contains($definition.section)) { $state[$definition.section] = [ordered]@{} }
            $state[$definition.section][$definition.property] = $observed
        }
    }
    return $state
}

function Assert-Configuration {
    if ([string]$request.context.scope -cne 'system') { throw 'Windows power settings require system placement.' }
    foreach ($definition in $settingDefinitions) {
        $leaf = Get-ConfiguredLeaf $definition
        if ($null -eq $leaf) { continue }
        foreach ($name in @('plugged_in_seconds', 'on_battery_seconds')) {
            if ((Test-WinixPropertyPresent $leaf $name) -and [uint64]$leaf.$name -gt [uint32]::MaxValue) {
                throw "$($definition.id).$name must be between 0 and 4294967295."
            }
        }
    }
}

function Get-Definition([string] $Setting) {
    $matchingSettings = @($settingDefinitions | Where-Object setting -CEQ $Setting)
    if ($matchingSettings.Count -ne 1) { throw "Unknown Windows power setting '$Setting'." }
    return $matchingSettings[0]
}

function New-TimeoutOperation($Definition, [string] $Source, [uint64] $Current, [uint64] $Desired, [string] $SchemeId) {
    return [ordered]@{
        id = "windows.power.$($Definition.id).$Source"
        action = 'set_power_timeout'
        resource = [ordered]@{ type = 'windows.power.timeout'; id = "$($Definition.id).$Source" }
        before = [ordered]@{ scheme_id = $SchemeId; setting = $Definition.setting; power_source = $Source; seconds = $Current }
        after = [ordered]@{ scheme_id = $SchemeId; setting = $Definition.setting; power_source = $Source; seconds = $Desired }
        data = [ordered]@{ on_battery = ($Source -ceq 'on_battery') }
    }
}

function Assert-TimeoutOperation($Item) {
    if ([string]$Item.action -cne 'set_power_timeout' -or [string]$Item.resource.type -cne 'windows.power.timeout') {
        throw "Invalid power timeout operation '$($Item.id)'."
    }
    if (@($Item.before.PSObject.Properties).Count -ne 4 -or @($Item.after.PSObject.Properties).Count -ne 4 -or @($Item.data.PSObject.Properties).Count -ne 1) {
        throw "Power timeout operation '$($Item.id)' has an invalid shape."
    }
    $definition = Get-Definition ([string]$Item.after.setting)
    $source = [string]$Item.after.power_source
    $expectedBattery = $source -ceq 'on_battery'
    $expectedId = "windows.power.$($definition.id).$source"
    if ($source -notin @('plugged_in', 'on_battery') -or [string]$Item.id -cne $expectedId -or [string]$Item.resource.id -cne "$($definition.id).$source" -or
        [bool]$Item.data.on_battery -ne $expectedBattery -or [string]$Item.before.setting -cne $definition.setting -or
        [string]$Item.before.power_source -cne $source -or [string]$Item.before.scheme_id -cne [string]$Item.after.scheme_id) {
        throw "Power timeout operation '$($Item.id)' has inconsistent data."
    }
    if ([uint64]$Item.after.seconds -gt [uint32]::MaxValue) { throw "Power timeout operation '$($Item.id)' is out of range." }
}

Assert-Configuration

if ($Operation -eq 'validate') {
    Write-WinixResponse @{ protocol_version = 2; valid = $true; diagnostics = @() }
    return
}

if ($Operation -eq 'plan') {
    $operations = [System.Collections.Generic.List[object]]::new()
    $power = Get-ActiveSchemeState
    foreach ($definition in $settingDefinitions) {
        $leaf = Get-ConfiguredLeaf $definition
        if ($null -eq $leaf) { continue }
        foreach ($source in @('plugged_in', 'on_battery')) {
            $propertyName = if ($source -ceq 'on_battery') { 'on_battery_seconds' } else { 'plugged_in_seconds' }
            if (-not (Test-WinixPropertyPresent $leaf $propertyName)) { continue }
            $onBattery = $source -ceq 'on_battery'
            $current = Get-Timeout $power.scheme $definition.setting $onBattery
            $desired = [uint64]$leaf.$propertyName
            if ($current -ne $desired) { $operations.Add((New-TimeoutOperation $definition $source $current $desired $power.scheme_id)) }
        }
    }
    Write-WinixResponse @{ protocol_version = 2; success = $true; changed = $false; state = Get-ManagedState; operations = @($operations); diagnostics = @(); restart_required = @{ explorer = $false; system = $false } }
    return
}

if ($null -eq $request.PSObject.Properties['operations']) { throw 'Apply requires an operations queue.' }
if (-not [bool]$request.context.elevated) { throw 'Applying Windows power settings requires elevation.' }

# Preflight the entire queue before changing any setting.
$seen = @{}
$power = Get-ActiveSchemeState
foreach ($item in @($request.operations)) {
    if ($seen.ContainsKey([string]$item.id)) { throw "Duplicate operation id '$($item.id)'." }
    $seen[[string]$item.id] = $true
    Assert-TimeoutOperation $item
    $current = Get-Timeout $power.scheme ([string]$item.before.setting) ([bool]$item.data.on_battery)
    $observed = [ordered]@{ scheme_id = $power.scheme_id; setting = [string]$item.before.setting; power_source = [string]$item.before.power_source; seconds = $current }
    if (-not (Test-WinixJsonEqual $observed $item.before)) { throw "Power timeout plan '$($item.id)' is stale." }
}

$appliedIds = [System.Collections.Generic.List[string]]::new()
foreach ($item in @($request.operations)) {
    $scheme = [Guid]$item.after.scheme_id
    [WinixPowerSettingsApi]::WriteTimeout($scheme, [string]$item.after.setting, [bool]$item.data.on_battery, [uint32]$item.after.seconds)
    [WinixPowerSettingsApi]::Activate($scheme)
    $observedScheme = Get-ActiveSchemeState
    $actual = Get-Timeout $observedScheme.scheme ([string]$item.after.setting) ([bool]$item.data.on_battery)
    if ($observedScheme.scheme_id -cne [string]$item.after.scheme_id -or $actual -ne [uint64]$item.after.seconds) {
        throw "Power timeout '$($item.resource.id)' did not reach its planned postcondition."
    }
    $appliedIds.Add([string]$item.id)
}

Write-WinixResponse @{ protocol_version = 2; success = $true; changed = ($appliedIds.Count -gt 0); state = Get-ManagedState; operations = @($request.operations); applied_operation_ids = @($appliedIds); diagnostics = @(); restart_required = @{ explorer = $false; system = $false } }
