#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
  Fan policy helpers and status schema (AUTO/MAX). No CIM calls here once
  Wmi module is wired — prefer calling PredatorPh317.Wmi from the host loop.
#>

function Import-FanControllerConfig {
    param(
        [Parameter(Mandatory)]
        [string] $LiteralPath
    )
    throw 'Import-FanControllerConfig: not implemented (skeleton).'
}

function Assert-FanControllerConfig {
    <#
    .SYNOPSIS
      Validate required keys and safety ranges (mirrors install + runtime).
    #>
    param(
        [Parameter(Mandatory)]
        $Configuration
    )
    throw 'Assert-FanControllerConfig: not implemented (skeleton).'
}

function New-FanControllerStatus {
    <#
    .SYNOPSIS
      Build the heartbeat object written to adaptive-fan-status.json.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('AUTO', 'MAX')]
        [string] $State,

        [Parameter(Mandatory)]
        [ValidateSet('HEALTHY_VERIFIED', 'DEGRADED', 'FAILED')]
        [string] $Status,

        [uint32] $FanBehaviorBitmap = 0,

        [int] $CpuFanRpm = 0,

        [int] $GpuFanRpm = 0,

        [hashtable] $Extra = $null
    )
    throw 'New-FanControllerStatus: not implemented (skeleton).'
}

function Test-MaxFanHealth {
    param(
        [Parameter(Mandatory)]
        [int] $Mode,

        [Parameter(Mandatory)]
        [int] $CpuFanRpm,

        [Parameter(Mandatory)]
        [int] $GpuFanRpm,

        [Parameter(Mandatory)]
        [int] $MinimumMaxRpm
    )
    throw 'Test-MaxFanHealth: not implemented (skeleton).'
}

function Get-FanPolicyDecision {
    <#
    .SYNOPSIS
      Pure policy: inputs in, desired AUTO|MAX out (no side effects).
    .NOTES
      Extract hysteresis / rise / load rules from the monolith for unit tests.
    #>
    param(
        [Parameter(Mandatory)]
        $Configuration,

        [Parameter(Mandatory)]
        $Sample,

        [Parameter(Mandatory)]
        [ValidateSet('AUTO', 'MAX')]
        [string] $CurrentState
    )
    throw 'Get-FanPolicyDecision: not implemented (skeleton).'
}

Export-ModuleMember -Function @(
    'Import-FanControllerConfig',
    'Assert-FanControllerConfig',
    'New-FanControllerStatus',
    'Test-MaxFanHealth',
    'Get-FanPolicyDecision'
)
