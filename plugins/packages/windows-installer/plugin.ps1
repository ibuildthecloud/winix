param([Parameter(Mandatory)] [ValidateSet('validate', 'plan', 'apply')] [string] $Operation)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.PluginSdk.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Winix.WindowsInstaller.psm1') -Force

$request = Read-WinixRequest
if ($request.context.scope -cne 'system') {
    throw 'Windows Installer packages require system placement.'
}

switch ($Operation) {
    'validate' {
        $response = Invoke-WindowsInstallerValidate -Request $request
    }
    'plan' {
        $response = Invoke-WindowsInstallerPlan -Request $request
    }
    'apply' {
        if (-not (Test-WinixAdministrator)) {
            throw 'Windows Installer package removal requires an elevated token.'
        }
        if (-not (Test-WinixPropertyPresent -Object $request -Name 'operations')) {
            throw 'Apply request is missing its planned operations.'
        }
        $response = Invoke-WindowsInstallerApply -Request $request
    }
}

Write-WinixResponse -Response $response
