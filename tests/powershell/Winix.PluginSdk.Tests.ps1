BeforeAll {
    $sdkPath = Join-Path $PSScriptRoot '..\..\plugins\shared\Winix.PluginSdk.psm1'
    Import-Module $sdkPath -Force
}

Describe 'Test-WinixJsonEqual' {
    It 'treats deliberately reordered object properties as equal after a complete JSON round trip' {
        $plannedState = @'
{"before":{"path":"HKCU:\\Software\\Winix","values":{"enabled":true,"count":2}},"operation_id":"registry:example"}
'@ | ConvertFrom-Json
        $roundTrippedState = @'
{"operation_id":"registry:example","before":{"values":{"count":2,"enabled":true},"path":"HKCU:\\Software\\Winix"}}
'@ | ConvertFrom-Json

        Test-WinixJsonEqual -Left $plannedState -Right $roundTrippedState | Should -BeTrue
    }

    It 'does not ignore array order' {
        $left = [pscustomobject]@{ values = @('first', 'second') }
        $right = [pscustomobject]@{ values = @('second', 'first') }

        Test-WinixJsonEqual -Left $left -Right $right | Should -BeFalse
    }

    It 'detects a changed nested value' {
        $left = [pscustomobject]@{ state = [pscustomobject]@{ enabled = $true } }
        $right = [pscustomobject]@{ state = [pscustomobject]@{ enabled = $false } }

        Test-WinixJsonEqual -Left $left -Right $right | Should -BeFalse
    }
}
