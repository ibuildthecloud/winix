BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\..\plugins\windows\wsl\Winix.Wsl.psm1'
    Import-Module $modulePath -Force

    function New-TestWslState {
        param(
            [bool] $FeaturesEnabled = $true,
            [bool] $Installed = $true,
            [bool] $RestartPending = $false,
            [bool] $UpdateRequired = $false,
            [AllowNull()] [string] $Version = '2.5.0.0',
            [string[]] $Distros = @()
        )

        return [pscustomobject][ordered]@{
            features_enabled = $FeaturesEnabled
            installed = $Installed
            restart_pending = $RestartPending
            update_required = $UpdateRequired
            version = $Version
            distros = @($Distros)
        }
    }

    function New-TestWslAbsentState {
        return [pscustomobject][ordered]@{
            features_enabled = $false
            installed = $false
            restart_pending = $false
            update_required = $false
            version = $null
            distros = @()
        }
    }

    function New-TestWslDistroOperation {
        param([Parameter(Mandatory)] [string] $Name)

        return [pscustomobject][ordered]@{
            id = "wsl.system.install-distro.$Name"
            action = 'install_distro'
            resource = [pscustomobject][ordered]@{ type = 'windows.wsl.distro'; id = $Name }
            before = [pscustomobject]@{ installed = $false }
            after = [pscustomobject]@{ installed = $true }
            data = [pscustomobject]@{ name = $Name }
        }
    }

    function New-TestWslUninstallOperation {
        param([Parameter(Mandatory)] [object] $Before)

        return [pscustomobject][ordered]@{
            id = 'wsl.system.uninstall'
            action = 'uninstall'
            resource = [pscustomobject][ordered]@{ type = 'windows.wsl'; id = 'wsl' }
            before = $Before
            after = New-TestWslAbsentState
            data = [pscustomobject]@{ destructive = $true }
        }
    }

    function New-TestWslRequest {
        param(
            [Parameter(Mandatory)] [object[]] $Operations,
            [Parameter(Mandatory)] [object] $Configuration
        )

        return [pscustomobject]@{
            protocol_version = 2
            path = 'system.windows.wsl'
            configuration = $Configuration
            operations = $Operations
        }
    }
}

Describe 'WSL closed-plan system apply' {
    BeforeEach {
        $script:wslMutationCount = 0
        Mock Write-WinixEvent -ModuleName Winix.Wsl {}
    }

    It 'preflights a stale second distribution before mutating the first' {
        $current = New-TestWslState -Distros @('Debian')
        $request = New-TestWslRequest -Configuration ([pscustomobject]@{ distros = @('Ubuntu', 'Debian') }) -Operations @(
            (New-TestWslDistroOperation -Name 'Ubuntu')
            (New-TestWslDistroOperation -Name 'Debian')
        )

        {
            Invoke-WslSystemApply -Request $request `
                -GetState { $current } `
                -ResolveDistros { param($names) $names } `
                -Mutate { $script:wslMutationCount++ }
        } | Should -Throw "*Debian*already installed*"

        $script:wslMutationCount | Should -Be 0
        Should -Invoke Write-WinixEvent -ModuleName Winix.Wsl -Times 0 -Exactly
    }

    It 'accepts a reordered full state after a complete JSON round trip' {
        $plannedBefore = New-TestWslState -Distros @('Ubuntu')
        $reorderedCurrent = @'
{"distros":["Ubuntu"],"version":"2.5.0.0","update_required":false,"restart_pending":false,"installed":true,"features_enabled":true}
'@ | ConvertFrom-Json
        $request = New-TestWslRequest -Configuration ([pscustomobject]@{ state = 'absent' }) -Operations @(
            (New-TestWslUninstallOperation -Before $plannedBefore)
        )
        $script:wslObservationCount = 0

        $result = Invoke-WslSystemApply -Request $request `
            -GetState {
                $script:wslObservationCount++
                if ($script:wslObservationCount -eq 1) { return $reorderedCurrent }
                return New-TestWslAbsentState
            } `
            -ResolveDistros { param($names) $names } `
            -Mutate { $script:wslMutationCount++ }

        $result.success | Should -BeTrue
        @($result.applied_operation_ids) | Should -Be @('wsl.system.uninstall')
        $script:wslMutationCount | Should -Be 1
    }

    It 'rejects tampered data in a later operation before any mutation' {
        $current = New-TestWslState
        $first = New-TestWslDistroOperation -Name 'Ubuntu'
        $second = New-TestWslDistroOperation -Name 'Debian'
        $second.data | Add-Member -NotePropertyName arguments -NotePropertyValue @('--exec', 'payload')
        $request = New-TestWslRequest -Configuration ([pscustomobject]@{ distros = @('Ubuntu', 'Debian') }) -Operations @($first, $second)

        {
            Invoke-WslSystemApply -Request $request `
                -GetState { $current } `
                -ResolveDistros { param($names) $names } `
                -Mutate { $script:wslMutationCount++ }
        } | Should -Throw '*tampered distribution data*'

        $script:wslMutationCount | Should -Be 0
        Should -Invoke Write-WinixEvent -ModuleName Winix.Wsl -Times 0 -Exactly
    }

    It 'rejects an unexpected operation property before mutation' {
        $operationItem = New-TestWslDistroOperation -Name 'Ubuntu'
        $operationItem | Add-Member -NotePropertyName command -NotePropertyValue 'wsl.exe --install Ubuntu'
        $request = New-TestWslRequest -Configuration ([pscustomobject]@{ distros = @('Ubuntu') }) -Operations @($operationItem)

        {
            Invoke-WslSystemApply -Request $request `
                -GetState { New-TestWslState } `
                -ResolveDistros { param($names) $names } `
                -Mutate { $script:wslMutationCount++ }
        } | Should -Throw '*unexpected: command*'

        $script:wslMutationCount | Should -Be 0
    }

    It 'rejects a tampered semantic resource before mutation' {
        $operationItem = New-TestWslDistroOperation -Name 'Ubuntu'
        $operationItem.resource.id = 'Debian'
        $request = New-TestWslRequest -Configuration ([pscustomobject]@{ distros = @('Ubuntu') }) -Operations @($operationItem)

        {
            Invoke-WslSystemApply -Request $request `
                -GetState { New-TestWslState } `
                -ResolveDistros { param($names) $names } `
                -Mutate { $script:wslMutationCount++ }
        } | Should -Throw '*not a configured WSL distribution operation*'

        $script:wslMutationCount | Should -Be 0
    }

    It 'rejects duplicate operation IDs before observation or mutation' {
        $first = New-TestWslDistroOperation -Name 'Ubuntu'
        $second = $first | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $request = New-TestWslRequest -Configuration ([pscustomobject]@{ distros = @('Ubuntu') }) -Operations @($first, $second)
        $script:wslObservationCount = 0

        {
            Invoke-WslSystemApply -Request $request `
                -GetState { $script:wslObservationCount++; New-TestWslState } `
                -ResolveDistros { param($names) $names } `
                -Mutate { $script:wslMutationCount++ }
        } | Should -Throw '*operation ID*duplicated*'

        $script:wslObservationCount | Should -Be 0
        $script:wslMutationCount | Should -Be 0
    }

    It 'rejects duplicate semantic resources even when IDs differ' {
        $first = New-TestWslDistroOperation -Name 'Ubuntu'
        $second = $first | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $second.id = 'wsl.system.install-distro.tampered'
        $request = New-TestWslRequest -Configuration ([pscustomobject]@{ distros = @('Ubuntu') }) -Operations @($first, $second)

        {
            Invoke-WslSystemApply -Request $request `
                -GetState { New-TestWslState } `
                -ResolveDistros { param($names) $names } `
                -Mutate { $script:wslMutationCount++ }
        } | Should -Throw '*resource*duplicated*'

        $script:wslMutationCount | Should -Be 0
    }

    It 'reports a failed postcondition without accounting the failed operation' {
        $current = New-TestWslState
        $request = New-TestWslRequest -Configuration ([pscustomobject]@{ distros = @('Ubuntu') }) -Operations @(
            (New-TestWslDistroOperation -Name 'Ubuntu')
        )

        $result = Invoke-WslSystemApply -Request $request `
            -GetState { $current } `
            -ResolveDistros { param($names) $names } `
            -Mutate { $script:wslMutationCount++ }

        $result.success | Should -BeFalse
        $result.changed | Should -BeTrue
        @($result.applied_operation_ids).Count | Should -Be 0
        $result.error.code | Should -Be 'wsl.apply.postcondition_failed'
        $script:wslMutationCount | Should -Be 1
    }
}

Describe 'WSL closed-plan user apply' {
    BeforeEach {
        Mock Write-WinixEvent -ModuleName Winix.Wsl {}
    }

    It 'rejects tampered first-run data before changing the registry' {
        $operationItem = [pscustomobject][ordered]@{
            id = 'wsl.user.suppress-first-run-oobe'
            action = 'suppress_first_run_oobe'
            resource = [pscustomobject]@{ type = 'windows.wsl.first_run_oobe'; id = 'current-user' }
            before = 'available'
            after = 'suppressed'
            data = [pscustomobject]@{ value = 1 }
        }
        $request = [pscustomobject]@{
            path = 'users.current.windows.wsl'
            configuration = [pscustomobject]@{ first_run_oobe = 'suppressed' }
            operations = @($operationItem)
        }
        $script:wslMutationCount = 0

        {
            Invoke-WslUserApply -Request $request -GetState { 'available' } -Mutate { $script:wslMutationCount++ }
        } | Should -Throw '*data has invalid properties*'

        $script:wslMutationCount | Should -Be 0
    }
}
