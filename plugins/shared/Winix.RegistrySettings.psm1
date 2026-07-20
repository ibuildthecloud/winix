Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-WinixRegistrySettingsPlugin {
    param(
        [Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation,
        [Parameter(Mandatory)] [object] $Request,
        [Parameter(Mandatory)] [ValidateSet('system', 'user')] [string] $Scope,
        [Parameter(Mandatory)] [string] $ResourceType,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Definitions,
        [bool] $RestartExplorer = $false,
        [bool] $RestartSystem = $false
    )

    if ("$($Request.context.scope)" -cne $Scope) { throw "Unsupported $ResourceType scope '$($Request.context.scope)'." }
    if ($Operation -eq 'validate') {
        Write-WinixResponse @{ protocol_version = 2; valid = $true; diagnostics = @() }
        return
    }

    $byId = @{}
    foreach ($definition in $Definitions) {
        $id = "$($definition.id)"
        if ($byId.ContainsKey($id)) { throw "Duplicate registry setting definition '$id'." }
        $byId[$id] = $definition
    }

    if ($Operation -eq 'plan') {
        $state = [ordered]@{}
        $operations = [System.Collections.Generic.List[object]]::new()
        foreach ($definition in $Definitions) {
            $currentRaw = Get-WinixProperty $definition.path $definition.name
            $state[$definition.id] = & $definition.decode $currentRaw
            if (Test-WinixJsonEqual $currentRaw $definition.desired_raw) { continue }
            $operationItem = [ordered]@{
                id = "$ResourceType.$($definition.id).set"
                action = 'set_registry_value'
                resource = @{ type = $ResourceType; id = "$($definition.id)" }
                before = $currentRaw
                after = $definition.desired_raw
                data = @{ path = "$($definition.path)"; name = "$($definition.name)"; property_type = "$($definition.property_type)" }
            }
            $operations.Add($operationItem)
            Write-WinixEvent -Kind 'resource_status' -ResourceType $ResourceType -ResourceId "$($definition.id)" -Data @{ status = 'change_required'; operation = $operationItem }
        }
        Write-WinixResponse @{ protocol_version = 2; success = $true; changed = $false; state = $state; operations = $operations; diagnostics = @(); error = $null; restart_required = @{ explorer = ($RestartExplorer -and $operations.Count -gt 0); system = ($RestartSystem -and $operations.Count -gt 0) } }
        return
    }

    if ($Scope -eq 'system' -and -not (Test-WinixAdministrator)) { throw "$ResourceType system settings require an elevated token." }
    if ($Scope -eq 'user' -and (Test-WinixAdministrator)) { throw "$ResourceType user settings cannot run with an elevated token." }
    if (-not (Test-WinixPropertyPresent $Request 'operations')) { throw 'Apply request is missing its planned operations.' }
    $planned = @($Request.operations)
    foreach ($operationItem in $planned) {
        $id = "$($operationItem.resource.id)"
        if ($operationItem.action -ne 'set_registry_value' -or $operationItem.resource.type -cne $ResourceType -or -not $byId.ContainsKey($id)) {
            throw "Unsupported planned operation '$($operationItem.id)'."
        }
        $definition = $byId[$id]
        if ("$($operationItem.data.path)" -cne "$($definition.path)" -or "$($operationItem.data.name)" -cne "$($definition.name)" -or "$($operationItem.data.property_type)" -cne "$($definition.property_type)" -or -not (Test-WinixJsonEqual $operationItem.after $definition.desired_raw)) {
            throw "Planned operation '$($operationItem.id)' does not match the declared registry setting '$id'."
        }
        $current = Get-WinixProperty $definition.path $definition.name
        if (-not (Test-WinixJsonEqual $current $operationItem.before)) { throw "Plan is stale for '$($operationItem.id)': the registry value changed after planning." }
    }

    $applied = [System.Collections.Generic.List[string]]::new()
    foreach ($operationItem in $planned) {
        $definition = $byId["$($operationItem.resource.id)"]
        Write-WinixEvent -Kind 'resource_change_started' -ResourceType $ResourceType -ResourceId "$($definition.id)" -Data @{ operation_id = $operationItem.id; action = $operationItem.action; before = $operationItem.before; after = $operationItem.after }
        Set-WinixProperty $definition.path $definition.name $definition.desired_raw $definition.property_type | Out-Null
        $observed = Get-WinixProperty $definition.path $definition.name
        if (-not (Test-WinixJsonEqual $observed $definition.desired_raw)) { throw "Registry setting '$($definition.id)' did not reach its planned postcondition." }
        $applied.Add($operationItem.id)
        Write-WinixEvent -Kind 'resource_change_completed' -ResourceType $ResourceType -ResourceId "$($definition.id)" -Data @{ operation_id = $operationItem.id; changed = $true; observed = (& $definition.decode $observed) }
    }
    Write-WinixResponse @{ protocol_version = 2; success = $true; changed = ($applied.Count -gt 0); operations = $planned; applied_operation_ids = $applied; diagnostics = @(); error = $null; restart_required = @{ explorer = ($RestartExplorer -and $applied.Count -gt 0); system = ($RestartSystem -and $applied.Count -gt 0) } }
}

Export-ModuleMember -Function Invoke-WinixRegistrySettingsPlugin
