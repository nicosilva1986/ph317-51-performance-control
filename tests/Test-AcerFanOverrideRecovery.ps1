[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$resultPath = 'C:\Acer-Driver-Audit\FanControl\override-recovery-result.json'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    $pwsh = (Get-Command pwsh.exe).Source
    $process = Start-Process -FilePath $pwsh -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"')
    ) -Wait -PassThru
    exit $process.ExitCode
}

$gaming = Get-CimInstance -Namespace 'root\wmi' -ClassName AcerGamingFunction | Select-Object -First 1
if (-not $gaming) { throw 'AcerGamingFunction is unavailable.' }

function Read-Behavior([uint32] $InputValue) {
    $read = Invoke-CimMethod -InputObject $gaming -MethodName GetGamingFanBehavior -Arguments @{ gmInput = $InputValue }
    return [uint64]$read.gmOutput
}
function Read-Rpm([uint32] $InputValue) {
    $read = Invoke-CimMethod -InputObject $gaming -MethodName GetGamingSysInfo -Arguments @{ gmInput = $InputValue }
    return [int]([uint64]$read.gmOutput -shr 8)
}
function Apply-Max {
    Invoke-CimMethod -InputObject $gaming -MethodName SetGamingFanBehavior -Arguments @{ gmInput = [uint64]0x00820009 } | Out-Null
    Invoke-CimMethod -InputObject $gaming -MethodName SetGamingFanSpeed -Arguments @{ gmInput = [uint64]0x00006401 } | Out-Null
    Invoke-CimMethod -InputObject $gaming -MethodName SetGamingFanSpeed -Arguments @{ gmInput = [uint64]0x00006404 } | Out-Null
}

$before = [ordered]@{
    behavior0 = Read-Behavior 0
    behavior1 = Read-Behavior 1
    behavior4 = Read-Behavior 4
    behavior5 = Read-Behavior 5
    behavior9 = Read-Behavior 9
    cpuRpm = Read-Rpm 0x0201
    gpuRpm = Read-Rpm 0x0601
}
$autoWrite = Invoke-CimMethod -InputObject $gaming -MethodName SetGamingFanBehavior -Arguments @{ gmInput = [uint64]0x00410009 }
$started = Get-Date
Start-Sleep -Milliseconds 250
$autoReadback = [ordered]@{
    behavior0 = Read-Behavior 0
    behavior1 = Read-Behavior 1
    behavior4 = Read-Behavior 4
    behavior5 = Read-Behavior 5
    behavior9 = Read-Behavior 9
    cpuRpm = Read-Rpm 0x0201
    gpuRpm = Read-Rpm 0x0601
}

$recovered = $false
$samples = [System.Collections.Generic.List[object]]::new()
try {
    while (((Get-Date) - $started).TotalSeconds -lt 15) {
        $sample = [ordered]@{
            elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
            behavior0 = Read-Behavior 0
            behavior9 = Read-Behavior 9
            cpuRpm = Read-Rpm 0x0201
            gpuRpm = Read-Rpm 0x0601
        }
        $samples.Add($sample)
        if ($sample.behavior9 -eq 512 -and $sample.cpuRpm -ge 5000 -and $sample.gpuRpm -ge 5000) {
            $recovered = $true
            break
        }
        Start-Sleep -Milliseconds 250
    }
}
finally {
    if (-not $recovered) { Apply-Max }
}

$result = [ordered]@{
    testedAt = (Get-Date).ToString('o')
    before = $before
    autoWriteOutput = [uint32]$autoWrite.gmOutput
    autoReadback = $autoReadback
    recovered = $recovered
    recoveryMilliseconds = if ($recovered) { $samples[-1].elapsedMs } else { $null }
    finalSample = if ($samples.Count) { $samples[-1] } else { $null }
    status = if ($recovered -and $samples[-1].elapsedMs -le 10000) { 'PASS' } else { 'FAILED' }
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding utf8
$result | ConvertTo-Json -Depth 8
if ($result.status -ne 'PASS') { exit 1 }
