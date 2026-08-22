param(
    [Parameter(Mandatory)] [ValidateSet('Write','Read')] [string]$Mode,
    [Parameter(Mandatory)] [string]$PrimaryRoot,
    [Parameter(Mandatory)] [string]$SecondaryRoot,
    [Parameter(Mandatory)] [guid]$OperationId
)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'src\powershell\maintenance\CRUWStateMachine.Common.ps1')
$adapter=@{
    GetNow={ [DateTimeOffset]::Parse('2026-08-22T12:34:56.1234567-03:00') }
    ProtectFileAcl={param($path)}
    TestProtectedAcl={param($path)[ordered]@{verified=$true}}
}
if($Mode-eq'Write'){
    $context=[ordered]@{timestamp='2026-08-22T12:34:56.1234567-03:00';nested=[ordered]@{value=7}}
    $entry=Write-CRUWDualJournal $PrimaryRoot $SecondaryRoot $OperationId 0 PREPARED $null $context $adapter
    [string]$entry.payloadSha256
}else{
    $path=(Get-ChildItem -LiteralPath $PrimaryRoot -File -Filter ('removal-journal-'+$OperationId.ToString('N')+'-000000-*.json')).FullName
    if(@($path).Count-ne1){throw 'expected one journal entry'}
    $document=Read-CRUWJournalDocument $path
    if([string]$document.payload.stage-cne'PREPARED'-or(ConvertTo-CRUWUtcRoundtripString $document.payload.context.timestamp)-cne'2026-08-22T15:34:56.1234567Z'){throw 'cross-engine semantic read failed'}
    [string]$document.payloadSha256
}
