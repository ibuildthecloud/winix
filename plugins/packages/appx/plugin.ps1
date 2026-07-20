param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.PluginSdk.psm1') -Force

$script:ProvisionedInventory = $null
$script:UserInventory = $null
$script:SystemRegisteredInventory = $null
$script:SystemRegistryInventory = $null

function Get-UserInventory {
    if ($null -eq $script:UserInventory) {
        $script:UserInventory = @(Get-AppxPackage -ErrorAction SilentlyContinue | Sort-Object PackageFullName -Unique)
    }
    return @($script:UserInventory)
}

function Get-SystemRegisteredInventory {
    if ($null -eq $script:SystemRegisteredInventory) {
        $script:SystemRegisteredInventory = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Sort-Object PackageFullName -Unique)
    }
    return @($script:SystemRegisteredInventory)
}

function Get-SystemRegistryInventory {
    if ($null -ne $script:SystemRegistryInventory) { return @($script:SystemRegistryInventory) }

    # Unelevated planning cannot use Get-AppxPackage -AllUsers. Build the
    # read-only registry inventory once, then filter the cached package names.
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore'
    $packageNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($key in @(Get-ChildItem (Join-Path $root 'Applications') -ErrorAction SilentlyContinue)) {
        $registeredPath = Get-RegisteredPath $key.PSPath
        if (-not [string]::IsNullOrWhiteSpace($registeredPath) -and (Test-Path -LiteralPath $registeredPath)) {
            [void]$packageNames.Add($key.PSChildName)
        }
    }
    foreach ($userKey in @(Get-ChildItem $root -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'S-1-*' })) {
        foreach ($key in @(Get-ChildItem $userKey.PSPath -ErrorAction SilentlyContinue)) {
            $registeredPath = Get-RegisteredPath $key.PSPath
            if (-not [string]::IsNullOrWhiteSpace($registeredPath) -and (Test-Path -LiteralPath $registeredPath)) {
                [void]$packageNames.Add($key.PSChildName)
            }
        }
    }
    $script:SystemRegistryInventory = @($packageNames | Sort-Object)
    return @($script:SystemRegistryInventory)
}

function Get-ProvisionedInventory {
    if ($null -ne $script:ProvisionedInventory) { return @($script:ProvisionedInventory) }
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $command = 'Get-AppxProvisionedPackage -Online | Select-Object DisplayName,PackageName,Version | ConvertTo-Json -Depth 5 -Compress'
    $json = & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -Command $command
    if ($LASTEXITCODE -ne 0) { throw "Windows PowerShell provisioning inventory failed with exit code $LASTEXITCODE." }
    $script:ProvisionedInventory = if ([string]::IsNullOrWhiteSpace(($json -join ''))) { @() } else { @((($json -join "`n") | ConvertFrom-Json)) }
    return @($script:ProvisionedInventory)
}

function Remove-ProvisionedPackage([string] $PackageName) {
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $escaped = $PackageName.Replace("'", "''")
    $command = "Remove-AppxProvisionedPackage -Online -PackageName '$escaped' -AllUsers -ErrorAction Stop | Out-Null"
    & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -Command $command
    $exitCode = $LASTEXITCODE
    $script:ProvisionedInventory = $null
    if ($exitCode -ne 0) {
        $stillProvisioned = @(Get-ProvisionedInventory | Where-Object { $_.PackageName -ceq $PackageName })
        if ($stillProvisioned.Count -gt 0) { throw "Windows PowerShell provisioning removal failed for '$PackageName' with exit code $exitCode." }
    }
}

function Remove-RegisteredPackageForAllUsers([string] $PackageFullName) {
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $escaped = $PackageFullName.Replace("'", "''")
    $command = "Remove-AppxPackage -Package '$escaped' -AllUsers -ErrorAction Stop"
    & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -Command $command
    $exitCode = $LASTEXITCODE
    $script:SystemRegisteredInventory = $null
    $script:SystemRegistryInventory = $null
    if ($exitCode -ne 0) { throw "Windows PowerShell all-user AppX removal failed for '$PackageFullName' with exit code $exitCode." }
}

function Get-UserAppxState([string] $Name) {
    $packages = @(Get-UserInventory | Where-Object { $_.Name -ceq $Name })
    return [ordered]@{
        installed = ($packages.Count -gt 0)
        packages = @($packages | ForEach-Object {
            [ordered]@{
                name = $_.Name
                package_full_name = $_.PackageFullName
                version = $_.Version.ToString()
            }
        })
    }
}

function Get-SystemAppxState([string] $Name) {
    if (Test-WinixAdministrator) {
        $registered = @(Get-SystemRegisteredInventory | Where-Object { $_.Name -ceq $Name })
        $provisioned = @(Get-ProvisionedInventory |
            Where-Object { $_.DisplayName -ceq $Name } | Sort-Object PackageName -Unique)
        return [ordered]@{
            installed = ($registered.Count -gt 0 -or $provisioned.Count -gt 0)
            inventory_source = 'appx_cmdlets'
            registered = @($registered | ForEach-Object {
                [ordered]@{ name = $_.Name; package_full_name = $_.PackageFullName; version = $_.Version.ToString() }
            })
            provisioned = @($provisioned | ForEach-Object {
                [ordered]@{ name = $_.DisplayName; package_name = $_.PackageName; version = $_.Version.ToString() }
            })
        }
    }

    # The supported AppX cmdlets require elevation for machine inventory. The
    # registry is used only for a read-only plan; elevated apply re-observes
    # authoritative state before making changes.
    $packageNames = @(Get-SystemRegistryInventory | Where-Object {
        $_.StartsWith("$Name`_", [System.StringComparison]::Ordinal)
    })
    return [ordered]@{
        installed = ($packageNames.Count -gt 0)
        inventory_source = 'appx_registry'
        packages = @($packageNames)
    }
}

function Get-AppxState([string] $Name, [string] $Scope) {
    if ($Scope -eq 'system') { return Get-SystemAppxState -Name $Name }
    return Get-UserAppxState -Name $Name
}

function Get-RegisteredPath([string] $RegistryPath) {
    $item = Get-ItemProperty $RegistryPath -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    $property = $item.PSObject.Properties['Path']
    if ($null -eq $property) { return $null }
    return $property.Value
}

$request = Read-WinixRequest
$diagnostics = [System.Collections.Generic.List[object]]::new()

$scope = $request.context.scope
if ($scope -notin @('system', 'user')) { throw "Unsupported AppX scope '$scope'." }

if ($Operation -in @('validate', 'plan')) {
    $validationInventory = if ($scope -eq 'system' -and (Test-WinixAdministrator)) {
        @(Get-SystemRegisteredInventory)
    } else {
        @(Get-UserInventory)
    }
    foreach ($entry in $request.configuration.PSObject.Properties) {
        $packageName = $entry.Name
        $matchingPackages = @($validationInventory | Where-Object { $_.Name -ieq $packageName })
        foreach ($package in $matchingPackages) {
            if ($package.Name -cne $packageName) {
                $diagnostics.Add(@{
                    severity = 'error'
                    code = 'appx.package_name.non_canonical'
                    path = "$($request.path).$packageName"
                    message = "AppX package name '$packageName' is not canonical; use '$($package.Name)'."
                    help = "Use $($package.Name)."
                })
                break
            }
        }
    }
    if ($Operation -eq 'validate') {
        Write-WinixResponse @{ protocol_version = 2; valid = ($diagnostics.Count -eq 0); diagnostics = $diagnostics }
        exit
    }
    if ($diagnostics.Count -gt 0) {
        Write-WinixResponse @{ protocol_version = 2; success = $false; changed = $false; state = @{}; operations = @(); diagnostics = $diagnostics; error = @{ code = 'appx.plan.failed'; message = 'AppX could not produce a valid plan.' }; restart_required = @{ explorer = $false; system = $false } }
        exit
    }
}

if ($Operation -eq 'apply') {
    if ($scope -eq 'user' -and (Test-WinixAdministrator)) {
        throw 'Current-user AppX configuration cannot run with an elevated token.'
    }
    if ($scope -eq 'system' -and -not (Test-WinixAdministrator)) {
        throw 'System AppX configuration requires an elevated token.'
    }
    if (-not (Test-WinixPropertyPresent $request 'operations')) {
        throw 'Apply request is missing its planned operations.'
    }

    $planned = @($request.operations)
    foreach ($operationItem in $planned) {
        if ($operationItem.resource.type -ne 'appx.package' -or $operationItem.action -ne 'uninstall') {
            throw "Unsupported planned operation '$($operationItem.id)'."
        }
        $current = Get-AppxState -Name $operationItem.resource.id -Scope $scope
        if ($scope -eq 'user' -and -not (Test-WinixJsonEqual $current $operationItem.before)) {
            throw "Plan is stale for '$($operationItem.id)': AppX package state changed after planning."
        }
    }

    $applied = [System.Collections.Generic.List[string]]::new()
    foreach ($operationItem in $planned) {
        $packageName = $operationItem.resource.id
        Write-WinixEvent -Kind 'resource_change_started' -ResourceType 'appx.package' -ResourceId $packageName -Data @{ operation_id = $operationItem.id; action = 'uninstall'; before = $operationItem.before; after = $operationItem.after }
        if ($scope -eq 'system') {
            $authoritative = Get-SystemAppxState -Name $packageName
            foreach ($package in @($authoritative.provisioned)) {
                Remove-ProvisionedPackage -PackageName $package.package_name
            }
            foreach ($package in @($authoritative.registered)) {
                Remove-RegisteredPackageForAllUsers -PackageFullName $package.package_full_name
            }
        } else {
            foreach ($package in @($operationItem.before.packages)) {
                Remove-AppxPackage -Package $package.package_full_name -ErrorAction Stop
            }
            $script:UserInventory = $null
        }
        $observed = Get-AppxState -Name $packageName -Scope $scope
        if ($observed.Installed) {
            $diagnostic = @{
                severity = 'error'
                code = 'appx.package.postcondition.not_absent'
                path = "$($request.path).$packageName"
                message = "AppX package '$packageName' remains installed after removal."
                data = @{ operation_id = $operationItem.id; observed = $observed; applied_operation_ids = @($applied) }
            }
            Write-WinixEvent -Kind 'diagnostic' -ResourceType 'appx.package' -ResourceId $packageName -Diagnostic $diagnostic
            Write-WinixResponse @{ protocol_version = 2; success = $false; changed = $true; operations = $planned; applied_operation_ids = $applied; diagnostics = @($diagnostic); error = @{ code = 'appx.apply.postcondition_failed'; message = "Planned AppX operation '$($operationItem.id)' did not reach its declared postcondition." }; restart_required = @{ explorer = $false; system = $false } }
            exit
        }
        $applied.Add($operationItem.id)
        Write-WinixEvent -Kind 'resource_change_completed' -ResourceType 'appx.package' -ResourceId $packageName -Data @{ operation_id = $operationItem.id; changed = $true }
    }
    Write-WinixResponse @{ protocol_version = 2; success = $true; changed = ($applied.Count -gt 0); operations = $planned; applied_operation_ids = $applied; diagnostics = @(); restart_required = @{ explorer = $false; system = $false } }
    exit
}

$state = [ordered]@{}
$operations = [System.Collections.Generic.List[object]]::new()
foreach ($entry in $request.configuration.PSObject.Properties) {
    $packageName = $entry.Name
    $current = Get-AppxState -Name $packageName -Scope $scope
    $state[$packageName] = $current
    if (-not $current.installed) { continue }

    $plannedOperation = [ordered]@{
        id = "appx.$scope.uninstall.$packageName"
        action = 'uninstall'
        resource = @{ type = 'appx.package'; id = $packageName }
        before = $current
        after = @{ installed = $false; packages = @() }
        data = @{}
    }
    $operations.Add($plannedOperation)
    Write-WinixEvent -Kind 'resource_status' -ResourceType 'appx.package' -ResourceId $packageName -Data @{ status = 'change_required'; operation = $plannedOperation }
}

Write-WinixResponse @{
    protocol_version = 2
    success = $true
    changed = $false
    state = $state
    operations = $operations
    diagnostics = $diagnostics
    error = $null
    restart_required = @{ explorer = $false; system = $false }
}
