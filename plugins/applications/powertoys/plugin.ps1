param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.PluginSdk.psm1') -Force
$request = Read-WinixRequest

$packageName = 'Microsoft.CommandPalette'
$processName = 'Microsoft.CmdPal.UI'
$activationUri = 'x-cmdpal://background'
$powerToysSettingsPath = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\settings.json'
$grabAndMoveSettingsPath = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\GrabAndMove\settings.json'
$desiredShortcut = [ordered]@{
    win = $false
    ctrl = $false
    alt = $true
    shift = $false
    code = 32
    key = ''
}

function Get-PowerToysDscPath {
    $runningPaths = @(Get-Process -Name 'PowerToys' -ErrorAction SilentlyContinue | ForEach-Object {
        try { Join-Path (Split-Path -Parent ([string]$_.Path)) 'PowerToys.DSC.exe' } catch { $null }
    } | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Sort-Object -Unique)
    if ($runningPaths.Count -eq 1) { return $runningPaths[0] }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'PowerToys\PowerToys.DSC.exe')
        $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'PowerToys\PowerToys.DSC.exe' })
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Sort-Object -Unique
    if ($candidates.Count -eq 0) { return $null }
    if ($candidates.Count -gt 1) { throw "Multiple PowerToys DSC executables were found: $($candidates -join ', ')." }
    return $candidates[0]
}

function Get-GrabAndMoveState {
    $general = Get-Content -LiteralPath $powerToysSettingsPath -Raw | ConvertFrom-Json -Depth 100
    if ($null -eq $general.PSObject.Properties['enabled'] -or $null -eq $general.enabled.PSObject.Properties['GrabAndMove']) {
        throw "PowerToys settings '$powerToysSettingsPath' do not contain enabled.GrabAndMove."
    }
    $module = Get-Content -LiteralPath $grabAndMoveSettingsPath -Raw | ConvertFrom-Json -Depth 100
    if (
        $null -eq $module.PSObject.Properties['properties'] -or
        $null -eq $module.properties.PSObject.Properties['modifierKey'] -or
        $null -eq $module.properties.modifierKey.PSObject.Properties['value']
    ) {
        throw "Grab And Move settings '$grabAndMoveSettingsPath' do not contain properties.modifierKey.value."
    }
    $modifierValue = [int]$module.properties.modifierKey.value
    if ($modifierValue -notin @(0, 1)) { throw "Grab And Move modifierKey value '$modifierValue' is unsupported." }
    return [ordered]@{
        enabled = [bool]$general.enabled.GrabAndMove
        activation_modifier = $(if ($modifierValue -eq 1) { 'win' } else { 'alt' })
    }
}

function New-GrabAndMoveContent([string] $Content, [string] $Modifier) {
    $root = [Text.Json.Nodes.JsonNode]::Parse($Content)
    if ($root -isnot [Text.Json.Nodes.JsonObject]) { throw 'Grab And Move settings must contain a JSON object.' }
    if (
        $null -eq $root['properties'] -or $root['properties'] -isnot [Text.Json.Nodes.JsonObject] -or
        $null -eq $root['properties']['modifierKey'] -or $root['properties']['modifierKey'] -isnot [Text.Json.Nodes.JsonObject]
    ) {
        throw 'Grab And Move settings do not contain properties.modifierKey.'
    }
    $root['properties']['modifierKey']['value'] = $(if ($Modifier -ceq 'win') { 1 } else { 0 })
    $options = [Text.Json.JsonSerializerOptions]::new()
    $options.WriteIndented = $false
    return $root.ToJsonString($options) + [Environment]::NewLine
}

function Set-FileContentAtomically([string] $Path, [string] $Content) {
    $directory = Split-Path -Parent $Path
    $temporaryPath = Join-Path $directory ('.winix-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporaryPath, $Content, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporaryPath, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    }
}

function Get-PowerToysDscSettings([string] $DscPath) {
    $output = @(& $DscPath get --module App --resource settings 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "PowerToys DSC failed to read general settings (exit code $LASTEXITCODE): $($output -join [Environment]::NewLine)"
    }
    $result = ($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 100
    if ($null -eq $result.PSObject.Properties['settings'] -or $null -eq $result.settings.enabled.PSObject.Properties['GrabAndMove']) {
        throw 'PowerToys DSC output does not contain settings.enabled.GrabAndMove.'
    }
    return $result.settings
}

function New-DesiredPowerToysDscSettings([object] $Settings, [bool] $Enabled) {
    $copy = ($Settings | ConvertTo-Json -Compress -Depth 100) | ConvertFrom-Json -Depth 100
    $copy.enabled.GrabAndMove = $Enabled
    return $copy
}

function Set-GrabAndMoveEnabled([string] $DscPath, [object] $Settings) {
    $inputValue = @{ settings = $Settings } | ConvertTo-Json -Compress -Depth 100
    $output = @(& $DscPath set --module App --resource settings --input $inputValue 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "PowerToys DSC failed to set Grab And Move enabled state (exit code $LASTEXITCODE): $($output -join [Environment]::NewLine)"
    }
}

function Send-GrabAndMoveRefresh {
    try {
        $refreshEvent = [Threading.EventWaitHandle]::OpenExisting('Local\PowerToysGrabAndMove-RefreshSettingsEvent-a7b3c1d2-4e5f-6a7b-8c9d-0e1f2a3b4c5d6')
        try { [void]$refreshEvent.Set() } finally { $refreshEvent.Dispose() }
    } catch [Threading.WaitHandleCannotBeOpenedException] {
        # The module is disabled or PowerToys is not currently running. It will read the file on its next start.
        $null = $_
    }
}

function Get-CommandPalettePackage {
    $packages = @(Get-AppxPackage -Name $packageName -ErrorAction SilentlyContinue | Sort-Object PackageFullName -Unique)
    if ($packages.Count -eq 0) { return $null }
    if ($packages.Count -gt 1) { throw "Multiple current-user Command Palette packages were found: $(@($packages.PackageFullName) -join ', ')." }
    return $packages[0]
}

function Get-SettingsPath([object] $Package) {
    return Join-Path $env:LOCALAPPDATA "Packages\$($Package.PackageFamilyName)\LocalState\settings.json"
}

function Get-FileState([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [ordered]@{ exists = $false } }
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        exists = $true
        length = [int64]$item.Length
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Get-CommandPaletteProcesses([object] $Package) {
    $installRoot = [IO.Path]::GetFullPath([string]$Package.InstallLocation).TrimEnd([IO.Path]::DirectorySeparatorChar)
    return @(Get-Process -Name $processName -ErrorAction SilentlyContinue | Where-Object {
        try {
            $path = [IO.Path]::GetFullPath([string]$_.Path)
            $path.StartsWith($installRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
        } catch {
            $false
        }
    })
}

function Get-ShortcutState([string] $Path) {
    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100
    if ($null -eq $document.PSObject.Properties['Hotkey'] -or $null -eq $document.Hotkey) {
        throw "Command Palette settings '$Path' do not contain a Hotkey object."
    }
    $hotkey = $document.Hotkey
    foreach ($name in @('win', 'ctrl', 'alt', 'shift', 'code', 'key')) {
        if ($null -eq $hotkey.PSObject.Properties[$name]) {
            throw "Command Palette Hotkey is missing required property '$name'."
        }
    }
    return [ordered]@{
        win = [bool]$hotkey.win
        ctrl = [bool]$hotkey.ctrl
        alt = [bool]$hotkey.alt
        shift = [bool]$hotkey.shift
        code = [int]$hotkey.code
        key = [string]$hotkey.key
    }
}

function New-DesiredContent([string] $Content) {
    $root = [Text.Json.Nodes.JsonNode]::Parse($Content)
    if ($root -isnot [Text.Json.Nodes.JsonObject]) { throw 'Command Palette settings must contain a JSON object.' }
    if ($null -eq $root['Hotkey'] -or $root['Hotkey'] -isnot [Text.Json.Nodes.JsonObject]) {
        throw 'Command Palette settings do not contain a Hotkey object.'
    }
    $root['Hotkey'] = [Text.Json.Nodes.JsonNode]::Parse('{"win":false,"ctrl":false,"alt":true,"shift":false,"code":32,"key":""}')
    $options = [Text.Json.JsonSerializerOptions]::new()
    $options.WriteIndented = $true
    return $root.ToJsonString($options) + [Environment]::NewLine
}

function Get-ContentState([string] $Content) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Content)
    return [ordered]@{
        exists = $true
        length = [int64]$bytes.Length
        sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
}

function Test-ShortcutEqual([object] $Left, [object] $Right) {
    return (
        [bool]$Left.win -eq [bool]$Right.win -and
        [bool]$Left.ctrl -eq [bool]$Right.ctrl -and
        [bool]$Left.alt -eq [bool]$Right.alt -and
        [bool]$Left.shift -eq [bool]$Right.shift -and
        [int]$Left.code -eq [int]$Right.code -and
        [string]$Left.key -ceq [string]$Right.key
    )
}

function Start-CommandPaletteAndWait([object] $Package) {
    $null = Start-Process -FilePath 'explorer.exe' -ArgumentList $activationUri -WindowStyle Hidden -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        if (@(Get-CommandPaletteProcesses $Package).Count -gt 0) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Command Palette did not relaunch within 15 seconds.'
}

$diagnostics = [System.Collections.Generic.List[object]]::new()
if ([string]$request.context.scope -cne 'user') {
    $diagnostics.Add(@{ severity = 'error'; code = 'powertoys.scope.invalid'; path = $request.path; message = 'PowerToys application settings are current-user configuration.' })
}

$package = $null
$settingsPath = $null
$manageCommandPalette = Test-WinixPropertyPresent $request.configuration 'command_palette'
$manageGrabAndMove = Test-WinixPropertyPresent $request.configuration 'grab_and_move'
$powerToysDscPath = $null
if ($manageCommandPalette) {
    try {
        $package = Get-CommandPalettePackage
        if ($null -eq $package) {
            $diagnostics.Add(@{ severity = 'error'; code = 'powertoys.command_palette.not_installed'; path = "$($request.path).command_palette"; message = 'The Microsoft Command Palette package is not installed for the current user.' })
        } else {
            $settingsPath = Get-SettingsPath $package
            if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
                $diagnostics.Add(@{ severity = 'error'; code = 'powertoys.command_palette.settings.not_initialized'; path = "$($request.path).command_palette"; message = "Command Palette has not created '$settingsPath'. Launch Command Palette once, then plan again." })
            } else {
                [void](Get-ShortcutState $settingsPath)
                [void](New-DesiredContent (Get-Content -LiteralPath $settingsPath -Raw))
            }
        }
    } catch {
        $diagnostics.Add(@{ severity = 'error'; code = 'powertoys.command_palette.settings.invalid'; path = "$($request.path).command_palette"; message = $_.Exception.Message })
    }
}
if ($manageGrabAndMove) {
    try {
        foreach ($path in @($powerToysSettingsPath, $grabAndMoveSettingsPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "PowerToys has not initialized '$path'. Launch PowerToys once, then plan again." }
        }
        $powerToysDscPath = Get-PowerToysDscPath
        if ($null -eq $powerToysDscPath) { throw 'PowerToys.DSC.exe was not found in the current PowerToys installation.' }
        [void](Get-PowerToysDscSettings $powerToysDscPath)
        [void](Get-GrabAndMoveState)
        [void](New-GrabAndMoveContent (Get-Content -LiteralPath $grabAndMoveSettingsPath -Raw) ([string]$request.configuration.grab_and_move.activation_modifier))
    } catch {
        $diagnostics.Add(@{ severity = 'error'; code = 'powertoys.grab_and_move.settings.invalid'; path = "$($request.path).grab_and_move"; message = $_.Exception.Message })
    }
}

if ($Operation -eq 'validate') {
    Write-WinixResponse @{ protocol_version = 2; valid = ($diagnostics.Count -eq 0); diagnostics = $diagnostics }
    exit
}
if ($Operation -eq 'plan' -and $diagnostics.Count -gt 0) {
    Write-WinixResponse @{ protocol_version = 2; success = $false; changed = $false; state = @{}; operations = @(); diagnostics = $diagnostics; error = @{ code = 'powertoys.plan.failed'; message = 'PowerToys could not produce a valid plan.' }; restart_required = @{ explorer = $false; system = $false } }
    exit
}
$state = [ordered]@{}
$operations = [System.Collections.Generic.List[object]]::new()
if ($manageCommandPalette) {
    if ($null -eq $package -or $null -eq $settingsPath) { throw 'Command Palette package state is unavailable.' }
    $currentShortcut = Get-ShortcutState $settingsPath
    $fileState = Get-FileState $settingsPath
    $running = @(Get-CommandPaletteProcesses $package).Count -gt 0
    $state.command_palette = [ordered]@{
        activation_shortcut = $currentShortcut
        running = $running
        package_version = [string]$package.Version
        settings_file = $fileState
    }
    if (-not (Test-ShortcutEqual $currentShortcut $desiredShortcut)) {
        $currentContent = Get-Content -LiteralPath $settingsPath -Raw
        $desiredContent = New-DesiredContent $currentContent
        $operations.Add([ordered]@{
            id = 'applications.powertoys.command_palette.activation_shortcut.set'
            action = 'set_activation_shortcut'
            resource = @{ type = 'applications.powertoys.command_palette'; id = 'activation_shortcut' }
            before = [ordered]@{ hotkey = $currentShortcut; running = $running; settings_file = $fileState }
            after = [ordered]@{ hotkey = $desiredShortcut; running = $running }
            data = [ordered]@{
                package_family_name = [string]$package.PackageFamilyName
                package_version = [string]$package.Version
                settings_path = $settingsPath
                written_file = Get-ContentState $desiredContent
                relaunch = $running
            }
        })
    }
}
if ($manageGrabAndMove) {
    $currentGrabAndMove = Get-GrabAndMoveState
    $desiredGrabAndMove = [ordered]@{
        enabled = [bool]$request.configuration.grab_and_move.enabled
        activation_modifier = [string]$request.configuration.grab_and_move.activation_modifier
    }
    $state.grab_and_move = $currentGrabAndMove
    if (-not (Test-WinixJsonEqual $currentGrabAndMove $desiredGrabAndMove)) {
        $desiredGrabAndMoveContent = New-GrabAndMoveContent (Get-Content -LiteralPath $grabAndMoveSettingsPath -Raw) $desiredGrabAndMove.activation_modifier
        $desiredDscSettings = New-DesiredPowerToysDscSettings (Get-PowerToysDscSettings $powerToysDscPath) $desiredGrabAndMove.enabled
        $operations.Add([ordered]@{
            id = 'applications.powertoys.grab_and_move.settings.set'
            action = 'set_grab_and_move_settings'
            resource = @{ type = 'applications.powertoys.grab_and_move'; id = 'settings' }
            before = [ordered]@{
                settings = $currentGrabAndMove
                general_file = Get-FileState $powerToysSettingsPath
                module_file = Get-FileState $grabAndMoveSettingsPath
            }
            after = [ordered]@{ settings = $desiredGrabAndMove }
            data = [ordered]@{
                dsc_path = $powerToysDscPath
                general_settings_path = $powerToysSettingsPath
                module_settings_path = $grabAndMoveSettingsPath
                written_module_file = Get-ContentState $desiredGrabAndMoveContent
                dsc_settings = $desiredDscSettings
            }
        })
    }
}

if ($Operation -eq 'plan') {
    foreach ($operationItem in $operations) {
        Write-WinixEvent -Kind 'resource_status' -ResourceType $operationItem.resource.type -ResourceId $operationItem.resource.id -Data @{ status = 'change_required'; operation = $operationItem }
    }
    Write-WinixResponse @{ protocol_version = 2; success = $true; changed = $false; state = $state; operations = @($operations); diagnostics = @(); restart_required = @{ explorer = $false; system = $false } }
    exit
}

if (Test-WinixAdministrator) { throw 'Current-user PowerToys configuration cannot run with an elevated token.' }
if (-not (Test-WinixPropertyPresent $request 'operations')) { throw 'Apply request is missing its planned operations.' }
$planned = @($request.operations)
foreach ($operationItem in $planned) {
    if ([string]$operationItem.id -ceq 'applications.powertoys.command_palette.activation_shortcut.set') {
        if (
            -not $manageCommandPalette -or
            [string]$operationItem.action -cne 'set_activation_shortcut' -or
            [string]$operationItem.resource.type -cne 'applications.powertoys.command_palette' -or
            [string]$operationItem.resource.id -cne 'activation_shortcut' -or
            [string]$operationItem.data.package_family_name -cne [string]$package.PackageFamilyName -or
            [string]$operationItem.data.package_version -cne [string]$package.Version -or
            [string]$operationItem.data.settings_path -cne $settingsPath -or
            [bool]$operationItem.data.relaunch -ne [bool]$operationItem.before.running -or
            -not (Test-ShortcutEqual $operationItem.after.hotkey $desiredShortcut) -or
            [bool]$operationItem.after.running -ne [bool]$operationItem.before.running
        ) { throw "Unsupported planned PowerToys operation '$($operationItem.id)'." }
        $observedFile = Get-FileState $settingsPath
        $observedShortcut = Get-ShortcutState $settingsPath
        $observedRunning = @(Get-CommandPaletteProcesses $package).Count -gt 0
        if (-not (Test-WinixJsonEqual $observedFile $operationItem.before.settings_file)) { throw "Plan is stale for '$($operationItem.id)': Command Palette settings.json changed after planning." }
        if (-not (Test-ShortcutEqual $observedShortcut $operationItem.before.hotkey)) { throw "Plan is stale for '$($operationItem.id)': the Command Palette activation shortcut changed after planning." }
        if ($observedRunning -ne [bool]$operationItem.before.running) { throw "Plan is stale for '$($operationItem.id)': the Command Palette running state changed after planning." }
    } elseif ([string]$operationItem.id -ceq 'applications.powertoys.grab_and_move.settings.set') {
        if (
            -not $manageGrabAndMove -or
            [string]$operationItem.action -cne 'set_grab_and_move_settings' -or
            [string]$operationItem.resource.type -cne 'applications.powertoys.grab_and_move' -or
            [string]$operationItem.resource.id -cne 'settings' -or
            [string]$operationItem.data.dsc_path -cne $powerToysDscPath -or
            [string]$operationItem.data.general_settings_path -cne $powerToysSettingsPath -or
            [string]$operationItem.data.module_settings_path -cne $grabAndMoveSettingsPath -or
            [string]$operationItem.after.settings.activation_modifier -cne [string]$request.configuration.grab_and_move.activation_modifier -or
            [bool]$operationItem.after.settings.enabled -ne [bool]$request.configuration.grab_and_move.enabled
        ) { throw "Unsupported planned PowerToys operation '$($operationItem.id)'." }
        if (-not (Test-WinixJsonEqual (Get-FileState $powerToysSettingsPath) $operationItem.before.general_file)) { throw "Plan is stale for '$($operationItem.id)': the PowerToys general settings changed after planning." }
        if (-not (Test-WinixJsonEqual (Get-FileState $grabAndMoveSettingsPath) $operationItem.before.module_file)) { throw "Plan is stale for '$($operationItem.id)': the Grab And Move settings changed after planning." }
        if (-not (Test-WinixJsonEqual (Get-GrabAndMoveState) $operationItem.before.settings)) { throw "Plan is stale for '$($operationItem.id)': the Grab And Move state changed after planning." }
        $reconstructedDscSettings = New-DesiredPowerToysDscSettings (Get-PowerToysDscSettings $powerToysDscPath) ([bool]$operationItem.after.settings.enabled)
        if (-not (Test-WinixJsonEqual $reconstructedDscSettings $operationItem.data.dsc_settings)) { throw "Plan is stale for '$($operationItem.id)': the planned PowerToys DSC settings can no longer be reproduced." }
    } else {
        throw "Unsupported planned PowerToys operation '$($operationItem.id)'."
    }
}

$applied = [System.Collections.Generic.List[string]]::new()
foreach ($operationItem in $planned) {
    Write-WinixEvent -Kind 'resource_change_started' -ResourceType $operationItem.resource.type -ResourceId $operationItem.resource.id -Data @{ operation_id = $operationItem.id; action = $operationItem.action; before = $operationItem.before; after = $operationItem.after }
    if ([string]$operationItem.id -ceq 'applications.powertoys.command_palette.activation_shortcut.set') {
        $relaunch = [bool]$operationItem.data.relaunch
        $writeCompleted = $false
        try {
            $processes = @(Get-CommandPaletteProcesses $package)
            if ($processes.Count -gt 0) {
                $processes | Stop-Process -Force
                foreach ($process in $processes) {
                    if (-not $process.WaitForExit(15000)) {
                        throw "Command Palette process '$($process.Id)' did not stop within 15 seconds."
                    }
                }
            }

            $content = Get-Content -LiteralPath $settingsPath -Raw
            $desiredContent = New-DesiredContent $content
            if (-not (Test-WinixJsonEqual (Get-ContentState $desiredContent) $operationItem.data.written_file)) {
                throw "Plan is stale for '$($operationItem.id)': the planned Command Palette document can no longer be reproduced."
            }

            Set-FileContentAtomically $settingsPath $desiredContent
            $writeCompleted = $true
            if (-not (Test-WinixJsonEqual (Get-FileState $settingsPath) $operationItem.data.written_file)) { throw 'Command Palette settings did not reach the planned file postcondition.' }
            if (-not (Test-ShortcutEqual (Get-ShortcutState $settingsPath) $desiredShortcut)) { throw 'Command Palette activation shortcut did not reach Alt+Space.' }
        } finally {
            if ($relaunch -and @(Get-CommandPaletteProcesses $package).Count -eq 0) {
                Start-CommandPaletteAndWait $package
            }
        }
        if (-not $writeCompleted) { throw 'Command Palette settings were not updated.' }
        $observedRunning = @(Get-CommandPaletteProcesses $package).Count -gt 0
        if ($observedRunning -ne [bool]$operationItem.after.running) { throw 'Command Palette did not return to its planned running state.' }
        if (-not (Test-ShortcutEqual (Get-ShortcutState $settingsPath) $operationItem.after.hotkey)) { throw 'Command Palette activation shortcut did not retain its planned value after relaunch.' }
    } else {
        $desiredGrabAndMoveContent = New-GrabAndMoveContent (Get-Content -LiteralPath $grabAndMoveSettingsPath -Raw) ([string]$operationItem.after.settings.activation_modifier)
        if (-not (Test-WinixJsonEqual (Get-ContentState $desiredGrabAndMoveContent) $operationItem.data.written_module_file)) {
            throw "Plan is stale for '$($operationItem.id)': the planned Grab And Move document can no longer be reproduced."
        }
        Set-FileContentAtomically $grabAndMoveSettingsPath $desiredGrabAndMoveContent
        if (-not (Test-WinixJsonEqual (Get-FileState $grabAndMoveSettingsPath) $operationItem.data.written_module_file)) { throw 'Grab And Move settings did not reach the planned file postcondition.' }
        Set-GrabAndMoveEnabled $powerToysDscPath $operationItem.data.dsc_settings
        Send-GrabAndMoveRefresh
        if (-not (Test-WinixJsonEqual (Get-GrabAndMoveState) $operationItem.after.settings)) { throw 'Grab And Move did not reach the planned settings state.' }
    }
    $applied.Add([string]$operationItem.id)
    Write-WinixEvent -Kind 'resource_change_completed' -ResourceType $operationItem.resource.type -ResourceId $operationItem.resource.id -Data @{ operation_id = $operationItem.id; changed = $true }
}

$finalState = [ordered]@{}
if ($manageCommandPalette) {
    $finalState.command_palette = [ordered]@{
        activation_shortcut = Get-ShortcutState $settingsPath
        running = (@(Get-CommandPaletteProcesses $package).Count -gt 0)
        package_version = [string]$package.Version
        settings_file = Get-FileState $settingsPath
    }
}
if ($manageGrabAndMove) { $finalState.grab_and_move = Get-GrabAndMoveState }
Write-WinixResponse @{ protocol_version = 2; success = $true; changed = ($applied.Count -gt 0); state = $finalState; operations = $planned; applied_operation_ids = $applied; diagnostics = @(); restart_required = @{ explorer = $false; system = $false } }
