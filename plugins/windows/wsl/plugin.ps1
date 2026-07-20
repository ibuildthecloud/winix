param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.PluginSdk.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Winix.Wsl.psm1') -Force

$StableReleaseUri = 'https://api.github.com/repos/microsoft/WSL/releases/latest'
$ReleaseCatalogUri = 'https://api.github.com/repos/microsoft/WSL/releases?per_page=30'
$RestartReceiptPath = Join-Path $env:ProgramData 'Winix\windows-wsl\install-restart.json'
$FirstRunOobePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
$script:OnlineDistros = $null
$script:LatestReleases = @{}

function Get-WslFirstRunOobeState {
    if (-not (Test-Path -LiteralPath $FirstRunOobePath)) { return 'available' }
    $item = Get-ItemProperty -LiteralPath $FirstRunOobePath
    $property = $item.PSObject.Properties['OOBEComplete']
    if ($null -ne $property -and $property.Value -eq 1) { return 'suppressed' }
    return 'available'
}

function Get-BootIdentifier {
    return (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
}

function Get-BootTicks {
    return (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().Ticks
}

function Test-WslInstallRestartPending {
    if (-not (Test-Path -LiteralPath $RestartReceiptPath)) { return $false }
    try {
        $receipt = Get-Content -LiteralPath $RestartReceiptPath -Raw | ConvertFrom-Json
        $recordedTicks = if ($null -ne $receipt.PSObject.Properties['boot_ticks']) {
            [long]$receipt.boot_ticks
        } elseif ($receipt.boot_id -is [DateTime]) {
            $receipt.boot_id.ToUniversalTime().Ticks
        } else {
            [DateTimeOffset]::Parse("$($receipt.boot_id)").UtcDateTime.Ticks
        }
        return $recordedTicks -eq (Get-BootTicks)
    } catch {
        # A receipt written by a successful first-install command is treated
        # conservatively until its boot identity can be checked.
        return $true
    }
}

function Test-WslFeaturesProvisioned {
    return Test-Path -LiteralPath $RestartReceiptPath
}

function Write-WslInstallRestartReceipt {
    $directory = Split-Path -Parent $RestartReceiptPath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    @{ boot_id = Get-BootIdentifier; boot_ticks = Get-BootTicks; created_at = [DateTime]::UtcNow.ToString('o') } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath $RestartReceiptPath -Encoding utf8NoBOM
}

function Invoke-Wsl([string[]] $Arguments, [switch] $AllowFailure) {
    # Windows 11 can turn otherwise read-only wsl.exe commands into an
    # interactive update prompt. Do not let plugin observation allocate a
    # console window or inherit input that could accept that prompt.
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'wsl.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    # wsl.exe writes redirected command output as UTF-16LE.
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::Unicode
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::Unicode
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'wsl.exe could not be started.' }
        $process.StandardInput.Close()
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $standardError = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
        $text = @($standardOutput.GetAwaiter().GetResult(), $standardError.GetAwaiter().GetResult()) -join "`n"
        $output = @($text -split '\r?\n' | Where-Object { -not [string]::IsNullOrEmpty($_) })
    } finally {
        $process.Dispose()
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $detail = ($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' '
        throw "wsl.exe $($Arguments -join ' ') failed with exit code $exitCode$(if ($detail) { ": $detail" })."
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Test-WslUpdateRequired([object[]] $Results) {
    $text = @($Results | Where-Object { $null -ne $_ } | ForEach-Object { $_.Output }) -join "`n"
    return $text -match '(?i)Windows Subsystem for Linux must be updated to the latest version to proceed'
}

function Invoke-DismFeature([string] $FeatureName, [ValidateSet('Enable', 'Disable')] [string] $Action) {
    $arguments = @('/Online', "/$Action-Feature", "/FeatureName:$FeatureName", '/NoRestart')
    if ($Action -eq 'Enable') { $arguments += '/All' }
    $output = @(& dism.exe @arguments 2>&1 | ForEach-Object { "$_" })
    $exitCode = $LASTEXITCODE
    if ($exitCode -notin @(0, 3010)) {
        $detail = ($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' '
        throw "dism.exe $($arguments -join ' ') failed with exit code $exitCode$(if ($detail) { ": $detail" })."
    }
}

function Enable-WslFeatures {
    Invoke-DismFeature -FeatureName 'VirtualMachinePlatform' -Action Enable
    Invoke-DismFeature -FeatureName 'Microsoft-Windows-Subsystem-Linux' -Action Enable
}

function ConvertTo-WslVersion([string] $Text) {
    $match = [regex]::Match($Text, '(?<!\d)(\d+\.\d+(?:\.\d+){0,2})(?!\d)')
    if (-not $match.Success) { return $null }
    $parts = @($match.Groups[1].Value.Split('.') | ForEach-Object { [int]$_ })
    while ($parts.Count -lt 4) { $parts += 0 }
    return [version]::new($parts[0], $parts[1], $parts[2], $parts[3])
}

function Get-WslState {
    $restartPending = Test-WslInstallRestartPending
    $featuresProvisioned = Test-WslFeaturesProvisioned
    $versionResult = Invoke-Wsl -Arguments @('--version') -AllowFailure
    $versionRequiresUpdate = Test-WslUpdateRequired -Results @($versionResult)
    $statusResult = if ($versionResult.ExitCode -eq 0 -or $versionRequiresUpdate) { $null } else { Invoke-Wsl -Arguments @('--status') -AllowFailure }
    $updateRequired = Test-WslUpdateRequired -Results @($versionResult, $statusResult)
    $statusSucceeded = $null -ne $statusResult -and $statusResult.ExitCode -eq 0
    $installed = $versionResult.ExitCode -eq 0 -or $statusSucceeded -or $updateRequired
    $featuresEnabled = $featuresProvisioned -or $installed
    if (-not $installed) {
        return [ordered]@{ features_enabled = $featuresEnabled; installed = $false; restart_pending = $restartPending; update_required = $false; version = $null; distros = @() }
    }

    $version = if ($versionResult.ExitCode -eq 0) {
        ConvertTo-WslVersion -Text ($versionResult.Output -join "`n")
    } else { $null }
    $list = if ($updateRequired) { $null } else { Invoke-Wsl -Arguments @('--list', '--quiet') -AllowFailure }
    $distros = if ($null -ne $list -and $list.ExitCode -eq 0) {
        @($list.Output | ForEach-Object { $_.Trim().TrimStart([char]0xfeff) } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    } else { @() }
    return [ordered]@{
        features_enabled = $featuresEnabled
        installed = $true
        restart_pending = $restartPending
        update_required = $updateRequired
        version = if ($null -eq $version) { $null } else { $version.ToString() }
        distros = @($distros)
    }
}

function Get-OnlineDistros {
    if ($null -ne $script:OnlineDistros) { return $script:OnlineDistros }
    $result = Invoke-Wsl -Arguments @('--list', '--online')
    $catalog = [ordered]@{}
    $tableSeen = $false
    foreach ($line in $result.Output) {
        if ($line -match '^\s*-{3,}' -or $line -match '^\s*NAME\s{2,}FRIENDLY\s+NAME\s*$') { $tableSeen = $true; continue }
        if (-not $tableSeen) { continue }
        if ($line -match '^\s*(?:\*\s*)?(\S+)(?:\s{2,}|\s*$)') {
            $name = $Matches[1].Trim().TrimStart([char]0xfeff)
            if ($name) { $catalog[$name] = $name }
        }
    }
    if ($catalog.Count -eq 0) { throw 'wsl.exe --list --online returned no parseable distribution names.' }
    $script:OnlineDistros = $catalog
    return $script:OnlineDistros
}

function Resolve-Distros([string[]] $Names, [System.Collections.Generic.List[object]] $Diagnostics, [string] $Path) {
    $resolved = [System.Collections.Generic.List[string]]::new()
    if ($Names.Count -eq 0) { return @() }
    $catalog = Get-OnlineDistros
    foreach ($name in $Names) {
        $canonical = @($catalog.Keys | Where-Object { $_ -ieq $name }) | Select-Object -First 1
        if ($null -eq $canonical) {
            $Diagnostics.Add(@{ severity = 'error'; code = 'wsl.distro.unknown'; path = "$Path.distros"; message = "'$name' is not offered by wsl.exe --list --online."; help = 'Use an exact distribution name from wsl.exe --list --online.' })
        } elseif ($canonical -cne $name) {
            $Diagnostics.Add(@{ severity = 'error'; code = 'wsl.distro.non_canonical'; path = "$Path.distros"; message = "WSL distribution '$name' is not canonical; use '$canonical'."; help = "Use $canonical." })
        } else {
            $resolved.Add($canonical)
        }
    }
    return @($resolved)
}

function Get-LatestWslRelease([bool] $Preview) {
    $key = if ($Preview) { 'preview' } else { 'stable' }
    if ($script:LatestReleases.ContainsKey($key)) { return $script:LatestReleases[$key] }
    $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'Winix-WSL-Plugin' }
    $release = if ($Preview) {
        $releases = Invoke-RestMethod -Uri $ReleaseCatalogUri -Headers $headers -Method Get
        @($releases | Where-Object { -not $_.draft -and $_.prerelease } | Select-Object -First 1)
    } else {
        Invoke-RestMethod -Uri $StableReleaseUri -Headers $headers -Method Get
    }
    if ($null -eq $release -or @($release).Count -eq 0) { throw "The WSL $key release catalog returned no release." }
    $release = @($release)[0]
    $version = ConvertTo-WslVersion -Text "$($release.tag_name)"
    if ($null -eq $version) { throw "The WSL $key release tag '$($release.tag_name)' has no parseable version." }
    $resolved = [pscustomobject]@{ Version = $version.ToString(); Tag = "$($release.tag_name)"; Preview = $Preview }
    $script:LatestReleases[$key] = $resolved
    return $resolved
}

function Write-PlanFailure([object[]] $Diagnostics) {
    Write-WinixResponse @{ protocol_version = 2; success = $false; changed = $false; state = @{}; operations = @(); diagnostics = $Diagnostics; error = @{ code = 'wsl.plan.failed'; message = 'WSL could not produce a valid plan.' }; restart_required = @{ explorer = $false; system = $false } }
}

$request = Read-WinixRequest
$diagnostics = [System.Collections.Generic.List[object]]::new()
$scope = "$($request.context.scope)"

if ($scope -eq 'user') {
    foreach ($property in @('state', 'version', 'preview', 'distros')) {
        if (Test-WinixPropertyPresent $request.configuration $property) {
            $diagnostics.Add(@{ severity = 'error'; code = 'wsl.scope.invalid'; path = "$($request.path).$property"; message = "windows.wsl.$property is system-scoped; place it under system.windows.wsl." })
        }
    }
    if (-not (Test-WinixPropertyPresent $request.configuration 'first_run_oobe')) {
        $diagnostics.Add(@{ severity = 'error'; code = 'wsl.user.configuration.empty'; path = $request.path; message = 'User-scoped windows.wsl requires first_run_oobe.' })
    }

    if ($Operation -eq 'validate') {
        Write-WinixResponse @{ protocol_version = 2; valid = ($diagnostics.Count -eq 0); diagnostics = $diagnostics }
        exit
    }
    if ($diagnostics.Count -gt 0) { Write-PlanFailure -Diagnostics $diagnostics; exit }

    $currentOobe = Get-WslFirstRunOobeState
    if ($Operation -eq 'plan') {
        $operations = [System.Collections.Generic.List[object]]::new()
        if ($currentOobe -ne 'suppressed') {
            $operations.Add([ordered]@{
                id = 'wsl.user.suppress-first-run-oobe'
                action = 'suppress_first_run_oobe'
                resource = @{ type = 'windows.wsl.first_run_oobe'; id = 'current-user' }
                before = $currentOobe
                after = 'suppressed'
                data = @{}
            })
            Write-WinixEvent -Kind 'resource_status' -ResourceType 'windows.wsl.first_run_oobe' -ResourceId 'current-user' -Data @{ status = 'change_required'; operation = $operations[0] }
        }
        Write-WinixResponse @{ protocol_version = 2; success = $true; changed = $false; state = @{ first_run_oobe = $currentOobe }; operations = $operations; diagnostics = @(); error = $null; restart_required = @{ explorer = $false; system = $false } }
        exit
    }

    if (Test-WinixAdministrator) { throw 'User WSL settings cannot run with an elevated token.' }
    $result = Invoke-WslUserApply -Request $request -GetState { Get-WslFirstRunOobeState } -Mutate {
        if (-not (Test-Path -LiteralPath $FirstRunOobePath)) { New-Item -Path $FirstRunOobePath -Force | Out-Null }
        New-ItemProperty -LiteralPath $FirstRunOobePath -Name 'OOBEComplete' -PropertyType DWord -Value 1 -Force | Out-Null
    }
    Write-WinixResponse $result
    exit
}

if ($scope -ne 'system') { throw "Unsupported WSL scope '$scope'." }
if (Test-WinixPropertyPresent $request.configuration 'first_run_oobe') {
    $diagnostics.Add(@{ severity = 'error'; code = 'wsl.scope.invalid'; path = "$($request.path).first_run_oobe"; message = 'windows.wsl.first_run_oobe is user-scoped; place it under users.current.windows.wsl.' })
}
$desiredState = if (Test-WinixPropertyPresent $request.configuration 'state') { "$($request.configuration.state)" } else { 'installed' }
$desiredDistros = @()
if (Test-WinixPropertyPresent $request.configuration 'distros') {
    $desiredDistros = @($request.configuration.distros | ForEach-Object { "$_" })
}
$preview = (Test-WinixPropertyPresent $request.configuration 'preview') -and [bool]$request.configuration.preview
$manageVersion = Test-WinixPropertyPresent $request.configuration 'version'

if ($Operation -eq 'validate') {
    $current = Get-WslState
    if ($desiredState -eq 'installed' -and $current.update_required -and -not $manageVersion) {
        $diagnostics.Add(@{ severity = 'error'; code = 'wsl.update_required'; path = $request.path; message = 'WSL must be updated before its state or distributions can be reconciled.'; help = "Set version to 'latest' or run wsl.exe --update, then reconcile again." })
    }
    if ($desiredState -eq 'installed' -and $desiredDistros.Count -gt 0 -and $current.installed -and -not $current.update_required) {
        try { [void](Resolve-Distros -Names $desiredDistros -Diagnostics $diagnostics -Path $request.path) }
        catch { $diagnostics.Add(@{ severity = 'error'; code = 'wsl.catalog.failed'; path = "$($request.path).distros"; message = "WSL online distribution lookup failed: $($_.Exception.Message)" }) }
    }
    if ($manageVersion) {
        try { [void](Get-LatestWslRelease -Preview $preview) }
        catch { $diagnostics.Add(@{ severity = 'error'; code = 'wsl.release.failed'; path = "$($request.path).version"; message = "WSL release lookup failed: $($_.Exception.Message)" }) }
    }
    Write-WinixResponse @{ protocol_version = 2; valid = ($diagnostics.Count -eq 0); diagnostics = $diagnostics }
    exit
}

if ($diagnostics.Count -gt 0) {
    if ($Operation -eq 'plan') { Write-PlanFailure -Diagnostics $diagnostics; exit }
    throw $diagnostics[0].message
}

$current = Get-WslState
$state = $current
$operations = [System.Collections.Generic.List[object]]::new()
$restartRequired = $false

if ($Operation -eq 'plan') {
    if ($desiredState -eq 'absent') {
        if ($current.installed -or $current.features_enabled) {
            $operations.Add([ordered]@{
                id = 'wsl.system.uninstall'
                action = 'uninstall'
                resource = @{ type = 'windows.wsl'; id = 'wsl' }
                before = $current
                after = @{ features_enabled = $false; installed = $false; restart_pending = $false; update_required = $false; version = $null; distros = @() }
                data = @{ destructive = $true }
            })
            $restartRequired = $true
        }
    } elseif (-not $current.features_enabled) {
        $operations.Add([ordered]@{
            id = 'wsl.system.enable-features'
            action = 'enable_features'
            resource = @{ type = 'windows.wsl'; id = 'wsl' }
            before = $current
            after = @{ features_enabled = $true; installed = $false; restart_pending = $true; update_required = $false; version = $null; distros = @() }
            data = @{ features = @('VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux') }
        })
        $restartRequired = $true
        if ($desiredDistros.Count -gt 0 -or $manageVersion) {
            $diagnostics.Add(@{ severity = 'info'; code = 'wsl.restart_before_configuration'; path = $request.path; message = 'WSL must finish installation and restart before Winix can upgrade it or install distributions. Re-run plan and apply after restarting.' })
        }
    } elseif ($current.restart_pending) {
        $restartRequired = $true
        $diagnostic = @{ severity = 'warning'; code = 'wsl.restart_pending'; path = $request.path; message = 'WSL Windows features were enabled during the current boot. Restart Windows before upgrading WSL or installing distributions.' }
        $diagnostics.Add($diagnostic)
        Write-WinixEvent -Kind 'diagnostic' -ResourceType 'windows.wsl' -ResourceId 'wsl' -Diagnostic $diagnostic
    } elseif (-not $current.installed) {
        $operations.Add([ordered]@{
            id = 'wsl.system.install'
            action = 'install'
            resource = @{ type = 'windows.wsl'; id = 'wsl' }
            before = $current
            after = @{ features_enabled = $true; installed = $true; restart_pending = $false; update_required = $false; version = $null; distros = @() }
            data = @{}
        })
    } else {
        if ($current.update_required -and -not $manageVersion) {
            $diagnostics.Add(@{ severity = 'error'; code = 'wsl.update_required'; path = $request.path; message = 'WSL must be updated before its state or distributions can be reconciled.'; help = "Set version to 'latest' or run wsl.exe --update, then reconcile again." })
            Write-PlanFailure -Diagnostics $diagnostics
            exit
        }
        $resolvedDistros = @()
        if (-not $current.update_required) {
            try { $resolvedDistros = @(Resolve-Distros -Names $desiredDistros -Diagnostics $diagnostics -Path $request.path) }
            catch { $diagnostics.Add(@{ severity = 'error'; code = 'wsl.catalog.failed'; path = "$($request.path).distros"; message = "WSL online distribution lookup failed: $($_.Exception.Message)" }) }
        }
        $release = $null
        if ($manageVersion) {
            try { $release = Get-LatestWslRelease -Preview $preview }
            catch { $diagnostics.Add(@{ severity = 'error'; code = 'wsl.release.failed'; path = "$($request.path).version"; message = "WSL release lookup failed: $($_.Exception.Message)" }) }
        }
        if (@($diagnostics | Where-Object severity -eq 'error').Count -gt 0) { Write-PlanFailure -Diagnostics $diagnostics; exit }

        $needsUpdate = $false
        if ($null -ne $release) {
            $installedVersion = if ($null -eq $current.version) { $null } else { ConvertTo-WslVersion -Text "$($current.version)" }
            $targetVersion = [version]$release.Version
            # `latest` is a minimum, not a downgrade request. This also avoids
            # trying to move a newer prerelease back to the stable release.
            $needsUpdate = $current.update_required -or $null -eq $installedVersion -or $installedVersion -lt $targetVersion
        }
        if ($needsUpdate) {
            $operations.Add([ordered]@{
                id = "wsl.system.update.$($release.Version)"
                action = 'update'
                resource = @{ type = 'windows.wsl'; id = 'wsl' }
                before = $current
                after = @{ features_enabled = $true; installed = $true; restart_pending = $false; update_required = $false; version = $release.Version; distros = @($current.distros) }
                data = @{ preview = $preview; release_tag = $release.Tag; version = $release.Version }
            })
            if ($current.update_required -and $desiredDistros.Count -gt 0) {
                $diagnostics.Add(@{ severity = 'info'; code = 'wsl.update_before_distros'; path = "$($request.path).distros"; message = 'WSL must be updated before its distribution catalog can be read. Reconcile again after applying the update.' })
            }
        }
        foreach ($distro in $resolvedDistros) {
            if (@($current.distros | Where-Object { $_ -ceq $distro }).Count -gt 0) { continue }
            $operations.Add([ordered]@{
                id = "wsl.system.install-distro.$distro"
                action = 'install_distro'
                resource = @{ type = 'windows.wsl.distro'; id = $distro }
                before = @{ installed = $false }
                after = @{ installed = $true }
                data = @{ name = $distro }
            })
        }
    }

    foreach ($operationItem in $operations) {
        Write-WinixEvent -Kind 'resource_status' -ResourceType $operationItem.resource.type -ResourceId $operationItem.resource.id -Data @{ status = 'change_required'; operation = $operationItem }
    }
    Write-WinixResponse @{ protocol_version = 2; success = $true; changed = $false; state = $state; operations = $operations; diagnostics = $diagnostics; error = $null; restart_required = @{ explorer = $false; system = $restartRequired } }
    exit
}

if (-not (Test-WinixAdministrator)) { throw 'WSL configuration requires an elevated token.' }
$result = Invoke-WslSystemApply -Request $request -GetState { Get-WslState } -ResolveDistros {
    param([string[]] $Names)
    $catalogDiagnostics = [System.Collections.Generic.List[object]]::new()
    $canonical = @(Resolve-Distros -Names $Names -Diagnostics $catalogDiagnostics -Path $request.path)
    if ($catalogDiagnostics.Count -gt 0 -or $canonical.Count -ne $Names.Count) {
        throw 'One or more planned WSL distributions are no longer in the online catalog.'
    }
    return $canonical
} -Mutate {
    param([object] $operationItem, [object] $observedBefore)
    switch ($operationItem.action) {
        'enable_features' {
            Enable-WslFeatures
            Write-WslInstallRestartReceipt
        }
        'install' {
            [void](Invoke-Wsl -Arguments @('--install', '--no-distribution'))
        }
        'update' {
            $arguments = @('--update', '--web-download')
            if ([bool]$operationItem.data.preview) { $arguments += '--pre-release' }
            [void](Invoke-Wsl -Arguments $arguments)
        }
        'install_distro' {
            [void](Invoke-Wsl -Arguments @('--install', '--distribution', "$($operationItem.data.name)", '--no-launch'))
        }
        'uninstall' {
            foreach ($distro in @($observedBefore.distros)) { [void](Invoke-Wsl -Arguments @('--unregister', "$distro")) }
            if ($observedBefore.installed) { [void](Invoke-Wsl -Arguments @('--uninstall') -AllowFailure) }
            Invoke-DismFeature -FeatureName 'Microsoft-Windows-Subsystem-Linux' -Action Disable
            Invoke-DismFeature -FeatureName 'VirtualMachinePlatform' -Action Disable
            Remove-Item -LiteralPath $RestartReceiptPath -Force -ErrorAction SilentlyContinue
        }
    }
}
if ($result.success) { $result.diagnostics = $diagnostics }
Write-WinixResponse $result
