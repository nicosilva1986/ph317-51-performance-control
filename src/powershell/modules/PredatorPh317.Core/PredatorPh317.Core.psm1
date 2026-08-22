#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
  Shared helpers for PH317-51 performance control (no WMI fan policy).
.NOTES
  Skeleton — implement by extracting from AcerAdaptiveFanController.ps1
  and AcerFanWatchdog.ps1 without changing external behavior.
#>

function Assert-SupportedHardware {
    <#
    .SYNOPSIS
      Throws unless Win32_ComputerSystem is Acer PH317-51.
    #>
    throw 'Assert-SupportedHardware: not implemented (skeleton). Extract from existing hosts.'
}

function Get-FanControlRoot {
    <#
    .SYNOPSIS
      Default protected root under ProgramData.
    #>
    param(
        [string] $Root = 'C:\ProgramData\AcerAdaptiveFanControl'
    )
    return $Root
}

function Get-FileSha256Hex {
    param(
        [Parameter(Mandatory)]
        [string] $LiteralPath
    )
    throw 'Get-FileSha256Hex: not implemented (skeleton).'
}

function Write-JsonlEvent {
    <#
    .SYNOPSIS
      Append one compressed JSON line; rotate by size when needed.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $LiteralPath,

        [Parameter(Mandatory)]
        [string] $Event,

        [string] $Detail = '',

        [int] $MaxBytes = 2097152,

        [hashtable] $Extra = $null
    )
    throw 'Write-JsonlEvent: not implemented (skeleton).'
}

function ConvertTo-IsoTimestamp {
    return (Get-Date).ToString('o')
}

Export-ModuleMember -Function @(
    'Assert-SupportedHardware',
    'Get-FanControlRoot',
    'Get-FileSha256Hex',
    'Write-JsonlEvent',
    'ConvertTo-IsoTimestamp'
)
