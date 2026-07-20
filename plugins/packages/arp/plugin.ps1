param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.PluginSdk.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Winix.Arp.psm1') -Force

$request = Read-WinixRequest
$diagnostics = [System.Collections.Generic.List[object]]::new()
if ($request.context.scope -ne 'system') { throw 'ARP programs require system placement.' }

if ($Operation -eq 'validate') {
    foreach ($entry in $request.configuration.PSObject.Properties) {
        Assert-ArpRegistrationId -RegistrationId $entry.Name
        $current = Get-ArpProgram -RegistrationId $entry.Name
        if ($current.installed -and $current.display_name -cne $entry.Value.display_name) {
            $diagnostics.Add(@{ severity = 'error'; code = 'arp.display_name.mismatch'; path = "$($request.path).$($entry.Name)"; message = "ARP registration '$($entry.Name)' is '$($current.display_name)', not configured display name '$($entry.Value.display_name)'." })
        }
        if ($current.installed) {
            try { [void](Get-ArpUninstallInvocation -CommandLine $current.uninstall_string) }
            catch { $diagnostics.Add(@{ severity = 'error'; code = 'arp.provider.unsupported'; path = "$($request.path).$($entry.Name)"; message = $_.Exception.Message }) }
        }
    }
    Write-WinixResponse @{ protocol_version = 2; valid = ($diagnostics.Count -eq 0); diagnostics = $diagnostics }
    exit
}

if ($Operation -eq 'apply') {
    if (-not (Test-WinixAdministrator)) { throw 'ARP program removal requires an elevated token.' }
    if (-not (Test-WinixPropertyPresent $request 'operations')) { throw 'Apply request is missing its planned operations.' }
    Write-WinixResponse (Invoke-ArpApply -Request $request)
    exit
}

$state = [ordered]@{}
$operations = [System.Collections.Generic.List[object]]::new()
foreach ($entry in $request.configuration.PSObject.Properties) {
    $registrationId = $entry.Name
    Assert-ArpRegistrationId -RegistrationId $registrationId
    $current = Get-ArpProgram -RegistrationId $registrationId
    $state[$registrationId] = $current
    if (-not $current.installed) { continue }
    $plannedOperation = [ordered]@{
        id = "arp.system.uninstall.$registrationId"
        action = 'uninstall'
        resource = @{ type = 'arp.program'; id = $registrationId }
        before = $current
        after = Get-ArpAbsentState -RegistrationId $registrationId
        data = @{ invocation = Get-ArpUninstallInvocation -CommandLine $current.uninstall_string }
    }
    $operations.Add($plannedOperation)
    Write-WinixEvent -Kind 'resource_status' -ResourceType 'arp.program' -ResourceId $registrationId -Data @{ status = 'change_required'; operation = $plannedOperation }
}
Write-WinixResponse @{ protocol_version = 2; success = $true; changed = $false; state = $state; operations = $operations; diagnostics = @(); error = $null; restart_required = @{ explorer = $false; system = $false } }
