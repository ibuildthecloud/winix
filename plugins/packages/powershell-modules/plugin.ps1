param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.PluginSdk.psm1') -Force
Import-Module Microsoft.PowerShell.PSResourceGet -ErrorAction Stop

function Get-ModuleVersions([string] $Name, [string] $Scope) {
    return @(
        Get-InstalledPSResource -Name $Name -Scope $Scope -ErrorAction SilentlyContinue |
            Where-Object { $_.Type -eq 'Module' -and $_.Name -ceq $Name } |
            ForEach-Object { $_.Version.ToString() } |
            Sort-Object -Unique
    )
}

function Find-ModuleCandidate([string] $Name, [string] $Version, [string] $Repository, [bool] $Prerelease) {
    $parameters = @{ Name = $Name; Type = 'Module'; ErrorAction = 'Stop' }
    if ($Version -and $Version -ne 'latest') { $parameters.Version = $Version }
    if ($Repository) { $parameters.Repository = $Repository }
    if ($Prerelease) { $parameters.Prerelease = $true }
    $matchingResources = @(Find-PSResource @parameters | Where-Object { $_.Type -eq 'Module' })
    if ($matchingResources.Count -eq 0) { return $null }
    $candidate = $matchingResources[0]
    return [pscustomobject]@{
        Name = $candidate.Name
        Version = $candidate.Version.ToString()
        Repository = $candidate.Repository
    }
}

function Compare-ModuleVersion([string] $Left, [string] $Right) {
    try {
        return ([System.Management.Automation.SemanticVersion]$Left).CompareTo(
            [System.Management.Automation.SemanticVersion]$Right
        )
    } catch {
        return [string]::Compare($Left, $Right, [System.StringComparison]::OrdinalIgnoreCase)
    }
}

function Get-HighestModuleVersion([object[]] $Versions) {
    $highest = $null
    foreach ($version in $Versions) {
        if ($null -eq $highest -or (Compare-ModuleVersion -Left "$version" -Right "$highest") -gt 0) {
            $highest = "$version"
        }
    }
    return $highest
}

function Test-VersionSetsEqual([object[]] $Left, [object[]] $Right) {
    $leftValues = @($Left | ForEach-Object { "$_" } | Sort-Object -Unique)
    $rightValues = @($Right | ForEach-Object { "$_" } | Sort-Object -Unique)
    if ($leftValues.Count -ne $rightValues.Count) { return $false }
    for ($index = 0; $index -lt $leftValues.Count; $index++) {
        if ($leftValues[$index] -ne $rightValues[$index]) { return $false }
    }
    return $true
}

function New-ModuleOperation(
    [string] $Name,
    [string] $Action,
    [object[]] $Before,
    [object[]] $After,
    [string] $Scope,
    [string] $Repository,
    [string] $TargetVersion,
    [bool] $Prerelease
) {
    return [ordered]@{
        id = "powershell_modules.$($Scope.ToLowerInvariant()).$Action.$Name"
        action = $Action
        resource = @{ type = 'powershell.module'; id = $Name }
        before = @{ installed = ($Before.Count -gt 0); versions = @($Before) }
        after = @{ installed = ($After.Count -gt 0); versions = @($After) }
        data = @{
            scope = $Scope
            repository = $Repository
            target_version = $TargetVersion
            prerelease = $Prerelease
            depends_on = @()
        }
    }
}

$request = Read-WinixRequest
$isSystem = $request.context.scope -eq 'system'
$scope = if ($isSystem) { 'AllUsers' } else { 'CurrentUser' }
$diagnostics = [System.Collections.Generic.List[object]]::new()

if ($Operation -in @('validate', 'plan')) {
    $identities = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $request.configuration.PSObject.Properties) {
        if (-not $identities.Add($entry.Name)) {
            $diagnostics.Add(@{
                severity = 'error'
                code = 'powershell_module.name.duplicate'
                path = $entry.Name
                message = 'Module names must also be unique when compared case-insensitively.'
            })
        }
    }
    if ($Operation -eq 'validate') {
        Write-WinixResponse @{ protocol_version = 2; valid = ($diagnostics.Count -eq 0); diagnostics = $diagnostics }
        exit
    }
}

if ($Operation -eq 'apply') {
    $isAdministrator = Test-WinixAdministrator
    if ($isSystem -and -not $isAdministrator) { throw 'System PowerShell module configuration requires an elevated token.' }
    if (-not $isSystem -and $isAdministrator) { throw 'User PowerShell module configuration cannot run with an elevated token.' }
    if (-not (Test-WinixPropertyPresent $request 'operations')) { throw 'Apply request is missing its planned operations.' }
    $planned = @($request.operations)

    foreach ($operationItem in $planned) {
        $moduleName = $operationItem.resource.id
        if ($operationItem.resource.type -ne 'powershell.module' -or $operationItem.action -notin @('install', 'upgrade', 'downgrade', 'uninstall')) {
            throw "Unsupported planned operation '$($operationItem.id)'."
        }
        if ($operationItem.data.scope -ne $scope) { throw "Planned scope for '$($operationItem.id)' does not match the execution scope." }
        if (-not (Test-WinixPropertyPresent $request.configuration $moduleName)) { throw "Planned module '$moduleName' is not present in configuration." }
        $current = @(Get-ModuleVersions -Name $moduleName -Scope $scope)
        if (-not (Test-VersionSetsEqual -Left $current -Right @($operationItem.before.versions))) {
            throw "Plan is stale for '$($operationItem.id)': installed module versions changed after planning."
        }
    }

    $applied = [System.Collections.Generic.List[string]]::new()
    foreach ($operationItem in $planned) {
        $moduleName = $operationItem.resource.id
        Write-WinixEvent -Kind 'resource_change_started' -ResourceType 'powershell.module' -ResourceId $moduleName -Data @{ operation_id = $operationItem.id; action = $operationItem.action; before = $operationItem.before; after = $operationItem.after }
        try {
            if ($operationItem.action -eq 'uninstall') {
                foreach ($version in @($operationItem.before.versions)) {
                    Uninstall-PSResource -Name $moduleName -Version $version -Scope $scope -Confirm:$false -ErrorAction Stop
                }
            } else {
                $parameters = @{
                    Name = $moduleName
                    Version = $operationItem.data.target_version
                    Scope = $scope
                    TrustRepository = $true
                    AcceptLicense = $true
                    Quiet = $true
                    ErrorAction = 'Stop'
                }
                if ($operationItem.data.repository) { $parameters.Repository = $operationItem.data.repository }
                if ([bool]$operationItem.data.prerelease) { $parameters.Prerelease = $true }
                Install-PSResource @parameters
            }
        } catch {
            $diagnostic = @{ severity = 'error'; code = 'powershell_module.operation.failed'; path = $moduleName; message = $_.Exception.Message; data = @{ operation_id = $operationItem.id; applied_operation_ids = @($applied) } }
            Write-WinixEvent -Kind 'diagnostic' -ResourceType 'powershell.module' -ResourceId $moduleName -Diagnostic $diagnostic
            Write-WinixResponse @{ protocol_version = 2; success = $false; changed = ($applied.Count -gt 0); operations = $planned; applied_operation_ids = $applied; diagnostics = @($diagnostic); error = @{ code = 'powershell_module.apply.failed'; message = "Planned PowerShell module operation '$($operationItem.id)' failed." }; restart_required = @{ explorer = $false; system = $false } }
            exit
        }
        $observed = @(Get-ModuleVersions -Name $moduleName -Scope $scope)
        if (-not (Test-VersionSetsEqual -Left $observed -Right @($operationItem.after.versions))) {
            $diagnostic = @{ severity = 'error'; code = 'powershell_module.postcondition.not_satisfied'; path = $moduleName; message = "Module '$moduleName' completed '$($operationItem.action)' but installed versions do not match the planned postcondition."; data = @{ operation_id = $operationItem.id; expected_versions = @($operationItem.after.versions); observed_versions = $observed; applied_operation_ids = @($applied) } }
            Write-WinixEvent -Kind 'diagnostic' -ResourceType 'powershell.module' -ResourceId $moduleName -Diagnostic $diagnostic
            Write-WinixResponse @{ protocol_version = 2; success = $false; changed = $true; operations = $planned; applied_operation_ids = $applied; diagnostics = @($diagnostic); error = @{ code = 'powershell_module.apply.postcondition_failed'; message = "Planned PowerShell module operation '$($operationItem.id)' did not reach its declared postcondition." }; restart_required = @{ explorer = $false; system = $false } }
            exit
        }
        $applied.Add($operationItem.id)
        Write-WinixEvent -Kind 'resource_change_completed' -ResourceType 'powershell.module' -ResourceId $moduleName -Data @{ operation_id = $operationItem.id; changed = $true; observed_versions = $observed }
    }
    Write-WinixResponse @{ protocol_version = 2; success = $true; changed = ($applied.Count -gt 0); operations = $planned; applied_operation_ids = $applied; diagnostics = @(); restart_required = @{ explorer = $false; system = $false } }
    exit
}

$state = [ordered]@{}
$operations = [System.Collections.Generic.List[object]]::new()
foreach ($entry in $request.configuration.PSObject.Properties) {
    $moduleName = $entry.Name
    $module = $entry.Value
    $desired = if (Test-WinixPropertyPresent $module 'state') { $module.state } else { 'installed' }
    $versionPolicy = if (Test-WinixPropertyPresent $module 'version') { $module.version } else { $null }
    $repository = if (Test-WinixPropertyPresent $module 'repository') { $module.repository } else { $null }
    $prerelease = if (Test-WinixPropertyPresent $module 'prerelease') { [bool]$module.prerelease } else { $false }
    $installed = @(Get-ModuleVersions -Name $moduleName -Scope $scope)
    $state[$moduleName] = @{ name = $moduleName; installed = ($installed.Count -gt 0); versions = $installed; scope = $scope }

    if ($desired -eq 'absent') {
        if ($installed.Count -gt 0) {
            $operations.Add((New-ModuleOperation -Name $moduleName -Action 'uninstall' -Before $installed -After @() -Scope $scope -Repository $repository -TargetVersion $null -Prerelease $prerelease))
        }
        continue
    }
    if ($installed.Count -gt 0 -and -not $versionPolicy) { continue }

    try {
        $candidate = Find-ModuleCandidate -Name $moduleName -Version $versionPolicy -Repository $repository -Prerelease $prerelease
    } catch {
        $candidate = $null
        $diagnostics.Add(@{ severity = 'error'; code = 'powershell_module.catalog.failed'; path = "$($request.path).$moduleName"; message = "PowerShell could not query module '$moduleName': $($_.Exception.Message)" })
    }
    if ($null -eq $candidate) {
        if (-not ($diagnostics | Where-Object { $_.path -eq "$($request.path).$moduleName" })) {
            $diagnostics.Add(@{ severity = 'error'; code = 'powershell_module.version_unavailable'; path = "$($request.path).$moduleName"; message = "PowerShell could not find module '$moduleName'$(if ($versionPolicy -and $versionPolicy -ne 'latest') { " version '$versionPolicy'" }) in the requested repository." })
        }
        continue
    }
    if ($candidate.Name -cne $moduleName) {
        $diagnostics.Add(@{ severity = 'error'; code = 'powershell_module.name.non_canonical'; path = "$($request.path).$moduleName"; message = "Module name '$moduleName' is not canonical; use '$($candidate.Name)'."; help = "Use $($candidate.Name)." })
        continue
    }
    if ($installed -contains $candidate.Version) { continue }

    $action = 'install'
    if ($installed.Count -gt 0) {
        $highestInstalled = Get-HighestModuleVersion -Versions $installed
        $comparison = Compare-ModuleVersion -Left $candidate.Version -Right $highestInstalled
        if ($versionPolicy -eq 'latest' -and $comparison -lt 0) {
            $diagnostics.Add(@{ severity = 'warning'; code = 'powershell_module.installed_newer_than_repository'; path = "$($request.path).$moduleName"; message = "Installed version '$highestInstalled' of '$moduleName' is newer than repository version '$($candidate.Version)'; no downgrade was planned for the latest policy." })
            continue
        }
        $action = if ($comparison -ge 0) { 'upgrade' } else { 'downgrade' }
    }
    $after = @($installed + $candidate.Version | Sort-Object -Unique)
    $operations.Add((New-ModuleOperation -Name $moduleName -Action $action -Before $installed -After $after -Scope $scope -Repository $(if ($repository) { $repository } else { $candidate.Repository }) -TargetVersion $candidate.Version -Prerelease $prerelease))
}

$success = -not ($diagnostics | Where-Object { $_.severity -eq 'error' })
foreach ($operationItem in $operations) {
    Write-WinixEvent -Kind 'resource_status' -ResourceType 'powershell.module' -ResourceId $operationItem.resource.id -Data @{ status = 'change_required'; operation = $operationItem }
}
Write-WinixResponse @{
    protocol_version = 2
    success = $success
    changed = $false
    state = $state
    operations = $operations
    diagnostics = $diagnostics
    error = $(if ($success) { $null } else { @{ code = 'powershell_module.plan.failed'; message = 'PowerShell module provider could not produce a complete deterministic plan.' } })
    restart_required = @{ explorer = $false; system = $false }
}
