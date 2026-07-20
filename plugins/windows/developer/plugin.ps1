param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.PluginSdk.psm1') -Force

$sudoPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo'
$endTaskPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'
$developerModePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
$longPathsPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'

function Get-OptionalRegistryValue([string] $Path, [string] $Name) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Get-ItemProperty -LiteralPath $Path
    $property = $item.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-SudoMode {
    $value = Get-OptionalRegistryValue -Path $sudoPath -Name Enabled
    switch ($value) {
        1 { return 'force_new_window' }
        2 { return 'disable_input' }
        3 { return 'inline' }
        default { return 'disabled' }
    }
}

function Get-EndTaskState {
    $value = Get-OptionalRegistryValue -Path $endTaskPath -Name TaskbarEndTask
    if ($value -eq 1) { return 'enabled' }
    return 'disabled'
}

function Get-BinarySettingState([string] $Path, [string] $Name) {
    if ((Get-OptionalRegistryValue -Path $Path -Name $Name) -eq 1) { return 'enabled' }
    return 'disabled'
}

function Get-DesiredResources([object] $Request) {
    $resources = [System.Collections.Generic.List[object]]::new()
    if ($Request.context.scope -eq 'system') {
        if (Test-WinixPropertyPresent $Request.configuration 'end_task') { throw 'windows.developer.end_task is user-scoped; place it under users.current.' }
        if (Test-WinixPropertyPresent $Request.configuration 'sudo') {
            $resources.Add(@{ id = 'sudo'; current = (Get-SudoMode); desired = $Request.configuration.sudo.mode })
        }
        if (Test-WinixPropertyPresent $Request.configuration 'developer_mode') {
            $resources.Add(@{ id = 'developer_mode'; current = (Get-BinarySettingState -Path $developerModePath -Name 'AllowDevelopmentWithoutDevLicense'); desired = "$($Request.configuration.developer_mode)" })
        }
        if (Test-WinixPropertyPresent $Request.configuration 'long_paths') {
            $resources.Add(@{ id = 'long_paths'; current = (Get-BinarySettingState -Path $longPathsPath -Name 'LongPathsEnabled'); desired = "$($Request.configuration.long_paths)" })
        }
    } elseif ($Request.context.scope -eq 'user') {
        foreach ($property in @('sudo', 'developer_mode', 'long_paths')) {
            if (Test-WinixPropertyPresent $Request.configuration $property) { throw "windows.developer.$property is system-scoped; place it under system." }
        }
        if (Test-WinixPropertyPresent $Request.configuration 'end_task') {
            $resources.Add(@{ id = 'end_task'; current = (Get-EndTaskState); desired = $Request.configuration.end_task })
        }
    } else { throw "Unsupported developer-settings scope '$($Request.context.scope)'." }
    return @($resources)
}

$request = Read-WinixRequest

if ($Operation -eq 'validate') {
    try { [void](Get-DesiredResources -Request $request); $diagnostics = @() }
    catch { $diagnostics = @(@{ severity = 'error'; code = 'windows.developer.scope.invalid'; path = $request.path; message = $_.Exception.Message }) }
    Write-WinixResponse @{ protocol_version = 2; valid = ($diagnostics.Count -eq 0); diagnostics = $diagnostics }
    exit
}

if ($Operation -eq 'apply') {
    if ($request.context.scope -eq 'system' -and -not (Test-WinixAdministrator)) { throw 'System developer settings require an elevated token.' }
    if ($request.context.scope -eq 'user' -and (Test-WinixAdministrator)) { throw 'User developer settings cannot run with an elevated token.' }
    if (-not (Test-WinixPropertyPresent $request 'operations')) { throw 'Apply request is missing its planned operations.' }
    $planned = @($request.operations)
    $applied = [System.Collections.Generic.List[string]]::new()
    foreach ($operationItem in $planned) {
        $resourceId = $operationItem.resource.id
        $current = switch ($resourceId) {
            'sudo' { Get-SudoMode }
            'end_task' { Get-EndTaskState }
            'developer_mode' { Get-BinarySettingState -Path $developerModePath -Name 'AllowDevelopmentWithoutDevLicense' }
            'long_paths' { Get-BinarySettingState -Path $longPathsPath -Name 'LongPathsEnabled' }
            default { throw "Unsupported developer setting '$resourceId'." }
        }
        if ($current -ne $operationItem.before) { throw "Plan is stale for '$($operationItem.id)': developer setting changed after planning." }
    }
    foreach ($operationItem in $planned) {
        $resourceId = $operationItem.resource.id
        Write-WinixEvent -Kind 'resource_change_started' -ResourceType 'windows.developer.setting' -ResourceId $resourceId -Data @{ operation_id = $operationItem.id; action = 'configure'; before = $operationItem.before; after = $operationItem.after }
        if ($resourceId -eq 'sudo') {
            $cliMode = switch ($operationItem.after) { 'force_new_window' { 'forceNewWindow' }; 'disable_input' { 'disableInput' }; 'inline' { 'normal' } }
            $null = & "$env:SystemRoot\System32\sudo.exe" config --enable $cliMode 2>&1
            if ($LASTEXITCODE -ne 0) { throw "sudo config failed with exit code $LASTEXITCODE." }
            $observed = Get-SudoMode
        } elseif ($resourceId -eq 'end_task') {
            if (-not (Test-Path -LiteralPath $endTaskPath)) { New-Item -Path $endTaskPath -Force | Out-Null }
            $value = if ($operationItem.after -eq 'enabled') { 1 } else { 0 }
            New-ItemProperty -LiteralPath $endTaskPath -Name TaskbarEndTask -PropertyType DWord -Value $value -Force | Out-Null
            $observed = Get-EndTaskState
        } else {
            $mapping = if ($resourceId -eq 'developer_mode') {
                @{ path = $developerModePath; name = 'AllowDevelopmentWithoutDevLicense' }
            } else {
                @{ path = $longPathsPath; name = 'LongPathsEnabled' }
            }
            $value = if ($operationItem.after -eq 'enabled') { 1 } else { 0 }
            Set-WinixProperty $mapping.path $mapping.name $value 'DWord' | Out-Null
            $observed = Get-BinarySettingState -Path $mapping.path -Name $mapping.name
        }
        if ($observed -ne $operationItem.after) { throw "Developer setting '$resourceId' did not reach its declared postcondition." }
        $applied.Add($operationItem.id)
        Write-WinixEvent -Kind 'resource_change_completed' -ResourceType 'windows.developer.setting' -ResourceId $resourceId -Data @{ operation_id = $operationItem.id; changed = $true; observed = $observed }
    }
    Write-WinixResponse @{ protocol_version = 2; success = $true; changed = ($applied.Count -gt 0); operations = $planned; applied_operation_ids = $applied; diagnostics = @(); error = $null; restart_required = @{ explorer = $false; system = $false } }
    exit
}

$state = [ordered]@{}
$operations = [System.Collections.Generic.List[object]]::new()
foreach ($resource in @(Get-DesiredResources -Request $request)) {
    $state[$resource.id] = $resource.current
    if ($resource.current -eq $resource.desired) { continue }
    $plannedOperation = [ordered]@{
        id = "windows.developer.$($request.context.scope).configure.$($resource.id)"
        action = 'configure'
        resource = @{ type = 'windows.developer.setting'; id = $resource.id }
        before = $resource.current
        after = $resource.desired
        data = @{}
    }
    $operations.Add($plannedOperation)
    Write-WinixEvent -Kind 'resource_status' -ResourceType 'windows.developer.setting' -ResourceId $resource.id -Data @{ status = 'change_required'; operation = $plannedOperation }
}
Write-WinixResponse @{ protocol_version = 2; success = $true; changed = $false; state = $state; operations = $operations; diagnostics = @(); error = $null; restart_required = @{ explorer = $false; system = $false } }
