BeforeAll {
    $sdkPath = Join-Path $PSScriptRoot '..\..\plugins\shared\Winix.PluginSdk.psm1'
    $modulePath = Join-Path $PSScriptRoot '..\..\plugins\packages\appx\Winix.Appx.psm1'
    Import-Module $sdkPath -Force
    Import-Module $modulePath -Force

    function New-TestSystemAppxState {
        param(
            [string[]] $PackageNames = @()
        )

        return [pscustomobject][ordered]@{
            installed = ($PackageNames.Count -gt 0)
            packages = @($PackageNames)
        }
    }

    function New-TestSystemAppxSnapshot {
        param(
            [Parameter(Mandatory)] [object] $State,
            [string[]] $RegisteredPackageNames = @(),
            [string[]] $ProvisionedPackageNames = @()
        )

        return [pscustomobject][ordered]@{
            state = $State
            registered_package_names = @($RegisteredPackageNames)
            provisioned_package_names = @($ProvisionedPackageNames)
        }
    }

    function New-TestSystemAppxOperation {
        param(
            [Parameter(Mandatory)] [string] $Name,
            [Parameter(Mandatory)] [object] $Before
        )

        return [pscustomobject][ordered]@{
            id = "appx.system.uninstall.$Name"
            action = 'uninstall'
            resource = [pscustomobject][ordered]@{ type = 'appx.package'; id = $Name }
            before = $Before
            after = [pscustomobject][ordered]@{ installed = $false; packages = @() }
            data = [pscustomobject][ordered]@{
                package_names = @($Before.packages)
                depends_on = @()
            }
        }
    }

    function New-TestSystemAppxRequest {
        param([Parameter(Mandatory)] [object[]] $Operations)

        $configuration = [ordered]@{}
        foreach ($operationItem in $Operations) {
            $configuration[$operationItem.resource.id] = [ordered]@{ state = 'absent' }
        }
        return [pscustomobject]@{
            protocol_version = 2
            path = 'system.packages.appx'
            configuration = [pscustomobject]$configuration
            operations = $Operations
        }
    }
}

Describe 'System AppX closed-plan apply' {
    BeforeEach {
        Mock Write-WinixEvent -ModuleName Winix.Appx {}
        Mock Remove-ProvisionedPackage -ModuleName Winix.Appx {}
        Mock Remove-RegisteredPackageForAllUsers -ModuleName Winix.Appx {}
    }

    It 'preflights a stale second operation before starting the first mutation' {
        $firstName = 'Contoso.First'
        $secondName = 'Contoso.Second'
        $firstPackage = 'Contoso.First_1.0.0.0_x64__publisher'
        $secondPackage = 'Contoso.Second_1.0.0.0_x64__publisher'
        $firstBefore = New-TestSystemAppxState -PackageNames $firstPackage
        $secondBefore = New-TestSystemAppxState -PackageNames $secondPackage
        $request = New-TestSystemAppxRequest -Operations @(
            (New-TestSystemAppxOperation -Name $firstName -Before $firstBefore)
            (New-TestSystemAppxOperation -Name $secondName -Before $secondBefore)
        )
        $staleSecond = New-TestSystemAppxState `
            -PackageNames 'Contoso.Second_2.0.0.0_x64__publisher'

        Mock Get-SystemAppxSnapshot -ModuleName Winix.Appx {
            param($Name)
            if ($Name -ceq $firstName) {
                return New-TestSystemAppxSnapshot `
                    -State $firstBefore `
                    -RegisteredPackageNames $firstPackage
            }
            return New-TestSystemAppxSnapshot `
                -State $staleSecond `
                -RegisteredPackageNames $staleSecond.packages
        }

        { Invoke-SystemAppxApply -Request $request } |
            Should -Throw "*appx.system.uninstall.$secondName*changed after planning*"
        Should -Invoke Remove-ProvisionedPackage -ModuleName Winix.Appx -Times 0 -Exactly
        Should -Invoke Remove-RegisteredPackageForAllUsers -ModuleName Winix.Appx -Times 0 -Exactly
        Should -Invoke Write-WinixEvent -ModuleName Winix.Appx -Times 0 -Exactly
    }

    It 'accepts a deliberately reordered before state after a complete JSON round trip' {
        $name = 'Contoso.Reordered'
        $packageName = 'Contoso.Reordered_1.0.0.0_x64__publisher'
        $before = @"
{"packages":["$packageName"],"installed":true}
"@ | ConvertFrom-Json
        $operationItem = New-TestSystemAppxOperation -Name $name -Before $before
        $request = New-TestSystemAppxRequest -Operations @($operationItem)
        $snapshot = New-TestSystemAppxSnapshot `
            -State (New-TestSystemAppxState -PackageNames $packageName) `
            -RegisteredPackageNames $packageName

        Mock Get-SystemAppxSnapshot -ModuleName Winix.Appx { return $snapshot }
        Mock Get-SystemAppxState -ModuleName Winix.Appx {
            return New-TestSystemAppxState
        }

        $result = Invoke-SystemAppxApply -Request $request

        $result.success | Should -BeTrue
        @($result.applied_operation_ids) | Should -Be @("appx.system.uninstall.$name")
        Should -Invoke Remove-RegisteredPackageForAllUsers -ModuleName Winix.Appx -Times 1 -Exactly `
            -ParameterFilter { $PackageFullName -ceq $packageName }
    }

    It 'rejects tampered package targets before mutation' {
        $name = 'Contoso.Tampered'
        $packageName = 'Contoso.Tampered_1.0.0.0_x64__publisher'
        $before = New-TestSystemAppxState -PackageNames $packageName
        $operationItem = New-TestSystemAppxOperation -Name $name -Before $before
        $operationItem.data.package_names = @('Contoso.Tampered_2.0.0.0_x64__publisher')
        $request = New-TestSystemAppxRequest -Operations @($operationItem)

        { Invoke-SystemAppxApply -Request $request } |
            Should -Throw "*targets for '$name' were changed after planning*"
        Should -Invoke Remove-ProvisionedPackage -ModuleName Winix.Appx -Times 0 -Exactly
        Should -Invoke Remove-RegisteredPackageForAllUsers -ModuleName Winix.Appx -Times 0 -Exactly
    }

    It 'rejects an operation whose ID does not exactly identify its resource' {
        $name = 'Contoso.Identity'
        $packageName = 'Contoso.Identity_1.0.0.0_x64__publisher'
        $before = New-TestSystemAppxState -PackageNames $packageName
        $operationItem = New-TestSystemAppxOperation -Name $name -Before $before
        $operationItem.id = 'appx.system.uninstall.Contoso.Other'
        $request = New-TestSystemAppxRequest -Operations @($operationItem)

        { Invoke-SystemAppxApply -Request $request } | Should -Throw '*Unsupported planned operation*'
        Should -Invoke Remove-RegisteredPackageForAllUsers -ModuleName Winix.Appx -Times 0 -Exactly
    }

    It 'rejects duplicate package resources before mutation' {
        $name = 'Contoso.Duplicate'
        $packageName = 'Contoso.Duplicate_1.0.0.0_x64__publisher'
        $before = New-TestSystemAppxState -PackageNames $packageName
        $first = New-TestSystemAppxOperation -Name $name -Before $before
        $second = New-TestSystemAppxOperation -Name $name -Before $before
        $request = New-TestSystemAppxRequest -Operations @($first, $second)
        $snapshot = New-TestSystemAppxSnapshot `
            -State $before `
            -RegisteredPackageNames $packageName

        Mock Get-SystemAppxSnapshot -ModuleName Winix.Appx { return $snapshot }

        { Invoke-SystemAppxApply -Request $request } | Should -Throw '*Duplicate planned operation ID*'
        Should -Invoke Remove-RegisteredPackageForAllUsers -ModuleName Winix.Appx -Times 0 -Exactly
    }

    It 'rejects an authoritative mutation target outside the planned package union' {
        $name = 'Contoso.ClosedTargets'
        $packageName = 'Contoso.ClosedTargets_1.0.0.0_x64__publisher'
        $unplannedPackageName = 'Contoso.ClosedTargets_2.0.0.0_x64__publisher'
        $before = New-TestSystemAppxState -PackageNames $packageName
        $operationItem = New-TestSystemAppxOperation -Name $name -Before $before
        $request = New-TestSystemAppxRequest -Operations @($operationItem)
        $inconsistentSnapshot = New-TestSystemAppxSnapshot `
            -State $before `
            -RegisteredPackageNames @($packageName, $unplannedPackageName)

        Mock Get-SystemAppxSnapshot -ModuleName Winix.Appx { return $inconsistentSnapshot }

        { Invoke-SystemAppxApply -Request $request } |
            Should -Throw "*inventory for '$name' produced inconsistent mutation targets*"
        Should -Invoke Remove-ProvisionedPackage -ModuleName Winix.Appx -Times 0 -Exactly
        Should -Invoke Remove-RegisteredPackageForAllUsers -ModuleName Winix.Appx -Times 0 -Exactly
    }

    It 'reports a failed postcondition without accounting the current operation as applied' {
        $name = 'Contoso.Remains'
        $packageName = 'Contoso.Remains_1.0.0.0_x64__publisher'
        $before = New-TestSystemAppxState -PackageNames $packageName
        $operationItem = New-TestSystemAppxOperation -Name $name -Before $before
        $request = New-TestSystemAppxRequest -Operations @($operationItem)
        $snapshot = New-TestSystemAppxSnapshot `
            -State $before `
            -ProvisionedPackageNames $packageName

        Mock Get-SystemAppxSnapshot -ModuleName Winix.Appx { return $snapshot }
        Mock Get-SystemAppxState -ModuleName Winix.Appx { return $before }

        $result = Invoke-SystemAppxApply -Request $request

        $result.success | Should -BeFalse
        $result.changed | Should -BeTrue
        @($result.applied_operation_ids).Count | Should -Be 0
        $result.diagnostics[0].code | Should -Be 'appx.package.postcondition.not_absent'
        Should -Invoke Remove-ProvisionedPackage -ModuleName Winix.Appx -Times 1 -Exactly
    }
}
