param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.PluginSdk.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.RegistrySettings.psm1') -Force
$request = Read-WinixRequest
$definitions = [System.Collections.Generic.List[object]]::new()

if (Test-WinixPropertyPresent $request.configuration 'alt_tab') {
    $definitions.Add(@{
        id = 'alt_tab'
        path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        name = 'MultiTaskingAltTabFilter'
        property_type = 'DWord'
        desired_raw = 3
        decode = {
            param($value)
            if ($value -eq 3) { 'windows_only' } else { 'windows_and_tabs' }
        }
    })
}

Invoke-WinixRegistrySettingsPlugin -Operation $Operation -Request $request -Scope user -ResourceType 'windows.multitasking.setting' -Definitions @($definitions) -RestartExplorer $true
