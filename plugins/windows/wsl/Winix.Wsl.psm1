Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.PluginSdk.psm1')

function Test-WslObjectValue {
    param([AllowNull()] [object] $Value)

    return $null -ne $Value -and (
        $Value -is [System.Collections.IDictionary] -or
        $Value.GetType() -eq [System.Management.Automation.PSCustomObject]
    )
}

function Get-WslMemberNames {
    param([Parameter(Mandatory)] [object] $Value)

    if ($Value -is [System.Collections.IDictionary]) {
        return @($Value.Keys | ForEach-Object { "$_" })
    }
    return @($Value.PSObject.Properties.Name)
}

function Get-WslMemberValue {
    param(
        [Parameter(Mandatory)] [object] $Value,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($Value -is [System.Collections.IDictionary]) { return $Value[$Name] }
    return $Value.PSObject.Properties[$Name].Value
}

function Test-WslMemberPresent {
    param(
        [Parameter(Mandatory)] [object] $Value,
        [Parameter(Mandatory)] [string] $Name
    )

    if (-not (Test-WslObjectValue $Value)) { return $false }
    return @(Get-WslMemberNames $Value | Where-Object { $_ -ceq $Name }).Count -eq 1
}

function Assert-WslExactProperties {
    param(
        [AllowNull()] [object] $Value,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Names,
        [Parameter(Mandatory)] [string] $Label
    )

    if (-not (Test-WslObjectValue $Value)) { throw "$Label must be an object." }
    $actual = @(Get-WslMemberNames $Value)
    $missing = @($Names | Where-Object { -not ($actual -ccontains $_) })
    $extra = @($actual | Where-Object { -not ($Names -ccontains $_) })
    if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
        $details = @()
        if ($missing.Count -gt 0) { $details += "missing: $($missing -join ', ')" }
        if ($extra.Count -gt 0) { $details += "unexpected: $($extra -join ', ')" }
        throw "$Label has invalid properties ($($details -join '; '))."
    }
}

function Assert-WslNonemptyString {
    param(
        [AllowNull()] [object] $Value,
        [Parameter(Mandatory)] [string] $Label
    )

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "$Label must be a nonempty string."
    }
}

function Assert-WslJsonEqual {
    param(
        [AllowNull()] [object] $Actual,
        [AllowNull()] [object] $Expected,
        [Parameter(Mandatory)] [string] $Message
    )

    if (-not (Test-WinixJsonEqual -Left $Actual -Right $Expected)) { throw $Message }
}

function Get-WslDesiredState {
    param([Parameter(Mandatory)] [object] $Configuration)

    if (Test-WslMemberPresent $Configuration 'state') { return "$(Get-WslMemberValue $Configuration 'state')" }
    return 'installed'
}

function Get-WslPreviewIntent {
    param([Parameter(Mandatory)] [object] $Configuration)

    return (Test-WslMemberPresent $Configuration 'preview') -and [bool](Get-WslMemberValue $Configuration 'preview')
}

function Get-WslConfiguredDistros {
    param([Parameter(Mandatory)] [object] $Configuration)

    if (-not (Test-WslMemberPresent $Configuration 'distros')) { return @() }
    return @(Get-WslMemberValue $Configuration 'distros' | ForEach-Object { "$_" })
}

function Get-WslNormalizedVersion {
    param(
        [Parameter(Mandatory)] [string] $Text,
        [Parameter(Mandatory)] [string] $Label
    )

    try { $parsed = [version]$Text } catch { throw "$Label '$Text' is not a valid version." }
    if ($parsed.Major -lt 0 -or $parsed.Minor -lt 0) { throw "$Label '$Text' is not a valid version." }
    $build = if ($parsed.Build -lt 0) { 0 } else { $parsed.Build }
    $revision = if ($parsed.Revision -lt 0) { 0 } else { $parsed.Revision }
    return [version]::new($parsed.Major, $parsed.Minor, $build, $revision).ToString()
}

function Assert-WslReleaseData {
    param(
        [Parameter(Mandatory)] [object] $Data,
        [Parameter(Mandatory)] [object] $Configuration,
        [Parameter(Mandatory)] [string] $OperationId
    )

    Assert-WslExactProperties -Value $Data -Names @('preview', 'release_tag', 'version') -Label "Planned operation '$OperationId' data"
    $preview = Get-WslMemberValue $Data 'preview'
    if ($preview -isnot [bool] -or $preview -ne (Get-WslPreviewIntent $Configuration)) {
        throw "Planned operation '$OperationId' preview channel does not match configuration."
    }
    $releaseTag = Get-WslMemberValue $Data 'release_tag'
    $version = Get-WslMemberValue $Data 'version'
    Assert-WslNonemptyString -Value $releaseTag -Label "Planned operation '$OperationId' release tag"
    Assert-WslNonemptyString -Value $version -Label "Planned operation '$OperationId' version"
    $normalizedVersion = Get-WslNormalizedVersion -Text $version -Label "Planned operation '$OperationId' version"
    if ($normalizedVersion -cne $version) {
        throw "Planned operation '$OperationId' version '$version' is not canonical."
    }
    $tagMatch = [regex]::Match($releaseTag, '(?<!\d)(\d+\.\d+(?:\.\d+){0,2})(?!\d)')
    if (-not $tagMatch.Success -or (Get-WslNormalizedVersion -Text $tagMatch.Groups[1].Value -Label "Planned operation '$OperationId' release tag") -cne $version) {
        throw "Planned operation '$OperationId' release tag does not identify version '$version'."
    }
}

function New-WslAbsentState {
    return [ordered]@{
        features_enabled = $false
        installed = $false
        restart_pending = $false
        update_required = $false
        version = $null
        distros = @()
    }
}

function Assert-WslBaseOperation {
    param(
        [AllowNull()] [object] $OperationItem,
        [Parameter(Mandatory)] [int] $Index
    )

    $label = "Planned WSL operation at index $Index"
    Assert-WslExactProperties -Value $OperationItem -Names @('id', 'action', 'resource', 'before', 'after', 'data') -Label $label
    $id = Get-WslMemberValue $OperationItem 'id'
    $action = Get-WslMemberValue $OperationItem 'action'
    Assert-WslNonemptyString -Value $id -Label "$label id"
    Assert-WslNonemptyString -Value $action -Label "$label action"
    Assert-WslExactProperties -Value (Get-WslMemberValue $OperationItem 'resource') -Names @('type', 'id') -Label "Planned operation '$id' resource"
    Assert-WslNonemptyString -Value (Get-WslMemberValue (Get-WslMemberValue $OperationItem 'resource') 'type') -Label "Planned operation '$id' resource type"
    Assert-WslNonemptyString -Value (Get-WslMemberValue (Get-WslMemberValue $OperationItem 'resource') 'id') -Label "Planned operation '$id' resource id"
    if (-not (Test-WslObjectValue (Get-WslMemberValue $OperationItem 'data'))) {
        throw "Planned operation '$id' data must be an object."
    }
}

function Assert-WslUniqueOperations {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Operations)

    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $resources = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    for ($index = 0; $index -lt $Operations.Count; $index++) {
        $operationItem = $Operations[$index]
        Assert-WslBaseOperation -OperationItem $operationItem -Index $index
        $id = "$(Get-WslMemberValue $operationItem 'id')"
        $resource = Get-WslMemberValue $operationItem 'resource'
        $resourceType = "$(Get-WslMemberValue $resource 'type')"
        $resourceId = "$(Get-WslMemberValue $resource 'id')"
        if (-not $ids.Add($id)) { throw "Planned WSL operation ID '$id' is duplicated." }
        $resourceKey = "$($resourceType.Length):$resourceType$resourceId"
        if (-not $resources.Add($resourceKey)) {
            throw "Planned WSL resource '$resourceType/$resourceId' is duplicated."
        }
    }
}

function Assert-WslSystemOperation {
    param(
        [Parameter(Mandatory)] [object] $OperationItem,
        [Parameter(Mandatory)] [object] $ObservedState,
        [Parameter(Mandatory)] [object] $Configuration
    )

    $id = "$(Get-WslMemberValue $OperationItem 'id')"
    $action = "$(Get-WslMemberValue $OperationItem 'action')"
    $resource = Get-WslMemberValue $OperationItem 'resource'
    $resourceType = "$(Get-WslMemberValue $resource 'type')"
    $resourceId = "$(Get-WslMemberValue $resource 'id')"
    $before = Get-WslMemberValue $OperationItem 'before'
    $after = Get-WslMemberValue $OperationItem 'after'
    $data = Get-WslMemberValue $OperationItem 'data'
    $desiredState = Get-WslDesiredState $Configuration

    switch ($action) {
        'enable_features' {
            if ($desiredState -cne 'installed' -or $id -cne 'wsl.system.enable-features' -or $resourceType -cne 'windows.wsl' -or $resourceId -cne 'wsl') {
                throw "Planned operation '$id' is not the configured WSL feature operation."
            }
            Assert-WslJsonEqual -Actual $before -Expected $ObservedState -Message "Plan is stale for '$id': WSL state changed after planning."
            if ([bool]$ObservedState.features_enabled) { throw "Plan is stale for '$id': the WSL Windows features are already provisioned." }
            $expectedAfter = [ordered]@{ features_enabled = $true; installed = $false; restart_pending = $true; update_required = $false; version = $null; distros = @() }
            Assert-WslJsonEqual -Actual $after -Expected $expectedAfter -Message "Planned operation '$id' has a tampered postcondition."
            Assert-WslJsonEqual -Actual $data -Expected ([ordered]@{ features = @('VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux') }) -Message "Planned operation '$id' has tampered feature data."
        }
        'install' {
            if ($desiredState -cne 'installed' -or $id -cne 'wsl.system.install' -or $resourceType -cne 'windows.wsl' -or $resourceId -cne 'wsl') {
                throw "Planned operation '$id' is not the configured WSL install operation."
            }
            Assert-WslJsonEqual -Actual $before -Expected $ObservedState -Message "Plan is stale for '$id': WSL state changed after planning."
            if ([bool]$ObservedState.installed -or -not [bool]$ObservedState.features_enabled -or [bool]$ObservedState.restart_pending) {
                throw "Plan is stale for '$id': WSL cannot be installed in the observed feature/restart state."
            }
            $expectedAfter = [ordered]@{ features_enabled = $true; installed = $true; restart_pending = $false; update_required = $false; version = $null; distros = @() }
            Assert-WslJsonEqual -Actual $after -Expected $expectedAfter -Message "Planned operation '$id' has a tampered postcondition."
            Assert-WslExactProperties -Value $data -Names @() -Label "Planned operation '$id' data"
        }
        'uninstall' {
            if ($desiredState -cne 'absent' -or $id -cne 'wsl.system.uninstall' -or $resourceType -cne 'windows.wsl' -or $resourceId -cne 'wsl') {
                throw "Planned operation '$id' is not the configured WSL uninstall operation."
            }
            Assert-WslJsonEqual -Actual $before -Expected $ObservedState -Message "Plan is stale for '$id': WSL state changed after planning."
            Assert-WslJsonEqual -Actual $after -Expected (New-WslAbsentState) -Message "Planned operation '$id' has a tampered postcondition."
            Assert-WslJsonEqual -Actual $data -Expected ([ordered]@{ destructive = $true }) -Message "Planned operation '$id' has tampered uninstall data."
        }
        'update' {
            if ($desiredState -cne 'installed' -or -not (Test-WslMemberPresent $Configuration 'version') -or "$(Get-WslMemberValue $Configuration 'version')" -cne 'latest' -or $resourceType -cne 'windows.wsl' -or $resourceId -cne 'wsl') {
                throw "Planned operation '$id' is not the configured WSL update operation."
            }
            Assert-WslReleaseData -Data $data -Configuration $Configuration -OperationId $id
            $targetVersion = "$(Get-WslMemberValue $data 'version')"
            if ($id -cne "wsl.system.update.$targetVersion") { throw "Planned operation '$id' does not identify its target version." }
            Assert-WslJsonEqual -Actual $before -Expected $ObservedState -Message "Plan is stale for '$id': WSL state changed after planning."
            if (-not [bool]$ObservedState.installed) { throw "Plan is stale for '$id': WSL is no longer installed." }
            $expectedAfter = [ordered]@{ features_enabled = $true; installed = $true; restart_pending = $false; update_required = $false; version = $targetVersion; distros = @($ObservedState.distros) }
            Assert-WslJsonEqual -Actual $after -Expected $expectedAfter -Message "Planned operation '$id' has a tampered postcondition."
            if (-not [bool]$ObservedState.update_required -and $null -ne $ObservedState.version -and [version]$ObservedState.version -ge [version]$targetVersion) {
                throw "Plan is stale for '$id': WSL no longer requires the planned update."
            }
        }
        'install_distro' {
            $configuredDistros = @(Get-WslConfiguredDistros $Configuration)
            $name = if (Test-WslMemberPresent $data 'name') { Get-WslMemberValue $data 'name' } else { $null }
            if ($desiredState -cne 'installed' -or $resourceType -cne 'windows.wsl.distro' -or $name -isnot [string] -or $resourceId -cne $name -or $id -cne "wsl.system.install-distro.$name" -or -not ($configuredDistros -ccontains $name)) {
                throw "Planned operation '$id' is not a configured WSL distribution operation."
            }
            if (-not [bool]$ObservedState.installed) { throw "Plan is stale for '$id': WSL is no longer installed." }
            if (@($ObservedState.distros | Where-Object { $_ -ceq $name }).Count -gt 0) {
                throw "Plan is stale for '$id': distribution '$name' is already installed."
            }
            Assert-WslJsonEqual -Actual $before -Expected ([ordered]@{ installed = $false }) -Message "Planned operation '$id' has a tampered precondition."
            Assert-WslJsonEqual -Actual $after -Expected ([ordered]@{ installed = $true }) -Message "Planned operation '$id' has a tampered postcondition."
            Assert-WslJsonEqual -Actual $data -Expected ([ordered]@{ name = $name }) -Message "Planned operation '$id' has tampered distribution data."
        }
        default { throw "Unsupported planned WSL operation '$id' with action '$action'." }
    }
}

function Test-WslSystemPostcondition {
    param(
        [Parameter(Mandatory)] [object] $OperationItem,
        [Parameter(Mandatory)] [object] $ObservedState
    )

    $action = "$(Get-WslMemberValue $OperationItem 'action')"
    $resource = Get-WslMemberValue $OperationItem 'resource'
    $resourceId = "$(Get-WslMemberValue $resource 'id')"
    $data = Get-WslMemberValue $OperationItem 'data'
    switch ($action) {
        'enable_features' { return [bool]$ObservedState.features_enabled -and [bool]$ObservedState.restart_pending }
        'install' { return [bool]$ObservedState.installed -and -not [bool]$ObservedState.restart_pending }
        'uninstall' {
            return -not [bool]$ObservedState.installed -and
                -not [bool]$ObservedState.features_enabled -and
                -not [bool]$ObservedState.restart_pending -and
                @($ObservedState.distros).Count -eq 0
        }
        'update' {
            return [bool]$ObservedState.installed -and
                -not [bool]$ObservedState.update_required -and
                "$($ObservedState.version)" -ceq "$(Get-WslMemberValue $data 'version')"
        }
        'install_distro' { return @($ObservedState.distros | Where-Object { $_ -ceq $resourceId }).Count -gt 0 }
    }
    return $false
}

function Invoke-WslSystemApply {
    param(
        [Parameter(Mandatory)] [object] $Request,
        [Parameter(Mandatory)] [scriptblock] $GetState,
        [Parameter(Mandatory)] [scriptblock] $ResolveDistros,
        [Parameter(Mandatory)] [scriptblock] $Mutate
    )

    if (-not (Test-WslMemberPresent $Request 'operations')) { throw 'Apply request is missing its planned operations.' }
    $planned = @((Get-WslMemberValue $Request 'operations'))
    Assert-WslUniqueOperations -Operations $planned

    $exclusiveActions = @($planned | Where-Object { "$(Get-WslMemberValue $_ 'action')" -in @('enable_features', 'install', 'uninstall') })
    if ($exclusiveActions.Count -gt 0 -and $planned.Count -ne 1) {
        throw "Planned WSL action '$(Get-WslMemberValue $exclusiveActions[0] 'action')' must be the only operation in its queue."
    }

    # Pass one: observe and validate every operation and external catalog
    # precondition. Nothing below this boundary is allowed to mutate the host.
    $observedBefore = if ($planned.Count -eq 0) { $null } else { & $GetState }
    foreach ($operationItem in $planned) {
        Assert-WslSystemOperation -OperationItem $operationItem -ObservedState $observedBefore -Configuration $Request.configuration
    }
    $distroNames = @($planned | Where-Object { "$(Get-WslMemberValue $_ 'action')" -ceq 'install_distro' } | ForEach-Object { "$(Get-WslMemberValue (Get-WslMemberValue $_ 'data') 'name')" })
    if ($distroNames.Count -gt 0) {
        $resolved = @(& $ResolveDistros $distroNames)
        Assert-WslJsonEqual -Actual $resolved -Expected $distroNames -Message 'The WSL online distribution catalog changed after planning.'
    }

    # Pass two: consume the already validated closed queue in order.
    $applied = [System.Collections.Generic.List[string]]::new()
    foreach ($operationItem in $planned) {
        $id = "$(Get-WslMemberValue $operationItem 'id')"
        $action = "$(Get-WslMemberValue $operationItem 'action')"
        $resource = Get-WslMemberValue $operationItem 'resource'
        $resourceType = "$(Get-WslMemberValue $resource 'type')"
        $resourceId = "$(Get-WslMemberValue $resource 'id')"
        Write-WinixEvent -Kind 'resource_change_started' -ResourceType $resourceType -ResourceId $resourceId -Data @{ operation_id = $id; action = $action; before = (Get-WslMemberValue $operationItem 'before'); after = (Get-WslMemberValue $operationItem 'after') }
        & $Mutate $operationItem $observedBefore

        $observedAfter = & $GetState
        if (-not (Test-WslSystemPostcondition -OperationItem $operationItem -ObservedState $observedAfter)) {
            $diagnostic = @{ severity = 'error'; code = 'wsl.postcondition.failed'; path = $Request.path; message = "Planned WSL operation '$id' did not reach its declared postcondition."; data = @{ operation_id = $id; observed = $observedAfter; applied_operation_ids = @($applied) } }
            Write-WinixEvent -Kind 'diagnostic' -ResourceType $resourceType -ResourceId $resourceId -Diagnostic $diagnostic
            return @{ protocol_version = 2; success = $false; changed = $true; operations = $planned; applied_operation_ids = $applied; diagnostics = @($diagnostic); error = @{ code = 'wsl.apply.postcondition_failed'; message = $diagnostic.message }; restart_required = @{ explorer = $false; system = ($action -in @('install', 'uninstall')) } }
        }
        $applied.Add($id)
        Write-WinixEvent -Kind 'resource_change_completed' -ResourceType $resourceType -ResourceId $resourceId -Data @{ operation_id = $id; changed = $true }
    }

    return @{ protocol_version = 2; success = $true; changed = ($applied.Count -gt 0); operations = $planned; applied_operation_ids = $applied; diagnostics = @(); restart_required = @{ explorer = $false; system = (@($planned | Where-Object { "$(Get-WslMemberValue $_ 'action')" -in @('enable_features', 'uninstall') }).Count -gt 0) } }
}

function Invoke-WslUserApply {
    param(
        [Parameter(Mandatory)] [object] $Request,
        [Parameter(Mandatory)] [scriptblock] $GetState,
        [Parameter(Mandatory)] [scriptblock] $Mutate
    )

    if (-not (Test-WslMemberPresent $Request 'operations')) { throw 'Apply request is missing its planned operations.' }
    $planned = @((Get-WslMemberValue $Request 'operations'))
    Assert-WslUniqueOperations -Operations $planned
    if ($planned.Count -gt 1) { throw 'The WSL first-run OOBE queue contains duplicate operations.' }

    $observedBefore = if ($planned.Count -eq 0) { $null } else { & $GetState }
    foreach ($operationItem in $planned) {
        $id = "$(Get-WslMemberValue $operationItem 'id')"
        $resource = Get-WslMemberValue $operationItem 'resource'
        if ($id -cne 'wsl.user.suppress-first-run-oobe' -or
            "$(Get-WslMemberValue $operationItem 'action')" -cne 'suppress_first_run_oobe' -or
            "$(Get-WslMemberValue $resource 'type')" -cne 'windows.wsl.first_run_oobe' -or
            "$(Get-WslMemberValue $resource 'id')" -cne 'current-user') {
            throw "Unsupported planned WSL operation '$id'."
        }
        Assert-WslJsonEqual -Actual (Get-WslMemberValue $operationItem 'before') -Expected $observedBefore -Message "Plan is stale for '$id': WSL first-run OOBE state changed after planning."
        if ($observedBefore -cne 'available') { throw "Plan is stale for '$id': WSL first-run OOBE is already suppressed." }
        if ((Get-WslMemberValue $operationItem 'after') -isnot [string] -or "$(Get-WslMemberValue $operationItem 'after')" -cne 'suppressed') {
            throw "Planned operation '$id' has an unsupported postcondition."
        }
        Assert-WslExactProperties -Value (Get-WslMemberValue $operationItem 'data') -Names @() -Label "Planned operation '$id' data"
    }

    $applied = [System.Collections.Generic.List[string]]::new()
    foreach ($operationItem in $planned) {
        $id = "$(Get-WslMemberValue $operationItem 'id')"
        $resource = Get-WslMemberValue $operationItem 'resource'
        $resourceType = "$(Get-WslMemberValue $resource 'type')"
        $resourceId = "$(Get-WslMemberValue $resource 'id')"
        Write-WinixEvent -Kind 'resource_change_started' -ResourceType $resourceType -ResourceId $resourceId -Data @{ operation_id = $id; action = 'suppress_first_run_oobe'; before = (Get-WslMemberValue $operationItem 'before'); after = 'suppressed' }
        & $Mutate
        $observedAfter = & $GetState
        if ($observedAfter -cne 'suppressed') {
            $diagnostic = @{ severity = 'error'; code = 'wsl.first_run_oobe.postcondition.failed'; path = "$($Request.path).first_run_oobe"; message = 'Windows did not retain the requested WSL first-run OOBE state.'; data = @{ operation_id = $id; observed = $observedAfter; applied_operation_ids = @($applied) } }
            Write-WinixEvent -Kind 'diagnostic' -ResourceType $resourceType -ResourceId $resourceId -Diagnostic $diagnostic
            return @{ protocol_version = 2; success = $false; changed = $true; operations = $planned; applied_operation_ids = $applied; diagnostics = @($diagnostic); error = @{ code = 'wsl.apply.postcondition_failed'; message = $diagnostic.message }; restart_required = @{ explorer = $false; system = $false } }
        }
        $applied.Add($id)
        Write-WinixEvent -Kind 'resource_change_completed' -ResourceType $resourceType -ResourceId $resourceId -Data @{ operation_id = $id; changed = $true; observed = $observedAfter }
    }

    return @{ protocol_version = 2; success = $true; changed = ($applied.Count -gt 0); operations = $planned; applied_operation_ids = $applied; diagnostics = @(); error = $null; restart_required = @{ explorer = $false; system = $false } }
}

Export-ModuleMember -Function Invoke-WslSystemApply, Invoke-WslUserApply
