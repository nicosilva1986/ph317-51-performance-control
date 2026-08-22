[CmdletBinding()]
param(
    [switch] $ConfirmTemporaryRecoveryEnablement,
    [switch] $UserDeclaredOriginalSystemRestoreDisabled,
    [switch] $UserDeclaredOriginalWinReDisabled
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Warning 'Ensure-WinREEnabled.ps1 is a compatibility wrapper; CRUW maintenance now requires WinRE and System Restore together.'
$replacement = Join-Path $PSScriptRoot 'Prepare-CRUWRecoveryFacilities.ps1'
if (-not (Test-Path -LiteralPath $replacement -PathType Leaf)) {
    throw "Required recovery-facilities preparer is missing: $replacement"
}
& $replacement `
    -ConfirmTemporaryRecoveryEnablement:$ConfirmTemporaryRecoveryEnablement `
    -UserDeclaredOriginalSystemRestoreDisabled:$UserDeclaredOriginalSystemRestoreDisabled `
    -UserDeclaredOriginalWinReDisabled:$UserDeclaredOriginalWinReDisabled
