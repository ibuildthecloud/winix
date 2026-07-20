param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.PluginSdk.psm1') -Force
Import-Module Microsoft.WinGet.Client -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'backends\Native.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'backends\Pinget.psm1') -Force
$metadataBackend = if ($env:WINIX_WINGET_METADATA_BACKEND) { $env:WINIX_WINGET_METADATA_BACKEND.ToLowerInvariant() } else { 'native' }
if ($metadataBackend -notin @('native', 'pinget')) { throw "Unsupported WinGet metadata backend '$metadataBackend'." }
$metadataBackendFallback = $null
if ($Operation -ne 'apply' -and $metadataBackend -eq 'pinget') {
    try { Initialize-WinixPingetMetadataBackend }
    catch {
        $metadataBackendFallback = $_.Exception.Message
        $metadataBackend = 'native'
    }
}

function Invoke-WingetCapture([string[]] $Arguments) {
    $output = & winget @Arguments 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Format-WingetFailure([string] $Id, [string] $Action, [string[]] $Arguments, [int] $ExitCode, [string] $Output) {
    $hexExitCode = '0x{0:X8}' -f ([int64]$ExitCode -band 0xffffffffL)
    $command = 'winget ' + (($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
    $details = $Output.TrimEnd()
    if (-not $details) { $details = '<no output>' }
    return "winget $Action failed for $Id with exit code $ExitCode ($hexExitCode).`nCommand: $command`nOutput:`n$details"
}

function Invoke-WingetCommand([string] $Id, [string] $Action, [string[]] $Arguments) {
    $result = Invoke-WingetCapture -Arguments $Arguments
    if ($result.ExitCode -ne 0) { throw (Format-WingetFailure -Id $Id -Action $Action -Arguments $Arguments -ExitCode $result.ExitCode -Output $result.Output) }
}

function Test-WingetPackageNotInstalled([int] $ExitCode) {
    return $ExitCode -eq -1978335212 # 0x8A150014 APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND
}

function Get-WingetInstalled([string] $Id, [string] $Source, [string] $Scope) {
    $arguments = @('list', '--id', $Id, '--exact', '--details', '--scope', $Scope, '--disable-interactivity', '--accept-source-agreements')
    if ($Source) { $arguments += @('--source', $Source) }
    $result = Invoke-WingetCapture -Arguments $arguments
    if (Test-WingetPackageNotInstalled -ExitCode $result.ExitCode) { return [pscustomobject]@{ Installed = $false; Version = $null; Scope = $Scope } }
    if ($result.ExitCode -ne 0) { throw (Format-WingetFailure -Id $Id -Action 'list' -Arguments $arguments -ExitCode $result.ExitCode -Output $result.Output) }
    $match = [regex]::Match($result.Output, '(?m)^Version:\s*(?<version>[^\r\n]+)\s*$')
    if (-not $match.Success) { throw "winget list returned success for '$Id' at $Scope scope but its detailed output did not contain a Version field.`nOutput:`n$($result.Output.TrimEnd())" }
    return [pscustomobject]@{ Installed = $true; Version = $match.Groups['version'].Value.Trim(); Scope = $Scope }
}

function Get-WingetInstalledBatch([object[]] $Queries, [string] $Scope) {
    return @($Queries | ForEach-Object -Parallel {
        $query = $_
        $arguments = @('list', '--id', $query.Id, '--exact', '--details', '--scope', $using:Scope, '--disable-interactivity', '--accept-source-agreements')
        if ($query.Source) { $arguments += @('--source', $query.Source) }
        $output = & winget @arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        $match = [regex]::Match($output, '(?m)^Version:\s*(?<version>[^\r\n]+)\s*$')
        $notInstalled = $exitCode -eq -1978335212
        $succeeded = $exitCode -eq 0 -and $match.Success
        [pscustomobject]@{
            Id = $query.Id
            Installed = $succeeded
            Version = $(if ($succeeded) { $match.Groups['version'].Value.Trim() } else { $null })
            Scope = $using:Scope
            QuerySucceeded = ($succeeded -or $notInstalled)
            ExitCode = $exitCode
            Output = $output
            Arguments = $arguments
        }
    } -ThrottleLimit 8)
}

function Invoke-WingetShow([string] $Id, [string] $Source, [string] $Scope, [string] $Version) {
    $arguments = @('show', '--id', $Id, '--exact', '--disable-interactivity', '--accept-source-agreements')
    if ($Source) { $arguments += @('--source', $Source) }
    if ($Scope) { $arguments += @('--scope', $Scope) }
    if ($Version) { $arguments += @('--version', $Version) }
    return Invoke-WingetCapture -Arguments $arguments
}

function Get-WingetApplicableCandidate([string] $Id, [string] $Source, [string] $Scope, [string] $Version) {
    $result = Invoke-WingetShow -Id $Id -Source $Source -Scope $Scope -Version $Version
    if ($result.ExitCode -ne 0 -or $result.Output -match 'No applicable installer found') { return $null }
    $match = [regex]::Match($result.Output, '(?m)^Version:\s*(?<version>[^\r\n]+)\s*$')
    if (-not $match.Success) { return $null }
    return [pscustomobject]@{ Version = $match.Groups['version'].Value.Trim(); Scope = $Scope }
}

function Resolve-WingetApplicableCandidate([string] $Id, [string] $Source, [bool] $IsSystem, [string] $Version) {
    if ($IsSystem) {
        return Get-WingetApplicableCandidate -Id $Id -Source $Source -Scope 'machine' -Version $Version
    }
    $user = Get-WingetApplicableCandidate -Id $Id -Source $Source -Scope 'user' -Version $Version
    if ($null -ne $user) { return $user }
    $machine = Get-WingetApplicableCandidate -Id $Id -Source $Source -Scope 'machine' -Version $Version
    if ($null -ne $machine) { return [pscustomobject]@{ Version = $machine.Version; Scope = 'machine-only' } }
    $neutral = Get-WingetApplicableCandidate -Id $Id -Source $Source -Scope $null -Version $Version
    if ($null -ne $neutral) { return [pscustomobject]@{ Version = $neutral.Version; Scope = $null } }
    return $null
}

function Find-CatalogPackage([string] $Id, [string] $Source) {
    if ($metadataBackend -eq 'pinget') { return Find-WinixPingetCatalogPackage -Id $Id -Source $Source }
    return Find-WinixNativeCatalogPackage -Id $Id -Source $Source
}

function Resolve-VersionAction([object] $CatalogPackage, [string] $Current, [string] $Target, [string] $Source) {
    if ($metadataBackend -eq 'pinget') {
        $pinget = Resolve-WinixPingetVersionAction -CatalogPackage $CatalogPackage -Current $Current -Target $Target
        if ($pinget.Supported) { return $pinget.Action }
        $nativePackage = Find-WinixNativeCatalogPackage -Id $CatalogPackage.Id -Source $Source
        if ($null -eq $nativePackage) { return $null }
        return Resolve-WinixNativeVersionAction -CatalogPackage $nativePackage -Current $Current -Target $Target
    }
    return Resolve-WinixNativeVersionAction -CatalogPackage $CatalogPackage -Current $Current -Target $Target
}

function New-PackageOperation([string] $Id, [string] $Action, [object] $Before, [object] $After, [string] $Source, [string] $QueryScope, [string] $InstallScope, [string] $DependsOn) {
    $dependencies = [System.Collections.Generic.List[string]]::new()
    if ($DependsOn) { $dependencies.Add($DependsOn) }
    return [ordered]@{
        id = "winget.$QueryScope.$Action.$Id"
        action = $Action
        resource = @{ type = 'winget.package'; id = $Id }
        before = $Before
        after = $After
        data = @{ source = $Source; query_scope = $QueryScope; install_scope = $InstallScope; depends_on = $dependencies }
    }
}

function Test-PackageState([object] $Record, [object] $Expected) {
    return $Record.Installed -eq [bool]$Expected.installed -and (-not $Record.Installed -or $Record.Version -eq $Expected.version)
}

function Assert-WinGetResult([object] $Result, [string] $Action, [string] $Id) {
    if ($null -eq $Result) { throw "Microsoft.WinGet.Client returned no result for '$Action' of '$Id'." }
    if ($Result.Status.ToString() -ne 'Ok') {
        throw "Microsoft.WinGet.Client $Action failed for '$Id': status=$($Result.Status), installer_error=$($Result.InstallerErrorCode), extended_error=$($Result.ExtendedErrorCode), correlation_data=$($Result.CorrelationData)"
    }
}

$request = Read-WinixRequest
$diagnostics = [System.Collections.Generic.List[object]]::new()
if ($metadataBackendFallback) {
    $diagnostics.Add(@{ severity = 'warning'; code = 'winget.metadata_backend.fallback'; path = $request.path; message = "Pinget metadata is not available yet; this run is using the native WinGet metadata backend: $metadataBackendFallback" })
}
$isSystem = $request.context.scope -eq 'system'
$queryScope = if ($isSystem) { 'machine' } else { 'user' }

if ($Operation -eq 'validate') {
    $identities = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $request.configuration.PSObject.Properties) {
        if (-not $identities.Add($entry.Name)) {
            $diagnostics.Add(@{ severity = 'error'; code = 'winget.package_id.duplicate'; path = $entry.Name; message = 'Package IDs must also be unique when compared case-insensitively.' })
            continue
        }
        $source = if (Test-WinixPropertyPresent $entry.Value 'source') { $entry.Value.source } else { $null }
        try { $catalog = Find-CatalogPackage -Id $entry.Name -Source $source }
        catch {
            $catalog = $null
            $diagnostics.Add(@{ severity = 'error'; code = 'winget.catalog.failed'; path = "$($request.path).$($entry.Name)"; message = "WinGet could not query package '$($entry.Name)': $($_.Exception.Message)" })
        }
        if ($null -eq $catalog) {
            if (-not ($diagnostics | Where-Object { $_.path -eq "$($request.path).$($entry.Name)" })) { $diagnostics.Add(@{ severity = 'error'; code = 'winget.package_id.not_found'; path = "$($request.path).$($entry.Name)"; message = "WinGet could not resolve package ID '$($entry.Name)'." }) }
        } elseif ($catalog.Id -cne $entry.Name) {
            $diagnostics.Add(@{ severity = 'error'; code = 'winget.package_id.non_canonical'; path = "$($request.path).$($entry.Name)"; message = "Package ID '$($entry.Name)' is not canonical; use '$($catalog.Id)'."; help = "Use $($catalog.Id)." })
        }
    }
    Write-WinixResponse @{ protocol_version = 2; valid = ($diagnostics.Count -eq 0); diagnostics = $diagnostics }
    exit
}

if ($Operation -eq 'apply') {
    $isAdministrator = Test-WinixAdministrator
    if (-not $isSystem -and $isAdministrator) { throw 'User WinGet configuration cannot run with an elevated token.' }
    if ($isSystem -and -not $isAdministrator) { throw 'System WinGet configuration requires an elevated token.' }
    if (-not (Test-WinixPropertyPresent $request 'operations')) { throw 'Apply request is missing its planned operations.' }
    $planned = @($request.operations)
    foreach ($operationItem in $planned) {
        $packageId = $operationItem.resource.id
        if ($operationItem.resource.type -ne 'winget.package' -or $operationItem.action -notin @('install', 'uninstall', 'upgrade', 'downgrade')) { throw "Unsupported planned operation '$($operationItem.id)'." }
        if (-not (Test-WinixPropertyPresent $request.configuration $packageId)) { throw "Planned package '$packageId' is not present in configuration." }
        $current = Get-WingetInstalled -Id $packageId -Source $operationItem.data.source -Scope $operationItem.data.query_scope
        if (-not (Test-PackageState -Record $current -Expected $operationItem.before)) { throw "Plan is stale for '$($operationItem.id)': installed state changed after planning." }
        $scopeMigrationDependencies = @($operationItem.data.depends_on | Where-Object { $_ -like 'winget.*' })
        if ($scopeMigrationDependencies.Count -gt 0) {
            $otherScope = if ($operationItem.data.query_scope -eq 'user') { 'machine' } else { 'user' }
            $other = Get-WingetInstalled -Id $packageId -Source $operationItem.data.source -Scope $otherScope
            if ($other.Installed) { throw "Plan prerequisite for '$($operationItem.id)' has not been applied: '$packageId' is still installed at $otherScope scope." }
        }
    }

    $applied = [System.Collections.Generic.List[string]]::new()
    foreach ($operationItem in $planned) {
        $packageId = $operationItem.resource.id
        Write-WinixEvent -Kind 'resource_change_started' -ResourceType 'winget.package' -ResourceId $packageId -Data @{ operation_id = $operationItem.id; action = $operationItem.action; before = $operationItem.before; after = $operationItem.after }
        try {
            if ($operationItem.action -eq 'uninstall') {
                $arguments = @('uninstall', '--id', $packageId, '--exact', '--scope', $operationItem.data.query_scope, '--disable-interactivity', '--accept-source-agreements')
                if ($operationItem.data.source) { $arguments += @('--source', $operationItem.data.source) }
                Invoke-WingetCommand -Id $packageId -Action 'uninstall' -Arguments $arguments
                $result = $null
            } elseif ($operationItem.action -eq 'install') {
                $catalog = Find-WinixNativeCatalogPackage -Id $packageId -Source $operationItem.data.source
                $parameters = @{ PSCatalogPackage = $catalog; Version = $operationItem.after.version; Mode = 'Silent'; Force = $true; Confirm = $false; ErrorAction = 'Stop' }
                if ($operationItem.data.install_scope -eq 'user') { $parameters.Scope = 'User' }
                elseif ($operationItem.data.install_scope -eq 'machine') { $parameters.Scope = 'System' }
                $result = Install-WinGetPackage @parameters
            } else {
                $catalog = Find-WinixNativeCatalogPackage -Id $packageId -Source $operationItem.data.source
                $parameters = @{ PSCatalogPackage = $catalog; Version = $operationItem.after.version; Mode = 'Silent'; Force = $true; Confirm = $false; ErrorAction = 'Stop' }
                if ($operationItem.data.install_scope -eq 'user') { $parameters.Scope = 'User' }
                elseif ($operationItem.data.install_scope -eq 'machine') { $parameters.Scope = 'System' }
                $result = Update-WinGetPackage @parameters
            }
            if ($operationItem.action -ne 'uninstall') { Assert-WinGetResult -Result $result -Action $operationItem.action -Id $packageId }
        } catch {
            $diagnostic = @{ severity = 'error'; code = 'winget.operation.failed'; path = $packageId; message = $_.Exception.Message; data = @{ operation_id = $operationItem.id; applied_operation_ids = @($applied) } }
            Write-WinixEvent -Kind 'diagnostic' -ResourceType 'winget.package' -ResourceId $packageId -Diagnostic $diagnostic
            Write-WinixResponse @{ protocol_version = 2; success = $false; changed = ($applied.Count -gt 0); operations = $planned; applied_operation_ids = $applied; diagnostics = @($diagnostic); error = @{ code = 'winget.apply.failed'; message = "Planned WinGet operation '$($operationItem.id)' failed." }; restart_required = @{ explorer = $false; system = $false } }
            exit
        }
        $observed = Get-WingetInstalled -Id $packageId -Source $operationItem.data.source -Scope $operationItem.data.query_scope
        if (-not (Test-PackageState -Record $observed -Expected $operationItem.after)) {
            $diagnostic = @{ severity = 'error'; code = 'winget.package.postcondition.not_satisfied'; path = "$($request.path).$packageId"; message = "Package '$packageId' completed '$($operationItem.action)' but the declared postcondition was not satisfied at $($operationItem.data.query_scope) scope."; help = 'Review the WinGet result and registered package state before retrying.'; data = @{ operation_id = $operationItem.id; expected = $operationItem.after; observed = @{ installed = $observed.Installed; version = $observed.Version; scope = $observed.Scope }; applied_operation_ids = @($applied) } }
            Write-WinixEvent -Kind 'diagnostic' -ResourceType 'winget.package' -ResourceId $packageId -Diagnostic $diagnostic
            Write-WinixResponse @{ protocol_version = 2; success = $false; changed = $true; operations = $planned; applied_operation_ids = $applied; diagnostics = @($diagnostic); error = @{ code = 'winget.apply.postcondition_failed'; message = "Planned WinGet operation '$($operationItem.id)' did not reach its declared postcondition." }; restart_required = @{ explorer = $false; system = $false } }
            exit
        }
        $applied.Add($operationItem.id)
        Write-WinixEvent -Kind 'resource_change_completed' -ResourceType 'winget.package' -ResourceId $packageId -Data @{ operation_id = $operationItem.id; changed = $true; verified_scope = $operationItem.data.query_scope; observed_version = $observed.Version }
    }
    Write-WinixResponse @{ protocol_version = 2; success = $true; changed = ($applied.Count -gt 0); operations = $planned; applied_operation_ids = $applied; diagnostics = @(); restart_required = @{ explorer = $false; system = $false } }
    exit
}

$identities = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$queries = @($request.configuration.PSObject.Properties | ForEach-Object {
    [pscustomobject]@{
        Id = $_.Name
        Source = $(if (Test-WinixPropertyPresent $_.Value 'source') { $_.Value.source } else { $null })
    }
})
$installedById = @{}
foreach ($record in @(Get-WingetInstalledBatch -Queries $queries -Scope $queryScope)) {
    $installedById[$record.Id] = $record
    if (-not $record.QuerySucceeded) {
        $diagnostics.Add(@{ severity = 'error'; code = 'winget.installed_query.failed'; path = "$($request.path).$($record.Id)"; message = (Format-WingetFailure -Id $record.Id -Action 'list' -Arguments $record.Arguments -ExitCode $record.ExitCode -Output $record.Output) })
    }
}
$state = [ordered]@{}
$operations = [System.Collections.Generic.List[object]]::new()
foreach ($entry in $request.configuration.PSObject.Properties) {
    $package = $entry.Value
    $packageId = $entry.Name
    $source = if (Test-WinixPropertyPresent $package 'source') { $package.source } else { $null }
    $desired = if (Test-WinixPropertyPresent $package 'state') { $package.state } else { 'installed' }
    if (-not $identities.Add($packageId)) {
        $diagnostics.Add(@{ severity = 'error'; code = 'winget.package_id.duplicate'; path = "$($request.path).$packageId"; message = 'Package IDs must also be unique when compared case-insensitively.' })
        continue
    }

    try { $catalog = Find-CatalogPackage -Id $packageId -Source $source }
    catch {
        $catalog = $null
        $diagnostics.Add(@{ severity = 'error'; code = 'winget.catalog.failed'; path = "$($request.path).$packageId"; message = "WinGet could not query package '$packageId': $($_.Exception.Message)" })
    }
    if ($null -eq $catalog) {
        if (-not ($diagnostics | Where-Object { $_.path -eq "$($request.path).$packageId" })) { $diagnostics.Add(@{ severity = 'error'; code = 'winget.package_id.not_found'; path = "$($request.path).$packageId"; message = "WinGet could not resolve package ID '$packageId'." }) }
        continue
    }
    if ($catalog.Id -cne $packageId) {
        $diagnostics.Add(@{ severity = 'error'; code = 'winget.package_id.non_canonical'; path = "$($request.path).$packageId"; message = "Package ID '$packageId' is not canonical; use '$($catalog.Id)'."; help = "Use $($catalog.Id)." })
        continue
    }

    $installed = $installedById[$packageId]
    if (-not $installed.QuerySucceeded) { continue }
    $state[$packageId] = @{ id = $packageId; installed = $installed.Installed; version = $installed.Version; scope = $queryScope }

    if ($desired -eq 'absent') {
        if ($installed.Installed) { $operations.Add((New-PackageOperation -Id $packageId -Action 'uninstall' -Before @{ installed = $true; version = $installed.Version } -After @{ installed = $false; version = $null } -Source $source -QueryScope $queryScope -InstallScope $null)) }
        continue
    }

    $dependsOn = $null
    if (-not $installed.Installed) {
        $otherScope = if ($isSystem) { 'user' } else { 'machine' }
        $other = Get-WingetInstalled -Id $packageId -Source $source -Scope $otherScope
        if ($other.Installed) {
            $prior = @($request.context.prior_operations | Where-Object { $_.resource.type -eq 'winget.package' -and $_.resource.id -eq $packageId -and $_.action -eq 'uninstall' -and $_.data.query_scope -eq $otherScope })
            if ($prior.Count -eq 1) { $dependsOn = $prior[0].id }
            else {
                $diagnostics.Add(@{ severity = 'error'; code = 'winget.package.scope_conflict'; path = "$($request.path).$packageId"; message = "Package '$packageId' is installed at $otherScope scope, but this configuration requires $queryScope scope." })
                continue
            }
        }
    }

    $versionPolicy = if (Test-WinixPropertyPresent $package 'version') { $package.version } else { $null }
    if ($installed.Installed -and -not $versionPolicy) { continue }
    if ($installed.Installed -and $versionPolicy -and $versionPolicy -ne 'latest' -and $installed.Version -eq $versionPolicy) { continue }
    $requestedVersion = if ($versionPolicy -and $versionPolicy -ne 'latest') { $versionPolicy } else { $null }
    $candidate = Resolve-WingetApplicableCandidate -Id $packageId -Source $source -IsSystem $isSystem -Version $requestedVersion
    if ($null -eq $candidate) {
        $diagnostics.Add(@{ severity = 'error'; code = 'winget.package.version_unavailable'; path = "$($request.path).$packageId"; message = "WinGet could not find an applicable installer for '$packageId'$(if ($requestedVersion) { " version '$requestedVersion'" })." })
        continue
    }
    if ($candidate.Scope -eq 'machine-only') {
        $diagnostics.Add(@{ severity = 'error'; code = 'winget.package.requires_machine_scope'; path = "$($request.path).$packageId"; message = "Package '$packageId' requires machine scope for this version."; help = "Move '$packageId' to system.packages.winget."; data = @{ reason = 'WinGet found no applicable user-scope installer.'; version = $candidate.Version } })
        continue
    }
    if (-not $installed.Installed) {
        $operations.Add((New-PackageOperation -Id $packageId -Action 'install' -Before @{ installed = $false; version = $null } -After @{ installed = $true; version = $candidate.Version } -Source $source -QueryScope $queryScope -InstallScope $candidate.Scope -DependsOn $dependsOn))
        continue
    }
    if ($installed.Version -eq $candidate.Version) { continue }
    $action = Resolve-VersionAction -CatalogPackage $catalog -Current $installed.Version -Target $candidate.Version -Source $source
    if (-not $action) {
        $diagnostics.Add(@{ severity = 'error'; code = 'winget.package.version_order_unknown'; path = "$($request.path).$packageId"; message = "WinGet could not deterministically order installed version '$($installed.Version)' and target version '$($candidate.Version)' for '$packageId'." })
        continue
    }
    if ($versionPolicy -eq 'latest' -and $action -eq 'downgrade') {
        $diagnostics.Add(@{ severity = 'warning'; code = 'winget.package.installed_newer_than_catalog'; path = "$($request.path).$packageId"; message = "Installed version '$($installed.Version)' of '$packageId' is newer than catalog version '$($candidate.Version)'; no downgrade was planned for the latest policy." })
        continue
    }
    $operations.Add((New-PackageOperation -Id $packageId -Action $action -Before @{ installed = $true; version = $installed.Version } -After @{ installed = $true; version = $candidate.Version } -Source $source -QueryScope $queryScope -InstallScope $candidate.Scope))
}

$success = -not ($diagnostics | Where-Object { $_.severity -eq 'error' })
foreach ($operationItem in $operations) { Write-WinixEvent -Kind 'resource_status' -ResourceType 'winget.package' -ResourceId $operationItem.resource.id -Data @{ status = 'change_required'; operation = $operationItem } }
Write-WinixResponse @{ protocol_version = 2; success = $success; changed = $false; state = $state; operations = $operations; diagnostics = $diagnostics; error = $(if ($success) { $null } else { @{ code = 'winget.plan.failed'; message = 'WinGet could not produce a complete deterministic plan.' } }); restart_required = @{ explorer = $false; system = $false } }
