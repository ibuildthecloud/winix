param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\..\shared\Winix.PluginSdk.psm1') -Force
$request = Read-WinixRequest
if ($Operation -eq 'validate') {
    Write-WinixResponse @{ protocol_version = 2; valid = $true; diagnostics = @() }
    exit
}

Add-Type -Path (Join-Path $PSScriptRoot 'TaskbarSettingsApi.cs') | Out-Null

$advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$searchPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'
$layoutPolicyPath = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'
$bluetoothPath = 'HKCU:\Control Panel\Bluetooth'
$notifyIconSettingsPath = 'HKCU:\Control Panel\NotifyIconSettings'
$layoutFile = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Winix\TaskbarLayoutModification.xml'
$portableApps = @{
    windows_terminal = @{ type = 'app_user_model_id'; id = 'Microsoft.WindowsTerminal_8wekyb3d8bbwe!App' }
    jetbrains_toolbox = @{ type = 'desktop_application_link_path'; id = '%APPDATA%\Microsoft\Windows\Start Menu\Programs\JetBrains Toolbox.lnk' }
    microsoft_edge = @{ type = 'desktop_application_id'; id = 'MSEdge' }
}
$script:otherIconInventory = $null
$state = [ordered]@{}
$operations = [System.Collections.Generic.List[object]]::new()
$diagnostics = [System.Collections.Generic.List[object]]::new()

function Add-RegistryPlan([string] $Id, [string] $Path, [string] $Name, [object] $Current, [object] $Desired, [string] $PropertyType = 'DWord') {
    if ("$Current" -eq "$Desired") { return }
    $operations.Add([ordered]@{
        id = "taskbar.$Id"
        action = 'set_registry_value'
        resource = @{ type = 'windows.personalization.taskbar'; id = $Id }
        before = $Current
        after = $Desired
        data = @{ path = $Path; name = $Name; property_type = $PropertyType }
    })
}

function Get-TaskbarSystemSettingRaw([object] $Mapping) {
    if ($Mapping.value_type -eq 'int32') {
        return [Winix.Windows.Personalization.TaskbarSettingsApi]::ReadInt32($Mapping.setting_id)
    }
    return [Winix.Windows.Personalization.TaskbarSettingsApi]::ReadBoolean($Mapping.setting_id)
}

function Add-TaskbarSystemSettingPlan([string] $Id, [object] $Mapping, [object] $Current, [object] $Desired) {
    if ($Current -eq $Desired) { return }
    $operations.Add([ordered]@{
        id = "taskbar.$Id"
        action = 'set_system_setting'
        resource = @{ type = 'windows.personalization.taskbar'; id = $Id }
        before = $Current
        after = $Desired
        data = @{
            setting_id = $Mapping.setting_id
            value_type = $Mapping.value_type
        }
    })
}

function ConvertTo-TaskbarLayoutXml([object[]] $Slots, [bool] $Exhaustive) {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('<?xml version="1.0" encoding="utf-8"?>')
    $lines.Add('<LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" Version="1">')
    if ($Exhaustive) {
        $lines.Add('  <CustomTaskbarLayoutCollection PinListPlacement="Replace">')
    } else {
        $lines.Add('  <CustomTaskbarLayoutCollection PinListPlacement="Append">')
    }
    $lines.Add('    <defaultlayout:TaskbarLayout>')
    $lines.Add('      <taskbar:TaskbarPinList>')
    foreach ($slot in $Slots) {
        if (Test-WinixPropertyPresent $slot 'app_user_model_id') {
            $value = [System.Security.SecurityElement]::Escape([string]$slot.app_user_model_id)
            $lines.Add(('        <taskbar:UWA AppUserModelID="{0}" />' -f $value))
        } elseif (Test-WinixPropertyPresent $slot 'desktop_application_id') {
            $value = [System.Security.SecurityElement]::Escape([string]$slot.desktop_application_id)
            $lines.Add(('        <taskbar:DesktopApp DesktopApplicationID="{0}" />' -f $value))
        } else {
            $value = [System.Security.SecurityElement]::Escape([string]$slot.desktop_application_link_path)
            $lines.Add(('        <taskbar:DesktopApp DesktopApplicationLinkPath="{0}" />' -f $value))
        }
    }
    $lines.Add('      </taskbar:TaskbarPinList>')
    $lines.Add('    </defaultlayout:TaskbarLayout>')
    $lines.Add('  </CustomTaskbarLayoutCollection>')
    $lines.Add('</LayoutModificationTemplate>')
    return $lines -join "`n"
}

function Get-FileTextOrNull([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return [System.IO.File]::ReadAllText($Path)
}

function Get-OtherIconInventory {
    if ($null -ne $script:otherIconInventory) { return @($script:otherIconInventory) }
    $inventory = [System.Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $notifyIconSettingsPath) {
        foreach ($entry in @(Get-ChildItem -LiteralPath $notifyIconSettingsPath)) {
            $executablePath = Get-WinixProperty $entry.PSPath 'ExecutablePath'
            if ($null -eq $executablePath) { continue }
            $resolvedPath = [Winix.Windows.Personalization.TaskbarSettingsApi]::ExpandKnownFolderPath([string]$executablePath)
            $displayName = $null
            if (Test-Path -LiteralPath $resolvedPath -PathType Leaf) {
                $version = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($resolvedPath)
                if (-not [string]::IsNullOrWhiteSpace($version.FileDescription)) {
                    $displayName = $version.FileDescription.Trim()
                } elseif (-not [string]::IsNullOrWhiteSpace($version.ProductName)) {
                    $displayName = $version.ProductName.Trim()
                }
            }
            if ([string]::IsNullOrWhiteSpace($displayName)) {
                $tooltip = [string](Get-WinixProperty $entry.PSPath 'InitialTooltip')
                if (-not [string]::IsNullOrWhiteSpace($tooltip)) {
                    $displayName = ($tooltip -split "`r?`n", 2)[0].Trim()
                }
            }
            if ([string]::IsNullOrWhiteSpace($displayName)) { continue }
            $inventory.Add([ordered]@{
                display_name = $displayName
                entry_id = [string]$entry.PSChildName
                executable_path = [string]$executablePath
                resolved_executable_path = $resolvedPath
                is_promoted = Get-WinixProperty $entry.PSPath 'IsPromoted'
            })
        }
    }
    $script:otherIconInventory = @($inventory)
    return @($script:otherIconInventory)
}

function Get-OtherIconState([string] $DisplayName) {
    $matchingIcons = @(Get-OtherIconInventory | Where-Object { $_.display_name -ieq $DisplayName })
    if ($matchingIcons.Count -gt 1) { throw "System tray display name '$DisplayName' matches multiple notification-area entries." }
    if ($matchingIcons.Count -eq 0) {
        return [ordered]@{ state = 'absent'; display_name = $DisplayName }
    }
    $match = $matchingIcons[0]
    return [ordered]@{
        state = 'registered'
        visibility = $(if ($match.is_promoted -eq 1) { 'shown' } else { 'hidden' })
        display_name = $match.display_name
        entry_id = $match.entry_id
        executable_path = $match.executable_path
        resolved_executable_path = $match.resolved_executable_path
        is_promoted = $match.is_promoted
    }
}

$booleans = @{
    show_copilot = @{ path = $advanced; name = 'ShowCopilotButton'; property_type = 'DWord' }
    show_badges = @{ path = $advanced; name = 'TaskbarBadges'; property_type = 'DWord' }
}
$systemSettings = [ordered]@{
    alignment = @{
        setting_id = 'SystemSettings_DesktopTaskbar_Al'
        value_type = 'int32'
        desired = @{ left = 0; center = 1 }
        observed = @{ '0' = 'left'; '1' = 'center' }
    }
    show_task_view = @{
        setting_id = 'SystemSettings_DesktopTaskbar_TaskView'
        value_type = 'boolean'
    }
    show_widgets = @{
        setting_id = 'SystemSettings_DesktopTaskbar_Da'
        value_type = 'boolean'
    }
}
foreach ($name in $systemSettings.Keys) {
    if (-not (Test-WinixPropertyPresent $request.configuration $name)) { continue }
    $mapping = $systemSettings[$name]
    $current = Get-TaskbarSystemSettingRaw $mapping
    if ($mapping.value_type -eq 'int32') {
        $currentName = $mapping.observed["$current"]
        if ($null -eq $currentName) {
            throw "Taskbar setting '$name' returned unknown value '$current'; the undocumented Windows API has changed."
        }
        $desired = $mapping.desired[[string]$request.configuration.$name]
        $state[$name] = $currentName
    } else {
        $desired = [bool]$request.configuration.$name
        $state[$name] = [bool]$current
    }
    Add-TaskbarSystemSettingPlan -Id $name -Mapping $mapping -Current $current -Desired $desired
}
foreach ($name in $booleans.Keys) {
    if (-not (Test-WinixPropertyPresent $request.configuration $name)) { continue }
    $mapping = $booleans[$name]
    $current = Get-WinixProperty $mapping.path $mapping.name
    $state[$name] = ("$current" -ne '0')
    $desiredNumber = if ($request.configuration.$name) { 1 } else { 0 }
    $desired = if ($mapping.property_type -eq 'String') { "$desiredNumber" } else { $desiredNumber }
    Add-RegistryPlan -Id $name -Path $mapping.path -Name $mapping.name -Current $current -Desired $desired -PropertyType $mapping.property_type
}

if (Test-WinixPropertyPresent $request.configuration 'show_search') {
    $values = @{ hidden = 0; icon = 1; box = 2 }
    $reverse = @{ '0' = 'hidden'; '1' = 'icon'; '2' = 'box' }
    $current = Get-WinixProperty $searchPath 'SearchboxTaskbarMode'
    $state.show_search = $reverse["$current"]
    Add-RegistryPlan -Id 'show_search' -Path $searchPath -Name 'SearchboxTaskbarMode' -Current $current -Desired $values[$request.configuration.show_search]
}
if (Test-WinixPropertyPresent $request.configuration 'combine_buttons') {
    $values = @{ always = 0; when_full = 1; never = 2 }
    $reverse = @{ '0' = 'always'; '1' = 'when_full'; '2' = 'never' }
    $current = Get-WinixProperty $advanced 'TaskbarGlomLevel'
    $state.combine_buttons = $reverse["$current"]
    Add-RegistryPlan -Id 'combine_buttons' -Path $advanced -Name 'TaskbarGlomLevel' -Current $current -Desired $values[$request.configuration.combine_buttons]
}
if (Test-WinixPropertyPresent $request.configuration 'system_tray') {
    $trayState = [ordered]@{}
    if (Test-WinixPropertyPresent $request.configuration.system_tray 'show_seconds') {
        $current = Get-WinixProperty $advanced 'ShowSecondsInSystemClock'
        $trayState.show_seconds = ($current -ne 0)
        Add-RegistryPlan -Id 'system_tray.show_seconds' -Path $advanced -Name 'ShowSecondsInSystemClock' -Current $current -Desired $(if ($request.configuration.system_tray.show_seconds) { 1 } else { 0 })
    }
    if (Test-WinixPropertyPresent $request.configuration.system_tray 'show_touch_keyboard') {
        $values = @{ never = 0; when_no_keyboard = 1; always = 2 }
        $reverse = @{ '0' = 'never'; '1' = 'when_no_keyboard'; '2' = 'always' }
        $current = Get-WinixProperty $advanced 'TouchKeyboardAutoInvokeEnabled'
        $trayState.show_touch_keyboard = $reverse["$current"]
        Add-RegistryPlan -Id 'system_tray.show_touch_keyboard' -Path $advanced -Name 'TouchKeyboardAutoInvokeEnabled' -Current $current -Desired $values[$request.configuration.system_tray.show_touch_keyboard]
    }
    if (Test-WinixPropertyPresent $request.configuration.system_tray 'show_bluetooth') {
        $current = Get-WinixProperty $bluetoothPath 'Notification Area Icon'
        $trayState.show_bluetooth = ($current -ne 0)
        Add-RegistryPlan -Id 'system_tray.show_bluetooth' -Path $bluetoothPath -Name 'Notification Area Icon' -Current $current -Desired $(if ($request.configuration.system_tray.show_bluetooth) { 1 } else { 0 })
    }
    if (Test-WinixPropertyPresent $request.configuration.system_tray 'other_icons') {
        $otherIconsState = [ordered]@{}
        $configuredNames = @{}
        foreach ($displayName in $request.configuration.system_tray.other_icons.PSObject.Properties.Name) {
            if ($configuredNames.ContainsKey($displayName)) { throw "System tray display names must be unique ignoring case: '$displayName'." }
            $configuredNames[$displayName] = $true
            $current = Get-OtherIconState $displayName
            $desiredVisibility = [string]$request.configuration.system_tray.other_icons.PSObject.Properties[$displayName].Value.visibility
            $otherIconsState[$displayName] = $current
            if ($current.state -eq 'absent') {
                $diagnostic = @{ severity = 'error'; code = 'taskbar.system_tray.other_icon_not_registered'; path = "system_tray.other_icons.$displayName"; message = "No registered notification-area icon has the display name '$displayName'." }
                $diagnostics.Add($diagnostic)
                Write-WinixEvent -Kind 'diagnostic' -ResourceType 'windows.personalization.taskbar' -ResourceId "system_tray.other_icons.$displayName" -Diagnostic $diagnostic
            } elseif ($current.visibility -ne $desiredVisibility) {
                $operations.Add([ordered]@{
                    id = "taskbar.system_tray.other_icons.$displayName"
                    action = 'set_other_icon_visibility'
                    resource = @{ type = 'windows.personalization.taskbar'; id = "system_tray.other_icons.$displayName" }
                    before = $current
                    after = @{ visibility = $desiredVisibility }
                    data = @{ display_name = $displayName; entry_id = $current.entry_id }
                })
            }
        }
        $trayState.other_icons = $otherIconsState
    }
    $state.system_tray = $trayState
}
if (Test-WinixPropertyPresent $request.configuration 'automatically_hide') {
    $current = [Winix.Windows.Personalization.TaskbarSettingsApi]::ReadAutomaticallyHide()
    $desired = [bool]$request.configuration.automatically_hide
    $state.automatically_hide = $current
    if ($current -ne $desired) {
        $operations.Add([ordered]@{
            id = 'taskbar.automatically_hide'
            action = 'set_automatically_hide'
            resource = @{ type = 'windows.personalization.taskbar'; id = 'automatically_hide' }
            before = $current
            after = $desired
            data = @{}
        })
    }
}

if (Test-WinixPropertyPresent $request.configuration 'slots') {
    $windowsVersion = [Environment]::OSVersion.Version
    if ($windowsVersion.Major -lt 10 -or $windowsVersion.Build -lt 22000) {
        $diagnostic = @{ severity = 'error'; code = 'taskbar.slots.windows_11_required'; path = 'slots'; message = 'Ordered taskbar slots require Windows 11 (build 22000 or newer).' }
        $diagnostics.Add($diagnostic)
        Write-WinixEvent -Kind 'diagnostic' -ResourceType 'windows.personalization.taskbar' -ResourceId 'slots' -Diagnostic $diagnostic
    } else {
        $slotConfiguration = $request.configuration.slots
        $desiredSlots = @($slotConfiguration.apps)
        $exhaustive = [bool]$slotConfiguration.exhaustive
        $state.slots = $null
        if (-not $exhaustive) {
            $diagnostic = @{ severity = 'warning'; code = 'taskbar.slots.non_exhaustive_order'; path = 'slots.exhaustive'; message = 'Existing pins are retained and may precede configured apps, so Win+number positions are not guaranteed.' }
            $diagnostics.Add($diagnostic)
            Write-WinixEvent -Kind 'diagnostic' -ResourceType 'windows.personalization.taskbar' -ResourceId 'slots' -Diagnostic $diagnostic
        }
        $installedAppIds = @{}
        foreach ($app in @(Get-StartApps)) { $installedAppIds[[string]$app.AppID] = $true }
        $slotsValid = $true
        $resolvedSlots = [System.Collections.Generic.List[object]]::new()
        for ($index = 0; $index -lt $desiredSlots.Count; $index++) {
            $slot = $desiredSlots[$index]
            $configuredId = $null
            if (Test-WinixPropertyPresent $slot 'app') {
                $mapping = $portableApps[[string]$slot.app]
                $resolvedId = [string]$mapping.id
                if ($mapping.type -eq 'app_user_model_id') {
                    $configuredId = $resolvedId
                    $resolvedSlots.Add([pscustomobject]@{ app_user_model_id = $resolvedId })
                } elseif ($mapping.type -eq 'desktop_application_id') {
                    $configuredId = $resolvedId
                    $resolvedSlots.Add([pscustomobject]@{ desktop_application_id = $resolvedId })
                } else {
                    $resolvedSlots.Add([pscustomobject]@{ desktop_application_link_path = $resolvedId })
                }
            } elseif (Test-WinixPropertyPresent $slot 'app_user_model_id') {
                $configuredId = [string]$slot.app_user_model_id
                $resolvedSlots.Add($slot)
            } elseif (Test-WinixPropertyPresent $slot 'desktop_application_id') {
                $configuredId = [string]$slot.desktop_application_id
                $resolvedSlots.Add($slot)
            } else {
                $resolvedSlots.Add($slot)
                $expandedPath = [Environment]::ExpandEnvironmentVariables([string]$slot.desktop_application_link_path)
                if (-not (Test-Path -LiteralPath $expandedPath -PathType Leaf)) {
                    $slotsValid = $false
                    $diagnostic = @{ severity = 'error'; code = 'taskbar.slots.shortcut_not_found'; path = "slots[$index].desktop_application_link_path"; message = "Taskbar slot $($index + 1) references a shortcut that does not exist: $expandedPath" }
                    $diagnostics.Add($diagnostic)
                    Write-WinixEvent -Kind 'diagnostic' -ResourceType 'windows.personalization.taskbar' -ResourceId 'slots' -Diagnostic $diagnostic
                }
            }
            if ($null -ne $configuredId -and -not $installedAppIds.ContainsKey($configuredId)) {
                $slotsValid = $false
                $diagnostic = @{ severity = 'error'; code = 'taskbar.slots.app_not_found'; path = "slots[$index]"; message = "Taskbar slot $($index + 1) references an app that is not installed for the current user: $configuredId" }
                $diagnostics.Add($diagnostic)
                Write-WinixEvent -Kind 'diagnostic' -ResourceType 'windows.personalization.taskbar' -ResourceId 'slots' -Diagnostic $diagnostic
            }
        }
        if ($slotsValid) {
            $desiredLayout = ConvertTo-TaskbarLayoutXml @($resolvedSlots) $exhaustive
            $currentLayout = Get-FileTextOrNull $layoutFile
            $currentPolicyFile = Get-WinixProperty $layoutPolicyPath 'StartLayoutFile'
            $currentPolicyEnabled = Get-WinixProperty $layoutPolicyPath 'LockedStartLayout'
            if ($currentLayout -ceq $desiredLayout -and "$currentPolicyFile" -eq $layoutFile -and $currentPolicyEnabled -eq 1) {
                $state.slots = $slotConfiguration
            } else {
                $operations.Add([ordered]@{
                    id = 'taskbar.slots'
                    action = 'set_taskbar_layout'
                    resource = @{ type = 'windows.personalization.taskbar'; id = 'slots' }
                    before = @{ layout = $currentLayout; policy_file = $currentPolicyFile; policy_enabled = $currentPolicyEnabled }
                    after = @{ slots = $slotConfiguration }
                    data = @{ path = $layoutFile; content = $desiredLayout; policy_path = $layoutPolicyPath }
                })
            }
            $diagnostic = @{ severity = 'warning'; code = 'taskbar.slots.sign_out_required'; path = 'slots'; message = 'Windows 11 applies an ordered taskbar layout at sign-in. Sign out and sign back in after apply.' }
            $diagnostics.Add($diagnostic)
            Write-WinixEvent -Kind 'diagnostic' -ResourceType 'windows.personalization.taskbar' -ResourceId 'slots' -Diagnostic $diagnostic
        }
    }
}

if ($Operation -eq 'plan') {
    foreach ($operationItem in $operations) {
        Write-WinixEvent -Kind 'resource_status' -ResourceType $operationItem.resource.type -ResourceId $operationItem.resource.id -Data @{ status = 'change_required'; operation = $operationItem }
    }
    $restartExplorer = @($operations | Where-Object { $_.action -ne 'set_automatically_hide' }).Count -gt 0
    Write-WinixResponse @{ protocol_version = 2; success = $true; changed = $false; state = $state; operations = $operations; diagnostics = $diagnostics; restart_required = @{ explorer = $restartExplorer; system = $false } }
    exit
}

if (-not (Test-WinixPropertyPresent $request 'operations')) { throw 'Apply request is missing its planned operations.' }
$planned = @($request.operations)
foreach ($operationItem in $planned) {
    if ($operationItem.resource.type -ne 'windows.personalization.taskbar') { throw "Unsupported planned operation '$($operationItem.id)'." }
    if ($operationItem.action -eq 'set_system_setting') {
        $settingName = [string]$operationItem.resource.id
        if (-not $systemSettings.Contains($settingName)) { throw "Unsupported taskbar system setting in planned operation '$($operationItem.id)'." }
        $expectedMapping = $systemSettings[$settingName]
        if ([string]$operationItem.data.setting_id -ne $expectedMapping.setting_id -or [string]$operationItem.data.value_type -ne $expectedMapping.value_type) {
            throw "Invalid taskbar system setting data in planned operation '$($operationItem.id)'."
        }
        if ([string]$operationItem.id -ne "taskbar.$settingName") {
            throw "Invalid taskbar system setting operation ID '$($operationItem.id)'."
        }
        if ($expectedMapping.value_type -eq 'int32') {
            if ($null -eq $expectedMapping.observed["$($operationItem.before)"] -or $null -eq $expectedMapping.observed["$($operationItem.after)"]) {
                throw "Invalid taskbar system setting value in planned operation '$($operationItem.id)'."
            }
        } elseif ($operationItem.before -isnot [bool] -or $operationItem.after -isnot [bool]) {
            throw "Invalid taskbar system setting value in planned operation '$($operationItem.id)'."
        }
        $mapping = @{ setting_id = $expectedMapping.setting_id; value_type = $expectedMapping.value_type }
        $current = Get-TaskbarSystemSettingRaw $mapping
        if ($current -ne $operationItem.before) { throw "Plan is stale for '$($operationItem.id)': the taskbar system setting changed after planning." }
    } elseif ($operationItem.action -eq 'set_automatically_hide') {
        if ([string]$operationItem.id -ne 'taskbar.automatically_hide' -or [string]$operationItem.resource.id -ne 'automatically_hide' -or $operationItem.before -isnot [bool] -or $operationItem.after -isnot [bool] -or @($operationItem.data.PSObject.Properties).Count -ne 0) {
            throw "Invalid taskbar autohide operation '$($operationItem.id)'."
        }
        $current = [Winix.Windows.Personalization.TaskbarSettingsApi]::ReadAutomaticallyHide()
        if ($current -ne $operationItem.before) { throw "Plan is stale for '$($operationItem.id)': the taskbar autohide setting changed after planning." }
    } elseif ($operationItem.action -eq 'set_other_icon_visibility') {
        $displayName = [string]$operationItem.data.display_name
        $expectedId = "taskbar.system_tray.other_icons.$displayName"
        $desiredVisibility = [string]$operationItem.after.visibility
        if ([string]::IsNullOrWhiteSpace($displayName) -or [string]$operationItem.id -cne $expectedId -or [string]$operationItem.resource.id -cne "system_tray.other_icons.$displayName" -or $desiredVisibility -notin @('shown', 'hidden') -or [string]$operationItem.before.state -cne 'registered' -or [string]$operationItem.before.visibility -notin @('shown', 'hidden') -or [string]$operationItem.before.visibility -eq $desiredVisibility -or @($operationItem.after.PSObject.Properties).Count -ne 1 -or @($operationItem.data.PSObject.Properties).Count -ne 2) {
            throw "Invalid system tray icon operation '$($operationItem.id)'."
        }
        $current = Get-OtherIconState $displayName
        if (-not (Test-WinixJsonEqual $current $operationItem.before) -or [string]$current.entry_id -cne [string]$operationItem.data.entry_id) {
            throw "Plan is stale for '$($operationItem.id)': the notification-area icon changed after planning."
        }
    } elseif ($operationItem.action -eq 'set_registry_value') {
        $current = Get-WinixProperty $operationItem.data.path $operationItem.data.name
        if ("$current" -ne "$($operationItem.before)") { throw "Plan is stale for '$($operationItem.id)': the registry value changed after planning." }
    } elseif ($operationItem.action -eq 'set_taskbar_layout') {
        $currentLayout = Get-FileTextOrNull $operationItem.data.path
        $currentPolicyFile = Get-WinixProperty $operationItem.data.policy_path 'StartLayoutFile'
        $currentPolicyEnabled = Get-WinixProperty $operationItem.data.policy_path 'LockedStartLayout'
        if ($currentLayout -cne $operationItem.before.layout -or "$currentPolicyFile" -ne "$($operationItem.before.policy_file)" -or "$currentPolicyEnabled" -ne "$($operationItem.before.policy_enabled)") {
            throw "Plan is stale for '$($operationItem.id)': the taskbar layout policy changed after planning."
        }
    } else {
        throw "Unsupported planned operation '$($operationItem.id)'."
    }
}
$applied = [System.Collections.Generic.List[string]]::new()
foreach ($operationItem in $planned) {
    Write-WinixEvent -Kind 'resource_change_started' -ResourceType $operationItem.resource.type -ResourceId $operationItem.resource.id -Data @{ operation_id = $operationItem.id; action = $operationItem.action; before = $operationItem.before; after = $operationItem.after }
    if ($operationItem.action -eq 'set_system_setting') {
        if ($operationItem.data.value_type -eq 'int32') {
            [Winix.Windows.Personalization.TaskbarSettingsApi]::WriteInt32($operationItem.data.setting_id, [int]$operationItem.after)
        } else {
            [Winix.Windows.Personalization.TaskbarSettingsApi]::WriteBoolean($operationItem.data.setting_id, [bool]$operationItem.after)
        }
        $mapping = @{ setting_id = [string]$operationItem.data.setting_id; value_type = [string]$operationItem.data.value_type }
        $observed = Get-TaskbarSystemSettingRaw $mapping
        if ($observed -ne $operationItem.after) { throw "Taskbar setting '$($operationItem.resource.id)' did not reach its planned postcondition." }
        if ($operationItem.resource.id -eq 'alignment') {
            $state.alignment = $systemSettings.alignment.observed["$observed"]
        } else {
            $state[[string]$operationItem.resource.id] = [bool]$observed
        }
    } elseif ($operationItem.action -eq 'set_automatically_hide') {
        [Winix.Windows.Personalization.TaskbarSettingsApi]::WriteAutomaticallyHide([bool]$operationItem.after)
        $observed = [Winix.Windows.Personalization.TaskbarSettingsApi]::ReadAutomaticallyHide()
        if ($observed -ne $operationItem.after) { throw "Taskbar setting 'automatically_hide' did not reach its planned postcondition." }
        $state.automatically_hide = $observed
    } elseif ($operationItem.action -eq 'set_other_icon_visibility') {
        $displayName = [string]$operationItem.data.display_name
        $entryPath = Join-Path $notifyIconSettingsPath ([string]$operationItem.data.entry_id)
        $desiredRaw = if ([string]$operationItem.after.visibility -eq 'shown') { 1 } else { 0 }
        Set-WinixProperty $entryPath 'IsPromoted' $desiredRaw 'DWord' | Out-Null
        $script:otherIconInventory = $null
        $observed = Get-OtherIconState $displayName
        if ($observed.state -ne 'registered' -or $observed.visibility -ne [string]$operationItem.after.visibility -or $observed.is_promoted -ne $desiredRaw) {
            throw "System tray icon '$displayName' did not reach its planned postcondition."
        }
        $state.system_tray.other_icons[$displayName] = $observed
    } elseif ($operationItem.action -eq 'set_registry_value') {
        Set-WinixProperty $operationItem.data.path $operationItem.data.name $operationItem.after $operationItem.data.property_type | Out-Null
        $observed = Get-WinixProperty $operationItem.data.path $operationItem.data.name
        if ("$observed" -ne "$($operationItem.after)") { throw "Taskbar setting '$($operationItem.resource.id)' did not reach its planned postcondition." }
    } else {
        $directory = Split-Path -Parent $operationItem.data.path
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
        [System.IO.File]::WriteAllText($operationItem.data.path, [string]$operationItem.data.content, [System.Text.UTF8Encoding]::new($false))
        Set-WinixProperty $operationItem.data.policy_path 'StartLayoutFile' $operationItem.data.path 'String' | Out-Null
        Set-WinixProperty $operationItem.data.policy_path 'LockedStartLayout' 1 'DWord' | Out-Null
        if ((Get-FileTextOrNull $operationItem.data.path) -cne [string]$operationItem.data.content -or "$(Get-WinixProperty $operationItem.data.policy_path 'StartLayoutFile')" -ne "$($operationItem.data.path)" -or (Get-WinixProperty $operationItem.data.policy_path 'LockedStartLayout') -ne 1) {
            throw "Taskbar layout verification failed for '$($operationItem.id)'."
        }
    }
    $applied.Add($operationItem.id)
    Write-WinixEvent -Kind 'resource_change_completed' -ResourceType $operationItem.resource.type -ResourceId $operationItem.resource.id -Data @{ operation_id = $operationItem.id; changed = $true }
}
$restartExplorer = @($planned | Where-Object { $_.action -ne 'set_automatically_hide' }).Count -gt 0
Write-WinixResponse @{ protocol_version = 2; success = $true; changed = ($applied.Count -gt 0); state = $state; operations = $planned; applied_operation_ids = $applied; diagnostics = $diagnostics; restart_required = @{ explorer = $restartExplorer; system = $false } }
