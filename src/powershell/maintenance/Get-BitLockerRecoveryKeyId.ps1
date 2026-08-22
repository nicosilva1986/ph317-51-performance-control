[CmdletBinding()]
param(
    [string] $MountPoint = 'C:',
    [string] $OutputPath = 'C:\Acer-Driver-Audit\Recovery\bitlocker-protector-id.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    $process = Start-Process -FilePath $pwsh -Verb RunAs -WindowStyle Hidden -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $PSCommandPath + '"'),
        '-MountPoint', ('"' + $MountPoint + '"'),
        '-OutputPath', ('"' + $OutputPath + '"')
    ) -Wait -PassThru
    exit $process.ExitCode
}

$volume = Get-BitLockerVolume -MountPoint $MountPoint
$recoveryProtectors = @($volume.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword')
$ids = @($recoveryProtectors | ForEach-Object {
    $safeId = ([string]$_.KeyProtectorId).Trim('{}')
    [ordered]@{
        idSuffix = if ($safeId.Length -ge 8) { $safeId.Substring($safeId.Length - 8) } else { $safeId }
    }
})

$result = [ordered]@{
    checkedAt = (Get-Date).ToString('o')
    mountPoint = $MountPoint
    volumeStatus = [string]$volume.VolumeStatus
    protectionStatus = [string]$volume.ProtectionStatus
    recoveryPasswordProtectorCount = $recoveryProtectors.Count
    protectorIdSuffixes = @($ids)
    recoveryPasswordRecorded = $false
    status = if ($recoveryProtectors.Count -ge 1) { 'PASS' } else { 'FAILED' }
}

$directory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
[IO.File]::WriteAllText($OutputPath, ($result | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
if ($result.status -ne 'PASS') { exit 1 }
exit 0
