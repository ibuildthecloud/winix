Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-WinixRequest {
    $inputText = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($inputText)) {
        throw 'The plugin request on stdin was empty.'
    }
    $request = $inputText | ConvertFrom-Json -Depth 100
    if ($request.protocol_version -ne 2) {
        throw "Unsupported protocol version: $($request.protocol_version)"
    }
    return $request
}

function Write-WinixResponse {
    param([Parameter(Mandatory)] [object] $Response)
    $record = [ordered]@{ type = 'result'; result = $Response }
    [Console]::Out.WriteLine(($record | ConvertTo-Json -Depth 100 -Compress))
}

function Write-WinixEvent {
    param(
        [Parameter(Mandatory)] [string] $Kind,
        [string] $ResourceType,
        [string] $ResourceId,
        [object] $Data,
        [object] $Diagnostic
    )
    $record = [ordered]@{ type = 'event'; kind = $Kind }
    if ($ResourceType -or $ResourceId) {
        $record.resource = [ordered]@{ type = $ResourceType; id = $ResourceId }
    }
    if ($null -ne $Data) { $record.data = $Data }
    if ($null -ne $Diagnostic) { $record.diagnostic = $Diagnostic }
    [Console]::Out.WriteLine(($record | ConvertTo-Json -Depth 100 -Compress))
}

function Get-WinixProperty {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Name
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
    $property = $item.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Set-WinixProperty {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [object] $Value,
        [ValidateSet('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord')]
        [string] $Type = 'DWord'
    )
    $current = Get-WinixProperty -Path $Path -Name $Name
    if ($null -ne $current -and "$current" -eq "$Value") { return $false }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    return $true
}

function Test-WinixPropertyPresent {
    param([Parameter(Mandatory)] [object] $Object, [Parameter(Mandatory)] [string] $Name)
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Test-WinixJsonEqual {
    param([AllowNull()] [object] $Left, [AllowNull()] [object] $Right)
    $leftJson = ConvertTo-Json -InputObject $Left -Depth 100 -Compress
    $rightJson = ConvertTo-Json -InputObject $Right -Depth 100 -Compress
    $leftNode = [System.Text.Json.Nodes.JsonNode]::Parse($leftJson)
    $rightNode = [System.Text.Json.Nodes.JsonNode]::Parse($rightJson)
    return [System.Text.Json.Nodes.JsonNode]::DeepEquals($leftNode, $rightNode)
}

function Test-WinixAdministrator {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Export-ModuleMember -Function Read-WinixRequest, Write-WinixResponse, Write-WinixEvent, Get-WinixProperty, Set-WinixProperty, Test-WinixPropertyPresent, Test-WinixJsonEqual, Test-WinixAdministrator
