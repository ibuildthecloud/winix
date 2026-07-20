param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.PluginSdk.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.RegistrySettings.psm1') -Force
$request = Read-WinixRequest
$settingsPath = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$definitions = [System.Collections.Generic.List[object]]::new()

function Add-BooleanDefinition([string] $Id, [string] $Name, [bool] $Desired) {
    $definitions.Add(@{
        id = $Id
        path = $settingsPath
        name = $Name
        property_type = 'DWord'
        desired_raw = $(if ($Desired) { 1 } else { 0 })
        decode = { param($value) $value -eq 1 }.GetNewClosure()
    })
}

if (Test-WinixPropertyPresent $request.configuration 'get_latest_updates_as_soon_as_available') {
    Add-BooleanDefinition 'get_latest_updates_as_soon_as_available' 'IsContinuousInnovationOptedIn' ([bool]$request.configuration.get_latest_updates_as_soon_as_available)
}
if (Test-WinixPropertyPresent $request.configuration 'restart_notifications') {
    Add-BooleanDefinition 'restart_notifications' 'RestartNotificationsAllowed2' ([bool]$request.configuration.restart_notifications)
}
if (Test-WinixPropertyPresent $request.configuration 'update_other_microsoft_products') {
    Add-BooleanDefinition 'update_other_microsoft_products' 'AllowMUUpdateService' ([bool]$request.configuration.update_other_microsoft_products)
}

Invoke-WinixRegistrySettingsPlugin -Operation $Operation -Request $request -Scope system -ResourceType 'windows.update.setting' -Definitions @($definitions)
