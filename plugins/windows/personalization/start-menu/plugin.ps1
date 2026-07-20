param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\..\shared\Winix.PluginSdk.psm1') -Force
$request = Read-WinixRequest

$advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$folderPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start'
$settings = @{
    show_recently_added_apps = @{ path = $advanced; name = 'Start_NotifyNewApps' }
    show_most_used_apps = @{ path = $advanced; name = 'Start_TrackProgs' }
    show_recent_items = @{ path = $advanced; name = 'Start_TrackDocs' }
    show_recommendations = @{ path = $advanced; name = 'Start_IrisRecommendations' }
}
$folderNames = @{ settings = 'ShowSettings'; file_explorer = 'ShowFileExplorer'; documents = 'ShowDocuments'; downloads = 'ShowDownloads'; music = 'ShowMusic'; pictures = 'ShowPictures'; videos = 'ShowVideos'; network = 'ShowNetwork'; personal_folder = 'ShowPersonalFolder' }
$scope = $request.context.scope
if ($scope -notin @('system', 'user')) { throw "Unsupported Start menu scope '$scope'." }
$shortcutRoot = if ($scope -eq 'system') {
    Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
} else {
    Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
}
$oemPinsPath = if ($scope -eq 'system') {
    $profileList = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $profilesDirectory = [Environment]::ExpandEnvironmentVariables($profileList.ProfilesDirectory)
    Join-Path $profilesDirectory 'Default\AppData\Local\Microsoft\Windows\Shell\LayoutModification.json'
} else {
    Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Shell\LayoutModification.json'
}

function New-RegistryOperation([string] $Id, [string] $ResourceId, [string] $Path, [string] $Name, [object] $Before, [object] $After) {
    return [ordered]@{
        id = $Id
        action = 'set_registry_value'
        resource = @{ type = 'windows.personalization.start_menu'; id = $ResourceId }
        before = $Before
        after = $After
        data = @{ path = $Path; name = $Name; property_type = 'DWord' }
    }
}

function Test-ManagedFileStateEqual([object] $Left, [object] $Right) {
    if ([bool]$Left.exists -ne [bool]$Right.exists) { return $false }
    if (-not [bool]$Left.exists) { return $true }
    return (
        [int64]$Left.length -eq [int64]$Right.length -and
        [string]$Left.sha256 -ceq [string]$Right.sha256
    )
}

function Get-ShortcutPath([string] $Root, [string] $RelativePath) {
    if ([IO.Path]::IsPathRooted($RelativePath) -or [IO.Path]::GetExtension($RelativePath) -cne '.lnk') {
        throw "Start menu shortcut '$RelativePath' must be a relative path ending in '.lnk'."
    }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootPath $RelativePath))
    $prefix = $rootPath + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Start menu shortcut '$RelativePath' resolves outside the Programs directory."
    }
    return $candidate
}

function Get-ManagedFileState([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [ordered]@{ exists = $false }
    }
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        exists = $true
        length = $item.Length
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
}

$diagnostics = [System.Collections.Generic.List[object]]::new()
if ($scope -eq 'system') {
    foreach ($property in $request.configuration.PSObject.Properties) {
        if ($property.Name -notin @('oem_pins', 'shortcuts')) {
            $diagnostics.Add(@{
                severity = 'error'
                code = 'start_menu.property.wrong_placement'
                path = "$($request.path).$($property.Name)"
                message = "Start menu property '$($property.Name)' is user-scoped; only oem_pins and shortcuts may be configured at system placement."
            })
        }
    }
}
if (Test-WinixPropertyPresent $request.configuration 'shortcuts') {
    foreach ($entry in $request.configuration.shortcuts.PSObject.Properties) {
        try { [void](Get-ShortcutPath -Root $shortcutRoot -RelativePath $entry.Name) }
        catch {
            $diagnostics.Add(@{
                severity = 'error'
                code = 'start_menu.shortcut.invalid_path'
                path = "$($request.path).shortcuts.$($entry.Name)"
                message = $_.Exception.Message
            })
        }
    }
}

if ($Operation -eq 'validate') {
    Write-WinixResponse @{ protocol_version = 2; valid = ($diagnostics.Count -eq 0); diagnostics = $diagnostics }
    exit
}
if ($Operation -eq 'plan' -and $diagnostics.Count -gt 0) {
    Write-WinixResponse @{ protocol_version = 2; success = $false; changed = $false; state = @{}; operations = @(); diagnostics = $diagnostics; error = @{ code = 'start_menu.plan.failed'; message = 'Start menu could not produce a valid plan.' }; restart_required = @{ explorer = $false; system = $false } }
    exit
}

$state = [ordered]@{}
$operations = [System.Collections.Generic.List[object]]::new()
if (Test-WinixPropertyPresent $request.configuration 'oem_pins') {
    Write-WinixEvent -Kind 'resource_checking' -ResourceType 'windows.personalization.start_menu.oem_pins' -ResourceId $scope -Data @{ phase = 'plan'; scope = $scope }
    $current = Get-ManagedFileState -Path $oemPinsPath
    $state.oem_pins = $current
    if ($current.exists) {
        $operations.Add([ordered]@{
            id = "start_menu.oem_pins.$scope.remove"
            action = 'remove_oem_pins'
            resource = @{ type = 'windows.personalization.start_menu.oem_pins'; id = $scope }
            before = $current
            after = @{ exists = $false }
            data = @{ path = $oemPinsPath; scope = $scope }
        })
    }
}
foreach ($name in $settings.Keys) {
    if (-not (Test-WinixPropertyPresent $request.configuration $name)) { continue }
    Write-WinixEvent -Kind 'resource_checking' -ResourceType 'windows.personalization.start_menu' -ResourceId $name -Data @{ phase = 'plan' }
    $mapping = $settings[$name]
    $currentRaw = Get-WinixProperty $mapping.path $mapping.name
    $current = ($currentRaw -ne 0)
    $desired = [bool]$request.configuration.$name
    $state[$name] = $current
    if ($current -ne $desired) {
        $operations.Add((New-RegistryOperation -Id "start_menu.$name" -ResourceId $name -Path $mapping.path -Name $mapping.name -Before $currentRaw -After $(if ($desired) { 1 } else { 0 })))
    }
}
if (Test-WinixPropertyPresent $request.configuration 'folders') {
    $folderState = [ordered]@{}
    foreach ($entry in $request.configuration.folders.PSObject.Properties) {
        $currentRaw = Get-WinixProperty $folderPath $folderNames[$entry.Name]
        $current = if ($currentRaw -eq 1) { 'visible' } else { 'hidden' }
        $folderState[$entry.Name] = $current
        if ($current -ne $entry.Value) {
            $operations.Add((New-RegistryOperation -Id "start_menu.folders.$($entry.Name)" -ResourceId "folders.$($entry.Name)" -Path $folderPath -Name $folderNames[$entry.Name] -Before $currentRaw -After $(if ($entry.Value -eq 'visible') { 1 } else { 0 })))
        }
    }
    $state.folders = $folderState
}
if (Test-WinixPropertyPresent $request.configuration 'shortcuts') {
    $shortcutState = [ordered]@{}
    foreach ($entry in $request.configuration.shortcuts.PSObject.Properties) {
        $path = Get-ShortcutPath -Root $shortcutRoot -RelativePath $entry.Name
        Write-WinixEvent -Kind 'resource_checking' -ResourceType 'windows.personalization.start_menu.shortcut' -ResourceId $entry.Name -Data @{ phase = 'plan'; scope = $scope }
        $current = Get-ManagedFileState -Path $path
        $shortcutState[$entry.Name] = $current
        if ($current.exists) {
            $operations.Add([ordered]@{
                id = "start_menu.shortcut.$scope.$($entry.Name)"
                action = 'remove_shortcut'
                resource = @{ type = 'windows.personalization.start_menu.shortcut'; id = $entry.Name }
                before = $current
                after = @{ exists = $false }
                data = @{ path = $path; relative_path = $entry.Name; scope = $scope }
            })
        }
    }
    $state.shortcuts = $shortcutState
}

if ($Operation -eq 'plan') {
    foreach ($operationItem in $operations) {
        Write-WinixEvent -Kind 'resource_status' -ResourceType $operationItem.resource.type -ResourceId $operationItem.resource.id -Data @{ status = 'change_required'; operation = $operationItem }
    }
    Write-WinixResponse @{ protocol_version = 2; success = $true; changed = $false; state = $state; operations = $operations; diagnostics = @(); restart_required = @{ explorer = ($operations.Count -gt 0); system = $false } }
    exit
}

if ($scope -eq 'system' -and -not (Test-WinixAdministrator)) { throw 'System Start menu configuration requires an elevated token.' }
if ($scope -eq 'user' -and (Test-WinixAdministrator)) { throw 'Current-user Start menu configuration cannot run with an elevated token.' }
if (-not (Test-WinixPropertyPresent $request 'operations')) { throw 'Apply request is missing its planned operations.' }
$planned = @($request.operations)
foreach ($operationItem in $planned) {
    if ($operationItem.action -eq 'set_registry_value' -and $operationItem.resource.type -eq 'windows.personalization.start_menu') {
        if ($scope -ne 'user') { throw "Registry operation '$($operationItem.id)' is not supported at system placement." }
        $current = Get-WinixProperty $operationItem.data.path $operationItem.data.name
        if (-not (Test-WinixJsonEqual $current $operationItem.before)) { throw "Plan is stale for '$($operationItem.id)': the registry value changed after planning." }
        continue
    }
    if ($operationItem.action -eq 'remove_shortcut' -and $operationItem.resource.type -eq 'windows.personalization.start_menu.shortcut') {
        if ($operationItem.data.scope -cne $scope -or $operationItem.data.relative_path -cne $operationItem.resource.id) {
            throw "Planned shortcut operation '$($operationItem.id)' does not match its resource identity or scope."
        }
        $expectedPath = Get-ShortcutPath -Root $shortcutRoot -RelativePath $operationItem.resource.id
        if ($operationItem.data.path -cne $expectedPath) { throw "Planned shortcut operation '$($operationItem.id)' has an invalid path." }
        $current = Get-ManagedFileState -Path $expectedPath
        if (-not (Test-ManagedFileStateEqual $current $operationItem.before)) {
            throw "Plan is stale for '$($operationItem.id)': the shortcut changed after planning. Expected $($operationItem.before | ConvertTo-Json -Compress); observed $($current | ConvertTo-Json -Compress)."
        }
        continue
    }
    if ($operationItem.action -eq 'remove_oem_pins' -and $operationItem.resource.type -eq 'windows.personalization.start_menu.oem_pins') {
        if ($operationItem.data.scope -cne $scope -or $operationItem.resource.id -cne $scope -or $operationItem.data.path -cne $oemPinsPath) {
            throw "Planned OEM pins operation '$($operationItem.id)' does not match its placement."
        }
        $current = Get-ManagedFileState -Path $oemPinsPath
        if (-not (Test-ManagedFileStateEqual $current $operationItem.before)) {
            throw "Plan is stale for '$($operationItem.id)': the OEM pins file changed after planning. Expected $($operationItem.before | ConvertTo-Json -Compress); observed $($current | ConvertTo-Json -Compress)."
        }
        continue
    }
    throw "Unsupported planned operation '$($operationItem.id)'."
}

$applied = [System.Collections.Generic.List[string]]::new()
foreach ($operationItem in $planned) {
    Write-WinixEvent -Kind 'resource_change_started' -ResourceType $operationItem.resource.type -ResourceId $operationItem.resource.id -Data @{ operation_id = $operationItem.id; action = $operationItem.action; before = $operationItem.before; after = $operationItem.after }
    if ($operationItem.action -eq 'set_registry_value') {
        Set-WinixProperty $operationItem.data.path $operationItem.data.name $operationItem.after $operationItem.data.property_type | Out-Null
        $observed = Get-WinixProperty $operationItem.data.path $operationItem.data.name
        if (-not (Test-WinixJsonEqual $observed $operationItem.after)) { throw "Registry value for '$($operationItem.resource.id)' did not reach its planned postcondition." }
    } elseif ($operationItem.action -eq 'remove_shortcut') {
        Remove-Item -LiteralPath $operationItem.data.path -Force
        $observed = Get-ManagedFileState -Path $operationItem.data.path
        if ($observed.exists) { throw "Start menu shortcut '$($operationItem.resource.id)' remains after removal." }
    } else {
        Remove-Item -LiteralPath $operationItem.data.path -Force
        $observed = Get-ManagedFileState -Path $operationItem.data.path
        if ($observed.exists) { throw "OEM pins file for '$scope' placement remains after removal." }
    }
    $applied.Add($operationItem.id)
    Write-WinixEvent -Kind 'resource_change_completed' -ResourceType $operationItem.resource.type -ResourceId $operationItem.resource.id -Data @{ operation_id = $operationItem.id; changed = $true }
}
Write-WinixResponse @{ protocol_version = 2; success = $true; changed = ($applied.Count -gt 0); state = $state; operations = $planned; applied_operation_ids = $applied; diagnostics = @(); restart_required = @{ explorer = ($applied.Count -gt 0); system = $false } }
