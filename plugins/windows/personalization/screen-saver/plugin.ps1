param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\..\shared\Winix.PluginSdk.psm1') -Force
Add-Type -Path (Join-Path $PSScriptRoot 'ScreenSaverApi.cs')
$request = Read-WinixRequest
$resourceType = 'windows.personalization.screen_saver'

if ("$($request.context.scope)" -cne 'user') { throw "Unsupported $resourceType scope '$($request.context.scope)'." }
if ($Operation -eq 'validate') {
    Write-WinixResponse @{ protocol_version = 2; valid = $true; diagnostics = @() }
    exit
}

$desired = "$($request.configuration.state)"
$current = if ([Winix.ScreenSaver.ScreenSaverApi]::GetEnabled()) { 'enabled' } else { 'disabled' }
$operations = [System.Collections.Generic.List[object]]::new()
if ($current -cne $desired) {
    $operationItem = [ordered]@{
        id = 'windows.personalization.screen_saver.state.set'
        action = 'set_screen_saver_state'
        resource = @{ type = $resourceType; id = 'state' }
        before = $current
        after = $desired
        data = @{}
    }
    $operations.Add($operationItem)
}

if ($Operation -eq 'plan') {
    foreach ($operationItem in $operations) {
        Write-WinixEvent -Kind 'resource_status' -ResourceType $resourceType -ResourceId 'state' -Data @{ status = 'change_required'; operation = $operationItem }
    }
    Write-WinixResponse @{ protocol_version = 2; success = $true; changed = $false; state = @{ state = $current }; operations = $operations; diagnostics = @(); restart_required = @{ explorer = $false; system = $false } }
    exit
}

if (Test-WinixAdministrator) { throw 'Current-user screen saver configuration cannot run with an elevated token.' }
if (-not (Test-WinixPropertyPresent $request 'operations')) { throw 'Apply request is missing its planned operations.' }
$planned = @($request.operations)
foreach ($operationItem in $planned) {
    if ($operationItem.action -cne 'set_screen_saver_state' -or $operationItem.resource.type -cne $resourceType -or "$($operationItem.resource.id)" -cne 'state' -or "$($operationItem.after)" -cne $desired) {
        throw "Unsupported planned operation '$($operationItem.id)'."
    }
    if ($current -cne "$($operationItem.before)") {
        throw "Plan is stale for '$($operationItem.id)': the screen saver state changed after planning."
    }
}

$applied = [System.Collections.Generic.List[string]]::new()
foreach ($operationItem in $planned) {
    Write-WinixEvent -Kind 'resource_change_started' -ResourceType $resourceType -ResourceId 'state' -Data @{ operation_id = $operationItem.id; action = $operationItem.action; before = $operationItem.before; after = $operationItem.after }
    [Winix.ScreenSaver.ScreenSaverApi]::SetEnabled($operationItem.after -ceq 'enabled')
    $observed = if ([Winix.ScreenSaver.ScreenSaverApi]::GetEnabled()) { 'enabled' } else { 'disabled' }
    if ($observed -cne "$($operationItem.after)") { throw 'The screen saver state did not reach its planned postcondition.' }
    $applied.Add("$($operationItem.id)")
    Write-WinixEvent -Kind 'resource_change_completed' -ResourceType $resourceType -ResourceId 'state' -Data @{ operation_id = $operationItem.id; changed = $true; observed = $observed }
}
Write-WinixResponse @{ protocol_version = 2; success = $true; changed = ($applied.Count -gt 0); state = @{ state = $desired }; operations = $planned; applied_operation_ids = $applied; diagnostics = @(); restart_required = @{ explorer = $false; system = $false } }
