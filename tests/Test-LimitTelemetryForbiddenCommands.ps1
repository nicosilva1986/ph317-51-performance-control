#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AssertionCount = 0

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $script:AssertionCount++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Get-ParsedAst {
    param([Parameter(Mandatory = $true)][string]$Path)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw "PowerShell parse errors in $Path`: $(@($errors).Message -join '; ')" }
    return $ast
}

function Test-IsTelemetryWriteExpression {
    param([Parameter(Mandatory = $true)][System.Management.Automation.Language.CommandAst]$Command)

    $extent = $Command.Extent.Text
    if ($extent -match '(?i)StatusPath|adaptive-fan-status') { return $false }
    return $extent -match '(?i)\$(?:Directory|telemetryRoot|rotationRoot)(?![A-Za-z0-9_])'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$paths = @(
    (Join-Path $repositoryRoot 'src\powershell\telemetry\Invoke-LimitTelemetry.ps1'),
    (Join-Path $repositoryRoot 'tests\Test-InvokeLimitTelemetry.ps1'),
    $PSCommandPath
)
foreach ($path in $paths) {
    Assert-True -Condition (Test-Path -LiteralPath $path -PathType Leaf) -Message "AST gate input exists: $([System.IO.Path]::GetFileName($path))"
}

$forbiddenCommands = @(
    'Invoke-CimMethod', 'Set-CimInstance', 'Invoke-WmiMethod', 'Set-WmiInstance', 'Remove-WmiObject', 'wmic', 'wmic.exe',
    'Set-Service', 'Start-Service', 'Stop-Service', 'Restart-Service', 'Suspend-Service', 'New-Service', 'Remove-Service',
    'Register-ScheduledTask', 'Set-ScheduledTask', 'Start-ScheduledTask', 'Stop-ScheduledTask', 'Enable-ScheduledTask', 'Disable-ScheduledTask', 'Unregister-ScheduledTask',
    'powercfg', 'powercfg.exe', 'rdmsr', 'rdmsr.exe', 'wrmsr', 'wrmsr.exe',
    'reg', 'reg.exe', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty'
)
$writeCommands = @('Out-File', 'Set-Content', 'Add-Content')
$forbiddenMemberNames = @('InvokeMethod', 'InvokeMethodAsync')
$forbiddenTypePatterns = @('ManagementObject', 'ManagementClass', 'wmiclass', 'WinRing0', 'OpenLibSys', 'ThrottleStop', 'Microsoft.Win32.Registry')
$violations = New-Object System.Collections.Generic.List[string]

foreach ($path in $paths) {
    $ast = Get-ParsedAst -Path $path
    $commands = @($ast.FindAll({
                param($node)
                return $node -is [System.Management.Automation.Language.CommandAst]
            }, $true))
    foreach ($command in $commands) {
        $name = $command.GetCommandName()
        if ($null -ne $name -and $forbiddenCommands -contains $name) {
            $violations.Add("$path`:$($command.Extent.StartLineNumber): forbidden command $name")
        }
        if ($null -ne $name -and $writeCommands -contains $name -and -not (Test-IsTelemetryWriteExpression -Command $command)) {
            $violations.Add("$path`:$($command.Extent.StartLineNumber): write command is not statically scoped to the resolved telemetry directory")
        }
        if ($null -ne $name -and $writeCommands -contains $name -and $command.Extent.Text -match '(?i)StatusPath|adaptive-fan-status') {
            $violations.Add("$path`:$($command.Extent.StartLineNumber): write command targets the fan status path")
        }
        if ($null -ne $name -and $name -in @('New-Item', 'Set-Item', 'Remove-Item') -and $command.Extent.Text -match '(?i)(?:HKLM|HKCU|Registry)::?') {
            $violations.Add("$path`:$($command.Extent.StartLineNumber): registry write command is forbidden")
        }
    }

    $memberCalls = @($ast.FindAll({
                param($node)
                return $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]
            }, $true))
    foreach ($memberCall in $memberCalls) {
        $memberName = if ($memberCall.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) { [string]$memberCall.Member.Value } else { $null }
        if ($null -ne $memberName -and $forbiddenMemberNames -contains $memberName) {
            $violations.Add("$path`:$($memberCall.Extent.StartLineNumber): forbidden method invocation $memberName")
        }
    }

    $typeExpressions = @($ast.FindAll({
                param($node)
                return $node -is [System.Management.Automation.Language.TypeExpressionAst]
            }, $true))
    foreach ($typeExpression in $typeExpressions) {
        foreach ($pattern in $forbiddenTypePatterns) {
            if ($typeExpression.TypeName.FullName -match [regex]::Escape($pattern)) {
                $violations.Add("$path`:$($typeExpression.Extent.StartLineNumber): forbidden type $($typeExpression.TypeName.FullName)")
            }
        }
    }
}

$telemetrySource = [System.IO.File]::ReadAllText($paths[0])
$forbiddenSurfacePatterns = [ordered]@{
    oemFanControlSurface = ('Acer' + 'GamingFunction')
    kernelMsrDriver      = '(?i)WinRing0|OpenLibSys|\\\.\\(?:WinRing|RwDrv)'
    thermalToggle        = '(?i)BD\s+PROCHOT'
    thirdPartyTuner      = ('Throttle' + 'Stop')
}
foreach ($entry in $forbiddenSurfacePatterns.GetEnumerator()) {
    if ($telemetrySource -match $entry.Value) { $violations.Add("Telemetry source contains forbidden surface: $($entry.Key)") }
}

Assert-True -Condition ($violations.Count -eq 0) -Message $(if ($violations.Count) { $violations -join [Environment]::NewLine } else { 'No forbidden command, member invocation, type, or write target is present.' })
Write-Output "PASS Test-LimitTelemetryForbiddenCommands ($script:AssertionCount assertions)"
