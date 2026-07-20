param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.PluginSdk.psm1') -Force

$CatalogUri = 'https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest'
$RegistryPath = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'

function Get-ScopeInfo([bool] $System) {
    if ($System) {
        return [pscustomobject]@{
            Name = 'system'
            Registry = "Registry::HKEY_LOCAL_MACHINE\$RegistryPath"
            FontRoot = Join-Path $env:WINDIR 'Fonts'
            ReceiptRoot = Join-Path $env:ProgramData 'Winix\fonts\nerd-fonts'
        }
    }
    return [pscustomobject]@{
        Name = 'user'
        Registry = "Registry::HKEY_CURRENT_USER\$RegistryPath"
        FontRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
        ReceiptRoot = Join-Path $env:LOCALAPPDATA 'Winix\fonts\nerd-fonts'
    }
}

function Get-LatestRelease {
    if ($null -ne $script:LatestRelease) { return $script:LatestRelease }
    $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'Winix-Nerd-Fonts-Plugin' }
    $script:LatestRelease = Invoke-RestMethod -Uri $CatalogUri -Headers $headers -Method Get
    return $script:LatestRelease
}

function Resolve-FontAsset([string] $Name) {
    $release = Get-LatestRelease
    $expected = "$Name.zip"
    $asset = @($release.assets | Where-Object { $_.name -ceq $expected }) | Select-Object -First 1
    if ($null -ne $asset) {
        return [pscustomobject]@{ CanonicalName = $Name; Tag = "$($release.tag_name)"; Asset = $asset }
    }
    $differentCase = @($release.assets | Where-Object { $_.name -ieq $expected }) | Select-Object -First 1
    if ($null -ne $differentCase) {
        return [pscustomobject]@{
            CanonicalName = [IO.Path]::GetFileNameWithoutExtension("$($differentCase.name)")
            Tag = "$($release.tag_name)"
            Asset = $null
        }
    }
    return $null
}

function Get-ReceiptPath([object] $ScopeInfo, [string] $Name) {
    return Join-Path $ScopeInfo.ReceiptRoot "$Name.json"
}

function Read-FontReceipt([object] $ScopeInfo, [string] $Name) {
    $path = Get-ReceiptPath -ScopeInfo $ScopeInfo -Name $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 20 } catch { return $null }
}

function Get-RegisteredFontFiles([object] $ScopeInfo) {
    $files = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path -LiteralPath $ScopeInfo.Registry)) { return ,$files }
    $item = Get-ItemProperty -LiteralPath $ScopeInfo.Registry
    foreach ($property in $item.PSObject.Properties) {
        if ($property.Name -like 'PS*' -or $property.Value -isnot [string]) { continue }
        $fileName = [IO.Path]::GetFileName("$($property.Value)")
        if ($fileName) { [void]$files.Add($fileName) }
    }
    return ,$files
}

function Get-ObservedState([object] $ScopeInfo, [string] $Name) {
    $receipt = Read-FontReceipt -ScopeInfo $ScopeInfo -Name $Name
    if ($null -eq $receipt) {
        return [ordered]@{ installed = $false; release = $null; files = @() }
    }
    $registered = Get-RegisteredFontFiles -ScopeInfo $ScopeInfo
    $files = @($receipt.files | ForEach-Object { "$_" } | Sort-Object -Unique)
    $complete = $files.Count -gt 0
    foreach ($file in $files) {
        if (-not $registered.Contains($file)) { $complete = $false; break }
    }
    return [ordered]@{
        installed = $complete
        release = "$($receipt.release)"
        files = $files
    }
}

function Get-Archive([string] $Uri, [string] $Name) {
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "winix-nerd-fonts-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    $archive = Join-Path $temporaryRoot "$Name.zip"
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $archive -Headers @{ 'User-Agent' = 'Winix-Nerd-Fonts-Plugin' }
        $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        $expanded = Join-Path $temporaryRoot 'expanded'
        Expand-Archive -LiteralPath $archive -DestinationPath $expanded
        $fontFiles = @(Get-ChildItem -LiteralPath $expanded -Recurse -File |
            Where-Object { $_.Extension -in @('.ttf', '.otf') } |
            Sort-Object FullName)
        if ($fontFiles.Count -eq 0) { throw "Archive '$Name.zip' contained no TrueType or OpenType font files." }
        $duplicates = @($fontFiles | Group-Object Name | Where-Object Count -gt 1)
        if ($duplicates.Count -gt 0) {
            throw "Archive '$Name.zip' contains duplicate font file names: $($duplicates.Name -join ', ')."
        }
        return [pscustomobject]@{
            Root = $temporaryRoot
            Archive = $archive
            Expanded = $expanded
            Sha256 = $hash
            FontFiles = $fontFiles
        }
    } catch {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Get-StateValue([object] $State, [string] $Name) {
    if ($State -is [Collections.IDictionary]) {
        if ($State.Contains($Name)) { return $State[$Name] }
        return $null
    }
    $property = $State.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-StateEqual([object] $Left, [object] $Right) {
    if ([bool](Get-StateValue -State $Left -Name 'installed') -ne [bool](Get-StateValue -State $Right -Name 'installed')) { return $false }
    $leftReleaseValue = Get-StateValue -State $Left -Name 'release'
    $rightReleaseValue = Get-StateValue -State $Right -Name 'release'
    $leftRelease = if ($null -eq $leftReleaseValue) { '' } else { "$leftReleaseValue" }
    $rightRelease = if ($null -eq $rightReleaseValue) { '' } else { "$rightReleaseValue" }
    if ($leftRelease -cne $rightRelease) { return $false }
    $leftFiles = @(Get-StateValue -State $Left -Name 'files' | ForEach-Object { "$_" } | Sort-Object -Unique)
    $rightFiles = @(Get-StateValue -State $Right -Name 'files' | ForEach-Object { "$_" } | Sort-Object -Unique)
    return (($leftFiles -join "`n") -ceq ($rightFiles -join "`n"))
}

function Install-FontFiles([object[]] $Files) {
    $shell = New-Object -ComObject Shell.Application
    $fontsFolder = $shell.Namespace(0x14)
    if ($null -eq $fontsFolder) { throw 'Windows Fonts shell namespace is unavailable.' }
    foreach ($file in $Files) { $fontsFolder.CopyHere($file.FullName, 0x14) }
}

function Initialize-FontNativeMethods {
    if ('WinixFontNativeMethods' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WinixFontNativeMethods
{
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool RemoveFontResourceEx(string name, uint flags, IntPtr reserved);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr window, uint message, IntPtr wParam, IntPtr lParam,
        uint flags, uint timeout, out IntPtr result);
}
'@
}

function Remove-FontFiles([object] $ScopeInfo, [string[]] $FileNames) {
    Initialize-FontNativeMethods
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($fileName in $FileNames) { [void]$names.Add($fileName) }

    foreach ($fileName in $FileNames) {
        $path = Join-Path $ScopeInfo.FontRoot $fileName
        if (Test-Path -LiteralPath $path) {
            for ($attempt = 0; $attempt -lt 20; $attempt++) {
                if (-not [WinixFontNativeMethods]::RemoveFontResourceEx($path, 0, [IntPtr]::Zero)) { break }
            }
        }
    }

    if (Test-Path -LiteralPath $ScopeInfo.Registry) {
        $item = Get-ItemProperty -LiteralPath $ScopeInfo.Registry
        foreach ($property in $item.PSObject.Properties) {
            if ($property.Name -like 'PS*' -or $property.Value -isnot [string]) { continue }
            if ($names.Contains([IO.Path]::GetFileName("$($property.Value)"))) {
                Remove-ItemProperty -LiteralPath $ScopeInfo.Registry -Name $property.Name -Force
            }
        }
    }

    foreach ($fileName in $FileNames) {
        $path = Join-Path $ScopeInfo.FontRoot $fileName
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }

    $broadcast = [IntPtr]0xffff
    $result = [IntPtr]::Zero
    [void][WinixFontNativeMethods]::SendMessageTimeout($broadcast, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero, 0x0002, 5000, [ref]$result)

    $registered = Get-RegisteredFontFiles -ScopeInfo $ScopeInfo
    $remainingRegistrations = @($FileNames | Where-Object { $registered.Contains($_) })
    $remainingFiles = @($FileNames | Where-Object { Test-Path -LiteralPath (Join-Path $ScopeInfo.FontRoot $_) })
    if ($remainingRegistrations.Count -gt 0 -or $remainingFiles.Count -gt 0) {
        $remaining = (@($remainingRegistrations + $remainingFiles) | Sort-Object -Unique) -join ', '
        throw "Windows did not completely remove these font files: $remaining."
    }
}

function Wait-FontRegistration([object] $ScopeInfo, [string[]] $FileNames) {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $registered = Get-RegisteredFontFiles -ScopeInfo $ScopeInfo
        $missing = @($FileNames | Where-Object { -not $registered.Contains($_) })
        if ($missing.Count -eq 0) { return }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Windows did not register these font files: $($missing -join ', ')."
}

function Write-FontReceipt([object] $ScopeInfo, [string] $Name, [object] $Receipt) {
    New-Item -ItemType Directory -Path $ScopeInfo.ReceiptRoot -Force | Out-Null
    $path = Get-ReceiptPath -ScopeInfo $ScopeInfo -Name $Name
    $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    $Receipt | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
    Move-Item -LiteralPath $temporary -Destination $path -Force
}

$script:LatestRelease = $null
$request = Read-WinixRequest
$isSystem = $request.context.scope -eq 'system'
$scopeInfo = Get-ScopeInfo -System $isSystem
$diagnostics = [Collections.Generic.List[object]]::new()

if ($Operation -eq 'validate') {
    $identities = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $releaseFailure = $null
    foreach ($entry in $request.configuration.PSObject.Properties) {
        if (-not $identities.Add($entry.Name)) {
            $diagnostics.Add(@{ severity = 'error'; code = 'nerd_font.name.duplicate'; path = $entry.Name; message = 'Nerd Font family names must also be unique when compared case-insensitively.' })
            continue
        }
        $desired = if (Test-WinixPropertyPresent $entry.Value 'state') { "$($entry.Value.state)" } else { 'installed' }
        if ($desired -eq 'absent' -and $null -ne (Read-FontReceipt -ScopeInfo $scopeInfo -Name $entry.Name)) { continue }
        if ($null -eq $script:LatestRelease -and $null -eq $releaseFailure) {
            try { [void](Get-LatestRelease) } catch { $releaseFailure = $_.Exception.Message }
        }
        if ($releaseFailure) {
            $diagnostics.Add(@{ severity = 'error'; code = 'nerd_font.catalog.failed'; path = "$($request.path).$($entry.Name)"; message = "Nerd Fonts release catalog lookup failed: $releaseFailure" })
            continue
        }
        $resolved = Resolve-FontAsset -Name $entry.Name
        if ($null -eq $resolved) {
            $diagnostics.Add(@{ severity = 'error'; code = 'nerd_font.name.unknown'; path = "$($request.path).$($entry.Name)"; message = "The latest Nerd Fonts release has no '$($entry.Name).zip' family archive."; help = 'Use the exact ZIP asset name from the latest ryanoasis/nerd-fonts release, without .zip.' })
        } elseif ($null -eq $resolved.Asset) {
            $diagnostics.Add(@{ severity = 'error'; code = 'nerd_font.name.non_canonical'; path = "$($request.path).$($entry.Name)"; message = "Nerd Font family '$($entry.Name)' is not canonical; use '$($resolved.CanonicalName)'."; help = "Use $($resolved.CanonicalName)." })
        }
    }
    Write-WinixResponse @{ protocol_version = 2; valid = ($diagnostics.Count -eq 0); diagnostics = $diagnostics }
    exit
}

if ($Operation -eq 'apply') {
    $isAdministrator = Test-WinixAdministrator
    if ($isSystem -and -not $isAdministrator) { throw 'System Nerd Font configuration requires an elevated token.' }
    if (-not $isSystem -and $isAdministrator) { throw 'User Nerd Font configuration cannot run with an elevated token.' }
    if (-not (Test-WinixPropertyPresent $request 'operations')) { throw 'Apply request is missing its planned operations.' }
    $planned = @($request.operations)

    foreach ($operationItem in $planned) {
        $fontName = "$($operationItem.resource.id)"
        if ($operationItem.resource.type -ne 'font.nerd-font' -or $operationItem.action -notin @('install', 'uninstall')) { throw "Unsupported planned operation '$($operationItem.id)'." }
        if ($operationItem.data.scope -ne $scopeInfo.Name) { throw "Planned scope for '$($operationItem.id)' does not match the execution scope." }
        if (-not (Test-WinixPropertyPresent $request.configuration $fontName)) { throw "Planned font '$fontName' is not present in configuration." }
        $configured = $request.configuration.PSObject.Properties[$fontName].Value
        $desired = if (Test-WinixPropertyPresent $configured 'state') { "$($configured.state)" } else { 'installed' }
        if (($operationItem.action -eq 'install' -and $desired -ne 'installed') -or ($operationItem.action -eq 'uninstall' -and $desired -ne 'absent')) {
            throw "Planned action for '$($operationItem.id)' does not match configuration."
        }
        $current = Get-ObservedState -ScopeInfo $scopeInfo -Name $fontName
        if (-not (Test-StateEqual -Left $current -Right $operationItem.before)) {
            $expectedJson = $operationItem.before | ConvertTo-Json -Depth 20 -Compress
            $currentJson = $current | ConvertTo-Json -Depth 20 -Compress
            throw "Plan is stale for '$($operationItem.id)': managed font state changed after planning. Expected $expectedJson; observed $currentJson."
        }
    }

    $applied = [Collections.Generic.List[string]]::new()
    foreach ($operationItem in $planned) {
        $fontName = "$($operationItem.resource.id)"
        $mutationAttempted = $false
        Write-WinixEvent -Kind 'resource_change_started' -ResourceType 'font.nerd-font' -ResourceId $fontName -Data @{ operation_id = $operationItem.id; action = $operationItem.action; before = $operationItem.before; after = $operationItem.after }
        $archive = $null
        try {
            if ($operationItem.action -eq 'uninstall') {
                $mutationAttempted = $true
                $plannedNames = @($operationItem.data.files | ForEach-Object { "$_" } | Sort-Object -Unique)
                Remove-FontFiles -ScopeInfo $scopeInfo -FileNames $plannedNames
                $receiptPath = Get-ReceiptPath -ScopeInfo $scopeInfo -Name $fontName
                if (Test-Path -LiteralPath $receiptPath) { Remove-Item -LiteralPath $receiptPath -Force }
            } else {
                $archive = Get-Archive -Uri "$($operationItem.data.url)" -Name $fontName
                if ($archive.Sha256 -cne "$($operationItem.data.sha256)") { throw "Archive checksum differs from the approved plan." }
                $actualNames = @($archive.FontFiles.Name | Sort-Object -Unique)
                $plannedNames = @($operationItem.data.files | ForEach-Object { "$_" } | Sort-Object -Unique)
                if (($actualNames -join "`n") -cne ($plannedNames -join "`n")) { throw 'Archive font contents differ from the approved plan.' }
                $mutationAttempted = $true
                Install-FontFiles -Files $archive.FontFiles
                Wait-FontRegistration -ScopeInfo $scopeInfo -FileNames $plannedNames
                Write-FontReceipt -ScopeInfo $scopeInfo -Name $fontName -Receipt ([ordered]@{
                    source = 'ryanoasis/nerd-fonts'
                    release = "$($operationItem.data.release)"
                    asset = "$($operationItem.data.asset)"
                    sha256 = "$($operationItem.data.sha256)"
                    files = $plannedNames
                })
            }
            $observed = Get-ObservedState -ScopeInfo $scopeInfo -Name $fontName
            if (-not (Test-StateEqual -Left $observed -Right $operationItem.after)) {
                throw "Installed font state does not match the approved postcondition."
            }
        } catch {
            $diagnostic = @{ severity = 'error'; code = 'nerd_font.install.failed'; path = "$($request.path).$fontName"; message = $_.Exception.Message; data = @{ operation_id = $operationItem.id; applied_operation_ids = @($applied) } }
            Write-WinixEvent -Kind 'diagnostic' -ResourceType 'font.nerd-font' -ResourceId $fontName -Diagnostic $diagnostic
            Write-WinixResponse @{ protocol_version = 2; success = $false; changed = ($applied.Count -gt 0 -or $mutationAttempted); operations = $planned; applied_operation_ids = $applied; diagnostics = @($diagnostic); error = @{ code = 'nerd_font.apply.failed'; message = "Planned Nerd Font operation '$($operationItem.id)' failed." }; restart_required = @{ explorer = $false; system = $false } }
            exit
        } finally {
            if ($null -ne $archive) { Remove-Item -LiteralPath $archive.Root -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $applied.Add($operationItem.id)
        $completedData = @{ operation_id = $operationItem.id; action = $operationItem.action; changed = $true }
        if ($operationItem.action -eq 'install') { $completedData.release = $operationItem.data.release }
        Write-WinixEvent -Kind 'resource_change_completed' -ResourceType 'font.nerd-font' -ResourceId $fontName -Data $completedData
    }
    Write-WinixResponse @{ protocol_version = 2; success = $true; changed = ($applied.Count -gt 0); operations = $planned; applied_operation_ids = $applied; diagnostics = @(); restart_required = @{ explorer = $false; system = $false } }
    exit
}

$state = [ordered]@{}
$operations = [Collections.Generic.List[object]]::new()
foreach ($entry in $request.configuration.PSObject.Properties) {
    $fontName = $entry.Name
    $desired = if (Test-WinixPropertyPresent $entry.Value 'state') { "$($entry.Value.state)" } else { 'installed' }
    $observed = Get-ObservedState -ScopeInfo $scopeInfo -Name $fontName
    $state[$fontName] = $observed
    if ($desired -eq 'absent') {
        if ($observed.files.Count -gt 0) {
            $operations.Add([ordered]@{
                id = "nerd_fonts.$($scopeInfo.Name).uninstall.$fontName"
                action = 'uninstall'
                resource = @{ type = 'font.nerd-font'; id = $fontName }
                before = $observed
                after = [ordered]@{ installed = $false; release = $null; files = @() }
                data = @{ scope = $scopeInfo.Name; files = @($observed.files); depends_on = @() }
            })
        }
        continue
    }
    if ($observed.installed) { continue }

    $archive = $null
    try {
        $resolved = Resolve-FontAsset -Name $fontName
        if ($null -eq $resolved -or $null -eq $resolved.Asset) { throw "The latest Nerd Fonts release has no canonical '$fontName.zip' family archive." }
        $archive = Get-Archive -Uri "$($resolved.Asset.browser_download_url)" -Name $fontName
        $fileNames = @($archive.FontFiles.Name | Sort-Object -Unique)
        $after = [ordered]@{ installed = $true; release = $resolved.Tag; files = $fileNames }
        $operations.Add([ordered]@{
            id = "nerd_fonts.$($scopeInfo.Name).install.$fontName"
            action = 'install'
            resource = @{ type = 'font.nerd-font'; id = $fontName }
            before = $observed
            after = $after
            data = @{
                scope = $scopeInfo.Name
                release = $resolved.Tag
                asset = "$($resolved.Asset.name)"
                url = "$($resolved.Asset.browser_download_url)"
                sha256 = $archive.Sha256
                files = $fileNames
                depends_on = @()
            }
        })
    } catch {
        $diagnostics.Add(@{ severity = 'error'; code = 'nerd_font.catalog.failed'; path = "$($request.path).$fontName"; message = "Could not resolve Nerd Font family '$fontName': $($_.Exception.Message)" })
    } finally {
        if ($null -ne $archive) { Remove-Item -LiteralPath $archive.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

$success = -not ($diagnostics | Where-Object severity -eq 'error')
foreach ($operationItem in $operations) {
    Write-WinixEvent -Kind 'resource_status' -ResourceType 'font.nerd-font' -ResourceId $operationItem.resource.id -Data @{ status = 'change_required'; operation = $operationItem }
}
Write-WinixResponse @{
    protocol_version = 2
    success = $success
    changed = $false
    state = $state
    operations = $operations
    diagnostics = $diagnostics
    error = $(if ($success) { $null } else { @{ code = 'nerd_font.plan.failed'; message = 'Nerd Fonts provider could not produce a complete deterministic plan.' } })
    restart_required = @{ explorer = $false; system = $false }
}
