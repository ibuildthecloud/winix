param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.PluginSdk.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.RegistrySettings.psm1') -Force
$request = Read-WinixRequest
$advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$explorer = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
$definitions = [System.Collections.Generic.List[object]]::new()

function Add-BooleanDefinition([string] $Id, [string] $Path, [string] $Name, [bool] $Desired, [int] $TrueValue = 1, [int] $FalseValue = 0) {
    $definitions.Add(@{ id = $Id; path = $Path; name = $Name; property_type = 'DWord'; desired_raw = $(if ($Desired) { $TrueValue } else { $FalseValue }); decode = { param($value) $value -eq $TrueValue }.GetNewClosure() })
}

if (Test-WinixPropertyPresent $request.configuration 'show_file_extensions') { Add-BooleanDefinition 'show_file_extensions' $advanced 'HideFileExt' ([bool]$request.configuration.show_file_extensions) 0 1 }
if (Test-WinixPropertyPresent $request.configuration 'show_hidden_files') { Add-BooleanDefinition 'show_hidden_files' $advanced 'Hidden' ([bool]$request.configuration.show_hidden_files) }
if (Test-WinixPropertyPresent $request.configuration 'show_full_path_in_title_bar') { Add-BooleanDefinition 'show_full_path_in_title_bar' $advanced 'FullPathAddress' ([bool]$request.configuration.show_full_path_in_title_bar) }
if (Test-WinixPropertyPresent $request.configuration 'launch_to') {
    $desired = if ($request.configuration.launch_to -eq 'this_pc') { 1 } else { 2 }
    $definitions.Add(@{ id = 'launch_to'; path = $advanced; name = 'LaunchTo'; property_type = 'DWord'; desired_raw = $desired; decode = { param($value) if ($value -eq 1) { 'this_pc' } else { 'home' } } })
}
if (Test-WinixPropertyPresent $request.configuration 'show_frequent_folders') { Add-BooleanDefinition 'show_frequent_folders' $advanced 'ShowFrequent' ([bool]$request.configuration.show_frequent_folders) }
if (Test-WinixPropertyPresent $request.configuration 'show_recent_files') { Add-BooleanDefinition 'show_recent_files' $explorer 'ShowRecent' ([bool]$request.configuration.show_recent_files) }
if (Test-WinixPropertyPresent $request.configuration 'show_cloud_files_in_quick_access') { Add-BooleanDefinition 'show_cloud_files_in_quick_access' $explorer 'ShowCloudFilesInQuickAccess' ([bool]$request.configuration.show_cloud_files_in_quick_access) }
if (Test-WinixPropertyPresent $request.configuration 'show_version_control') { Add-BooleanDefinition 'show_version_control' $advanced 'NavPaneShowVersionControl' ([bool]$request.configuration.show_version_control) }
if (Test-WinixPropertyPresent $request.configuration 'show_sync_provider_notifications') { Add-BooleanDefinition 'show_sync_provider_notifications' $advanced 'ShowSyncProviderNotifications' ([bool]$request.configuration.show_sync_provider_notifications) }

Invoke-WinixRegistrySettingsPlugin -Operation $Operation -Request $request -Scope user -ResourceType 'windows.file_explorer.setting' -Definitions @($definitions) -RestartExplorer $true
