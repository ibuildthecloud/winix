param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.PluginSdk.psm1') -Force

function Get-ArpProgram([string] $RegistrationId) {
    $locations = @(
        @{ architecture = 'x64'; path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$RegistrationId" },
        @{ architecture = 'x86'; path = "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$RegistrationId" }
    )
    foreach ($location in $locations) {
        if (-not (Test-Path -LiteralPath $location.path)) { continue }
        $item = Get-ItemProperty -LiteralPath $location.path
        return [ordered]@{
            installed = $true
            registration_id = $RegistrationId
            display_name = $item.DisplayName
            version = $(if ($null -ne $item.PSObject.Properties['DisplayVersion']) { $item.DisplayVersion } else { $null })
            uninstall_string = $item.UninstallString
            architecture = $location.architecture
            registry_path = $location.path
        }
    }
    return [ordered]@{ installed = $false; registration_id = $RegistrationId; display_name = $null; version = $null; uninstall_string = $null; architecture = $null; registry_path = $null }
}

function Get-UninstallInvocation([string] $CommandLine) {
    if ($CommandLine -match '^"([^"]+)"\s*(.*)$') { $file = $Matches[1]; $arguments = $Matches[2] }
    elseif ($CommandLine -match '^(\S+)\s*(.*)$') { $file = $Matches[1]; $arguments = $Matches[2] }
    else { throw 'The ARP uninstall command could not be parsed.' }

    switch ([IO.Path]::GetFileName($file).ToLowerInvariant()) {
        'officeclicktorun.exe' { $arguments = "$arguments displaylevel=false forceappshutdown=true"; $successCodes = @(0) }
        'copilot_setup.exe' { $arguments = "$arguments --force-uninstall"; $successCodes = @(0, 19) }
        default { throw "ARP uninstall provider '$([IO.Path]::GetFileName($file))' has no non-interactive strategy." }
    }
    return @{ file = $file; arguments = $arguments; success_codes = $successCodes }
}

$request = Read-WinixRequest
$diagnostics = [System.Collections.Generic.List[object]]::new()
if ($request.context.scope -ne 'system') { throw 'ARP programs require system placement.' }

if ($Operation -eq 'validate') {
    foreach ($entry in $request.configuration.PSObject.Properties) {
        $current = Get-ArpProgram -RegistrationId $entry.Name
        if ($current.installed -and $current.display_name -cne $entry.Value.display_name) {
            $diagnostics.Add(@{ severity = 'error'; code = 'arp.display_name.mismatch'; path = "$($request.path).$($entry.Name)"; message = "ARP registration '$($entry.Name)' is '$($current.display_name)', not configured display name '$($entry.Value.display_name)'." })
        }
        if ($current.installed) {
            try { [void](Get-UninstallInvocation -CommandLine $current.uninstall_string) }
            catch { $diagnostics.Add(@{ severity = 'error'; code = 'arp.provider.unsupported'; path = "$($request.path).$($entry.Name)"; message = $_.Exception.Message }) }
        }
    }
    Write-WinixResponse @{ protocol_version = 2; valid = ($diagnostics.Count -eq 0); diagnostics = $diagnostics }
    exit
}

if ($Operation -eq 'apply') {
    if (-not (Test-WinixAdministrator)) { throw 'ARP program removal requires an elevated token.' }
    if (-not (Test-WinixPropertyPresent $request 'operations')) { throw 'Apply request is missing its planned operations.' }
    $planned = @($request.operations)
    $applied = [System.Collections.Generic.List[string]]::new()
    foreach ($operationItem in $planned) {
        if ($operationItem.resource.type -ne 'arp.program' -or $operationItem.action -ne 'uninstall') { throw "Unsupported planned operation '$($operationItem.id)'." }
        $registrationId = $operationItem.resource.id
        $current = Get-ArpProgram -RegistrationId $registrationId
        if (-not $current.installed) {
            $applied.Add($operationItem.id)
            Write-WinixEvent -Kind 'resource_change_completed' -ResourceType 'arp.program' -ResourceId $registrationId -Data @{ operation_id = $operationItem.id; changed = $false; status = 'already_absent' }
            continue
        }
        $expectedName = $request.configuration.PSObject.Properties[$registrationId].Value.display_name
        if ($current.display_name -cne $expectedName) { throw "ARP registration '$registrationId' changed identity after planning." }
        $invocation = Get-UninstallInvocation -CommandLine $current.uninstall_string
        Write-WinixEvent -Kind 'resource_change_started' -ResourceType 'arp.program' -ResourceId $registrationId -Data @{ operation_id = $operationItem.id; action = 'uninstall'; before = $current; after = $operationItem.after }
        $process = Start-Process -FilePath $invocation.file -ArgumentList $invocation.arguments -WindowStyle Hidden -Wait -PassThru
        if ($process.ExitCode -notin @($invocation.success_codes)) { throw "ARP uninstall failed for '$registrationId' with exit code $($process.ExitCode)." }
        $observed = Get-ArpProgram -RegistrationId $registrationId
        if ($observed.installed) { throw "ARP program '$registrationId' remains installed after uninstall." }
        $applied.Add($operationItem.id)
        Write-WinixEvent -Kind 'resource_change_completed' -ResourceType 'arp.program' -ResourceId $registrationId -Data @{ operation_id = $operationItem.id; changed = $true }
    }
    Write-WinixResponse @{ protocol_version = 2; success = $true; changed = ($applied.Count -gt 0); operations = $planned; applied_operation_ids = $applied; diagnostics = @(); error = $null; restart_required = @{ explorer = $false; system = $false } }
    exit
}

$state = [ordered]@{}
$operations = [System.Collections.Generic.List[object]]::new()
foreach ($entry in $request.configuration.PSObject.Properties) {
    $registrationId = $entry.Name
    $current = Get-ArpProgram -RegistrationId $registrationId
    $state[$registrationId] = $current
    if (-not $current.installed) { continue }
    $plannedOperation = [ordered]@{
        id = "arp.system.uninstall.$registrationId"
        action = 'uninstall'
        resource = @{ type = 'arp.program'; id = $registrationId }
        before = $current
        after = @{ installed = $false; registration_id = $registrationId; display_name = $null; version = $null; uninstall_string = $null; architecture = $null; registry_path = $null }
        data = @{}
    }
    $operations.Add($plannedOperation)
    Write-WinixEvent -Kind 'resource_status' -ResourceType 'arp.program' -ResourceId $registrationId -Data @{ status = 'change_required'; operation = $plannedOperation }
}
Write-WinixResponse @{ protocol_version = 2; success = $true; changed = $false; state = $state; operations = $operations; diagnostics = @(); error = $null; restart_required = @{ explorer = $false; system = $false } }
