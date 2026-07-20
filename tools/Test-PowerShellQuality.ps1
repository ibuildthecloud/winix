[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$pluginsRoot = Join-Path $repositoryRoot 'plugins'
$analyzerSettingsPath = Join-Path $repositoryRoot 'PSScriptAnalyzerSettings.psd1'
$qualityFailures = [Collections.Generic.List[string]]::new()
$powerShellSourceRoots = @(
    $pluginsRoot
    (Join-Path $repositoryRoot 'tools')
    (Join-Path $repositoryRoot 'tests\powershell')
)

function Add-QualityFailure {
    param([Parameter(Mandatory)] [string] $Message)

    $qualityFailures.Add($Message)
}

function Get-RelativeRepositoryPath {
    param([Parameter(Mandatory)] [string] $Path)

    return [IO.Path]::GetRelativePath($repositoryRoot, $Path).Replace('\', '/')
}

function Test-PathContainedBy {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Directory
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullDirectory = [IO.Path]::GetFullPath($Directory).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($fullDirectory, [StringComparison]::OrdinalIgnoreCase)
}

$powerShellFiles = @(
    foreach ($sourceRoot in $powerShellSourceRoots) {
        Get-ChildItem -LiteralPath $sourceRoot -Recurse -File | Where-Object Extension -In '.ps1', '.psm1'
    }
)
foreach ($powerShellFile in $powerShellFiles) {
    $tokens = $null
    $parserErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile(
        $powerShellFile.FullName,
        [ref]$tokens,
        [ref]$parserErrors
    )
    foreach ($parserError in $parserErrors) {
        $relativePath = Get-RelativeRepositoryPath -Path $powerShellFile.FullName
        Add-QualityFailure "$relativePath`:$($parserError.Extent.StartLineNumber): $($parserError.Message)"
    }
}

$manifestFiles = @(Get-ChildItem -LiteralPath $pluginsRoot -Recurse -File -Filter 'plugin.json')
$entrypointPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$manifestNames = @{}
$configurationPaths = @{}
$requiredManifestProperties = @('protocol_version', 'name', 'path', 'placements', 'entrypoint', 'schema', 'requires')

foreach ($manifestFile in $manifestFiles) {
    $relativeManifestPath = Get-RelativeRepositoryPath -Path $manifestFile.FullName
    try {
        $manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw | ConvertFrom-Json -Depth 100
    } catch {
        Add-QualityFailure "$relativeManifestPath`: invalid JSON: $($_.Exception.Message)"
        continue
    }

    $missingProperties = @($requiredManifestProperties | Where-Object { $null -eq $manifest.PSObject.Properties[$_] })
    foreach ($missingProperty in $missingProperties) {
        Add-QualityFailure "$relativeManifestPath`: missing required property '$missingProperty'."
    }
    if ($missingProperties.Count -gt 0) { continue }

    if ($manifest.protocol_version -ne 2) {
        Add-QualityFailure "$relativeManifestPath`: protocol_version must be 2."
    }
    if (@($manifest.placements).Count -eq 0) {
        Add-QualityFailure "$relativeManifestPath`: placements must not be empty."
    }
    foreach ($placement in @($manifest.placements)) {
        if ($placement -notin @('system', 'user')) {
            Add-QualityFailure "$relativeManifestPath`: unsupported placement '$placement'."
        }
    }

    $manifestName = [string]$manifest.name
    if ($manifestName -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        Add-QualityFailure "$relativeManifestPath`: name '$manifestName' must be non-empty kebab-case."
    }
    if ($manifestNames.ContainsKey($manifestName)) {
        Add-QualityFailure "$relativeManifestPath`: duplicate plugin name '$manifestName' (also in $($manifestNames[$manifestName]))."
    } else {
        $manifestNames[$manifestName] = $relativeManifestPath
    }

    $configurationPath = [string]$manifest.path
    if ($configurationPath -notmatch '^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*$') {
        Add-QualityFailure "$relativeManifestPath`: path '$configurationPath' must contain lower snake case segments."
    }
    if ($configurationPaths.ContainsKey($configurationPath)) {
        Add-QualityFailure "$relativeManifestPath`: duplicate configuration path '$configurationPath' (also in $($configurationPaths[$configurationPath]))."
    } else {
        $configurationPaths[$configurationPath] = $relativeManifestPath
    }

    $pluginDirectory = $manifestFile.DirectoryName
    foreach ($referenceProperty in @('entrypoint', 'schema')) {
        $reference = [string]$manifest.$referenceProperty
        if ([IO.Path]::IsPathRooted($reference)) {
            Add-QualityFailure "$relativeManifestPath`: $referenceProperty must be a relative path."
            continue
        }
        $referencedPath = [IO.Path]::GetFullPath((Join-Path $pluginDirectory $reference))
        if (-not (Test-PathContainedBy -Path $referencedPath -Directory $pluginDirectory)) {
            Add-QualityFailure "$relativeManifestPath`: $referenceProperty must remain inside its plugin directory."
            continue
        }
        if (-not (Test-Path -LiteralPath $referencedPath -PathType Leaf)) {
            Add-QualityFailure "$relativeManifestPath`: $referenceProperty '$reference' does not exist."
            continue
        }

        if ($referenceProperty -eq 'entrypoint') {
            $null = $entrypointPaths.Add($referencedPath)
        } else {
            try {
                $null = Get-Content -LiteralPath $referencedPath -Raw | ConvertFrom-Json -Depth 100
            } catch {
                $relativeSchemaPath = Get-RelativeRepositoryPath -Path $referencedPath
                Add-QualityFailure "$relativeSchemaPath`: invalid JSON: $($_.Exception.Message)"
            }
        }
    }
}

foreach ($pluginScript in @(Get-ChildItem -LiteralPath $pluginsRoot -Recurse -File -Filter 'plugin.ps1')) {
    if (-not $entrypointPaths.Contains($pluginScript.FullName)) {
        $relativePath = Get-RelativeRepositoryPath -Path $pluginScript.FullName
        Add-QualityFailure "$relativePath`: plugin entrypoint is not referenced by a plugin.json manifest."
    }
}

Import-Module PSScriptAnalyzer -MinimumVersion 1.25.0 -ErrorAction Stop
$analyzerFindings = @(
    foreach ($sourceRoot in $powerShellSourceRoots) {
        Invoke-ScriptAnalyzer -Path $sourceRoot -Recurse -Settings $analyzerSettingsPath
    }
)
foreach ($finding in $analyzerFindings) {
    $relativePath = Get-RelativeRepositoryPath -Path $finding.ScriptPath
    Add-QualityFailure "$relativePath`:$($finding.Line): [$($finding.RuleName)] $($finding.Message)"
}

foreach ($sourceFile in @(Get-ChildItem -LiteralPath $pluginsRoot -Recurse -File -Filter '*.cs')) {
    try {
        Add-Type -Path $sourceFile.FullName -ErrorAction Stop
    } catch {
        $relativePath = Get-RelativeRepositoryPath -Path $sourceFile.FullName
        Add-QualityFailure "$relativePath`: C# compilation failed: $($_.Exception.Message)"
    }
}

if ($qualityFailures.Count -gt 0) {
    $qualityFailures | Sort-Object | ForEach-Object { [Console]::Error.WriteLine($_) }
    throw "PowerShell quality checks failed with $($qualityFailures.Count) finding(s)."
}

Write-Output "PowerShell quality checks passed for $($manifestFiles.Count) plugins and $($powerShellFiles.Count) scripts/modules."
