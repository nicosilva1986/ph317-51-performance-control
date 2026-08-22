[CmdletBinding()]
param(
    [switch] $ConfirmTemporaryRecoveryEnablement,
    [switch] $UserDeclaredOriginalSystemRestoreDisabled,
    [switch] $UserDeclaredOriginalWinReDisabled
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $ConfirmTemporaryRecoveryEnablement) {
    throw 'Explicit -ConfirmTemporaryRecoveryEnablement is required; this command enables WinRE and System Restore temporarily'
}

$corePath = Join-Path $PSScriptRoot 'CRUWBlockerPreflight.Core.ps1'
if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) {
    throw "Required preflight core is missing: $corePath"
}
. $corePath

$isAdministrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdministrator) {
    $pwshCandidate = Join-Path $PSHOME 'pwsh.exe'
    $pwsh = if (Test-Path -LiteralPath $pwshCandidate) { $pwshCandidate } else { (Get-Command powershell.exe -ErrorAction Stop).Source }
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-ConfirmTemporaryRecoveryEnablement')
    if ($UserDeclaredOriginalSystemRestoreDisabled) { $arguments += '-UserDeclaredOriginalSystemRestoreDisabled' }
    if ($UserDeclaredOriginalWinReDisabled) { $arguments += '-UserDeclaredOriginalWinReDisabled' }
    $process = Start-Process -FilePath $pwsh -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -Wait -PassThru
    exit $process.ExitCode
}

$primaryParent = 'C:\Acer-Driver-Audit\Recovery'
$primaryAnchorBase = 'C:\Acer-Driver-Audit'
$secondaryParent = 'D:\Acer-Recovery'
$logicalDisks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:' OR DeviceID='D:'" -ErrorAction Stop)
foreach ($drive in @('C:', 'D:')) {
    $matches = @($logicalDisks | Where-Object { [string]::Equals([string]$_.DeviceID, $drive, [StringComparison]::OrdinalIgnoreCase) })
    if ($matches.Count -ne 1 -or [int]$matches[0].DriveType -ne 3) {
        throw "Recovery-facilities evidence drive must be one exact local fixed disk: $drive"
    }
}

$token = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N')
$beforeName = "cruw-recovery-facilities-$token-before.json"
$resultName = "cruw-recovery-facilities-$token-result.json"
$primaryBeforePath = Join-Path $primaryParent $beforeName
$secondaryBeforePath = Join-Path $secondaryParent $beforeName
$primaryResultPath = Join-Path $primaryParent $resultName
$secondaryResultPath = Join-Path $secondaryParent $resultName
[void](Assert-CruwLocalRecoveryPathBeforeWrite -CandidatePath $primaryBeforePath -AllowedBasePath $primaryParent -ExpectedDrive 'C:')
[void](Assert-CruwLocalRecoveryPathBeforeWrite -CandidatePath $secondaryBeforePath -AllowedBasePath $secondaryParent -ExpectedDrive 'D:')
[void](Assert-CruwLocalRecoveryPathBeforeWrite -CandidatePath $primaryResultPath -AllowedBasePath $primaryParent -ExpectedDrive 'C:')
[void](Assert-CruwLocalRecoveryPathBeforeWrite -CandidatePath $secondaryResultPath -AllowedBasePath $secondaryParent -ExpectedDrive 'D:')
$allAnchors = @()

function Get-CruwWinReState {
    $output = (& reagentc.exe /info 2>&1 | Out-String).Trim()
    $exitCode = $LASTEXITCODE
    $enabled = $exitCode -eq 0 -and $output -match '(?im)Windows[^\r\n]*RE[^\r\n]*:\s*(Enabled|Habilitado)'
    $disabled = $exitCode -eq 0 -and $output -match '(?im)Windows[^\r\n]*RE[^\r\n]*:\s*(Disabled|Deshabilitado)'
    $locationMatch = [regex]::Match($output, '(?im)(?:location|Ubicaci[oó]n)[^\r\n]*:\s*(\\\\\?\\GLOBALROOT[^\r\n]*)')
    $location = if ($locationMatch.Success) { $locationMatch.Groups[1].Value.Trim() } else { $null }
    $locationSha256 = $null
    if (-not [string]::IsNullOrWhiteSpace($location)) {
        try { $locationSha256 = Get-CruwCanonicalWinReLocationSha256 -Location $location }
        catch { $locationSha256 = $null }
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        State = if ($enabled) { 'Enabled' } elseif ($disabled) { 'Disabled' } else { 'Unknown' }
        Enabled = $enabled
        LocationSha256 = $locationSha256
        LocationVerified = [string]$locationSha256 -cmatch '^[A-F0-9]{64}$'
    }
}

function ConvertTo-CruwRestorePointRecord {
    param([Parameter(Mandatory)] $RestorePoint)

    $created = if ($RestorePoint.CreationTime -is [datetime]) { [datetime]$RestorePoint.CreationTime } else {
        try { [Management.ManagementDateTimeConverter]::ToDateTime([string]$RestorePoint.CreationTime) }
        catch { $null }
    }
    return [pscustomobject]@{
        SequenceNumber = $RestorePoint.SequenceNumber
        Description = [string]$RestorePoint.Description
        CreationDate = $created
    }
}

function Write-CruwDualRecoveryEvidence {
    param(
        [Parameter(Mandatory)] [string] $FileName,
        [Parameter(Mandatory)] $Document
    )

    $json = $Document | ConvertTo-Json -Depth 8
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json + [Environment]::NewLine)
    $targets = @(
        [pscustomobject]@{ Path = Join-Path $primaryParent $FileName; Parent = $primaryParent; Drive = 'C:' },
        [pscustomobject]@{ Path = Join-Path $secondaryParent $FileName; Parent = $secondaryParent; Drive = 'D:' }
    )
    foreach ($target in $targets) {
        [void](Assert-CruwLocalRecoveryPathBeforeWrite -CandidatePath $target.Path -AllowedBasePath $target.Parent -ExpectedDrive $target.Drive)
        $parentAcl = Test-CruwProtectedRecoveryAcl -Path $target.Parent
        if (-not $parentAcl.Verified -or (Test-Path -LiteralPath $target.Path)) {
            throw "Recovery evidence target is not a fresh file under a protected parent: $($target.Path)"
        }
        $stream = [IO.FileStream]::new(
            $target.Path,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough
        )
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        [void](Assert-CruwLocalRecoveryPathBeforeWrite -CandidatePath $target.Path -AllowedBasePath $target.Parent -ExpectedDrive $target.Drive -RequireFinalLeafFile)
        Set-CruwProtectedFileAcl -Path $target.Path
        $fileAcl = Test-CruwProtectedRecoveryAcl -Path $target.Path
        $streams = @(Get-Item -LiteralPath $target.Path -Stream * -ErrorAction Stop)
        if (-not $fileAcl.Verified -or $streams.Count -ne 1 -or [string]$streams[0].Stream -cne ':$DATA') {
            throw "Recovery evidence file failed ACL or stream verification: $($target.Path)"
        }
    }
    $primaryPath = Join-Path $primaryParent $FileName
    $secondaryPath = Join-Path $secondaryParent $FileName
    $primaryHash = (Get-FileHash -LiteralPath $primaryPath -Algorithm SHA256).Hash
    $secondaryHash = (Get-FileHash -LiteralPath $secondaryPath -Algorithm SHA256).Hash
    if ($primaryHash -cne $secondaryHash) { throw 'Dual recovery-facilities evidence hashes do not match' }
    return [pscustomobject]@{ PrimaryPath = $primaryPath; SecondaryPath = $secondaryPath; Sha256 = $primaryHash; Json = $json }
}

$finalOutput = $null
$finalExitCode = 1
try {
    $primaryAnchors = @(Enter-CruwDirectoryAnchorChain -DirectoryPath $primaryParent -AnchorBasePath $primaryAnchorBase -ExpectedDrive 'C:')
    $allAnchors = @($primaryAnchors)
    $secondaryAnchors = @(Enter-CruwDirectoryAnchorChain -DirectoryPath $secondaryParent -AnchorBasePath $secondaryParent -ExpectedDrive 'D:')
    $allAnchors += @($secondaryAnchors)
    foreach ($parent in @($primaryParent, $secondaryParent)) {
        Set-CruwProtectedRecoveryAcl -Path $parent
        $parentAcl = Test-CruwProtectedRecoveryAcl -Path $parent
        if (-not $parentAcl.Verified) { throw "Fixed recovery parent ACL verification failed: $parent" }
    }
    [void](Assert-CruwLocalRecoveryPathBeforeWrite -CandidatePath $primaryBeforePath -AllowedBasePath $primaryParent -ExpectedDrive 'C:')
    [void](Assert-CruwLocalRecoveryPathBeforeWrite -CandidatePath $secondaryBeforePath -AllowedBasePath $secondaryParent -ExpectedDrive 'D:')

    $winReBefore = Get-CruwWinReState
    $restoreBefore = @()
    $restoreQueryBeforeSucceeded = $false
    $restoreQueryBeforeError = $null
    try {
        $restoreBefore = @(Get-ComputerRestorePoint -ErrorAction Stop | ForEach-Object { ConvertTo-CruwRestorePointRecord $_ })
        $restoreQueryBeforeSucceeded = $true
    }
    catch { $restoreQueryBeforeError = $_.Exception.Message }
    $systemRestorePolicy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -ErrorAction SilentlyContinue
    $systemRestoreRuntime = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -ErrorAction SilentlyContinue
    $beforeEvidence = [ordered]@{
        schemaVersion = 1
        stage = 'BEFORE_TEMPORARY_ENABLEMENT'
        checkedAt = (Get-Date).ToString('o')
        evidenceToken = $token
        anchors = @($allAnchors | ForEach-Object { [ordered]@{ path = $_.Path; identity = $_.Identity } })
        winRe = [ordered]@{
            state = $winReBefore.State
            infoExitCode = $winReBefore.ExitCode
            locationSha256 = $winReBefore.LocationSha256
            locationVerified = $winReBefore.LocationVerified
            userDeclaredOriginalDisabled = [bool]$UserDeclaredOriginalWinReDisabled
        }
        systemRestore = [ordered]@{
            userDeclaredOriginalDisabled = [bool]$UserDeclaredOriginalSystemRestoreDisabled
            declarationIsOnlyOriginalStateAuthority = $true
            querySucceeded = $restoreQueryBeforeSucceeded
            queryError = $restoreQueryBeforeError
            restorePointCount = $restoreBefore.Count
            policyDisableSR = Get-CruwPropertyValue $systemRestorePolicy 'DisableSR'
            policyDisableConfig = Get-CruwPropertyValue $systemRestorePolicy 'DisableConfig'
            runtimeDisableSR = Get-CruwPropertyValue $systemRestoreRuntime 'DisableSR'
        }
        driverMutationPerformed = $false
        bitLockerMutationPerformed = $false
        rebootPerformed = $false
    }
    $beforeWrite = Write-CruwDualRecoveryEvidence -FileName $beforeName -Document $beforeEvidence

    $operationError = $null
    $winReEnableAttempted = $false
    $winReEnableExitCode = 0
    $systemRestoreEnableAttempted = $false
    $checkpointCreated = $false
    $checkpointReused = $false
    $checkpointUsable = $false
    $restoreAfter = @()
    $usableNamed = @()
    $latestAfter = @()
    try {
        if ($winReBefore.State -eq 'Unknown') { throw 'WinRE state could not be established before temporary enablement' }
        if (-not $winReBefore.Enabled) {
            $winReEnableAttempted = $true
            $null = (& reagentc.exe /enable 2>&1 | Out-String).Trim()
            $winReEnableExitCode = $LASTEXITCODE
            if ($winReEnableExitCode -ne 0) { throw "WinRE temporary enablement failed with exit $winReEnableExitCode" }
        }

        $systemRestoreEnableAttempted = $true
        Enable-ComputerRestore -Drive 'C:\' -ErrorAction Stop
        $checkpointDescription = 'Before CRUWBlocker removal'
        $checkpointNowBefore = Get-Date
        $checkpointCutoffBefore = $checkpointNowBefore.AddHours(-23)
        $restoreAfterEnable = @(Get-ComputerRestorePoint -ErrorAction Stop | ForEach-Object { ConvertTo-CruwRestorePointRecord $_ })
        $recentNamed = @(Get-CruwLatestRestorePointBySequence -RestorePoints @($restoreAfterEnable | Where-Object {
            $_.Description -ceq $checkpointDescription -and $null -ne $_.CreationDate -and
            $_.CreationDate -ge $checkpointCutoffBefore -and $_.CreationDate -le $checkpointNowBefore
        }))
        $latestBeforeCheckpoint = @(Get-CruwLatestRestorePointBySequence -RestorePoints $restoreAfterEnable)
        if (Test-CruwLatestRestorePointMatch -UsableNamedRestore $recentNamed -LatestRestore $latestBeforeCheckpoint) {
            $checkpointReused = $true
        }
        else {
            Checkpoint-Computer -Description $checkpointDescription -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
            $checkpointCreated = $true
        }
        $restoreAfter = @(Get-ComputerRestorePoint -ErrorAction Stop | ForEach-Object { ConvertTo-CruwRestorePointRecord $_ })
        $checkpointValidationNow = Get-Date
        $checkpointCutoff = $checkpointValidationNow.AddHours(-23)
        $usableNamed = @(Get-CruwLatestRestorePointBySequence -RestorePoints @($restoreAfter | Where-Object {
            $_.Description -ceq $checkpointDescription -and $null -ne $_.CreationDate -and
            $_.CreationDate -ge $checkpointCutoff -and $_.CreationDate -le $checkpointValidationNow
        }))
        $latestAfter = @(Get-CruwLatestRestorePointBySequence -RestorePoints $restoreAfter)
        $checkpointUsable = Test-CruwLatestRestorePointMatch -UsableNamedRestore $usableNamed -LatestRestore $latestAfter
        if (-not $checkpointUsable) { throw 'System Restore checkpoint is not the exact latest recent named point after enablement' }
    }
    catch { $operationError = $_.Exception.Message }

    $winReAfter = Get-CruwWinReState
    $beforePrimaryHashAfter = (Get-FileHash -LiteralPath $beforeWrite.PrimaryPath -Algorithm SHA256 -ErrorAction Stop).Hash
    $beforeSecondaryHashAfter = (Get-FileHash -LiteralPath $beforeWrite.SecondaryPath -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($beforePrimaryHashAfter -cne $beforeWrite.Sha256 -or $beforeSecondaryHashAfter -cne $beforeWrite.Sha256) {
        throw 'BEFORE recovery-facilities evidence changed before final result sealing'
    }
    $prepared = $null -eq $operationError -and $winReAfter.Enabled -and $winReAfter.LocationVerified -and $checkpointUsable
    $resultEvidence = [ordered]@{
        schemaVersion = 1
        stage = 'AFTER_TEMPORARY_ENABLEMENT'
        checkedAt = (Get-Date).ToString('o')
        evidenceToken = $token
        beforeEvidenceSha256 = $beforeWrite.Sha256
        restorationIntent = [ordered]@{
            winReOriginalState = if ($UserDeclaredOriginalWinReDisabled) { 'Disabled' } else { 'Unknown' }
            systemRestoreOriginalState = if ($UserDeclaredOriginalSystemRestoreDisabled) { 'Disabled' } else { 'Unknown' }
            originalStateWasNotInferred = $true
        }
        winRe = [ordered]@{
            enableAttempted = $winReEnableAttempted
            enableExitCode = $winReEnableExitCode
            stateAfter = $winReAfter.State
            locationSha256 = $winReAfter.LocationSha256
            locationVerified = $winReAfter.LocationVerified
        }
        systemRestore = [ordered]@{
            enableAttempted = $systemRestoreEnableAttempted
            checkpointCreated = $checkpointCreated
            checkpointReused = $checkpointReused
            checkpointUsableAndLatest = $checkpointUsable
            usablePointSequenceNumber = if ($checkpointUsable) { [long]$usableNamed[0].SequenceNumber } else { $null }
            latestPointSequenceNumber = if ($latestAfter.Count -eq 1) { [long]$latestAfter[0].SequenceNumber } else { $null }
            restorePointCountAfter = $restoreAfter.Count
            checkpointMustBeRevalidatedByFreshPreflight = $true
        }
        operationError = $operationError
        beforeEvidenceReverifiedBeforeResult = $true
        driverMutationPerformed = $false
        bitLockerMutationPerformed = $false
        rebootPerformed = $false
        status = if ($prepared) { 'PASS' } else { 'FAILED' }
    }
    $resultWrite = Write-CruwDualRecoveryEvidence -FileName $resultName -Document $resultEvidence
    $finalOutput = [ordered]@{
        status = $resultEvidence.status
        evidenceToken = $token
        beforeEvidence = [ordered]@{ primaryPath = $beforeWrite.PrimaryPath; secondaryPath = $beforeWrite.SecondaryPath; sha256 = $beforeWrite.Sha256 }
        resultEvidence = [ordered]@{ primaryPath = $resultWrite.PrimaryPath; secondaryPath = $resultWrite.SecondaryPath; sha256 = $resultWrite.Sha256 }
        beforeEvidenceReverifiedBeforeResult = $true
        freshPreflightStillRequired = $true
    } | ConvertTo-Json -Depth 5
    $finalExitCode = if ($prepared) { 0 } else { 2 }
}
finally {
    Exit-CruwDirectoryAnchorChain -Anchors $allAnchors
}

$finalOutput
exit $finalExitCode
