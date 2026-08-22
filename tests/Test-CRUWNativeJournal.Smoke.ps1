[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$isAdministrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdministrator) {
    throw 'Run this non-mutating native journal smoke from an already elevated console'
}

$commonPath = Join-Path $PSScriptRoot '..\src\powershell\maintenance\CRUWStateMachine.Common.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
    throw "CRUW state-machine common source missing: $commonPath"
}
. $commonPath

$adapter = New-CRUWNativeAdapter
$operationId = [guid]::NewGuid()
$token = $operationId.ToString('N')
$primaryParent = 'C:\Acer-Driver-Audit\Native-Smoke'
$secondaryParent = 'D:\Acer-Recovery\Native-Smoke'
$primary = Join-Path $primaryParent $token
$secondary = Join-Path $secondaryParent $token

try {
    foreach ($path in @($primary, $secondary)) {
        New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
    }
    $entry = Write-CRUWDualJournal `
        -PrimaryRoot $primary `
        -SecondaryRoot $secondary `
        -OperationId $operationId `
        -Sequence 0 `
        -Stage NATIVE_SMOKE `
        -PreviousPayloadSha256 $null `
        -Context ([ordered]@{ purpose = 'non-mutating-native-smoke'; secretRecorded = $false }) `
        -Adapter $adapter

    $state = Get-CRUWJournalPrefixState $primary $secondary $operationId $adapter
    if (-not [bool]$state.verified -or
        [int]$state.commonPrefixLength -ne 1 -or
        [string]$state.entries[0].payload.stage -cne 'NATIVE_SMOKE' -or
        [string]$entry.primarySha256 -cne [string]$entry.secondarySha256) {
        throw 'Native dual durable journal did not verify as one exact committed entry'
    }
    Write-Host 'PASS: native C:/D: durable journal bytes, hashes and protected file ACLs verified.'
}
finally {
    foreach ($record in @(
        [ordered]@{ path = $primary; parent = $primaryParent },
        [ordered]@{ path = $secondary; parent = $secondaryParent }
    )) {
        $resolvedPath = [IO.Path]::GetFullPath([string]$record.path).TrimEnd('\')
        $resolvedParent = [IO.Path]::GetFullPath([string]$record.parent).TrimEnd('\')
        if ([IO.Path]::GetDirectoryName($resolvedPath).TrimEnd('\') -cne $resolvedParent) {
            throw "Refusing native-smoke cleanup outside exact parent: $resolvedPath"
        }
        if (Test-Path -LiteralPath $resolvedPath) {
            Remove-Item -LiteralPath $resolvedPath -Recurse -Force
        }
    }
}
