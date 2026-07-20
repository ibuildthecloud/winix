BeforeAll {
    $sdkPath = Join-Path $PSScriptRoot '..\..\plugins\shared\Winix.PluginSdk.psm1'
    $modulePath = Join-Path $PSScriptRoot '..\..\plugins\packages\windows-installer\Winix.WindowsInstaller.psm1'
    Import-Module $sdkPath -Force
    Import-Module $modulePath -Force

    function New-TestWindowsInstallerState {
        param(
            [Parameter(Mandatory)] [string] $ProductCode,
            [string] $DisplayName = 'Contoso application',
            [string] $Version = '1.0'
        )

        return [pscustomobject][ordered]@{
            installed = $true
            product_code = $ProductCode
            display_name = $DisplayName
            version = $Version
            registry_path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$ProductCode"
        }
    }

    function New-TestWindowsInstallerRequest {
        param([Parameter(Mandatory)] [object[]] $Operations)

        $configuration = [ordered]@{}
        foreach ($operationItem in $Operations) {
            $configuration[$operationItem.resource.id] = [ordered]@{ state = 'absent' }
        }
        $request = [ordered]@{
            protocol_version = 2
            path = 'system.packages.windows_installer'
            configuration = [pscustomobject]$configuration
            operations = $Operations
        }
        # Apply always runs in a separate process and receives a JSON-decoded
        # copy of the plan. Keep these tests on that real protocol boundary.
        return $request | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
    }
}

Describe 'Windows Installer closed-plan apply' {
    BeforeEach {
        Mock Write-WinixEvent -ModuleName Winix.WindowsInstaller {}
        Mock Invoke-WindowsInstallerUninstall -ModuleName Winix.WindowsInstaller { return 0 }
    }

    It 'preflights operation two before mutating operation one' {
        $firstCode = '{11111111-1111-1111-1111-111111111111}'
        $secondCode = '{22222222-2222-2222-2222-222222222222}'
        $firstBefore = New-TestWindowsInstallerState -ProductCode $firstCode -DisplayName 'First application'
        $secondBefore = New-TestWindowsInstallerState -ProductCode $secondCode -DisplayName 'Second application'
        $request = New-TestWindowsInstallerRequest -Operations @(
            (New-WindowsInstallerOperation -ProductCode $firstCode -Before $firstBefore)
            (New-WindowsInstallerOperation -ProductCode $secondCode -Before $secondBefore)
        )
        $staleSecond = New-TestWindowsInstallerState -ProductCode $secondCode -DisplayName 'Second application' -Version '2.0'

        Mock Get-WindowsInstallerProduct -ModuleName Winix.WindowsInstaller {
            param($ProductCode)
            if ($ProductCode -ceq $firstCode) { return $firstBefore }
            return $staleSecond
        }

        { Invoke-WindowsInstallerApply -Request $request } | Should -Throw "*$secondCode*changed after planning*"
        Should -Invoke Invoke-WindowsInstallerUninstall -ModuleName Winix.WindowsInstaller -Times 0 -Exactly
        Should -Invoke Write-WinixEvent -ModuleName Winix.WindowsInstaller -Times 0 -Exactly
    }

    It 'accepts reordered before-state properties after a complete JSON round trip' {
        $productCode = '{33333333-3333-3333-3333-333333333333}'
        $before = New-TestWindowsInstallerState -ProductCode $productCode -DisplayName 'Reordered application'
        $operationItem = New-WindowsInstallerOperation -ProductCode $productCode -Before $before
        $request = New-TestWindowsInstallerRequest -Operations @($operationItem)
        $script:windowsInstallerObservationCount = 0
        $reorderedCurrent = @'
{"registry_path":"HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{33333333-3333-3333-3333-333333333333}","version":"1.0","display_name":"Reordered application","product_code":"{33333333-3333-3333-3333-333333333333}","installed":true}
'@ | ConvertFrom-Json
        $absent = Get-WindowsInstallerAbsentState -ProductCode $productCode

        Mock Get-WindowsInstallerProduct -ModuleName Winix.WindowsInstaller {
            $script:windowsInstallerObservationCount++
            if ($script:windowsInstallerObservationCount -le 2) { return $reorderedCurrent }
            return $absent
        }

        $result = Invoke-WindowsInstallerApply -Request $request

        $result.success | Should -BeTrue
        @($result.applied_operation_ids) | Should -Be @("windows_installer.system.uninstall.$productCode")
        Should -Invoke Invoke-WindowsInstallerUninstall -ModuleName Winix.WindowsInstaller -Times 1 -Exactly
    }

    It 'rejects tampered operation data before observation or mutation' {
        $productCode = '{44444444-4444-4444-4444-444444444444}'
        $before = New-TestWindowsInstallerState -ProductCode $productCode
        $operationItem = New-WindowsInstallerOperation -ProductCode $productCode -Before $before
        $operationItem.data = [pscustomobject]@{ arguments = @('/quiet') }
        $request = New-TestWindowsInstallerRequest -Operations @($operationItem)
        Mock Get-WindowsInstallerProduct -ModuleName Winix.WindowsInstaller {
            throw 'Tampered data must be rejected before observation.'
        }

        { Invoke-WindowsInstallerApply -Request $request } | Should -Throw '*planned data*changed after planning*'
        Should -Invoke Get-WindowsInstallerProduct -ModuleName Winix.WindowsInstaller -Times 0 -Exactly
        Should -Invoke Invoke-WindowsInstallerUninstall -ModuleName Winix.WindowsInstaller -Times 0 -Exactly
    }

    It 'rejects duplicate resource identities before mutation' {
        $productCode = '{55555555-5555-5555-5555-555555555555}'
        $before = New-TestWindowsInstallerState -ProductCode $productCode
        $firstOperation = New-WindowsInstallerOperation -ProductCode $productCode -Before $before
        $secondOperation = New-WindowsInstallerOperation -ProductCode $productCode -Before $before
        $secondOperation.id = "windows_installer.system.uninstall.$productCode.duplicate"
        $request = New-TestWindowsInstallerRequest -Operations @($firstOperation, $secondOperation)

        Mock Get-WindowsInstallerProduct -ModuleName Winix.WindowsInstaller { return $before }

        { Invoke-WindowsInstallerApply -Request $request } | Should -Throw '*Duplicate planned Windows Installer product*'
        Should -Invoke Invoke-WindowsInstallerUninstall -ModuleName Winix.WindowsInstaller -Times 0 -Exactly
    }

    It 'verifies the exact planned postcondition after uninstall' {
        $productCode = '{66666666-6666-6666-6666-666666666666}'
        $before = New-TestWindowsInstallerState -ProductCode $productCode
        $operationItem = New-WindowsInstallerOperation -ProductCode $productCode -Before $before
        $request = New-TestWindowsInstallerRequest -Operations @($operationItem)

        Mock Get-WindowsInstallerProduct -ModuleName Winix.WindowsInstaller { return $before }

        { Invoke-WindowsInstallerApply -Request $request } | Should -Throw '*did not reach its planned postcondition*'
        Should -Invoke Invoke-WindowsInstallerUninstall -ModuleName Winix.WindowsInstaller -Times 1 -Exactly
    }

    It 'preserves the Windows Installer reboot-required exit code' {
        $productCode = '{77777777-7777-7777-7777-777777777777}'
        $before = New-TestWindowsInstallerState -ProductCode $productCode
        $operationItem = New-WindowsInstallerOperation -ProductCode $productCode -Before $before
        $request = New-TestWindowsInstallerRequest -Operations @($operationItem)
        $absent = Get-WindowsInstallerAbsentState -ProductCode $productCode
        $script:windowsInstallerRestartObservationCount = 0

        Mock Get-WindowsInstallerProduct -ModuleName Winix.WindowsInstaller {
            $script:windowsInstallerRestartObservationCount++
            if ($script:windowsInstallerRestartObservationCount -le 2) { return $before }
            return $absent
        }
        Mock Invoke-WindowsInstallerUninstall -ModuleName Winix.WindowsInstaller { return 3010 }

        $result = Invoke-WindowsInstallerApply -Request $request

        $result.success | Should -BeTrue
        $result.restart_required.system | Should -BeTrue
    }
}

Describe 'Windows Installer runtime validation' {
    It 'rejects noncanonical product codes even when schema validation is bypassed' {
        $configuration = [pscustomobject]@{
            '{aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa}' = [pscustomobject]@{ state = 'absent' }
        }

        { Assert-WindowsInstallerConfiguration -Configuration $configuration } | Should -Throw '*not canonical*'
    }
}
