Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.WinGet.Client -ErrorAction Stop

function Find-WinixNativeCatalogPackage([string] $Id, [string] $Source) {
    $parameters = @{ Id = $Id; MatchOption = 'EqualsCaseInsensitive'; ErrorAction = 'Stop' }
    if ($Source) { $parameters.Source = $Source }
    $matchingPackages = @(Find-WinGetPackage @parameters)
    if ($matchingPackages.Count -ne 1) { return $null }
    return $matchingPackages[0]
}

function Resolve-WinixNativeVersionAction([object] $CatalogPackage, [string] $Current, [string] $Target) {
    $versions = @($CatalogPackage.AvailableVersions)
    $currentIndex = [Array]::IndexOf([string[]]$versions, $Current)
    $targetIndex = [Array]::IndexOf([string[]]$versions, $Target)
    if ($currentIndex -ge 0 -and $targetIndex -ge 0) {
        if ($targetIndex -lt $currentIndex) { return 'upgrade' }
        if ($targetIndex -gt $currentIndex) { return 'downgrade' }
    }
    $versionInfo = $CatalogPackage.GetPackageVersionInfo($Target)
    if ($null -ne $versionInfo) {
        $comparison = $versionInfo.CompareToVersion($Current)
        if ($comparison -eq 'Greater') { return 'upgrade' }
        if ($comparison -eq 'Lesser') { return 'downgrade' }
        if ($comparison -eq 'Equal') { return $null }
    }
    try {
        $comparison = ([version]$Target).CompareTo([version]$Current)
        if ($comparison -gt 0) { return 'upgrade' }
        if ($comparison -lt 0) { return 'downgrade' }
    } catch {
        try {
            $comparison = ([System.Management.Automation.SemanticVersion]$Target).CompareTo([System.Management.Automation.SemanticVersion]$Current)
            if ($comparison -gt 0) { return 'upgrade' }
            if ($comparison -lt 0) { return 'downgrade' }
        } catch { return $null }
    }
    return $null
}

Export-ModuleMember -Function Find-WinixNativeCatalogPackage, Resolve-WinixNativeVersionAction
