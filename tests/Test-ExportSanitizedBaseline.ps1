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

function Write-Utf8Json {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 20), $encoding)
}

function Test-ByteArrayEqual {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Left,
        [Parameter(Mandatory = $true)][byte[]]$Right
    )

    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$exporter = Join-Path $repositoryRoot 'src\powershell\Export-SanitizedBaseline.ps1'
Assert-True -Condition (Test-Path -LiteralPath $exporter -PathType Leaf) -Message 'Exporter script is present.'

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('predator-baseline-test-' + [guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($testRoot) | Out-Null

try {
    $fixturePath = Join-Path $testRoot 'offline-fixture.json'
    $benchmarkPath = Join-Path $testRoot 'benchmark-summary.json'
    $outputPath = Join-Path $testRoot 'sanitized-output.json'

    $fixture = [ordered]@{
        hardware = [ordered]@{
            system = [ordered]@{
                manufacturer = 'Acer'
                model        = 'Predator PH317-51'
                userName     = 'AliceLocal'
                computerName = 'PREDATOR-LAB'
                serialNumber = 'SN-PRIVATE-1234'
            }
            operatingSystem = [ordered]@{
                caption = 'Windows 11'
                note    = 'Collected by AliceLocal on PREDATOR-LAB from C:\Users\AliceLocal\Diagnostics\baseline.json'
            }
        }
        drivers = @(
            [ordered]@{
                name            = 'NVIDIA GeForce GTX 1060'
                provider        = 'NVIDIA'
                version         = '582.66'
                pnpDeviceId     = 'PCI\VEN_10DE&DEV_1C20\3&PRIVATE&0&00'
                deviceInstanceId = 'ACPI\VEN_PNP&DEV_0C0A\0'
            }
        )
        powerPlans = @([ordered]@{ name = 'Balanced'; guid = '381b4222-f694-41f0-9685-ff5bb260df2e'; active = $true })
        vbs = [ordered]@{ available = $true; virtualizationBasedSecurityStatus = 2 }
        acerGamingFunction = [ordered]@{ available = $true; methods = @('GetGamingFanBehavior') }
        tasks = @([ordered]@{ name = 'Acer Adaptive Fan Control'; state = 'Running' })
        controllerStatus = [ordered]@{ status = 'HEALTHY_VERIFIED'; cpuFanRpm = 6122; gpuFanRpm = 6122 }
    }
    $benchmark = [ordered]@{
        workload    = 'offline matrix test'
        artifactPath = 'C:\Users\AliceLocal\Benchmarks\raw.csv'
        hostNote    = 'Executed on PREDATOR-LAB'
        maxTempC    = 79
        wheaEvents  = 0
    }
    Write-Utf8Json -Path $fixturePath -Value $fixture
    Write-Utf8Json -Path $benchmarkPath -Value $benchmark

    $beforeFiles = @(Get-ChildItem -LiteralPath $testRoot -File | ForEach-Object Name)
    & $exporter -OutputPath $outputPath -OfflineSnapshotPath $fixturePath -BenchmarkSummaryPath $benchmarkPath | Out-Null
    $afterFiles = @(Get-ChildItem -LiteralPath $testRoot -File | ForEach-Object Name)
    $newFiles = @($afterFiles | Where-Object { $_ -notin $beforeFiles })

    Assert-True -Condition (Test-Path -LiteralPath $outputPath -PathType Leaf) -Message 'The exact requested output file was created.'
    Assert-True -Condition ($newFiles.Count -eq 1 -and $newFiles[0] -eq 'sanitized-output.json') -Message 'The exporter wrote no sibling or auxiliary files.'

    $rawOutput = [System.IO.File]::ReadAllText($outputPath)
    $parsed = $rawOutput | ConvertFrom-Json
    Assert-True -Condition ($parsed.collectionMode -eq 'offline') -Message 'Offline mode bypassed live collection.'
    Assert-True -Condition ($parsed.benchmarkSummaries.Count -eq 1) -Message 'The optional benchmark summary was embedded.'
    Assert-True -Condition ($parsed.benchmarkSummaries[0].sourceFile -eq 'benchmark-summary.json') -Message 'Only the benchmark leaf name was retained.'
    Assert-True -Condition ($parsed.baseline.hardware.system.userName -eq '[REDACTED]') -Message 'User name fields are redacted.'
    Assert-True -Condition ($parsed.baseline.hardware.system.computerName -eq '[REDACTED]') -Message 'Computer name fields are redacted.'
    Assert-True -Condition ($parsed.baseline.hardware.system.serialNumber -eq '[REDACTED]') -Message 'Serial number fields are redacted.'
    Assert-True -Condition ($parsed.baseline.drivers[0].pnpDeviceId -eq '[REDACTED]') -Message 'PnP IDs are redacted.'
    Assert-True -Condition ($parsed.baseline.drivers[0].deviceInstanceId -eq '[REDACTED]') -Message 'Device instance IDs are redacted.'
    Assert-True -Condition ($rawOutput -notmatch [regex]::Escape('AliceLocal')) -Message 'User identifiers do not remain in other strings.'
    Assert-True -Condition ($rawOutput -notmatch [regex]::Escape('PREDATOR-LAB')) -Message 'Machine identifiers do not remain in other strings.'
    Assert-True -Condition ($rawOutput -notmatch [regex]::Escape('SN-PRIVATE-1234')) -Message 'Serial values do not remain in output.'
    Assert-True -Condition ($rawOutput -notmatch 'PCI\\VEN_|ACPI\\VEN_') -Message 'PnP-style instance IDs do not remain in output.'
    Assert-True -Condition ($rawOutput -match '%USERPROFILE%') -Message 'Paths under user profiles are normalized.'
    Assert-True -Condition ($parsed.safety.diskEncryptionMaterialWasQueried -eq $false) -Message 'The output explicitly records that disk-encryption material was not queried.'

    $originalBytes = [System.IO.File]::ReadAllBytes($outputPath)
    $overwriteRefused = $false
    try {
        & $exporter -OutputPath $outputPath -OfflineSnapshotPath $fixturePath | Out-Null
    }
    catch {
        $overwriteRefused = $true
    }
    Assert-True -Condition $overwriteRefused -Message 'Existing output is refused without -Force.'
    $afterRefusalBytes = [System.IO.File]::ReadAllBytes($outputPath)
    Assert-True -Condition (Test-ByteArrayEqual -Left $originalBytes -Right $afterRefusalBytes) -Message 'Refused overwrite leaves existing output byte-identical.'

    & $exporter -OutputPath $outputPath -OfflineSnapshotPath $fixturePath -Force | Out-Null
    Assert-True -Condition (Test-Path -LiteralPath $outputPath -PathType Leaf) -Message '-Force replaces only the explicitly named output.'

    $secretFixturePath = Join-Path $testRoot 'secret-fixture.json'
    $secretOutputPath = Join-Path $testRoot 'must-not-exist.json'
    Write-Utf8Json -Path $secretFixturePath -Value ([ordered]@{
            bitLockerRecoveryPassword = ((1..8 | ForEach-Object { '{0:D6}' -f ($_ * 11111) }) -join '-')
        })
    $secretRefused = $false
    try {
        & $exporter -OutputPath $secretOutputPath -OfflineSnapshotPath $secretFixturePath | Out-Null
    }
    catch {
        $secretRefused = $_.Exception.Message -match 'Refusing export'
    }
    Assert-True -Condition $secretRefused -Message 'Recovery/credential material aborts the export.'
    Assert-True -Condition (-not (Test-Path -LiteralPath $secretOutputPath)) -Message 'Secret refusal occurs before any output file is created.'

    $secretBenchmarkPath = Join-Path $testRoot 'unsafe-benchmark.json'
    $secretBenchmarkOutput = Join-Path $testRoot 'unsafe-benchmark-output.json'
    Write-Utf8Json -Path $secretBenchmarkPath -Value ([ordered]@{
            notes = 'Recovery value ' + ((1..8 | ForEach-Object { '{0:D6}' -f (100000 + ($_ * 12345)) }) -join '-') + ' must never ship.'
        })
    $secretBenchmarkRefused = $false
    try {
        & $exporter -OutputPath $secretBenchmarkOutput -OfflineSnapshotPath $fixturePath -BenchmarkSummaryPath $secretBenchmarkPath | Out-Null
    }
    catch {
        $secretBenchmarkRefused = $_.Exception.Message -match 'Refusing export'
    }
    Assert-True -Condition $secretBenchmarkRefused -Message 'Sensitive values inside optional benchmark summaries are refused.'
    Assert-True -Condition (-not (Test-Path -LiteralPath $secretBenchmarkOutput)) -Message 'Unsafe benchmark refusal occurs before output creation.'

    $missingParent = Join-Path $testRoot 'missing-parent'
    $missingParentOutput = Join-Path $missingParent 'baseline.json'
    $parentCreationRefused = $false
    try {
        & $exporter -OutputPath $missingParentOutput -OfflineSnapshotPath $fixturePath | Out-Null
    }
    catch {
        $parentCreationRefused = $true
    }
    Assert-True -Condition $parentCreationRefused -Message 'A missing output parent is refused.'
    Assert-True -Condition (-not (Test-Path -LiteralPath $missingParent)) -Message 'The exporter never creates an output directory.'

    Write-Output "PASS Test-ExportSanitizedBaseline ($script:AssertionCount assertions)"
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
