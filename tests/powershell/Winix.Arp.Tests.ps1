BeforeAll {
    $sdkPath = Join-Path $PSScriptRoot '..\..\plugins\shared\Winix.PluginSdk.psm1'
    $modulePath = Join-Path $PSScriptRoot '..\..\plugins\packages\arp\Winix.Arp.psm1'
    Import-Module $sdkPath -Force
    Import-Module $modulePath -Force

    function New-TestArpState {
        param(
            [Parameter(Mandatory)] [string] $RegistrationId,
            [Parameter(Mandatory)] [string] $DisplayName,
            [string] $Version = '1.0',
            [string] $UninstallString = '"C:\Program Files\Contoso\OfficeClickToRun.exe" scenario=install'
        )

        return [pscustomobject][ordered]@{
            installed = $true
            registration_id = $RegistrationId
            display_name = $DisplayName
            version = $Version
            uninstall_string = $UninstallString
            architecture = 'x64'
            registry_path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$RegistrationId"
        }
    }

    function New-TestArpOperation {
        param([Parameter(Mandatory)] [object] $Before)

        $registrationId = [string]$Before.registration_id
        return [pscustomobject][ordered]@{
            id = "arp.system.uninstall.$registrationId"
            action = 'uninstall'
            resource = [pscustomobject]@{ type = 'arp.program'; id = $registrationId }
            before = $Before
            after = Get-ArpAbsentState -RegistrationId $registrationId
            data = [pscustomobject]@{
                invocation = Get-ArpUninstallInvocation -CommandLine $Before.uninstall_string
            }
        }
    }

    function New-TestArpRequest {
        param([Parameter(Mandatory)] [object[]] $Operations)

        $configuration = [ordered]@{}
        foreach ($operationItem in $Operations) {
            $configuration[$operationItem.resource.id] = [ordered]@{
                state = 'absent'
                display_name = $operationItem.before.display_name
            }
        }
        return [pscustomobject]@{
            protocol_version = 2
            path = 'system.packages.arp'
            configuration = [pscustomobject]$configuration
            operations = $Operations
        }
    }
}

Describe 'ARP closed-plan apply' {
    BeforeEach {
        Mock Write-WinixEvent -ModuleName Winix.Arp {}
        Mock Invoke-ArpUninstall -ModuleName Winix.Arp { return 0 }
    }

    It 'preflights operation two before mutating operation one' {
        $firstBefore = New-TestArpState -RegistrationId 'FirstProgram' -DisplayName 'First program'
        $secondBefore = New-TestArpState -RegistrationId 'SecondProgram' -DisplayName 'Second program'
        $request = New-TestArpRequest -Operations @(
            (New-TestArpOperation -Before $firstBefore)
            (New-TestArpOperation -Before $secondBefore)
        )
        $staleSecond = New-TestArpState -RegistrationId 'SecondProgram' -DisplayName 'Second program' -Version '2.0'

        Mock Get-ArpProgram -ModuleName Winix.Arp {
            param($RegistrationId)
            if ($RegistrationId -ceq 'FirstProgram') { return $firstBefore }
            return $staleSecond
        }

        { Invoke-ArpApply -Request $request } | Should -Throw "*SecondProgram*changed after planning*"
        Should -Invoke Invoke-ArpUninstall -ModuleName Winix.Arp -Times 0 -Exactly
        Should -Invoke Write-WinixEvent -ModuleName Winix.Arp -Times 0 -Exactly
    }

    It 'accepts a reordered before-state object after a complete JSON round trip' {
        $before = New-TestArpState -RegistrationId 'ReorderedProgram' -DisplayName 'Reordered program'
        $operationItem = New-TestArpOperation -Before $before
        $request = New-TestArpRequest -Operations @($operationItem)
        $script:arpObservationCount = 0
        $reorderedCurrent = @'
{"registry_path":"HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\ReorderedProgram","architecture":"x64","uninstall_string":"\"C:\\Program Files\\Contoso\\OfficeClickToRun.exe\" scenario=install","version":"1.0","display_name":"Reordered program","registration_id":"ReorderedProgram","installed":true}
'@ | ConvertFrom-Json
        $absent = Get-ArpAbsentState -RegistrationId 'ReorderedProgram'

        Mock Get-ArpProgram -ModuleName Winix.Arp {
            $script:arpObservationCount++
            if ($script:arpObservationCount -le 2) { return $reorderedCurrent }
            return $absent
        }

        $result = Invoke-ArpApply -Request $request

        $result.success | Should -BeTrue
        @($result.applied_operation_ids) | Should -Be @('arp.system.uninstall.ReorderedProgram')
        Should -Invoke Invoke-ArpUninstall -ModuleName Winix.Arp -Times 1 -Exactly
    }

    It 'rechecks the registration immediately before launching the uninstaller' {
        $before = New-TestArpState -RegistrationId 'RacedProgram' -DisplayName 'Raced program'
        $operationItem = New-TestArpOperation -Before $before
        $request = New-TestArpRequest -Operations @($operationItem)
        $stale = New-TestArpState -RegistrationId 'RacedProgram' -DisplayName 'Raced program' -Version '2.0'
        $script:arpObservationCount = 0

        Mock Get-ArpProgram -ModuleName Winix.Arp {
            $script:arpObservationCount++
            if ($script:arpObservationCount -eq 1) { return $before }
            return $stale
        }

        { Invoke-ArpApply -Request $request } | Should -Throw '*changed after queue preflight*'
        Should -Invoke Invoke-ArpUninstall -ModuleName Winix.Arp -Times 0 -Exactly
        Should -Invoke Write-WinixEvent -ModuleName Winix.Arp -Times 0 -Exactly
    }

    It 'rejects a tampered typed invocation before executing it' {
        $before = New-TestArpState -RegistrationId 'TamperedProgram' -DisplayName 'Tampered program'
        $operationItem = New-TestArpOperation -Before $before
        $operationItem.data.invocation.file_path = 'C:\Windows\System32\cmd.exe'
        $request = New-TestArpRequest -Operations @($operationItem)

        { Invoke-ArpApply -Request $request } | Should -Throw "*invocation*changed after planning*"
        Should -Invoke Invoke-ArpUninstall -ModuleName Winix.Arp -Times 0 -Exactly
    }

    It 'rejects coordinated command and data tampering against current state' {
        $current = New-TestArpState -RegistrationId 'CommandProgram' -DisplayName 'Command program'
        $observedCurrent = $current | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $operationItem = New-TestArpOperation -Before $current
        $operationItem.before.uninstall_string = '"C:\Program Files\Contoso\copilot_setup.exe" --uninstall'
        $operationItem.data.invocation = Get-ArpUninstallInvocation -CommandLine $operationItem.before.uninstall_string
        $request = New-TestArpRequest -Operations @($operationItem)

        Mock Get-ArpProgram -ModuleName Winix.Arp { return $observedCurrent }

        { Invoke-ArpApply -Request $request } | Should -Throw "*CommandProgram*changed after planning*"
        Should -Invoke Invoke-ArpUninstall -ModuleName Winix.Arp -Times 0 -Exactly
    }

    It 'rejects registration IDs that can escape the uninstall registry leaf' -ForEach @(
        '..'
        '.\Sibling'
        'Parent\Child'
        'Parent/Child'
        ' LeadingSpace'
        "Control$([char]1)Character"
    ) {
        { Assert-ArpRegistrationId -RegistrationId $_ } | Should -Throw '*ARP registration ID*'
    }
}

Describe 'ARP uninstall command planning' {
    It 'parses Windows quoting into typed arguments and adds the provider strategy' {
        $invocation = Get-ArpUninstallInvocation -CommandLine '"C:\Program Files\Common Files\Microsoft Shared\ClickToRun\OfficeClickToRun.exe" scenario=install "productstoremove=O365 Home"'

        $invocation.file_path | Should -Be 'C:\Program Files\Common Files\Microsoft Shared\ClickToRun\OfficeClickToRun.exe'
        @($invocation.arguments) | Should -Be @(
            'scenario=install'
            'productstoremove=O365 Home'
            'displaylevel=false'
            'forceappshutdown=true'
        )
        @($invocation.success_codes) | Should -Be @(0)
    }

    It 'rejects a supported provider basename at a non-canonical relative path' {
        { Get-ArpUninstallInvocation -CommandLine 'OfficeClickToRun.exe scenario=install' } |
            Should -Throw '*not fully qualified*'
    }

    It 'rejects unknown uninstall providers' {
        { Get-ArpUninstallInvocation -CommandLine '"C:\Program Files\Contoso\uninstall.exe" /silent' } |
            Should -Throw '*has no non-interactive strategy*'
    }

    It 'keeps native provider output out of the protocol stream' {
        $invocation = [pscustomobject]@{
            file_path = (Get-Process -Id $PID).Path
            arguments = @(
                '-NoLogo'
                '-NoProfile'
                '-NonInteractive'
                '-Command'
                'Write-Output provider-noise; Write-Error provider-error -ErrorAction Continue; exit 0'
            )
        }

        $result = @(Invoke-ArpUninstall -Invocation $invocation)

        $result | Should -HaveCount 1
        $result[0] | Should -Be 0
    }
}
