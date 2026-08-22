#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
  Integrity and emergency recovery helpers for the fan watchdog host.
#>

function Test-FanControlIntegrity {
    <#
    .SYNOPSIS
      Verify SHA-256 manifest for host scripts, modules, and config.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $ManifestPath
    )
    throw 'Test-FanControlIntegrity: not implemented (skeleton).'
}

function Test-PrimaryFanHeartbeat {
    param(
        [Parameter(Mandatory)]
        [string] $StatusPath,

        [Parameter(Mandatory)]
        $Configuration,

        [int] $HeartbeatMaximumAgeSeconds = 15,

        [int] $MaximumFutureSkewSeconds = 5
    )
    throw 'Test-PrimaryFanHeartbeat: not implemented (skeleton).'
}

function Test-PrimaryFanTaskDefinition {
    param(
        [Parameter(Mandatory)]
        $Task,

        [Parameter(Mandatory)]
        [string] $ControllerPath,

        [Parameter(Mandatory)]
        [string] $ConfigPath,

        [Parameter(Mandatory)]
        [string] $LogPath,

        [Parameter(Mandatory)]
        [string] $StatusPath
    )
    throw 'Test-PrimaryFanTaskDefinition: not implemented (skeleton).'
}

function Invoke-FanEmergencyRecovery {
    <#
    .SYNOPSIS
      Force MAX via Wmi module, then repair/restart primary task if needed.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Reason,

        [string] $PrimaryTaskName = 'Acer Adaptive Fan Control'
    )
    throw 'Invoke-FanEmergencyRecovery: not implemented (skeleton).'
}

Export-ModuleMember -Function @(
    'Test-FanControlIntegrity',
    'Test-PrimaryFanHeartbeat',
    'Test-PrimaryFanTaskDefinition',
    'Invoke-FanEmergencyRecovery'
)
