param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.PluginSdk.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.RegistrySettings.psm1') -Force
$request = Read-WinixRequest
$definitions = [System.Collections.Generic.List[object]]::new()
$base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
if (Test-WinixPropertyPresent $request.configuration 'do_not_disturb') {
    $desired = "$($request.configuration.do_not_disturb)"
    $definitions.Add(@{ id = 'do_not_disturb'; path = $base; name = 'NOC_GLOBAL_SETTING_TOASTS_ENABLED'; property_type = 'DWord'; desired_raw = $(if ($desired -eq 'enabled') { 0 } else { 1 }); decode = { param($value) if ($value -eq 0) { 'enabled' } else { 'disabled' } } })
}
if ((Test-WinixPropertyPresent $request.configuration 'applications') -and (Test-WinixPropertyPresent $request.configuration.applications 'PowerToys')) {
    $desired = [bool]$request.configuration.applications.PowerToys.enabled
    $definitions.Add(@{ id = 'applications.PowerToys'; path = (Join-Path $base 'PowerToys'); name = 'Enabled'; property_type = 'DWord'; desired_raw = $(if ($desired) { 1 } else { 0 }); decode = { param($value) $value -ne 0 } })
}
Invoke-WinixRegistrySettingsPlugin -Operation $Operation -Request $request -Scope user -ResourceType 'windows.notifications.setting' -Definitions @($definitions)
