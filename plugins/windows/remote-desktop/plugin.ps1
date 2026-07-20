param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.PluginSdk.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.RegistrySettings.psm1') -Force
$request = Read-WinixRequest
$desired = "$($request.configuration.state)"
$definitions = @(@{ id = 'state'; path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'; name = 'fDenyTSConnections'; property_type = 'DWord'; desired_raw = $(if ($desired -eq 'enabled') { 0 } else { 1 }); decode = { param($value) if ($value -eq 0) { 'enabled' } else { 'disabled' } } })
Invoke-WinixRegistrySettingsPlugin -Operation $Operation -Request $request -Scope system -ResourceType 'windows.remote_desktop.setting' -Definitions $definitions
