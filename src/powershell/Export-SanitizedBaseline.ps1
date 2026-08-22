#requires -Version 5.1

<#+
.SYNOPSIS
Exports a privacy-preserving, read-only system baseline as JSON.

.DESCRIPTION
Queries only explicitly selected, non-secret fields. The script never queries
BitLocker material, serial numbers, device instance IDs, or user/account data.
Before writing, it recursively redacts identifiers and refuses content that
looks like credentials, recovery passwords, API tokens, or private keys.

For repeatable tests and support triage, -OfflineSnapshotPath bypasses all live
queries and sanitizes the supplied JSON document instead.

.PARAMETER OutputPath
The exact JSON file to write. Its parent directory must already exist. No other
file or directory is created.

.PARAMETER OfflineSnapshotPath
Optional JSON input used instead of live system collection.

.PARAMETER BenchmarkSummaryPath
Optional JSON benchmark summaries to embed. Only the file name (not its source
path) is retained. Each input is size-limited and receives the same safety scan.

.PARAMETER Force
Allow replacement of the exact OutputPath. Without this switch, an existing
file is left untouched and the export fails.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OfflineSnapshotPath,

    [Parameter()]
    [ValidateCount(0, 32)]
    [string[]]$BenchmarkSummaryPath = @(),

    [Parameter()]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CollectorVersion = '0.1.0'
$script:SafetyPolicyVersion = 1
$script:CollectionErrors = New-Object System.Collections.Generic.List[object]

function Add-CollectionError {
    param(
        [Parameter(Mandatory = $true)][string]$Component,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $script:CollectionErrors.Add([pscustomobject][ordered]@{
            component = $Component
            message   = $Message
        })
}

function Get-ExactFileSystemPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$MustExist
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'A non-empty filesystem path is required.'
    }

    if ($Path.IndexOfAny([char[]]'*?[]') -ge 0) {
        throw 'Wildcard paths are not allowed.'
    }

    if ($MustExist) {
        $resolvedItem = Resolve-Path -LiteralPath $Path -ErrorAction Stop
        if ($resolvedItem.Provider.Name -ne 'FileSystem') {
            throw 'Only filesystem paths are allowed.'
        }
        return $resolvedItem.ProviderPath
    }

    $provider = $null
    $drive = $null
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $Path,
        [ref]$provider,
        [ref]$drive
    )
    if ($null -eq $provider -or $provider.Name -ne 'FileSystem') {
        throw 'Only filesystem paths are allowed.'
    }
    return $resolved
}

function Read-JsonDocument {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][long]$MaximumBytes,
        [Parameter(Mandatory = $true)][string]$Purpose
    )

    $resolved = Get-ExactFileSystemPath -Path $Path -MustExist
    $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
        throw "$Purpose must be a JSON file, not a directory."
    }
    if ($item.Length -gt $MaximumBytes) {
        throw "$Purpose exceeds the $MaximumBytes byte safety limit."
    }

    try {
        $text = [System.IO.File]::ReadAllText($resolved)
        $document = $text | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "$Purpose is not valid JSON."
    }

    return [pscustomobject][ordered]@{
        path     = $resolved
        document = $document
    }
}

function Test-IsSimpleValue {
    param([object]$Value)

    if ($null -eq $Value) { return $true }
    return (
        $Value -is [string] -or
        $Value -is [char] -or
        $Value -is [bool] -or
        $Value -is [byte] -or
        $Value -is [sbyte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64] -or
        $Value -is [single] -or
        $Value -is [double] -or
        $Value -is [decimal] -or
        $Value -is [datetime] -or
        $Value -is [datetimeoffset] -or
        $Value -is [guid] -or
        $Value -is [timespan]
    )
}

function Get-StructuredProperties {
    param([object]$InputObject)

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            [pscustomobject]@{ Name = [string]$key; Value = $InputObject[$key] }
        }
        return
    }

    foreach ($property in $InputObject.PSObject.Properties) {
        if ($property.MemberType -in @('NoteProperty', 'Property', 'AliasProperty', 'ScriptProperty')) {
            [pscustomobject]@{ Name = [string]$property.Name; Value = $property.Value }
        }
    }
}

function Test-SecretFieldName {
    param([string]$Name)

    $normalized = ($Name -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
    return (
        $normalized -match 'password|passwd|secret|credential' -or
        $normalized -match '(?:private|api|access|license|encryption|recovery)key$' -or
        $normalized -match '(?:access|refresh|bearer|auth|csrf|session|id)?token$' -or
        $normalized -match 'bitlocker' -or
        $normalized -match 'recoverykey|recoverypassword|recoverycode'
    )
}

function Test-RedactedFieldName {
    param([string]$Name)

    $normalized = ($Name -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
    return (
        $normalized -eq 'user' -or
        $normalized -match '(?:username|accountname|computername|machinename|hostname|serial|serialnumber|pnpid|pnpdeviceid|deviceinstanceid|instanceid)$'
    )
}

function Assert-NoForbiddenMaterial {
    param(
        [object]$InputObject,
        [string]$Location = '$'
    )

    if ($null -eq $InputObject) { return }

    if (Test-IsSimpleValue -Value $InputObject) {
        if ($InputObject -isnot [string]) { return }
        $value = [string]$InputObject

        $forbiddenValuePatterns = @(
            '(?i)-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----',
            '(?i)\b\d{6}(?:-\d{6}){7}\b',
            '(?i)\b(?:sk|ghp|github_pat|xox[baprs]|ya29)[-_\.][A-Za-z0-9_\-\.]{16,}\b',
            '(?i)\bAKIA[A-Z0-9]{16}\b',
            '(?i)\bAIza[A-Za-z0-9_\-]{20,}\b',
            '(?i)\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b',
            '(?i)(?:password|passwd|client[_-]?secret|api[_-]?key|access[_-]?token)\s*[:=]\s*[^\s,;]+'
        )
        foreach ($pattern in $forbiddenValuePatterns) {
            if ($value -match $pattern) {
                throw "Refusing export: credential or recovery material was detected at $Location."
            }
        }
        return
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [System.Collections.IDictionary]) {
        $index = 0
        foreach ($item in $InputObject) {
            Assert-NoForbiddenMaterial -InputObject $item -Location "$Location[$index]"
            $index++
        }
        return
    }

    foreach ($property in @(Get-StructuredProperties -InputObject $InputObject)) {
        if (Test-SecretFieldName -Name $property.Name) {
            throw "Refusing export: a secret-bearing field was detected at $Location."
        }
        Assert-NoForbiddenMaterial -InputObject $property.Value -Location "$Location.$($property.Name)"
    }
}

function Get-RedactionIdentifiers {
    param([object]$InputObject)

    $identifiers = New-Object System.Collections.Generic.List[string]

    function Visit-IdentifierNode {
        param([object]$Node)

        if ($null -eq $Node -or (Test-IsSimpleValue -Value $Node)) { return }
        if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [System.Collections.IDictionary]) {
            foreach ($item in $Node) { Visit-IdentifierNode -Node $item }
            return
        }

        foreach ($property in @(Get-StructuredProperties -InputObject $Node)) {
            if (Test-RedactedFieldName -Name $property.Name) {
                foreach ($candidate in @($property.Value)) {
                    if ($null -ne $candidate) {
                        $text = [string]$candidate
                        if ($text.Length -ge 4 -and $text -ne '[REDACTED]') {
                            $identifiers.Add($text)
                        }
                    }
                }
            }
            Visit-IdentifierNode -Node $property.Value
        }
    }

    Visit-IdentifierNode -Node $InputObject
    if (-not [string]::IsNullOrWhiteSpace($env:USERNAME) -and $env:USERNAME.Length -ge 4) {
        $identifiers.Add($env:USERNAME)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME) -and $env:COMPUTERNAME.Length -ge 4) {
        $identifiers.Add($env:COMPUTERNAME)
    }

    return @($identifiers | Sort-Object Length -Descending -Unique)
}

function ConvertTo-SanitizedString {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [string[]]$Identifiers
    )

    $sanitized = $Value
    $profilePattern = '(?i)(?<![A-Za-z0-9])[A-Z]:[\\/]Users[\\/][^\\/:*?"<>|\r\n]+'
    $sanitized = [regex]::Replace($sanitized, $profilePattern, '%USERPROFILE%')
    $sanitized = [regex]::Replace($sanitized, '(?i)(?<![A-Za-z0-9])/home/[^/\r\n]+', '%USERPROFILE%')

    $pnpPattern = '(?i)\b(?:PCI|USB|ACPI|HID|SCSI|STORAGE|ROOT|SWD|BTHENUM|DISPLAY)[\\/][A-Za-z0-9_&.{}+#-]+(?:[\\/][^\s,;"'']+)?'
    $sanitized = [regex]::Replace($sanitized, $pnpPattern, '[REDACTED-PNP-ID]')

    foreach ($identifier in @($Identifiers)) {
        if ([string]::IsNullOrWhiteSpace($identifier) -or $identifier.Length -lt 4) { continue }
        $sanitized = [regex]::Replace(
            $sanitized,
            [regex]::Escape($identifier),
            '[REDACTED]',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }
    return $sanitized
}

function ConvertTo-SanitizedValue {
    param(
        [object]$InputObject,
        [string[]]$Identifiers
    )

    if ($null -eq $InputObject) { return $null }

    if (Test-IsSimpleValue -Value $InputObject) {
        if ($InputObject -is [string]) {
            return ConvertTo-SanitizedString -Value ([string]$InputObject) -Identifiers $Identifiers
        }
        if ($InputObject -is [datetime]) {
            return $InputObject.ToUniversalTime().ToString('o')
        }
        if ($InputObject -is [datetimeoffset]) {
            return $InputObject.ToUniversalTime().ToString('o')
        }
        if ($InputObject -is [guid] -or $InputObject -is [timespan] -or $InputObject -is [char]) {
            return [string]$InputObject
        }
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [System.Collections.IDictionary]) {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($item in $InputObject) {
            $items.Add((ConvertTo-SanitizedValue -InputObject $item -Identifiers $Identifiers))
        }
        return ,$items.ToArray()
    }

    $result = [ordered]@{}
    foreach ($property in @(Get-StructuredProperties -InputObject $InputObject)) {
        if (Test-SecretFieldName -Name $property.Name) {
            throw 'Refusing export: a secret-bearing field reached the sanitizer.'
        }
        if (Test-RedactedFieldName -Name $property.Name) {
            $result[$property.Name] = '[REDACTED]'
        }
        else {
            $result[$property.Name] = ConvertTo-SanitizedValue -InputObject $property.Value -Identifiers $Identifiers
        }
    }
    return $result
}

function Convert-DateForExport {
    param([object]$Value)

    if ($null -eq $Value) { return $null }
    try {
        return ([datetime]$Value).ToUniversalTime().ToString('o')
    }
    catch {
        return $null
    }
}

function Get-OptionalPropertyValue {
    param(
        [object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-CimCollection {
    param(
        [Parameter(Mandatory = $true)][string]$ClassName,
        [string]$Namespace = 'root/cimv2',
        [string]$Component = $ClassName,
        [string[]]$Property = @()
    )

    try {
        $queryParameters = @{
            Namespace   = $Namespace
            ClassName   = $ClassName
            ErrorAction = 'Stop'
        }
        if ($Property.Count -gt 0) { $queryParameters['Property'] = $Property }
        return @(Get-CimInstance @queryParameters)
    }
    catch {
        Add-CollectionError -Component $Component -Message $_.Exception.Message
        return @()
    }
}

function Get-LiveBaseline {
    $computer = @(Get-CimCollection -ClassName 'Win32_ComputerSystem' -Component 'computerSystem' -Property @('Manufacturer', 'Model', 'TotalPhysicalMemory')) | Select-Object -First 1
    $bios = @(Get-CimCollection -ClassName 'Win32_BIOS' -Component 'bios' -Property @('Manufacturer', 'SMBIOSBIOSVersion', 'ReleaseDate')) | Select-Object -First 1
    $operatingSystem = @(Get-CimCollection -ClassName 'Win32_OperatingSystem' -Component 'operatingSystem' -Property @('Caption', 'Version', 'BuildNumber', 'OSArchitecture')) | Select-Object -First 1
    $processors = @(Get-CimCollection -ClassName 'Win32_Processor' -Component 'processor' -Property @('Name', 'Manufacturer', 'NumberOfCores', 'NumberOfLogicalProcessors', 'MaxClockSpeed'))
    $graphics = @(Get-CimCollection -ClassName 'Win32_VideoController' -Component 'graphics' -Property @('Name', 'VideoProcessor', 'DriverVersion', 'AdapterRAM'))
    $memoryModules = @(Get-CimCollection -ClassName 'Win32_PhysicalMemory' -Component 'memory' -Property @('Manufacturer', 'Capacity', 'ConfiguredClockSpeed', 'Speed', 'FormFactor'))

    $totalMemoryBytes = 0L
    foreach ($module in $memoryModules) {
        if ($null -ne $module.Capacity) { $totalMemoryBytes += [int64]$module.Capacity }
    }
    if ($totalMemoryBytes -eq 0 -and $null -ne $computer -and $null -ne $computer.TotalPhysicalMemory) {
        $totalMemoryBytes = [int64]$computer.TotalPhysicalMemory
    }

    $driverRows = New-Object System.Collections.Generic.List[object]
    foreach ($driver in @(Get-CimCollection -ClassName 'Win32_PnPSignedDriver' -Component 'drivers' -Property @('DeviceName', 'DriverProviderName', 'DriverVersion', 'DriverDate', 'DeviceClass'))) {
        if ([string]::IsNullOrWhiteSpace([string]$driver.DeviceName)) { continue }
        $driverRows.Add([pscustomobject][ordered]@{
                name       = [string]$driver.DeviceName
                provider   = [string]$driver.DriverProviderName
                version    = [string]$driver.DriverVersion
                driverDate = Convert-DateForExport -Value $driver.DriverDate
                deviceClass = [string]$driver.DeviceClass
            })
    }
    $drivers = @($driverRows | Sort-Object name, provider, version, deviceClass -Unique)

    $powerPlans = New-Object System.Collections.Generic.List[object]
    foreach ($plan in @(Get-CimCollection -ClassName 'Win32_PowerPlan' -Namespace 'root/cimv2/power' -Component 'powerPlans' -Property @('ElementName', 'InstanceID', 'IsActive'))) {
        $guid = $null
        if ([string]$plan.InstanceID -match '\{(?<guid>[0-9a-fA-F-]{36})\}') {
            $guid = $Matches.guid.ToLowerInvariant()
        }
        $powerPlans.Add([pscustomobject][ordered]@{
                name   = [string]$plan.ElementName
                guid   = $guid
                active = [bool]$plan.IsActive
            })
    }
    if ($powerPlans.Count -eq 0) {
        try {
            $powerCfgOutput = @(& powercfg.exe /list 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw 'powercfg /list returned a non-zero exit code.'
            }
            foreach ($line in $powerCfgOutput) {
                $text = [string]$line
                if ($text -notmatch '(?i)(?<guid>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') { continue }
                $planGuid = $Matches.guid.ToLowerInvariant()
                $displayName = $null
                if ($text -match '\((?<name>[^()]*)\)') { $displayName = $Matches.name.Trim() }
                $powerPlans.Add([pscustomobject][ordered]@{
                        name   = $displayName
                        guid   = $planGuid
                        active = $text.Contains('*')
                    })
            }
        }
        catch {
            Add-CollectionError -Component 'powerPlansFallback' -Message $_.Exception.Message
        }
    }

    $vbsRows = @(Get-CimCollection -ClassName 'Win32_DeviceGuard' -Namespace 'root/Microsoft/Windows/DeviceGuard' -Component 'vbs' -Property @('VirtualizationBasedSecurityStatus', 'SecurityServicesConfigured', 'SecurityServicesRunning', 'CodeIntegrityPolicyEnforcementStatus', 'UsermodeCodeIntegrityPolicyEnforcementStatus'))
    $vbs = if ($vbsRows.Count -gt 0) {
        $deviceGuard = $vbsRows | Select-Object -First 1
        [pscustomobject][ordered]@{
            available                         = $true
            virtualizationBasedSecurityStatus = [int]$deviceGuard.VirtualizationBasedSecurityStatus
            securityServicesConfigured         = @(Get-OptionalPropertyValue -InputObject $deviceGuard -Name 'SecurityServicesConfigured' | ForEach-Object { [int]$_ })
            securityServicesRunning            = @(Get-OptionalPropertyValue -InputObject $deviceGuard -Name 'SecurityServicesRunning' | ForEach-Object { [int]$_ })
            codeIntegrityPolicyStatus           = Get-OptionalPropertyValue -InputObject $deviceGuard -Name 'CodeIntegrityPolicyEnforcementStatus'
            userModeCodeIntegrityPolicyStatus   = Get-OptionalPropertyValue -InputObject $deviceGuard -Name 'UsermodeCodeIntegrityPolicyEnforcementStatus'
        }
    }
    else {
        [pscustomobject][ordered]@{ available = $false }
    }

    $acerGamingFunction = [ordered]@{
        available = $false
        namespace = 'root/wmi'
        methods   = @()
    }
    try {
        $acerClass = Get-CimClass -Namespace 'root/wmi' -ClassName 'AcerGamingFunction' -ErrorAction Stop
        $acerGamingFunction.available = $true
        $acerGamingFunction.methods = @($acerClass.CimClassMethods | ForEach-Object { [string]$_.Name } | Sort-Object)
    }
    catch {
        Add-CollectionError -Component 'AcerGamingFunction' -Message $_.Exception.Message
    }

    $taskRows = New-Object System.Collections.Generic.List[object]
    foreach ($taskName in @('Acer Adaptive Fan Control', 'Acer Adaptive Fan Watchdog')) {
        try {
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop | Select-Object -First 1
            $taskInfo = Get-ScheduledTaskInfo -InputObject $task -ErrorAction Stop
            $taskRows.Add([pscustomobject][ordered]@{
                    name           = $taskName
                    querySucceeded = $true
                    present        = $true
                    state          = [string]$task.State
                    lastRunTimeUtc = Convert-DateForExport -Value $taskInfo.LastRunTime
                    lastResult     = [int64]$taskInfo.LastTaskResult
                    nextRunTimeUtc = Convert-DateForExport -Value $taskInfo.NextRunTime
                })
        }
        catch {
            Add-CollectionError -Component "task:$taskName" -Message $_.Exception.Message
            $taskRows.Add([pscustomobject][ordered]@{
                    name           = $taskName
                    querySucceeded = $false
                    present        = $null
                    state          = 'Unavailable'
                })
        }
    }

    $controllerStatus = [ordered]@{
        available = $false
    }
    $statusPath = 'C:\ProgramData\AcerAdaptiveFanControl\adaptive-fan-status.json'
    if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
        try {
            $statusRead = Read-JsonDocument -Path $statusPath -MaximumBytes 65536 -Purpose 'Controller status'
            $status = $statusRead.document
            $controllerStatus = [ordered]@{
                available            = $true
                updatedAt            = Get-OptionalPropertyValue -InputObject $status -Name 'updatedAt'
                state                = Get-OptionalPropertyValue -InputObject $status -Name 'state'
                status               = Get-OptionalPropertyValue -InputObject $status -Name 'status'
                cpuTempC             = Get-OptionalPropertyValue -InputObject $status -Name 'cpuTempC'
                gpuTempC             = Get-OptionalPropertyValue -InputObject $status -Name 'gpuTempC'
                systemTempC          = Get-OptionalPropertyValue -InputObject $status -Name 'systemTempC'
                cpuLoadPct           = Get-OptionalPropertyValue -InputObject $status -Name 'cpuLoadPct'
                cpuMaxLogicalLoadPct = Get-OptionalPropertyValue -InputObject $status -Name 'cpuMaxLogicalLoadPct'
                cpuFanRpm            = Get-OptionalPropertyValue -InputObject $status -Name 'cpuFanRpm'
                gpuFanRpm            = Get-OptionalPropertyValue -InputObject $status -Name 'gpuFanRpm'
                fanBehaviorBitmap     = Get-OptionalPropertyValue -InputObject $status -Name 'fanBehaviorBitmap'
                hotSamples           = Get-OptionalPropertyValue -InputObject $status -Name 'hotSamples'
                loadSamples          = Get-OptionalPropertyValue -InputObject $status -Name 'loadSamples'
                coolSamples          = Get-OptionalPropertyValue -InputObject $status -Name 'coolSamples'
                failureSamples       = Get-OptionalPropertyValue -InputObject $status -Name 'failureSamples'
            }
        }
        catch {
            Add-CollectionError -Component 'controllerStatus' -Message $_.Exception.Message
        }
    }

    return [pscustomobject][ordered]@{
        hardware = [pscustomobject][ordered]@{
            system = [pscustomobject][ordered]@{
                manufacturer = if ($null -ne $computer) { [string]$computer.Manufacturer } else { $null }
                model        = if ($null -ne $computer) { [string]$computer.Model } else { $null }
            }
            bios = [pscustomobject][ordered]@{
                manufacturer = if ($null -ne $bios) { [string]$bios.Manufacturer } else { $null }
                version      = if ($null -ne $bios) { [string]$bios.SMBIOSBIOSVersion } else { $null }
                releaseDateUtc = if ($null -ne $bios) { Convert-DateForExport -Value $bios.ReleaseDate } else { $null }
            }
            operatingSystem = [pscustomobject][ordered]@{
                caption      = if ($null -ne $operatingSystem) { [string]$operatingSystem.Caption } else { $null }
                version      = if ($null -ne $operatingSystem) { [string]$operatingSystem.Version } else { $null }
                buildNumber  = if ($null -ne $operatingSystem) { [string]$operatingSystem.BuildNumber } else { $null }
                architecture = if ($null -ne $operatingSystem) { [string]$operatingSystem.OSArchitecture } else { $null }
            }
            processors = @($processors | ForEach-Object {
                    [pscustomobject][ordered]@{
                        name             = [string]$_.Name
                        manufacturer     = [string]$_.Manufacturer
                        cores            = [int]$_.NumberOfCores
                        logicalProcessors = [int]$_.NumberOfLogicalProcessors
                        maxClockMHz      = [int]$_.MaxClockSpeed
                    }
                })
            graphics = @($graphics | ForEach-Object {
                    [pscustomobject][ordered]@{
                        name                 = [string]$_.Name
                        videoProcessor       = [string]$_.VideoProcessor
                        driverVersion        = [string]$_.DriverVersion
                        adapterRamReportedGb = if ($null -ne $_.AdapterRAM) { [math]::Round(([double]$_.AdapterRAM / 1GB), 2) } else { $null }
                    }
                })
            memory = [pscustomobject][ordered]@{
                totalGiB = [math]::Round(([double]$totalMemoryBytes / 1GB), 2)
                modules  = @($memoryModules | ForEach-Object {
                        [pscustomobject][ordered]@{
                            manufacturer       = [string]$_.Manufacturer
                            capacityGiB        = [math]::Round(([double]$_.Capacity / 1GB), 2)
                            configuredClockMHz = if ($null -ne $_.ConfiguredClockSpeed) { [int]$_.ConfiguredClockSpeed } else { $null }
                            speedMHz           = if ($null -ne $_.Speed) { [int]$_.Speed } else { $null }
                            formFactorCode      = if ($null -ne $_.FormFactor) { [int]$_.FormFactor } else { $null }
                        }
                    })
            }
        }
        drivers             = $drivers
        powerPlans          = $powerPlans.ToArray()
        vbs                 = $vbs
        acerGamingFunction  = [pscustomobject]$acerGamingFunction
        tasks               = $taskRows.ToArray()
        controllerStatus    = [pscustomobject]$controllerStatus
        collectionErrors    = $script:CollectionErrors.ToArray()
    }
}

# Validate the exact output target before reading inputs or collecting data.
$resolvedOutputPath = Get-ExactFileSystemPath -Path $OutputPath
$outputRoot = [System.IO.Path]::GetPathRoot($resolvedOutputPath)
$outputTail = $resolvedOutputPath.Substring($outputRoot.Length)
if ($outputTail.Contains(':')) {
    throw 'NTFS alternate data stream output paths are not allowed.'
}
if ([System.IO.Path]::GetExtension($resolvedOutputPath) -ine '.json') {
    throw 'OutputPath must name a .json file.'
}
$outputParent = [System.IO.Path]::GetDirectoryName($resolvedOutputPath)
if ([string]::IsNullOrWhiteSpace($outputParent) -or -not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    throw 'The OutputPath parent directory must already exist; it will not be created.'
}
if (Test-Path -LiteralPath $resolvedOutputPath) {
    if (Test-Path -LiteralPath $resolvedOutputPath -PathType Container) {
        throw 'OutputPath must name a file, not a directory.'
    }
    if (-not $Force) {
        throw 'OutputPath already exists. Use -Force to replace that exact file.'
    }
}

$collectionMode = 'live'
if ($PSBoundParameters.ContainsKey('OfflineSnapshotPath')) {
    $offlineRead = Read-JsonDocument -Path $OfflineSnapshotPath -MaximumBytes 2097152 -Purpose 'Offline snapshot'
    $baseline = $offlineRead.document
    $collectionMode = 'offline'
}
else {
    $baseline = Get-LiveBaseline
}

$benchmarkSummaries = New-Object System.Collections.Generic.List[object]
foreach ($benchmarkPath in @($BenchmarkSummaryPath)) {
    $benchmarkRead = Read-JsonDocument -Path $benchmarkPath -MaximumBytes 1048576 -Purpose 'Benchmark summary'
    Assert-NoForbiddenMaterial -InputObject $benchmarkRead.document -Location '$.benchmark'
    $benchmarkSummaries.Add([pscustomobject][ordered]@{
            sourceFile = [System.IO.Path]::GetFileName($benchmarkRead.path)
            summary    = $benchmarkRead.document
        })
}

$candidate = [pscustomobject][ordered]@{
    schemaVersion      = 1
    collectorVersion   = $script:CollectorVersion
    generatedAtUtc     = [datetime]::UtcNow.ToString('o')
    collectionMode     = $collectionMode
    baseline           = $baseline
    benchmarkSummaries = $benchmarkSummaries.ToArray()
    safety             = [pscustomobject][ordered]@{
        policyVersion              = $script:SafetyPolicyVersion
        whitelistLiveCollection    = $true
        sensitiveIdentifiersRedacted = $true
        diskEncryptionMaterialWasQueried = $false
    }
}

Assert-NoForbiddenMaterial -InputObject $candidate
$identifiers = @(Get-RedactionIdentifiers -InputObject $candidate)
$sanitized = ConvertTo-SanitizedValue -InputObject $candidate -Identifiers $identifiers
Assert-NoForbiddenMaterial -InputObject $sanitized

$json = $sanitized | ConvertTo-Json -Depth 32
foreach ($identifier in $identifiers) {
    if ([string]::IsNullOrWhiteSpace($identifier) -or $identifier.Length -lt 4) { continue }
    if ($json.IndexOf($identifier, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw 'Refusing export: a sensitive identifier remained after redaction.'
    }
}
Assert-NoForbiddenMaterial -InputObject $json -Location '$.serializedOutput'

$encoding = New-Object System.Text.UTF8Encoding($false)
$bytes = $encoding.GetBytes($json + [Environment]::NewLine)
$fileMode = if ($Force) { [System.IO.FileMode]::Create } else { [System.IO.FileMode]::CreateNew }
$stream = $null
try {
    $stream = [System.IO.File]::Open(
        $resolvedOutputPath,
        $fileMode,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
}
finally {
    if ($null -ne $stream) { $stream.Dispose() }
}

Write-Output $resolvedOutputPath
