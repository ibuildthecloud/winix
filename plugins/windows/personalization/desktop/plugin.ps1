param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\..\shared\Winix.PluginSdk.psm1') -Force
Add-Type -Path (Join-Path $PSScriptRoot 'DesktopApi.cs')
$request = Read-WinixRequest

if ($Operation -eq 'validate') {
    Write-WinixResponse @{ protocol_version = 2; valid = $true; diagnostics = @() }
    exit
}

$state = [ordered]@{}
$operations = [System.Collections.Generic.List[object]]::new()

if (Test-WinixPropertyPresent $request.configuration 'icons') {
    $currentDisabled = [Winix.Desktop.DesktopApi]::GetIconsDisabled()
    $desiredDisabled = $request.configuration.icons -eq 'disabled'
    $state.icons = if ($currentDisabled) { 'disabled' } else { 'enabled' }
    if ($currentDisabled -ne $desiredDisabled) {
        $operations.Add([ordered]@{
            id = 'desktop.icons'
            action = 'set_desktop_icon_visibility'
            resource = @{ type = 'windows.personalization.desktop'; id = 'icons' }
            before = $state.icons
            after = $request.configuration.icons
            data = @{}
        })
    }
}

if (Test-WinixPropertyPresent $request.configuration 'color') {
    $desiredColor = $request.configuration.color.ToUpperInvariant()
    $currentColor = [Winix.Desktop.DesktopApi]::GetBackgroundColor()
    $solidColorActive = [Winix.Desktop.DesktopApi]::IsSolidColorActive()
    $state.color = if ($solidColorActive) { $currentColor } else { $null }
    if ($currentColor -ne $desiredColor -or -not $solidColorActive) {
        $operations.Add([ordered]@{
            id = 'desktop.color'
            action = 'set_desktop_solid_color'
            resource = @{ type = 'windows.personalization.desktop'; id = 'color' }
            before = @{ color = $currentColor; solid_color_active = $solidColorActive }
            after = $desiredColor
            data = @{}
        })
    }
}

if ($Operation -eq 'plan') {
    foreach ($operationItem in $operations) {
        Write-WinixEvent -Kind 'resource_status' -ResourceType $operationItem.resource.type -ResourceId $operationItem.resource.id -Data @{ status = 'change_required'; operation = $operationItem }
    }
    Write-WinixResponse @{ protocol_version = 2; success = $true; changed = $false; state = $state; operations = $operations; diagnostics = @(); restart_required = @{ explorer = $false; system = $false } }
    exit
}

if (-not (Test-WinixPropertyPresent $request 'operations')) { throw 'Apply request is missing its planned operations.' }
$planned = @($request.operations)
$alreadySatisfied = @{}
foreach ($operationItem in $planned) {
    if ($operationItem.resource.type -ne 'windows.personalization.desktop') { throw "Unsupported planned operation '$($operationItem.id)'." }
    switch ($operationItem.action) {
        'set_desktop_icon_visibility' {
            $current = if ([Winix.Desktop.DesktopApi]::GetIconsDisabled()) { 'disabled' } else { 'enabled' }
            if ($current -eq $operationItem.after) {
                $alreadySatisfied[$operationItem.id] = $true
            } elseif ($current -ne $operationItem.before) {
                throw "Plan is stale for '$($operationItem.id)': desktop icon visibility changed after planning."
            }
        }
        'set_desktop_solid_color' {
            $currentColor = [Winix.Desktop.DesktopApi]::GetBackgroundColor()
            $solidColorActive = [Winix.Desktop.DesktopApi]::IsSolidColorActive()
            if ($currentColor -eq $operationItem.after -and $solidColorActive) {
                $alreadySatisfied[$operationItem.id] = $true
            } elseif ($currentColor -ne $operationItem.before.color -or $solidColorActive -ne $operationItem.before.solid_color_active) {
                throw "Plan is stale for '$($operationItem.id)': the desktop background changed after planning."
            }
        }
        default { throw "Unsupported planned operation '$($operationItem.id)'." }
    }
}

$applied = [System.Collections.Generic.List[string]]::new()
$changedCount = 0
foreach ($operationItem in $planned) {
    Write-WinixEvent -Kind 'resource_change_started' -ResourceType $operationItem.resource.type -ResourceId $operationItem.resource.id -Data @{ operation_id = $operationItem.id; action = $operationItem.action; before = $operationItem.before; after = $operationItem.after }
    $changed = -not $alreadySatisfied.ContainsKey($operationItem.id)
    if ($changed) {
        switch ($operationItem.action) {
            'set_desktop_icon_visibility' {
                [Winix.Desktop.DesktopApi]::SetIconsDisabled($operationItem.after -eq 'disabled')
            }
            'set_desktop_solid_color' {
                [Winix.Desktop.DesktopApi]::SetSolidColor($operationItem.after)
            }
        }
        $changedCount++
    }
    $applied.Add($operationItem.id)
    Write-WinixEvent -Kind 'resource_change_completed' -ResourceType $operationItem.resource.type -ResourceId $operationItem.resource.id -Data @{ operation_id = $operationItem.id; changed = $changed; already_satisfied = (-not $changed) }
}
Write-WinixResponse @{ protocol_version = 2; success = $true; changed = ($changedCount -gt 0); state = $state; operations = $planned; applied_operation_ids = $applied; diagnostics = @(); restart_required = @{ explorer = $false; system = $false } }
