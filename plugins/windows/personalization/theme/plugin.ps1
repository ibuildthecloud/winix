param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\..\shared\Winix.PluginSdk.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\..\shared\Winix.RegistrySettings.psm1') -Force
$request = Read-WinixRequest
$desired = if ($request.configuration.mode -eq 'dark') { 0 } else { 1 }
$path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$decode = { param($value) if ($value -eq 0) { 'dark' } else { 'light' } }
$definitions = @(
    @{ id = 'apps_mode'; path = $path; name = 'AppsUseLightTheme'; property_type = 'DWord'; desired_raw = $desired; decode = $decode },
    @{ id = 'system_mode'; path = $path; name = 'SystemUsesLightTheme'; property_type = 'DWord'; desired_raw = $desired; decode = $decode }
)
Invoke-WinixRegistrySettingsPlugin -Operation $Operation -Request $request -Scope user -ResourceType 'windows.personalization.theme.setting' -Definitions $definitions -RestartExplorer $true
