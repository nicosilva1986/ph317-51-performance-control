$ErrorActionPreference='Stop'
$worker=Join-Path $PSScriptRoot 'Invoke-CrossEngineJournalWorker.ps1'
$temp=Join-Path $PSScriptRoot ('.cross-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
try{
    $cases=@(
        [ordered]@{writer='powershell.exe';reader='pwsh'},
        [ordered]@{writer='pwsh';reader='powershell.exe'}
    )
    foreach($case in $cases){
        $operation=[guid]::NewGuid();$primary=Join-Path $temp ($operation.ToString('N')+'-p');$secondary=Join-Path $temp ($operation.ToString('N')+'-s')
        New-Item -ItemType Directory -Path $primary,$secondary|Out-Null
        $writeHash=& $case.writer -NoLogo -NoProfile -ExecutionPolicy Bypass -File $worker -Mode Write -PrimaryRoot $primary -SecondaryRoot $secondary -OperationId $operation
        if($LASTEXITCODE-ne0){throw "$($case.writer) journal write failed"}
        $readHash=& $case.reader -NoLogo -NoProfile -ExecutionPolicy Bypass -File $worker -Mode Read -PrimaryRoot $primary -SecondaryRoot $secondary -OperationId $operation
        if($LASTEXITCODE-ne0-or[string]$writeHash-cne[string]$readHash){throw "$($case.writer) to $($case.reader) byte-hash handoff failed"}
    }
    'PASS: PS5.1-write/PS7-read and PS7-write/PS5.1-read canonical journal hashes match.'
}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
