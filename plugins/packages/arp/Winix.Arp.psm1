Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('Winix.Arp.CommandLine' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'ArpCommandLine.cs')
}

function Assert-ArpRegistrationId {
    param([Parameter(Mandatory)] [string] $RegistrationId)

    if ([string]::IsNullOrWhiteSpace($RegistrationId) -or $RegistrationId -cne $RegistrationId.Trim()) {
        throw "ARP registration ID '$RegistrationId' is not a canonical registry leaf."
    }
    if ($RegistrationId -in @('.', '..') -or $RegistrationId.Contains('\') -or $RegistrationId.Contains('/')) {
        throw "ARP registration ID '$RegistrationId' is not a single registry leaf."
    }
    foreach ($character in $RegistrationId.ToCharArray()) {
        if ([char]::IsControl($character)) {
            throw "ARP registration ID '$RegistrationId' contains a control character."
        }
    }
}

function Get-ArpUninstallInvocation {
    param([Parameter(Mandatory)] [string] $CommandLine)

    $commandParts = @([Winix.Arp.CommandLine]::Parse($CommandLine))
    if ($commandParts.Count -eq 0) {
        throw 'The ARP uninstall command could not be parsed.'
    }

    $expandedPath = [Environment]::ExpandEnvironmentVariables($commandParts[0])
    if (-not [IO.Path]::IsPathFullyQualified($expandedPath)) {
        throw "ARP uninstall executable '$expandedPath' is not fully qualified."
    }
    $filePath = [IO.Path]::GetFullPath($expandedPath)
    $argumentList = [Collections.Generic.List[string]]::new()
    foreach ($argument in @($commandParts | Select-Object -Skip 1)) {
        $argumentList.Add([string]$argument)
    }

    switch ([IO.Path]::GetFileName($filePath).ToLowerInvariant()) {
        'officeclicktorun.exe' {
            $argumentList.Add('displaylevel=false')
            $argumentList.Add('forceappshutdown=true')
            $successCodes = @(0)
        }
        'copilot_setup.exe' {
            $argumentList.Add('--force-uninstall')
            $successCodes = @(0, 19)
        }
        default {
            throw "ARP uninstall provider '$([IO.Path]::GetFileName($filePath))' has no non-interactive strategy."
        }
    }

    return [ordered]@{
        file_path = $filePath
        arguments = @($argumentList)
        success_codes = $successCodes
    }
}

function Get-ArpProgram {
    param([Parameter(Mandatory)] [string] $RegistrationId)

    Assert-ArpRegistrationId -RegistrationId $RegistrationId
    $locations = @(
        @{ architecture = 'x64'; path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$RegistrationId" }
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
    return [ordered]@{
        installed = $false
        registration_id = $RegistrationId
        display_name = $null
        version = $null
        uninstall_string = $null
        architecture = $null
        registry_path = $null
    }
}

function Get-ArpAbsentState {
    param([Parameter(Mandatory)] [string] $RegistrationId)

    return [ordered]@{
        installed = $false
        registration_id = $RegistrationId
        display_name = $null
        version = $null
        uninstall_string = $null
        architecture = $null
        registry_path = $null
    }
}

function Invoke-ArpUninstall {
    param([Parameter(Mandatory)] [object] $Invocation)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = [string]$Invocation.file_path
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @($Invocation.arguments)) {
        $startInfo.ArgumentList.Add([string]$argument)
    }

    $childProcess = [Diagnostics.Process]::Start($startInfo)
    if ($null -eq $childProcess) {
        throw "ARP uninstall process '$($Invocation.file_path)' did not start."
    }
    try {
        $standardOutput = $childProcess.StandardOutput.ReadToEndAsync()
        $standardError = $childProcess.StandardError.ReadToEndAsync()
        $childProcess.WaitForExit()
        # Native provider output must never enter the plugin's NDJSON stdout
        # stream. Drain both pipes concurrently and discard them here; the exit
        # code and authoritative postcondition determine success.
        [void]$standardOutput.GetAwaiter().GetResult()
        [void]$standardError.GetAwaiter().GetResult()
        return $childProcess.ExitCode
    } finally {
        $childProcess.Dispose()
    }
}

function Assert-ArpApplyPlan {
    param([Parameter(Mandatory)] [object] $Request)

    $operationIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $registrationIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($operationItem in @($Request.operations)) {
        if ($operationItem.resource.type -cne 'arp.program' -or $operationItem.action -cne 'uninstall') {
            throw "Unsupported planned operation '$($operationItem.id)'."
        }

        $registrationId = [string]$operationItem.resource.id
        Assert-ArpRegistrationId -RegistrationId $registrationId
        if (-not $operationIds.Add([string]$operationItem.id)) {
            throw "Duplicate planned operation ID '$($operationItem.id)'."
        }
        if (-not $registrationIds.Add($registrationId)) {
            throw "Duplicate planned ARP registration '$registrationId'."
        }
        if ($operationItem.id -cne "arp.system.uninstall.$registrationId") {
            throw "Planned operation '$($operationItem.id)' does not match ARP registration '$registrationId'."
        }

        $configurationProperties = @(
            $Request.configuration.PSObject.Properties | Where-Object Name -CEQ $registrationId
        )
        if ($configurationProperties.Count -ne 1) {
            throw "Planned ARP registration '$registrationId' is not present exactly in configuration."
        }
        $configuration = $configurationProperties[0].Value
        if ($configuration.state -cne 'absent' -or $operationItem.before.display_name -cne $configuration.display_name) {
            throw "Planned ARP registration '$registrationId' does not match configuration."
        }
        if ($operationItem.before.installed -ne $true -or $operationItem.before.registration_id -cne $registrationId) {
            throw "Planned ARP registration '$registrationId' has an invalid before state."
        }

        $expectedAfter = Get-ArpAbsentState -RegistrationId $registrationId
        if (-not (Test-WinixJsonEqual -Left $operationItem.after -Right $expectedAfter)) {
            throw "Planned ARP registration '$registrationId' has an invalid after state."
        }

        $plannedInvocation = Get-ArpUninstallInvocation -CommandLine ([string]$operationItem.before.uninstall_string)
        $expectedData = [ordered]@{ invocation = $plannedInvocation }
        if (-not (Test-WinixJsonEqual -Left $operationItem.data -Right $expectedData)) {
            throw "Planned ARP invocation for '$registrationId' was changed after planning."
        }

        $current = Get-ArpProgram -RegistrationId $registrationId
        if (-not (Test-WinixJsonEqual -Left $current -Right $operationItem.before)) {
            throw "ARP registration '$registrationId' changed after planning."
        }

        [pscustomobject]@{
            operation = $operationItem
            registration_id = $registrationId
            invocation = $operationItem.data.invocation
        }
    }
}

function Invoke-ArpApply {
    param([Parameter(Mandatory)] [object] $Request)

    # Assert-ArpApplyPlan enumerates and verifies the complete queue before this
    # function enters its mutation loop.
    $preparedOperations = @(Assert-ArpApplyPlan -Request $Request)
    $plannedOperations = @($Request.operations)
    $applied = [Collections.Generic.List[string]]::new()

    foreach ($prepared in $preparedOperations) {
        $operationItem = $prepared.operation
        $registrationId = $prepared.registration_id
        # Recheck immediately before launch to narrow the race after the
        # queue-wide all-or-nothing preflight.
        $current = Get-ArpProgram -RegistrationId $registrationId
        if (-not (Test-WinixJsonEqual -Left $current -Right $operationItem.before)) {
            throw "ARP registration '$registrationId' changed after queue preflight."
        }
        Write-WinixEvent -Kind 'resource_change_started' -ResourceType 'arp.program' -ResourceId $registrationId -Data @{
            operation_id = $operationItem.id
            action = 'uninstall'
            before = $operationItem.before
            after = $operationItem.after
        }
        $exitCode = Invoke-ArpUninstall -Invocation $prepared.invocation
        if ($exitCode -notin @($prepared.invocation.success_codes)) {
            throw "ARP uninstall failed for '$registrationId' with exit code $exitCode."
        }
        $observed = Get-ArpProgram -RegistrationId $registrationId
        if (-not (Test-WinixJsonEqual -Left $observed -Right $operationItem.after)) {
            throw "ARP program '$registrationId' remains installed after uninstall."
        }
        $applied.Add($operationItem.id)
        Write-WinixEvent -Kind 'resource_change_completed' -ResourceType 'arp.program' -ResourceId $registrationId -Data @{
            operation_id = $operationItem.id
            changed = $true
        }
    }

    return [ordered]@{
        protocol_version = 2
        success = $true
        changed = ($applied.Count -gt 0)
        operations = $plannedOperations
        applied_operation_ids = $applied
        diagnostics = @()
        error = $null
        restart_required = @{ explorer = $false; system = $false }
    }
}

Export-ModuleMember -Function Assert-ArpRegistrationId, Get-ArpUninstallInvocation, Get-ArpProgram, Get-ArpAbsentState, Invoke-ArpUninstall, Assert-ArpApplyPlan, Invoke-ArpApply
