Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProductCodePattern = '^\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\}$'

function Assert-WindowsInstallerProductCode {
    param([Parameter(Mandatory)] [string] $ProductCode)

    if ($ProductCode -cnotmatch $script:ProductCodePattern) {
        throw "Windows Installer product code '$ProductCode' is not canonical."
    }
}

function Assert-WindowsInstallerConfiguration {
    param([Parameter(Mandatory)] [object] $Configuration)

    foreach ($entry in $Configuration.PSObject.Properties) {
        $productCode = $entry.Name
        Assert-WindowsInstallerProductCode -ProductCode $productCode
        $expected = [ordered]@{ state = 'absent' }
        if (-not (Test-WinixJsonEqual -Left $entry.Value -Right $expected)) {
            throw "Windows Installer product '$productCode' must declare only state 'absent'."
        }
    }
}

function Get-WindowsInstallerRegistryLocations {
    param([Parameter(Mandatory)] [string] $ProductCode)

    Assert-WindowsInstallerProductCode -ProductCode $ProductCode
    return @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$ProductCode"
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$ProductCode"
    )
}

function Get-WindowsInstallerAbsentState {
    param([Parameter(Mandatory)] [string] $ProductCode)

    Assert-WindowsInstallerProductCode -ProductCode $ProductCode
    return [ordered]@{
        installed = $false
        product_code = $ProductCode
        display_name = $null
        version = $null
        registry_path = $null
    }
}

function Get-WindowsInstallerProduct {
    param([Parameter(Mandatory)] [string] $ProductCode)

    foreach ($path in @(Get-WindowsInstallerRegistryLocations -ProductCode $ProductCode)) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }
        $item = Get-ItemProperty -LiteralPath $path
        $displayNameProperty = $item.PSObject.Properties['DisplayName']
        $versionProperty = $item.PSObject.Properties['DisplayVersion']
        return [ordered]@{
            installed = $true
            product_code = $ProductCode
            display_name = $(if ($null -ne $displayNameProperty) { $displayNameProperty.Value } else { $null })
            version = $(if ($null -ne $versionProperty) { $versionProperty.Value } else { $null })
            registry_path = $path
        }
    }
    return Get-WindowsInstallerAbsentState -ProductCode $ProductCode
}

function New-WindowsInstallerOperation {
    param(
        [Parameter(Mandatory)] [string] $ProductCode,
        [Parameter(Mandatory)] [object] $Before
    )

    return [ordered]@{
        id = "windows_installer.system.uninstall.$ProductCode"
        action = 'uninstall'
        resource = [ordered]@{
            type = 'windows_installer.product'
            id = $ProductCode
        }
        before = $Before
        after = Get-WindowsInstallerAbsentState -ProductCode $ProductCode
        data = [ordered]@{}
    }
}

function Assert-WindowsInstallerObjectProperties {
    param(
        [Parameter(Mandatory)] [object] $Object,
        [Parameter(Mandatory)] [string[]] $Properties,
        [Parameter(Mandatory)] [string] $Description
    )

    foreach ($property in $Properties) {
        if (-not (Test-WinixPropertyPresent -Object $Object -Name $property)) {
            throw "$Description is missing '$property'."
        }
    }
}

function Assert-WindowsInstallerApplyPlan {
    param([Parameter(Mandatory)] [object] $Request)

    if (-not (Test-WinixPropertyPresent -Object $Request -Name 'configuration')) {
        throw 'Apply request is missing its Windows Installer configuration.'
    }
    if (-not (Test-WinixPropertyPresent -Object $Request -Name 'operations')) {
        throw 'Apply request is missing its planned operations.'
    }
    Assert-WindowsInstallerConfiguration -Configuration $Request.configuration

    $operationIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $productCodes = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($operationItem in @($Request.operations)) {
        Assert-WindowsInstallerObjectProperties -Object $operationItem -Properties @(
            'id', 'action', 'resource', 'before', 'after', 'data'
        ) -Description 'Planned Windows Installer operation'
        Assert-WindowsInstallerObjectProperties -Object $operationItem.resource -Properties @(
            'type', 'id'
        ) -Description "Planned Windows Installer operation '$($operationItem.id)' resource"

        $productCode = [string]$operationItem.resource.id
        Assert-WindowsInstallerProductCode -ProductCode $productCode
        if ($operationItem.resource.type -cne 'windows_installer.product' -or $operationItem.action -cne 'uninstall') {
            throw "Unsupported planned operation '$($operationItem.id)'."
        }
        if (-not $operationIds.Add([string]$operationItem.id)) {
            throw "Duplicate planned operation ID '$($operationItem.id)'."
        }
        if (-not $productCodes.Add($productCode)) {
            throw "Duplicate planned Windows Installer product '$productCode'."
        }
        if ($operationItem.id -cne "windows_installer.system.uninstall.$ProductCode") {
            throw "Planned operation '$($operationItem.id)' does not match Windows Installer product '$productCode'."
        }

        $expectedResource = [ordered]@{
            type = 'windows_installer.product'
            id = $productCode
        }
        if (-not (Test-WinixJsonEqual -Left $operationItem.resource -Right $expectedResource)) {
            throw "Planned Windows Installer resource '$productCode' was changed after planning."
        }

        $configurationProperties = @(
            $Request.configuration.PSObject.Properties | Where-Object Name -CEQ $productCode
        )
        if ($configurationProperties.Count -ne 1) {
            throw "Planned Windows Installer product '$productCode' is not present exactly in configuration."
        }

        Assert-WindowsInstallerObjectProperties -Object $operationItem.before -Properties @(
            'installed', 'product_code', 'display_name', 'version', 'registry_path'
        ) -Description "Planned before state for Windows Installer product '$productCode'"
        if ($operationItem.before.installed -ne $true -or $operationItem.before.product_code -cne $productCode) {
            throw "Planned before state for Windows Installer product '$productCode' is invalid."
        }
        if ([string]$operationItem.before.registry_path -cnotin @(Get-WindowsInstallerRegistryLocations -ProductCode $productCode)) {
            throw "Planned registry path for Windows Installer product '$productCode' is invalid."
        }

        $expectedBefore = [ordered]@{
            installed = $true
            product_code = $productCode
            display_name = $operationItem.before.display_name
            version = $operationItem.before.version
            registry_path = $operationItem.before.registry_path
        }
        if (-not (Test-WinixJsonEqual -Left $operationItem.before -Right $expectedBefore)) {
            throw "Planned before state for Windows Installer product '$productCode' was changed after planning."
        }

        $expectedAfter = Get-WindowsInstallerAbsentState -ProductCode $productCode
        if (-not (Test-WinixJsonEqual -Left $operationItem.after -Right $expectedAfter)) {
            throw "Planned after state for Windows Installer product '$productCode' was changed after planning."
        }
        if (-not (Test-WinixJsonEqual -Left $operationItem.data -Right ([ordered]@{}))) {
            throw "Planned data for Windows Installer product '$productCode' was changed after planning."
        }

        $current = Get-WindowsInstallerProduct -ProductCode $productCode
        if (-not (Test-WinixJsonEqual -Left $current -Right $operationItem.before)) {
            throw "Windows Installer product '$productCode' changed after planning."
        }

        [pscustomobject]@{
            operation = $operationItem
            product_code = $productCode
        }
    }
}

function Invoke-WindowsInstallerUninstall {
    param([Parameter(Mandatory)] [string] $ProductCode)

    Assert-WindowsInstallerProductCode -ProductCode $ProductCode
    $process = Start-Process `
        -FilePath 'msiexec.exe' `
        -ArgumentList @('/x', $ProductCode, '/qn', '/norestart') `
        -WindowStyle Hidden `
        -Wait `
        -PassThru
    return $process.ExitCode
}

function Invoke-WindowsInstallerApply {
    param([Parameter(Mandatory)] [object] $Request)

    # Materialize and validate the entire queue before entering the mutation loop.
    $preparedOperations = @(Assert-WindowsInstallerApplyPlan -Request $Request)
    $plannedOperations = @($Request.operations)
    $applied = [Collections.Generic.List[string]]::new()
    $restartRequired = $false

    foreach ($prepared in $preparedOperations) {
        $operationItem = $prepared.operation
        $productCode = $prepared.product_code
        # Narrow the race between the queue-wide preflight and this individual
        # mutation. A concurrent change after an earlier operation cannot be
        # rolled back safely, but it must never authorize this uninstall.
        $current = Get-WindowsInstallerProduct -ProductCode $productCode
        if (-not (Test-WinixJsonEqual -Left $current -Right $operationItem.before)) {
            throw "Windows Installer product '$productCode' changed after queue preflight."
        }
        Write-WinixEvent -Kind 'resource_change_started' -ResourceType 'windows_installer.product' -ResourceId $productCode -Data @{
            operation_id = $operationItem.id
            action = 'uninstall'
            before = $operationItem.before
            after = $operationItem.after
        }
        $exitCode = Invoke-WindowsInstallerUninstall -ProductCode $productCode
        if ($exitCode -notin @(0, 1605, 3010)) {
            $diagnostic = @{
                severity = 'error'
                code = 'windows_installer.uninstall.failed'
                path = "$($Request.path).$productCode"
                message = "Windows Installer uninstall failed for '$productCode' with exit code $exitCode."
                data = @{
                    operation_id = $operationItem.id
                    exit_code = $exitCode
                    applied_operation_ids = @($applied)
                }
            }
            Write-WinixEvent -Kind 'diagnostic' -ResourceType 'windows_installer.product' -ResourceId $productCode -Diagnostic $diagnostic
            return [ordered]@{
                protocol_version = 2
                success = $false
                changed = ($applied.Count -gt 0)
                operations = $plannedOperations
                applied_operation_ids = $applied
                diagnostics = @($diagnostic)
                error = @{
                    code = 'windows_installer.apply.failed'
                    message = "Planned Windows Installer operation '$($operationItem.id)' failed."
                }
                restart_required = @{ explorer = $false; system = $restartRequired }
            }
        }

        $observed = Get-WindowsInstallerProduct -ProductCode $productCode
        if (-not (Test-WinixJsonEqual -Left $observed -Right $operationItem.after)) {
            throw "Windows Installer product '$productCode' did not reach its planned postcondition."
        }
        if ($exitCode -eq 3010) {
            $restartRequired = $true
        }
        $applied.Add([string]$operationItem.id)
        Write-WinixEvent -Kind 'resource_change_completed' -ResourceType 'windows_installer.product' -ResourceId $productCode -Data @{
            operation_id = $operationItem.id
            changed = $true
            restart_exit_code = $exitCode
        }
    }

    return [ordered]@{
        protocol_version = 2
        success = $true
        changed = ($applied.Count -gt 0)
        operations = $plannedOperations
        applied_operation_ids = $applied
        diagnostics = @()
        error = $null
        restart_required = @{ explorer = $false; system = $restartRequired }
    }
}

function Invoke-WindowsInstallerValidate {
    param([Parameter(Mandatory)] [object] $Request)

    Assert-WindowsInstallerConfiguration -Configuration $Request.configuration
    return [ordered]@{
        protocol_version = 2
        valid = $true
        diagnostics = @()
    }
}

function Invoke-WindowsInstallerPlan {
    param([Parameter(Mandatory)] [object] $Request)

    Assert-WindowsInstallerConfiguration -Configuration $Request.configuration
    $state = [ordered]@{}
    $operations = [Collections.Generic.List[object]]::new()
    foreach ($entry in $Request.configuration.PSObject.Properties) {
        $productCode = $entry.Name
        $current = Get-WindowsInstallerProduct -ProductCode $productCode
        $state[$productCode] = $current
        if (-not $current.installed) {
            continue
        }
        $plannedOperation = New-WindowsInstallerOperation -ProductCode $productCode -Before $current
        $operations.Add($plannedOperation)
        Write-WinixEvent -Kind 'resource_status' -ResourceType 'windows_installer.product' -ResourceId $productCode -Data @{
            status = 'change_required'
            operation = $plannedOperation
        }
    }
    return [ordered]@{
        protocol_version = 2
        success = $true
        changed = $false
        state = $state
        operations = $operations
        diagnostics = @()
        error = $null
        restart_required = @{ explorer = $false; system = $false }
    }
}

Export-ModuleMember -Function `
    Assert-WindowsInstallerProductCode, `
    Assert-WindowsInstallerConfiguration, `
    Get-WindowsInstallerRegistryLocations, `
    Get-WindowsInstallerAbsentState, `
    Get-WindowsInstallerProduct, `
    New-WindowsInstallerOperation, `
    Assert-WindowsInstallerApplyPlan, `
    Invoke-WindowsInstallerUninstall, `
    Invoke-WindowsInstallerApply, `
    Invoke-WindowsInstallerValidate, `
    Invoke-WindowsInstallerPlan
