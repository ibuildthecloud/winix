param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\..\shared\Winix.PluginSdk.psm1') -Force

$RestartReceiptRoot = Join-Path $env:ProgramData 'Winix\windows-optional-features\restart-receipts'
$script:Catalogs = @{}

function Get-BootTicks {
    return (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().Ticks
}

function Get-ResourceDigest([string] $Provider, [string] $Name) {
    $bytes = [Text.Encoding]::UTF8.GetBytes("$Provider`n$Name")
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Get-RestartReceiptPath([string] $Provider, [string] $Name) {
    return Join-Path $RestartReceiptRoot "$(Get-ResourceDigest -Provider $Provider -Name $Name).json"
}

function Test-RestartReceiptPending([string] $Provider, [string] $Name, [string] $DesiredState) {
    $path = Get-RestartReceiptPath -Provider $Provider -Name $Name
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try {
        $receipt = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        return "$($receipt.provider)" -ceq $Provider -and
            "$($receipt.name)" -ceq $Name -and
            "$($receipt.state)" -ceq $DesiredState -and
            [long]$receipt.boot_ticks -eq (Get-BootTicks)
    } catch {
        # A receipt is written only after a successful servicing command. If it
        # cannot be interpreted, conservatively require a restart.
        return $true
    }
}

function Write-RestartReceipt([string] $Provider, [string] $Name, [string] $DesiredState) {
    New-Item -ItemType Directory -Path $RestartReceiptRoot -Force | Out-Null
    $receipt = [ordered]@{
        provider = $Provider
        name = $Name
        state = $DesiredState
        boot_ticks = Get-BootTicks
    }
    $receipt | ConvertTo-Json -Compress | Set-Content -LiteralPath (Get-RestartReceiptPath -Provider $Provider -Name $Name) -Encoding utf8NoBOM
}

function Invoke-WindowsPowerShellJson([string] $Script, [hashtable] $Environment = @{}) {
    # The inbox DISM module is a Windows PowerShell module. On some Windows 11
    # installations its CDXML servicing class is not registered for pwsh, so
    # invoke it in its native host and capture all output away from NDJSON.
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'powershell.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded)) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    foreach ($entry in $Environment.GetEnumerator()) {
        $startInfo.Environment[$entry.Key] = "$($entry.Value)"
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Windows PowerShell could not be started.' }
        $process.StandardInput.Close()
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $standardError = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output = $standardOutput.GetAwaiter().GetResult().Trim()
        $errorOutput = $standardError.GetAwaiter().GetResult().Trim()
        if ($process.ExitCode -ne 0) {
            $detail = if ($errorOutput) { ": $errorOutput" } else { '' }
            throw "Windows PowerShell servicing command failed with exit code $($process.ExitCode)$detail."
        }
        if ([string]::IsNullOrWhiteSpace($output)) { throw 'Windows PowerShell servicing command returned no JSON.' }
        return $output | ConvertFrom-Json -Depth 20
    } finally {
        $process.Dispose()
    }
}

function Get-ProviderCatalog([ValidateSet('capability', 'feature')] [string] $Provider) {
    if ($script:Catalogs.ContainsKey($Provider)) { return $script:Catalogs[$Provider] }
    $catalogScript = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
Import-Module Dism -ErrorAction Stop
$items = if ($env:WINIX_OPTIONAL_FEATURE_PROVIDER -eq 'capability') {
    @(Get-WindowsCapability -Online -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{ Name = "$($_.Name)"; State = "$($_.State)" }
    })
} else {
    @(Get-WindowsOptionalFeature -Online -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{ Name = "$($_.FeatureName)"; State = "$($_.State)" }
    })
}
[Console]::Out.Write((ConvertTo-Json -InputObject @($items) -Depth 5 -Compress))
'@
    $items = @(Invoke-WindowsPowerShellJson -Script $catalogScript -Environment @{ WINIX_OPTIONAL_FEATURE_PROVIDER = $Provider })
    $catalog = [ordered]@{}
    foreach ($item in $items) {
        $name = "$($item.Name)"
        if (-not [string]::IsNullOrWhiteSpace($name)) { $catalog[$name] = $item }
    }
    $script:Catalogs[$Provider] = $catalog
    return $catalog
}

function Resolve-Resource([string] $Provider, [string] $Name) {
    $catalog = Get-ProviderCatalog -Provider $Provider
    $exact = @($catalog.Keys | Where-Object { $_ -ieq $Name })
    if ($exact.Count -eq 1) {
        $canonical = "$($exact[0])"
        return [pscustomobject]@{ Name = $canonical; Item = $catalog[$canonical]; Shorthand = $false; Ambiguous = $false; Matches = @($canonical) }
    }
    if ($Provider -eq 'capability' -and -not $Name.Contains('~')) {
        $prefix = "$Name~"
        $matchingCapabilities = @($catalog.Keys | Where-Object { "$($_)".StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
        if ($matchingCapabilities.Count -eq 1) {
            $canonical = "$($matchingCapabilities[0])"
            return [pscustomobject]@{ Name = $canonical; Item = $catalog[$canonical]; Shorthand = $true; Ambiguous = $false; Matches = @($canonical) }
        }
        if ($matchingCapabilities.Count -gt 1) {
            return [pscustomobject]@{ Name = $null; Item = $null; Shorthand = $true; Ambiguous = $true; Matches = @($matchingCapabilities | ForEach-Object { "$_" } | Sort-Object) }
        }
    }
    return $null
}

function ConvertTo-OptionalFeatureState([string] $Provider, [string] $Name, [object] $Item) {
    $nativeState = "$($Item.State)"
    if ($Provider -eq 'capability') {
        $state = switch ($nativeState) {
            'Installed' { 'enabled' }
            'InstallPending' { 'enabled' }
            'NotPresent' { 'disabled' }
            'Staged' { 'disabled' }
            'UninstallPending' { 'disabled' }
            default { throw "Capability '$Name' has unsupported servicing state '$nativeState'." }
        }
        $nativePending = $nativeState -in @('InstallPending', 'UninstallPending')
    } else {
        $state = switch ($nativeState) {
            'Enabled' { 'enabled' }
            'EnablePending' { 'enabled' }
            'Disabled' { 'disabled' }
            'DisabledWithPayloadRemoved' { 'disabled' }
            'DisablePending' { 'disabled' }
            default { throw "Optional feature '$Name' has unsupported servicing state '$nativeState'." }
        }
        $nativePending = $nativeState -in @('EnablePending', 'DisablePending')
    }
    $receiptPending = Test-RestartReceiptPending -Provider $Provider -Name $Name -DesiredState $state
    return [ordered]@{
        provider = $Provider
        native_state = $nativeState
        state = $state
        restart_pending = ($nativePending -or $receiptPending)
    }
}

function Get-ResourceState([string] $Provider, [string] $Name) {
    $resolved = Resolve-Resource -Provider $Provider -Name $Name
    if ($null -eq $resolved) { return $null }
    return ConvertTo-OptionalFeatureState -Provider $Provider -Name $resolved.Name -Item $resolved.Item
}

function Get-DesiredResources([object] $Request, [System.Collections.Generic.List[object]] $Diagnostics) {
    $resources = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $Request.configuration.PSObject.Properties) {
        $name = $entry.Name
        $provider = "$($entry.Value.provider)"
        try {
            $resolved = Resolve-Resource -Provider $provider -Name $name
            if ($null -eq $resolved) {
                $Diagnostics.Add(@{ severity = 'error'; code = 'optional_features.resource.unknown'; path = "$($Request.path).$name"; message = "Windows $provider '$name' does not exist in the online servicing catalog." })
            } elseif ($resolved.Ambiguous) {
                $matchingCapabilities = @($resolved.Matches)
                $Diagnostics.Add(@{ severity = 'error'; code = 'optional_features.resource.ambiguous'; path = "$($Request.path).$name"; message = "Windows capability shorthand '$name' matches multiple catalog entries."; help = "Use one exact capability name: $($matchingCapabilities -join ', ')."; data = @{ matches = $matchingCapabilities } })
            } else {
                $canonicalConfigurationName = if ($resolved.Shorthand) { $resolved.Name.Substring(0, $resolved.Name.IndexOf('~')) } else { $resolved.Name }
                if ($canonicalConfigurationName -cne $name) {
                    $Diagnostics.Add(@{ severity = 'error'; code = 'optional_features.resource.non_canonical'; path = "$($Request.path).$name"; message = "Windows $provider name '$name' is not canonical; use '$canonicalConfigurationName'."; help = "Use $canonicalConfigurationName." })
                } else {
                    $resources.Add([pscustomobject]@{ ConfigurationName = $name; Name = $resolved.Name; Provider = $provider; DesiredState = "$($entry.Value.state)"; Item = $resolved.Item })
                }
            }
        } catch {
            $Diagnostics.Add(@{ severity = 'error'; code = 'optional_features.catalog.failed'; path = "$($Request.path).$name"; message = "The Windows $provider catalog could not be read: $($_.Exception.Message)" })
        }
    }
    return @($resources)
}

function Write-PlanFailure([object[]] $Diagnostics) {
    Write-WinixResponse @{ protocol_version = 2; success = $false; changed = $false; state = @{}; operations = @(); diagnostics = $Diagnostics; error = @{ code = 'optional_features.plan.failed'; message = 'Windows optional features could not produce a valid plan.' }; restart_required = @{ explorer = $false; system = $false } }
}

$request = Read-WinixRequest
$diagnostics = [System.Collections.Generic.List[object]]::new()
$scope = "$($request.context.scope)"
if ($scope -ne 'system') {
    $diagnostics.Add(@{ severity = 'error'; code = 'optional_features.scope.invalid'; path = $request.path; message = 'Windows optional features are system-scoped; place them under system.windows.features.optional.' })
}

if ($Operation -eq 'validate') {
    Write-WinixResponse @{ protocol_version = 2; valid = ($diagnostics.Count -eq 0); diagnostics = $diagnostics }
    exit
}

if ($diagnostics.Count -gt 0) {
    if ($Operation -eq 'plan') { Write-PlanFailure -Diagnostics $diagnostics; exit }
    throw $diagnostics[0].message
}
if (-not (Test-WinixAdministrator)) {
    $diagnostics.Add(@{ severity = 'error'; code = 'optional_features.elevation.required'; path = $request.path; message = 'Windows servicing inventory requires an elevated token.'; help = 'Run apply --system or apply --all to plan and apply through the elevated system worker. Run plan --system from an elevated terminal.' })
    if ($Operation -eq 'plan') { Write-PlanFailure -Diagnostics $diagnostics; exit }
    throw $diagnostics[0].message
}

$resources = @(Get-DesiredResources -Request $request -Diagnostics $diagnostics)
if ($diagnostics.Count -gt 0) {
    if ($Operation -eq 'plan') { Write-PlanFailure -Diagnostics $diagnostics; exit }
    throw $diagnostics[0].message
}

if ($Operation -eq 'plan') {
    $state = [ordered]@{}
    $operations = [System.Collections.Generic.List[object]]::new()
    $restartPending = $false
    foreach ($resource in $resources) {
        $observed = ConvertTo-OptionalFeatureState -Provider $resource.Provider -Name $resource.Name -Item $resource.Item
        $state[$resource.ConfigurationName] = $observed
        if ($observed.restart_pending) {
            $restartPending = $true
            $diagnostic = @{ severity = 'warning'; code = 'optional_features.restart.pending'; path = "$($request.path).$($resource.ConfigurationName)"; message = "Windows $($resource.Provider) '$($resource.Name)' has a pending servicing restart. Restart Windows, then run Winix again to continue." }
            $diagnostics.Add($diagnostic)
            Write-WinixEvent -Kind 'diagnostic' -ResourceType 'windows.optional_feature' -ResourceId $resource.Name -Diagnostic $diagnostic
            continue
        }
        if ($observed.state -ceq $resource.DesiredState) { continue }
        $action = if ($resource.DesiredState -eq 'enabled') { 'enable' } else { 'disable' }
        $digest = Get-ResourceDigest -Provider $resource.Provider -Name $resource.Name
        $operationItem = [ordered]@{
            id = "optional-features.$($resource.Provider).$action.$($digest.Substring(0, 16))"
            action = $action
            resource = @{ type = 'windows.optional_feature'; id = $resource.Name }
            before = $observed
            after = @{ provider = $resource.Provider; state = $resource.DesiredState }
            data = @{ provider = $resource.Provider; depends_on = @() }
        }
        $operations.Add($operationItem)
        Write-WinixEvent -Kind 'resource_status' -ResourceType $operationItem.resource.type -ResourceId $operationItem.resource.id -Data @{ status = 'change_required'; operation = $operationItem }
    }
    Write-WinixResponse @{ protocol_version = 2; success = $true; changed = $false; state = $state; operations = $operations; diagnostics = $diagnostics; error = $null; restart_required = @{ explorer = $false; system = $restartPending } }
    exit
}

if (-not (Test-WinixPropertyPresent $request 'operations')) { throw 'Apply request is missing its planned operations.' }
$planned = @($request.operations)

# Validate the complete closed queue and all preconditions before the first mutation.
foreach ($operationItem in $planned) {
    $name = "$($operationItem.resource.id)"
    $provider = "$($operationItem.data.provider)"
    if ($operationItem.resource.type -ne 'windows.optional_feature' -or $operationItem.action -notin @('enable', 'disable') -or $provider -notin @('capability', 'feature')) {
        throw "Unsupported planned operation '$($operationItem.id)'."
    }
    $expectedState = if ($operationItem.action -eq 'enable') { 'enabled' } else { 'disabled' }
    $expectedId = "optional-features.$provider.$($operationItem.action).$((Get-ResourceDigest -Provider $provider -Name $name).Substring(0, 16))"
    if ("$($operationItem.id)" -cne $expectedId -or "$($operationItem.after.provider)" -cne $provider -or "$($operationItem.after.state)" -cne $expectedState) {
        throw "Planned operation '$($operationItem.id)' contains unsupported identity or postcondition data."
    }
    $observed = Get-ResourceState -Provider $provider -Name $name
    if ($null -eq $observed) { throw "Plan is stale for '$($operationItem.id)': the Windows $provider no longer exists." }
    if (-not (Test-WinixJsonEqual $observed $operationItem.before)) { throw "Plan is stale for '$($operationItem.id)': servicing state changed after planning." }
}

$applied = [System.Collections.Generic.List[string]]::new()
$changedCount = 0
$restartRequired = $false
foreach ($operationItem in $planned) {
    $name = "$($operationItem.resource.id)"
    $provider = "$($operationItem.data.provider)"
    $desiredState = "$($operationItem.after.state)"
    Write-WinixEvent -Kind 'resource_change_started' -ResourceType $operationItem.resource.type -ResourceId $name -Data @{ operation_id = $operationItem.id; action = $operationItem.action; before = $operationItem.before; after = $operationItem.after }
    $current = Get-ResourceState -Provider $provider -Name $name
    $changed = $current.state -cne $desiredState
    $restartNeeded = $false
    if ($changed) {
        $mutationScript = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
Import-Module Dism -ErrorAction Stop
$provider = $env:WINIX_OPTIONAL_FEATURE_PROVIDER
$desiredState = $env:WINIX_OPTIONAL_FEATURE_STATE
$name = $env:WINIX_OPTIONAL_FEATURE_NAME
$result = if ($provider -eq 'capability') {
    if ($desiredState -eq 'enabled') {
        Add-WindowsCapability -Online -Name $name -ErrorAction Stop
    } else {
        Remove-WindowsCapability -Online -Name $name -ErrorAction Stop
    }
} elseif ($desiredState -eq 'enabled') {
    Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart -ErrorAction Stop
} else {
    Disable-WindowsOptionalFeature -Online -FeatureName $name -NoRestart -ErrorAction Stop
}
[Console]::Out.Write((@{ RestartNeeded = [bool]$result.RestartNeeded } | ConvertTo-Json -Compress))
'@
        $result = Invoke-WindowsPowerShellJson -Script $mutationScript -Environment @{
            WINIX_OPTIONAL_FEATURE_PROVIDER = $provider
            WINIX_OPTIONAL_FEATURE_STATE = $desiredState
            WINIX_OPTIONAL_FEATURE_NAME = $name
        }
        $changedCount++
        $restartNeeded = [bool]$result.RestartNeeded
        [void]$script:Catalogs.Remove($provider)
        if ($restartNeeded) { Write-RestartReceipt -Provider $provider -Name $name -DesiredState $desiredState }
    }
    $observedAfter = Get-ResourceState -Provider $provider -Name $name
    if ($observedAfter.state -cne $desiredState) {
        $diagnostic = @{ severity = 'error'; code = 'optional_features.postcondition.failed'; path = "$($request.path).$name"; message = "Windows $provider '$name' did not reach state '$desiredState'."; data = @{ operation_id = $operationItem.id; observed = $observedAfter; applied_operation_ids = @($applied) } }
        Write-WinixEvent -Kind 'diagnostic' -ResourceType $operationItem.resource.type -ResourceId $name -Diagnostic $diagnostic
        Write-WinixResponse @{ protocol_version = 2; success = $false; changed = ($changedCount -gt 0); operations = $planned; applied_operation_ids = $applied; diagnostics = @($diagnostic); error = @{ code = 'optional_features.apply.postcondition_failed'; message = $diagnostic.message }; restart_required = @{ explorer = $false; system = ($restartRequired -or $restartNeeded -or $observedAfter.restart_pending) } }
        exit
    }
    $restartRequired = $restartRequired -or $restartNeeded -or $observedAfter.restart_pending
    $applied.Add("$($operationItem.id)")
    Write-WinixEvent -Kind 'resource_change_completed' -ResourceType $operationItem.resource.type -ResourceId $name -Data @{ operation_id = $operationItem.id; changed = $changed; restart_needed = $restartNeeded; observed = $observedAfter }
}

Write-WinixResponse @{ protocol_version = 2; success = $true; changed = ($changedCount -gt 0); state = @{}; operations = $planned; applied_operation_ids = $applied; diagnostics = @(); error = $null; restart_required = @{ explorer = $false; system = $restartRequired } }
