Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProvisionedInventory = $null
$script:SystemRegisteredInventory = $null

function Assert-AppxPackageName {
    param([Parameter(Mandatory)] [string] $Name)

    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "AppX package name '$Name' is not canonical."
    }
}

function Assert-AppxPackageFullName {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $PackageFullName
    )

    if ([string]::IsNullOrWhiteSpace($PackageFullName) -or
        -not $PackageFullName.StartsWith("$Name`_", [StringComparison]::Ordinal)) {
        throw "AppX package full name '$PackageFullName' does not belong to '$Name'."
    }
    foreach ($character in $PackageFullName.ToCharArray()) {
        if ([char]::IsControl($character)) {
            throw "AppX package full name '$PackageFullName' contains a control character."
        }
    }
}

function Get-CanonicalAppxPackageNames {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [AllowEmptyCollection()] [object[]] $PackageNames,
        [switch] $RejectDuplicates
    )

    $unique = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($packageNameValue in @($PackageNames)) {
        if ($packageNameValue -isnot [string]) {
            throw "AppX package identity for '$Name' is not a string."
        }
        $packageName = [string]$packageNameValue
        Assert-AppxPackageFullName -Name $Name -PackageFullName $packageName
        if (-not $unique.Add($packageName) -and $RejectDuplicates) {
            throw "Duplicate AppX package identity '$packageName' for '$Name'."
        }
    }

    $sorted = [Collections.Generic.List[string]]::new()
    foreach ($packageName in $unique) {
        $sorted.Add($packageName)
    }
    $sorted.Sort([StringComparer]::Ordinal)
    return @($sorted)
}

function Get-SystemRegisteredInventory {
    if ($null -eq $script:SystemRegisteredInventory) {
        $script:SystemRegisteredInventory = @(
            Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
                Sort-Object PackageFullName -Unique
        )
    }
    return @($script:SystemRegisteredInventory)
}

function Get-ProvisionedInventory {
    if ($null -ne $script:ProvisionedInventory) { return @($script:ProvisionedInventory) }

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $command = 'Get-AppxProvisionedPackage -Online | Select-Object DisplayName,PackageName,Version | ConvertTo-Json -Depth 5 -Compress'
    $json = & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -Command $command
    if ($LASTEXITCODE -ne 0) {
        throw "Windows PowerShell provisioning inventory failed with exit code $LASTEXITCODE."
    }
    $script:ProvisionedInventory = if ([string]::IsNullOrWhiteSpace(($json -join ''))) {
        @()
    } else {
        @((($json -join "`n") | ConvertFrom-Json))
    }
    return @($script:ProvisionedInventory)
}

function Get-SystemAppxSnapshot {
    param([Parameter(Mandatory)] [string] $Name)

    # Unelevated planning can bind the package-name union but cannot
    # authoritatively classify registration versus provisioning. Apply proves
    # that this authoritative union is unchanged, then uses these two subsets
    # only to select the correct removal cmdlet for each planned identity.
    Assert-AppxPackageName -Name $Name
    $registeredNames = @(
        Get-SystemRegisteredInventory |
            Where-Object { $_.Name -ceq $Name } |
            ForEach-Object { [string]$_.PackageFullName }
    )
    $provisionedNames = @(
        Get-ProvisionedInventory |
            Where-Object { $_.DisplayName -ceq $Name } |
            ForEach-Object { [string]$_.PackageName }
    )
    $registeredNames = @(
        Get-CanonicalAppxPackageNames -Name $Name -PackageNames $registeredNames
    )
    $provisionedNames = @(
        Get-CanonicalAppxPackageNames -Name $Name -PackageNames $provisionedNames
    )
    $packageNames = @(
        Get-CanonicalAppxPackageNames `
            -Name $Name `
            -PackageNames @($registeredNames + $provisionedNames)
    )

    return [ordered]@{
        state = [ordered]@{
            installed = ($packageNames.Count -gt 0)
            packages = $packageNames
        }
        registered_package_names = $registeredNames
        provisioned_package_names = $provisionedNames
    }
}

function Get-SystemAppxState {
    param([Parameter(Mandatory)] [string] $Name)

    return (Get-SystemAppxSnapshot -Name $Name).state
}

function Remove-ProvisionedPackage {
    param([Parameter(Mandatory)] [string] $PackageName)

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $escaped = $PackageName.Replace("'", "''")
    $command = "Remove-AppxProvisionedPackage -Online -PackageName '$escaped' -AllUsers -ErrorAction Stop | Out-Null"
    $null = & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -Command $command
    $exitCode = $LASTEXITCODE
    $script:ProvisionedInventory = $null
    if ($exitCode -ne 0) {
        $stillProvisioned = @(
            Get-ProvisionedInventory | Where-Object { $_.PackageName -ceq $PackageName }
        )
        if ($stillProvisioned.Count -gt 0) {
            throw "Windows PowerShell provisioning removal failed for '$PackageName' with exit code $exitCode."
        }
    }
}

function Remove-RegisteredPackageForAllUsers {
    param([Parameter(Mandatory)] [string] $PackageFullName)

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $escaped = $PackageFullName.Replace("'", "''")
    $command = "Remove-AppxPackage -Package '$escaped' -AllUsers -ErrorAction Stop"
    $null = & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -Command $command
    $exitCode = $LASTEXITCODE
    $script:SystemRegisteredInventory = $null
    if ($exitCode -ne 0) {
        throw "Windows PowerShell all-user AppX removal failed for '$PackageFullName' with exit code $exitCode."
    }
}

function Assert-SystemAppxApplyPlan {
    param([Parameter(Mandatory)] [object] $Request)

    $operationIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $packageNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($operationItem in @($Request.operations)) {
        foreach ($propertyName in @('id', 'action', 'resource', 'before', 'after', 'data')) {
            if (-not (Test-WinixPropertyPresent -Object $operationItem -Name $propertyName)) {
                throw "Planned AppX operation is missing '$propertyName'."
            }
        }
        if ($operationItem.id -isnot [string] -or [string]::IsNullOrWhiteSpace($operationItem.id)) {
            throw 'Planned AppX operation has an invalid ID.'
        }
        if (-not $operationIds.Add([string]$operationItem.id)) {
            throw "Duplicate planned operation ID '$($operationItem.id)'."
        }

        $resource = $operationItem.resource
        if (-not (Test-WinixPropertyPresent -Object $resource -Name 'type') -or
            -not (Test-WinixPropertyPresent -Object $resource -Name 'id') -or
            $resource.id -isnot [string]) {
            throw "Planned AppX operation '$($operationItem.id)' has an invalid resource."
        }
        $name = [string]$resource.id
        Assert-AppxPackageName -Name $name
        $expectedResource = [ordered]@{ type = 'appx.package'; id = $name }
        if (-not (Test-WinixJsonEqual -Left $resource -Right $expectedResource) -or
            $operationItem.action -cne 'uninstall' -or
            $operationItem.id -cne "appx.system.uninstall.$name") {
            throw "Unsupported planned operation '$($operationItem.id)'."
        }
        if (-not $packageNames.Add($name)) {
            throw "Duplicate planned AppX package '$name'."
        }

        $configurationProperties = @(
            $Request.configuration.PSObject.Properties | Where-Object Name -CEQ $name
        )
        if ($configurationProperties.Count -ne 1 -or
            -not (Test-WinixJsonEqual -Left $configurationProperties[0].Value -Right @{ state = 'absent' })) {
            throw "Planned AppX package '$name' does not match configuration."
        }

        if (-not (Test-WinixPropertyPresent -Object $operationItem.before -Name 'packages') -or
            $operationItem.before.packages -isnot [Array]) {
            throw "Planned AppX package '$name' has an invalid before state."
        }
        $plannedPackageNames = @(
            Get-CanonicalAppxPackageNames `
                -Name $name `
                -PackageNames @($operationItem.before.packages) `
                -RejectDuplicates
        )
        $expectedBefore = [ordered]@{ installed = $true; packages = $plannedPackageNames }
        if ($plannedPackageNames.Count -eq 0 -or
            -not (Test-WinixJsonEqual -Left $operationItem.before -Right $expectedBefore)) {
            throw "Planned AppX package '$name' has an invalid before state."
        }

        $expectedAfter = [ordered]@{ installed = $false; packages = @() }
        if (-not (Test-WinixJsonEqual -Left $operationItem.after -Right $expectedAfter)) {
            throw "Planned AppX package '$name' has an invalid after state."
        }

        if (-not (Test-WinixPropertyPresent -Object $operationItem.data -Name 'package_names') -or
            -not (Test-WinixPropertyPresent -Object $operationItem.data -Name 'depends_on') -or
            $operationItem.data.package_names -isnot [Array] -or
            $operationItem.data.depends_on -isnot [Array]) {
            throw "Planned AppX package '$name' has invalid operation data."
        }
        foreach ($dependency in @($operationItem.data.depends_on)) {
            if ($dependency -isnot [string] -or [string]::IsNullOrWhiteSpace($dependency)) {
                throw "Planned AppX package '$name' has an invalid dependency ID."
            }
        }
        $expectedData = [ordered]@{
            package_names = $plannedPackageNames
            depends_on = @($operationItem.data.depends_on)
        }
        if (-not (Test-WinixJsonEqual -Left $operationItem.data -Right $expectedData)) {
            throw "Planned AppX targets for '$name' were changed after planning."
        }

        $snapshot = Get-SystemAppxSnapshot -Name $name
        $registeredPackageNames = @(
            Get-CanonicalAppxPackageNames `
                -Name $name `
                -PackageNames @($snapshot.registered_package_names) `
                -RejectDuplicates
        )
        $provisionedPackageNames = @(
            Get-CanonicalAppxPackageNames `
                -Name $name `
                -PackageNames @($snapshot.provisioned_package_names) `
                -RejectDuplicates
        )
        $authoritativePackageNames = @(
            Get-CanonicalAppxPackageNames `
                -Name $name `
                -PackageNames @($registeredPackageNames + $provisionedPackageNames)
        )
        $authoritativeState = [ordered]@{
            installed = ($authoritativePackageNames.Count -gt 0)
            packages = $authoritativePackageNames
        }
        if (-not (Test-WinixJsonEqual -Left $snapshot.state -Right $authoritativeState)) {
            throw "Authoritative AppX inventory for '$name' produced inconsistent mutation targets."
        }
        if (-not (Test-WinixJsonEqual -Left $authoritativeState -Right $operationItem.before)) {
            throw "Plan is stale for '$($operationItem.id)': AppX package state changed after planning."
        }

        [pscustomobject]@{
            operation = $operationItem
            name = $name
            registered_package_names = $registeredPackageNames
            provisioned_package_names = $provisionedPackageNames
        }
    }
}

function Invoke-SystemAppxApply {
    param([Parameter(Mandatory)] [object] $Request)

    # Assert-SystemAppxApplyPlan enumerates and verifies the complete queue
    # before this function enters its mutation loop.
    $preparedOperations = @(Assert-SystemAppxApplyPlan -Request $Request)
    $plannedOperations = @($Request.operations)
    $applied = [Collections.Generic.List[string]]::new()

    foreach ($prepared in $preparedOperations) {
        $operationItem = $prepared.operation
        $name = $prepared.name
        Write-WinixEvent -Kind 'resource_change_started' -ResourceType 'appx.package' -ResourceId $name -Data @{
            operation_id = $operationItem.id
            action = 'uninstall'
            before = $operationItem.before
            after = $operationItem.after
        }
        foreach ($packageName in @($prepared.provisioned_package_names)) {
            Remove-ProvisionedPackage -PackageName $packageName
        }
        foreach ($packageFullName in @($prepared.registered_package_names)) {
            Remove-RegisteredPackageForAllUsers -PackageFullName $packageFullName
        }

        $observed = Get-SystemAppxState -Name $name
        if (-not (Test-WinixJsonEqual -Left $observed -Right $operationItem.after)) {
            $diagnostic = @{
                severity = 'error'
                code = 'appx.package.postcondition.not_absent'
                path = "$($Request.path).$name"
                message = "AppX package '$name' remains installed after removal."
                data = @{
                    operation_id = $operationItem.id
                    observed = $observed
                    applied_operation_ids = @($applied)
                }
            }
            Write-WinixEvent `
                -Kind 'diagnostic' `
                -ResourceType 'appx.package' `
                -ResourceId $name `
                -Diagnostic $diagnostic
            return [ordered]@{
                protocol_version = 2
                success = $false
                changed = $true
                operations = $plannedOperations
                applied_operation_ids = $applied
                diagnostics = @($diagnostic)
                error = @{
                    code = 'appx.apply.postcondition_failed'
                    message = "Planned AppX operation '$($operationItem.id)' did not reach its declared postcondition."
                }
                restart_required = @{ explorer = $false; system = $false }
            }
        }

        $applied.Add($operationItem.id)
        Write-WinixEvent -Kind 'resource_change_completed' -ResourceType 'appx.package' -ResourceId $name -Data @{
            operation_id = $operationItem.id
            changed = $true
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
        restart_required = @{ explorer = $false; system = $false }
    }
}

Export-ModuleMember -Function `
    Assert-AppxPackageName, `
    Get-CanonicalAppxPackageNames, `
    Get-SystemRegisteredInventory, `
    Get-ProvisionedInventory, `
    Get-SystemAppxSnapshot, `
    Get-SystemAppxState, `
    Remove-ProvisionedPackage, `
    Remove-RegisteredPackageForAllUsers, `
    Assert-SystemAppxApplyPlan, `
    Invoke-SystemAppxApply
