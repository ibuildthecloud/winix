Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-WinixPingetMetadataBackend {
    Import-Module Devolutions.Pinget.Client -RequiredVersion 0.10.0 -ErrorAction Stop
}

function Find-WinixPingetCatalogPackage([string] $Id, [string] $Source) {
    $parameters = @{ Id = $Id; MatchOption = 'EqualsCaseInsensitive'; ErrorAction = 'Stop' }
    if ($Source) { $parameters.Source = $Source }
    $matchingPackages = @(Find-PingetPackage @parameters)
    if ($matchingPackages.Count -ne 1) { return $null }
    $package = $matchingPackages[0]
    return [pscustomobject]@{
        Id = [string]$package.Id
        Version = [string]$package.Version
        AvailableVersions = @($package.AvailableVersions | ForEach-Object { "$_" })
        Handle = $package
    }
}

function Resolve-WinixPingetVersionAction([object] $CatalogPackage, [string] $Current, [string] $Target) {
    try { $versionInfo = $CatalogPackage.Handle.GetPackageVersionInfo($Target) }
    catch { return [pscustomobject]@{ Supported = $false; Action = $null } }
    if ($null -eq $versionInfo) { return [pscustomobject]@{ Supported = $false; Action = $null } }
    $comparison = $versionInfo.CompareToVersion($Current).ToString()
    $action = if ($comparison -eq 'Greater') { 'upgrade' } elseif ($comparison -eq 'Lesser') { 'downgrade' } else { $null }
    return [pscustomobject]@{ Supported = $true; Action = $action }
}

Export-ModuleMember -Function Initialize-WinixPingetMetadataBackend, Find-WinixPingetCatalogPackage, Resolve-WinixPingetVersionAction
