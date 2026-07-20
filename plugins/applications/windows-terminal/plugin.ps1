param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.PluginSdk.psm1') -Force
$request = Read-WinixRequest

function Get-TerminalSettingsPath {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    )
    $existing = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($existing.Count -eq 0) { return $candidates[0] }
    if ($existing.Count -gt 1) { throw "Multiple Windows Terminal settings files were found: $($existing -join ', ')." }
    return $existing[0]
}

function Get-FileState([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [ordered]@{ exists = $false } }
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{ exists = $true; length = $item.Length; sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
}

function Set-JsonProperty([object] $Object, [string] $Name, [AllowNull()] [object] $Value) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
    else { $property.Value = $Value }
}

function Remove-JsonProperty([object] $Object, [string] $Name) {
    if ($null -ne $Object.PSObject.Properties[$Name]) {
        $Object.PSObject.Properties.Remove($Name)
    }
}

function Convert-Selector([string] $Selector) {
    $parts = $Selector.Split(':', 2)
    return @{ kind = $parts[0]; value = $parts[1] }
}

function Find-Profiles([object[]] $Profiles, [string] $Selector) {
    $parsed = Convert-Selector $Selector
    return @($Profiles | Where-Object {
        $property = $_.PSObject.Properties[$parsed.kind]
        $null -ne $property -and [string]$property.Value -ieq $parsed.value
    })
}

function Set-Appearance([object] $Target, [object] $Appearance) {
    $names = @{
        color_scheme = 'colorScheme'; opacity = 'opacity'; use_acrylic = 'useAcrylic'; padding = 'padding'
        cursor_shape = 'cursorShape'; bell_style = 'bellStyle'; background_image = 'backgroundImage'; background_image_opacity = 'backgroundImageOpacity'
        background_image_stretch_mode = 'backgroundImageStretchMode'; scrollbar_state = 'scrollbarState'
    }
    foreach ($property in $Appearance.PSObject.Properties) {
        if ($property.Name -eq 'font') {
            $font = if ($null -ne $Target.PSObject.Properties['font']) { $Target.font } else { [pscustomobject]@{} }
            foreach ($fontProperty in $property.Value.PSObject.Properties) { Set-JsonProperty $font $fontProperty.Name $fontProperty.Value }
            Set-JsonProperty $Target 'font' $font
        } else {
            Set-JsonProperty $Target $names[$property.Name] $property.Value
        }
    }
}

function Get-NormalizedKeys([object] $Keys) {
    return @($Keys | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
}

function Get-ComparisonSettings([object] $Settings) {
    $comparison = ($Settings | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json -Depth 100)
    if ($null -ne $comparison.PSObject.Properties['disabledProfileSources']) {
        Set-JsonProperty $comparison 'disabledProfileSources' @($comparison.disabledProfileSources | Sort-Object)
    }
    foreach ($collectionName in @('actions', 'keybindings')) {
        if ($null -eq $comparison.PSObject.Properties[$collectionName]) { continue }
        $sorted = @($comparison.$collectionName | Sort-Object {
            $id = if ($null -ne $_.PSObject.Properties['id']) { [string]$_.id } else { '' }
            $keys = if ($null -ne $_.PSObject.Properties['keys']) { @(Get-NormalizedKeys $_.keys) -join ',' } else { '' }
            "$id`n$keys"
        })
        Set-JsonProperty $comparison $collectionName $sorted
    }
    return $comparison
}

function Get-TerminalProfiles([object] $Settings) {
    if ($null -eq $Settings.PSObject.Properties['profiles']) { return @() }
    if ($null -eq $Settings.profiles.PSObject.Properties['list']) { return @() }
    return @($Settings.profiles.list)
}

function New-DesiredSettings([object] $Current, [object] $Configuration) {
    $desired = ($Current | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json -Depth 100)
    $profileList = @(Get-TerminalProfiles $desired)

    if (Test-WinixPropertyPresent $Configuration 'default_profile') {
        $matchedProfiles = @(Find-Profiles $profileList $Configuration.default_profile)
        if ($matchedProfiles.Count -ne 1) { throw "Default profile selector '$($Configuration.default_profile)' matched $($matchedProfiles.Count) profiles; exactly one is required." }
        if ($null -eq $matchedProfiles[0].PSObject.Properties['guid']) { throw "Default profile selector '$($Configuration.default_profile)' resolved to a profile without a GUID." }
        Set-JsonProperty $desired 'defaultProfile' ([string]$matchedProfiles[0].guid)
    }
    if (Test-WinixPropertyPresent $Configuration 'disabled_profile_sources') {
        Set-JsonProperty $desired 'disabledProfileSources' @($Configuration.disabled_profile_sources)
    }
    if (Test-WinixPropertyPresent $Configuration 'tab_switcher_mode') {
        $value = @{ mru = 'mru'; in_order = 'inOrder'; none = 'disabled' }[[string]$Configuration.tab_switcher_mode]
        Set-JsonProperty $desired 'tabSwitcherMode' $value
    }
    if (Test-WinixPropertyPresent $Configuration 'graphics_api') {
        if ($Configuration.graphics_api -eq 'automatic') {
            Remove-JsonProperty $desired 'rendering.graphicsAPI'
        } else {
            Set-JsonProperty $desired 'rendering.graphicsAPI' ([string]$Configuration.graphics_api)
        }
    }
    if (Test-WinixPropertyPresent $Configuration 'profiles') {
        if (Test-WinixPropertyPresent $Configuration.profiles 'defaults') {
            if ($null -eq $desired.PSObject.Properties['profiles']) { Set-JsonProperty $desired 'profiles' ([pscustomobject]@{}) }
            if ($null -eq $desired.profiles.PSObject.Properties['defaults']) { Set-JsonProperty $desired.profiles 'defaults' ([pscustomobject]@{}) }
            Set-Appearance $desired.profiles.defaults $Configuration.profiles.defaults
        }
        if (Test-WinixPropertyPresent $Configuration.profiles 'overrides') {
            foreach ($override in $Configuration.profiles.overrides.PSObject.Properties) {
                $matchedProfiles = @(Find-Profiles $profileList $override.Name)
                if ($matchedProfiles.Count -eq 0) { throw "Profile selector '$($override.Name)' did not match any Terminal profile." }
                foreach ($terminalProfile in $matchedProfiles) {
                    if (Test-WinixPropertyPresent $override.Value 'hidden') { Set-JsonProperty $terminalProfile 'hidden' ([bool]$override.Value.hidden) }
                    if (Test-WinixPropertyPresent $override.Value 'appearance') { Set-Appearance $terminalProfile $override.Value.appearance }
                }
            }
        }
    }
    if (Test-WinixPropertyPresent $Configuration 'key_bindings') {
        $managedPrefix = 'Winix.'
        $configuredKeys = @($Configuration.key_bindings.PSObject.Properties | ForEach-Object { Get-NormalizedKeys $_.Value.keys })
        $existingActions = if ($null -ne $desired.PSObject.Properties['actions']) { @($desired.actions) } else { @() }
        $existingBindings = if ($null -ne $desired.PSObject.Properties['keybindings']) { @($desired.keybindings) } else { @() }
        $actions = @($existingActions | Where-Object { $null -eq $_.PSObject.Properties['id'] -or -not ([string]$_.id).StartsWith($managedPrefix, [StringComparison]::Ordinal) })
        $bindings = @($existingBindings | Where-Object {
            if ($null -ne $_.PSObject.Properties['id'] -and ([string]$_.id).StartsWith($managedPrefix, [StringComparison]::Ordinal)) { return $false }
            $existingKeys = @(Get-NormalizedKeys $_.keys)
            return @($existingKeys | Where-Object { $_ -in $configuredKeys }).Count -eq 0
        })
        foreach ($entry in $Configuration.key_bindings.PSObject.Properties) {
            if (Test-WinixPropertyPresent $entry.Value 'state') { continue }
            if (Test-WinixPropertyPresent $entry.Value 'id') {
                $id = [string]$entry.Value.id
            } else {
                $id = "$managedPrefix$($entry.Name)"
                $actions += [pscustomobject][ordered]@{ command = [string]$entry.Value.command; id = $id }
            }
            $bindings += [pscustomobject][ordered]@{ id = $id; keys = $entry.Value.keys }
        }
        Set-JsonProperty $desired 'actions' @($actions)
        Set-JsonProperty $desired 'keybindings' @($bindings)
    }
    return $desired
}

$diagnostics = [System.Collections.Generic.List[object]]::new()
if ($request.context.scope -ne 'user') {
    $diagnostics.Add(@{ severity = 'error'; code = 'windows_terminal.scope.invalid'; path = $request.path; message = 'Windows Terminal settings are current-user configuration.' })
}
$settingsPath = Get-TerminalSettingsPath
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    $diagnostics.Add(@{ severity = 'error'; code = 'windows_terminal.settings.not_initialized'; path = $request.path; message = "Windows Terminal has not created '$settingsPath'. Launch Terminal once, then plan again." })
}

if ($Operation -eq 'validate') {
    Write-WinixResponse @{ protocol_version = 2; valid = ($diagnostics.Count -eq 0); diagnostics = $diagnostics }
    exit
}
if ($Operation -eq 'plan' -and $diagnostics.Count -gt 0) {
    Write-WinixResponse @{ protocol_version = 2; success = $false; changed = $false; state = @{}; operations = @(); diagnostics = $diagnostics; error = @{ code = 'windows_terminal.plan.failed'; message = 'Windows Terminal could not produce a valid plan.' }; restart_required = @{ explorer = $false; system = $false } }
    exit
}

$before = Get-FileState $settingsPath
$current = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json -Depth 100
try { $desired = New-DesiredSettings $current $request.configuration }
catch {
    if ($Operation -eq 'apply') { throw }
    $diagnostic = @{ severity = 'error'; code = 'windows_terminal.selector.invalid'; path = $request.path; message = $_.Exception.Message }
    Write-WinixResponse @{ protocol_version = 2; success = $false; changed = $false; state = @{}; operations = @(); diagnostics = @($diagnostic); error = @{ code = 'windows_terminal.plan.failed'; message = 'Windows Terminal could not produce a valid plan.' }; restart_required = @{ explorer = $false; system = $false } }
    exit
}
$desiredContent = ($desired | ConvertTo-Json -Depth 100) + [Environment]::NewLine
$operations = @()
$currentComparison = Get-ComparisonSettings $current
$desiredComparison = Get-ComparisonSettings $desired
if (-not (Test-WinixJsonEqual $currentComparison $desiredComparison)) {
    $afterBytes = [Text.UTF8Encoding]::new($false).GetBytes($desiredContent)
    $afterHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($afterBytes))
    $operations = @([ordered]@{
        id = 'windows_terminal.settings.write'; action = 'write_settings'; resource = @{ type = 'applications.windows_terminal.settings'; id = 'stable' }
        before = $before; after = @{ exists = $true; length = $afterBytes.Length; sha256 = $afterHash }
        data = @{ path = $settingsPath; content = $desiredContent }
    })
}

if ($Operation -eq 'plan') {
    foreach ($operationItem in $operations) { Write-WinixEvent -Kind 'resource_status' -ResourceType $operationItem.resource.type -ResourceId $operationItem.resource.id -Data @{ status = 'change_required'; operation = $operationItem } }
    Write-WinixResponse @{ protocol_version = 2; success = $true; changed = $false; state = @{ path = $settingsPath; file = $before }; operations = $operations; diagnostics = @(); restart_required = @{ explorer = $false; system = $false } }
    exit
}

if (Test-WinixAdministrator) { throw 'Current-user Windows Terminal configuration cannot run with an elevated token.' }
if (-not (Test-WinixPropertyPresent $request 'operations')) { throw 'Apply request is missing its planned operations.' }
$planned = @($request.operations)
foreach ($operationItem in $planned) {
    if ($operationItem.id -cne 'windows_terminal.settings.write' -or $operationItem.action -cne 'write_settings' -or $operationItem.resource.type -cne 'applications.windows_terminal.settings' -or $operationItem.data.path -cne $settingsPath) { throw "Unsupported planned operation '$($operationItem.id)'." }
    $observed = Get-FileState $settingsPath
    if (-not (Test-WinixJsonEqual $observed $operationItem.before)) { throw "Plan is stale for '$($operationItem.id)': settings.json changed after planning." }
}
$applied = [System.Collections.Generic.List[string]]::new()
foreach ($operationItem in $planned) {
    Write-WinixEvent -Kind 'resource_change_started' -ResourceType $operationItem.resource.type -ResourceId $operationItem.resource.id -Data @{ operation_id = $operationItem.id; action = $operationItem.action; before = $operationItem.before; after = $operationItem.after }
    $directory = Split-Path -Parent $settingsPath
    $temporaryPath = Join-Path $directory ('.winix-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporaryPath, [string]$operationItem.data.content, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporaryPath, $settingsPath, $true)
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    }
    $observed = Get-FileState $settingsPath
    if (-not (Test-WinixJsonEqual $observed $operationItem.after)) { throw 'Windows Terminal settings did not reach the planned postcondition.' }
    $applied.Add($operationItem.id)
    Write-WinixEvent -Kind 'resource_change_completed' -ResourceType $operationItem.resource.type -ResourceId $operationItem.resource.id -Data @{ operation_id = $operationItem.id; changed = $true }
}
Write-WinixResponse @{ protocol_version = 2; success = $true; changed = ($applied.Count -gt 0); state = @{ path = $settingsPath; file = (Get-FileState $settingsPath) }; operations = $planned; applied_operation_ids = $applied; diagnostics = @(); restart_required = @{ explorer = $false; system = $false } }
