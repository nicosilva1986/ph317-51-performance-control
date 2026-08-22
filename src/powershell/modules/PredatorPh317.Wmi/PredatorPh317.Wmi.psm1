#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
  AcerGamingFunction helpers for PH317-51.
.NOTES
  Payloads and sensor IDs must match docs/wmi-surface.md.
  Skeleton only — do not call from production hosts until implemented
  and parity-tested against the monolith.
#>

# Documented production constants (reference machine).
$script:FanBitmapCpuGpu = [uint64]0x0009
$script:BehaviorMax     = [uint64]0x00820009
$script:BehaviorAuto    = [uint64]0x00410009
$script:SpeedCpu100     = [uint64]0x00006401
$script:SpeedGpu100     = [uint64]0x00006404
$script:SensorCpuTemp   = [uint64]0x0101
$script:SensorGpuTemp   = [uint64]0x0A01
$script:SensorSysTemp   = [uint64]0x0301
$script:SensorCpuRpm    = [uint64]0x0201
$script:SensorGpuRpm    = [uint64]0x0601

function Get-AcerGamingFunctionInstance {
    <#
    .SYNOPSIS
      First AcerGamingFunction CIM instance in root\wmi.
    #>
    throw 'Get-AcerGamingFunctionInstance: not implemented (skeleton).'
}

function Invoke-GamingFanBehavior {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Auto', 'Max')]
        [string] $Mode
    )
    throw "Invoke-GamingFanBehavior($Mode): not implemented (skeleton)."
}

function Invoke-GamingFanSpeedPercent {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Cpu', 'Gpu')]
        [string] $Fan,

        [Parameter(Mandatory)]
        [ValidateRange(0, 100)]
        [int] $Percent
    )
    throw "Invoke-GamingFanSpeedPercent($Fan,$Percent): not implemented (skeleton)."
}

function Set-GamingFansMax {
    <#
    .SYNOPSIS
      Behavior MAX + CPU/GPU 100%. Throws if any gmOutput status != 0.
    #>
    throw 'Set-GamingFansMax: not implemented (skeleton).'
}

function Set-GamingFansAuto {
    throw 'Set-GamingFansAuto: not implemented (skeleton).'
}

function Get-GamingFanBehaviorRaw {
    param(
        [uint64] $FanBitmap = 0x0009
    )
    throw 'Get-GamingFanBehaviorRaw: not implemented (skeleton).'
}

function Get-GamingFanMode {
    <#
    .SYNOPSIS
      Decoded CPU mode nibble: 1=Auto, 2=Max (and 3=Custom when used).
    #>
    throw 'Get-GamingFanMode: not implemented (skeleton).'
}

function Get-GamingSensorValue {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CpuTemp', 'GpuTemp', 'SystemTemp', 'CpuRpm', 'GpuRpm')]
        [string] $Sensor
    )
    throw "Get-GamingSensorValue($Sensor): not implemented (skeleton)."
}

function Convert-GamingSensorRaw {
    param(
        [Parameter(Mandatory)]
        [uint64] $RawValue
    )
    return [int]($RawValue -shr 8)
}

Export-ModuleMember -Function @(
    'Get-AcerGamingFunctionInstance',
    'Invoke-GamingFanBehavior',
    'Invoke-GamingFanSpeedPercent',
    'Set-GamingFansMax',
    'Set-GamingFansAuto',
    'Get-GamingFanBehaviorRaw',
    'Get-GamingFanMode',
    'Get-GamingSensorValue',
    'Convert-GamingSensorRaw'
)
