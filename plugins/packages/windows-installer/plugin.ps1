param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.PluginSdk.psm1') -Force

function Get-InstallerProduct([string] $ProductCode) {
    $paths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$ProductCode",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$ProductCode"
    )
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $item = Get-ItemProperty -LiteralPath $path
        return [ordered]@{
            installed = $true
            product_code = $ProductCode
            display_name = $item.DisplayName
            version = $item.DisplayVersion
            registry_path = $path
        }
    }
    return [ordered]@{ installed = $false; product_code = $ProductCode; display_name = $null; version = $null; registry_path = $null }
}

$request = Read-WinixRequest
if ($request.context.scope -ne 'system') { throw 'Windows Installer packages require system placement.' }

if ($Operation -eq 'validate') {
    Write-WinixResponse @{ protocol_version = 2; valid = $true; diagnostics = @() }
    exit
}

if ($Operation -eq 'apply') {
    if (-not (Test-WinixAdministrator)) { throw 'Windows Installer package removal requires an elevated token.' }
    if (-not (Test-WinixPropertyPresent $request 'operations')) { throw 'Apply request is missing its planned operations.' }
    $planned = @($request.operations)
    foreach ($operationItem in $planned) {
        if ($operationItem.resource.type -ne 'windows_installer.product' -or $operationItem.action -ne 'uninstall') { throw "Unsupported planned operation '$($operationItem.id)'." }
    }

    $applied = [System.Collections.Generic.List[string]]::new()
    foreach ($operationItem in $planned) {
        $productCode = $operationItem.resource.id
        $current = Get-InstallerProduct -ProductCode $productCode
        if (-not $current.installed) {
            $applied.Add($operationItem.id)
            Write-WinixEvent -Kind 'resource_change_completed' -ResourceType 'windows_installer.product' -ResourceId $productCode -Data @{ operation_id = $operationItem.id; changed = $false; status = 'already_absent' }
            continue
        }
        Write-WinixEvent -Kind 'resource_change_started' -ResourceType 'windows_installer.product' -ResourceId $productCode -Data @{ operation_id = $operationItem.id; action = 'uninstall'; before = $operationItem.before; after = $operationItem.after }
        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', $productCode, '/qn', '/norestart') -WindowStyle Hidden -Wait -PassThru
        if ($process.ExitCode -notin @(0, 1605, 3010)) {
            $diagnostic = @{ severity = 'error'; code = 'windows_installer.uninstall.failed'; path = "$($request.path).$productCode"; message = "Windows Installer uninstall failed for '$productCode' with exit code $($process.ExitCode)."; data = @{ operation_id = $operationItem.id; exit_code = $process.ExitCode; applied_operation_ids = @($applied) } }
            Write-WinixEvent -Kind 'diagnostic' -ResourceType 'windows_installer.product' -ResourceId $productCode -Diagnostic $diagnostic
            Write-WinixResponse @{ protocol_version = 2; success = $false; changed = ($applied.Count -gt 0); operations = $planned; applied_operation_ids = $applied; diagnostics = @($diagnostic); error = @{ code = 'windows_installer.apply.failed'; message = "Planned Windows Installer operation '$($operationItem.id)' failed." }; restart_required = @{ explorer = $false; system = $false } }
            exit
        }
        $observed = Get-InstallerProduct -ProductCode $productCode
        if ($observed.installed) { throw "MSI product '$productCode' remains installed after a successful uninstall exit code." }
        $applied.Add($operationItem.id)
        Write-WinixEvent -Kind 'resource_change_completed' -ResourceType 'windows_installer.product' -ResourceId $productCode -Data @{ operation_id = $operationItem.id; changed = $true; restart_exit_code = $process.ExitCode }
    }
    Write-WinixResponse @{ protocol_version = 2; success = $true; changed = ($applied.Count -gt 0); operations = $planned; applied_operation_ids = $applied; diagnostics = @(); restart_required = @{ explorer = $false; system = $false } }
    exit
}

$state = [ordered]@{}
$operations = [System.Collections.Generic.List[object]]::new()
foreach ($entry in $request.configuration.PSObject.Properties) {
    $productCode = $entry.Name
    $current = Get-InstallerProduct -ProductCode $productCode
    $state[$productCode] = $current
    if (-not $current.installed) { continue }
    $plannedOperation = [ordered]@{
        id = "windows_installer.system.uninstall.$productCode"
        action = 'uninstall'
        resource = @{ type = 'windows_installer.product'; id = $productCode }
        before = $current
        after = @{ installed = $false; product_code = $productCode; display_name = $null; version = $null; registry_path = $null }
        data = @{}
    }
    $operations.Add($plannedOperation)
    Write-WinixEvent -Kind 'resource_status' -ResourceType 'windows_installer.product' -ResourceId $productCode -Data @{ status = 'change_required'; operation = $plannedOperation }
}
Write-WinixResponse @{ protocol_version = 2; success = $true; changed = $false; state = $state; operations = $operations; diagnostics = @(); error = $null; restart_required = @{ explorer = $false; system = $false } }
