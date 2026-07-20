param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.PluginSdk.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.RegistrySettings.psm1') -Force
$request = Read-WinixRequest
$desired = "$($request.configuration.state)"
$definitions = @(@{ id = 'state'; path = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; name = 'AllowNewsAndInterests'; property_type = 'DWord'; desired_raw = $(if ($desired -eq 'enabled') { 1 } else { 0 }); decode = { param($value) if ($value -eq 0) { 'disabled' } else { 'enabled' } } })
Invoke-WinixRegistrySettingsPlugin -Operation $Operation -Request $request -Scope system -ResourceType 'windows.widgets.setting' -Definitions $definitions
