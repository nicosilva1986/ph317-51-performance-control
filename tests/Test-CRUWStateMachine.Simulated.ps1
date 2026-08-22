[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot;$maintenanceRoot=Join-Path $repoRoot 'src\powershell\maintenance';$invokeScript=Join-Path $maintenanceRoot 'Invoke-CRUWBlockerRemoval.ps1';$postScript=Join-Path $maintenanceRoot 'Test-CRUWBlockerPostboot.ps1';$repairScript=Join-Path $maintenanceRoot 'Repair-CRUWInterruptedRemoval.ps1'
. (Join-Path $maintenanceRoot 'CRUWStateMachine.Common.ps1')
$script:assertions=0
$script:caseNames=[Collections.Generic.List[string]]::new()
function Assert-True([bool]$Condition,[string]$Message){$script:assertions++;if(-not$Condition){throw "ASSERTION FAILED: $Message"}}
function Assert-Equal($Actual,$Expected,[string]$Message){$script:assertions++;if([string]$Actual-cne[string]$Expected){throw "ASSERTION FAILED: $Message expected=$Expected actual=$Actual"}}
function Enter-SimulatedCase([string]$Name){$script:caseNames.Add($Name);Write-Verbose "CASE: $Name"}
function Write-Utf8([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}

function New-V3Fixture([string]$CaseRoot,[DateTimeOffset]$Now,[DateTimeOffset]$BootTime,[string]$Build='26200'){
    $primary=Join-Path $CaseRoot 'primary';$secondary=Join-Path $CaseRoot 'secondary';New-Item -ItemType Directory -Path (Join-Path $primary 'driver'),(Join-Path $primary 'implementation'),$secondary -Force|Out-Null
    $bootUtc=$BootTime.UtcDateTime.ToString('o');$marker=Get-CRUWStringSha256 ($bootUtc+'|'+$Build);$winReLocation='\\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE'
    $id0=Get-CRUWStringSha256 'SIMULATED-DISK-0';$id1=Get-CRUWStringSha256 'SIMULATED-DISK-1'
    $content=[ordered]@{
        'driver\cruwblocker.inf'='simulated-inf';'driver\CRUWBlocker.sys'='simulated-sys';'driver\CRUWBlocker.cat'='simulated-cat';'SYSTEM.before.hiv'='hive';'disk-drivers-before.txt'='drivers';'winre-before.txt'='winre';'implementation\Prepare-CRUWBlockerRemoval.ps1'='preflight-code';'implementation\CRUWBlockerPreflight.Core.ps1'='core-code'
    }
    foreach($entry in $content.GetEnumerator()){Write-Utf8 (Join-Path $primary $entry.Key) $entry.Value}
    foreach($toolName in @('CRUWStateMachine.Common.ps1','Invoke-CRUWBlockerRemoval.ps1','Test-CRUWBlockerPostboot.ps1','Repair-CRUWInterruptedRemoval.ps1')){
        Copy-Item -LiteralPath (Join-Path $maintenanceRoot $toolName) -Destination (Join-Path $primary ('implementation\'+$toolName))
    }
    $artifactContract=@([ordered]@{name='Prepare-CRUWBlockerRemoval.ps1';role='preflight-producer';capable=$false},[ordered]@{name='CRUWBlockerPreflight.Core.ps1';role='preflight-core';capable=$false},[ordered]@{name='CRUWStateMachine.Common.ps1';role='state-machine-common';capable=$true},[ordered]@{name='Invoke-CRUWBlockerRemoval.ps1';role='removal-executor';capable=$true},[ordered]@{name='Repair-CRUWInterruptedRemoval.ps1';role='interruption-repair';capable=$true},[ordered]@{name='Test-CRUWBlockerPostboot.ps1';role='postboot-validator';capable=$true})
    $toolArtifacts=@($artifactContract|ForEach-Object{$relative='implementation/'+$_.name;$physical=Resolve-CRUWSafeRelativeFilePath $primary $relative;[ordered]@{role=$_.role;relativePath=$relative;sha256=(Get-FileHash -LiteralPath $physical -Algorithm SHA256).Hash;driverMutationCapable=[bool]$_.capable}})
    $sysHash=(Get-FileHash -LiteralPath (Join-Path $primary 'driver\CRUWBlocker.sys') -Algorithm SHA256).Hash
    $catHash=(Get-FileHash -LiteralPath (Join-Path $primary 'driver\CRUWBlocker.cat') -Algorithm SHA256).Hash
    $filterSnapshot=[ordered]@{schemaVersion=1;capturedAt=$Now.AddMinutes(-2).ToString('o');bootMarkerSha256=$marker;diskDriveClassGuid='{4D36E967-E325-11CE-BFC1-08002BE10318}';publishedName='oem42.inf';classFilters=[ordered]@{lowerFilters=@('CRUWBlocker','ClassKeep');upperFilters=@('ClassUpper')};targetDevices=@([ordered]@{instanceIdSha256=$id0;lowerFilters=@('CRUWBlocker','KeepLower');upperFilters=@('KeepUpper')},[ordered]@{instanceIdSha256=$id1;lowerFilters=@('CRUWBlocker','KeepLower');upperFilters=@('KeepUpper')});service=[ordered]@{name='CRUWBlocker';start=0;type=1;imagePath='System32\drivers\CRUWBlocker.sys';imagePathVerified=$true;state='Running';binaryPresent=$true;binarySha256=$sysHash;binaryMatchesExport=$true;exportedDriverSignatureStatus='Valid';exportedCatalogSignatureStatus='Valid';exportedInfSignatureStatus='Valid';knownPackageHashesVerified=$true;ready=$true}}
    $filterPath=Join-Path $primary 'filter-snapshot-before.json';Write-Utf8 $filterPath (($filterSnapshot|ConvertTo-Json -Depth 8)+[Environment]::NewLine)
    $scriptHash=(Get-FileHash -LiteralPath (Join-Path $primary 'implementation\Prepare-CRUWBlockerRemoval.ps1') -Algorithm SHA256).Hash;$coreHash=(Get-FileHash -LiteralPath (Join-Path $primary 'implementation\CRUWBlockerPreflight.Core.ps1') -Algorithm SHA256).Hash
    $driverHashes=@('cruwblocker.inf','CRUWBlocker.sys','CRUWBlocker.cat'|ForEach-Object{$name=$_;[ordered]@{file=$name;Hash=(Get-FileHash -LiteralPath (Join-Path $primary ('driver\'+$name)) -Algorithm SHA256).Hash}})
    $infHash=[string]@($driverHashes|Where-Object{[string]$_.file-ieq'cruwblocker.inf'})[0].Hash
    $devices=@([ordered]@{instanceIdSha256=$id0;status='OK';className='DiskDrive';inf='oem42.inf';provider='CRU Acquisition Group, LLC';version='1.2.1.1';lowerFilters=@('CRUWBlocker','KeepLower');upperFilters=@('KeepUpper')},[ordered]@{instanceIdSha256=$id1;status='OK';className='DiskDrive';inf='oem42.inf';provider='CRU Acquisition Group, LLC';version='1.2.1.1';lowerFilters=@('CRUWBlocker','KeepLower');upperFilters=@('KeepUpper')})
    $preflight=[ordered]@{
        schemaVersion=3;checkedAt=$Now.AddMinutes(-2).ToString('o');implementation=[ordered]@{producerPerformsDriverMutation=$false;sealedBundleContainsBootCriticalMutation=$true;artifacts=$toolArtifacts};bootIdentity=[ordered]@{lastBootUpTimeUtc=$bootUtc;operatingSystemBuild=$Build;markerSha256=$marker;removalMustMatchThisBoot=$true;verified=$true};recoveryPath=$primary;secondaryRecoveryPath=$secondary;acConnected=$true;initialState=[ordered]@{winRe=[ordered]@{state='Enabled';enabled=$true;recoveryLocation=$winReLocation;recoveryLocationSha256=(Get-CRUWCanonicalWinReLocationSha256 $winReLocation)};systemRestore=[ordered]@{readyForTransaction=$true;operationalAtStart=$true;stateBasis='Restore points were queryable before this run';userDeclaredOriginalDisabled=$false;originalStateDeclarationSource='not-provided';originalStateWasNotInferred=$true;restorePointQuerySucceeded=$true;restorePointQueryError=$null;restorePointCountBefore=1;policyDisableSR=$null;policyDisableConfig=1;disableConfigRecordedButNotUsedAsDisableSignal=$true;runtimeDisableSR=$null;scheduledTaskState='Ready';scheduledTaskEnabled=$true}}
        bitLocker=[ordered]@{volumeStatus='FullyEncrypted';protectionStatus='On';encryptionPercentage=100;recoveryPasswordProtectorPresent=$true;recoveryPasswordProtectorCount=1;readyForBoundedSuspension=$true;allEncryptedMountedVolumesRecoverable=$true;mountedEncryptedVolumes=@([ordered]@{mountPoint='C:'});secretRecorded=$false};winReEnabled=$true;restorePoint=[ordered]@{usableRecentPoint=$true;usablePointSequenceNumber=4242};driverExport=[ordered]@{publishedName='oem42.inf';originalInf='cruwblocker.inf';provider='CRU Acquisition Group, LLC';className='DiskDrive';version='1.2.1.1';expectedFilesPresent=$true;hashes=$driverHashes;driverSignatureStatus='Valid';catalogSignatureStatus='Valid';infSignatureStatus='Valid';knownPackageHashesVerified=$true;signaturesValid=$true};rollbackCapability=[ordered]@{automaticRollbackEligible=$true;exactServiceConfigurationTargetSealed=$true;errorControlAndGroupSealed=$true;postAddExactLiveReadbackMandatory=$true;setupApiTextIsAuthority=$false;restorationGuaranteed=$false;exportedPackageVerified=$true;exportedInfSha256=$infHash;infServiceName='CRUWBlocker';infServiceType=1;infStartType=3;infErrorControl=1;infServiceBinary='%12%\CRUWBlocker.sys';infLoadOrderGroup='Pnp Filter';sealedLiveStart=0;sealedLiveType=1;sealedLiveErrorControl=1;sealedLiveGroup='Pnp Filter';sealedLiveImagePathRaw='System32\drivers\CRUWBlocker.sys';sealedLiveImagePathCanonical='\SystemRoot\System32\drivers\CRUWBlocker.sys';sealedLiveState='Running';sealedLiveStartOverrideAbsent=$true;bootPromotionObservationCount=9;diagnosticPromotionEvidenceSealed=$true;promotionEvidence=@([ordered]@{fileName='setupapi.dev.log';sha256=('9'*64);length=4096;matchCount=9});failures=@()};systemHiveSaved=$true;devices=$devices
        driverBindingDiscovery=[ordered]@{class='DiskDrive';presentOnly=$true;publishedName='oem42.inf';lowerFilter='CRUWBlocker';targetDeviceCount=2;expectedTargetDeviceCount=2;presentDiskDriveCount=2;exactlyTwoPresentDiskDrives=$true;exactlyTwoTargetBindings=$true;allPackageBindingsAlsoHaveFilter=$true;verified=$true;targetDevicesHealthy=$true};filterSnapshot=[ordered]@{relativePath='filter-snapshot-before.json';sha256=(Get-FileHash -LiteralPath $filterPath -Algorithm SHA256).Hash;deviceAndClassUpperAndLowerFiltersCaptured=$true;serviceReady=$true};storageLayout=[ordered]@{verified=$true;failures=@();distinctPhysicalDiskCount=2;volumes=@([ordered]@{driveLetter='C';mounted=$true;diskNumber=0;deviceInstanceIdSha256=$id0;offline=$false;readOnly=$false;diskHealth='Healthy';diskOperationalStatus=@('Online');volumeHealth='Healthy';volumeOperationalStatus=@('OK');fileSystem='NTFS'},[ordered]@{driveLetter='D';mounted=$true;diskNumber=1;deviceInstanceIdSha256=$id1;offline=$false;readOnly=$false;diskHealth='Healthy';diskOperationalStatus=@('Online');volumeHealth='Healthy';volumeOperationalStatus=@('OK');fileSystem='NTFS'})};fallbackDriver=[ordered]@{publishedName='disk.inf';filePresent=$true;microsoftDiskDrivePackagePresent=$true;deviceChecks=@();failures=@();verified=$true};physicalDisks=@();disksHealthy=$true;pendingReboot=[ordered]@{detected=$false};offMachineRecoveryKeyConfirmed=$true;driverMutationPerformed=$false;mutationPerformed=$false;secondaryBackup=[ordered]@{verified=$true;files=@()};protectedAcl=[ordered]@{primary=[ordered]@{Verified=$true};secondary=[ordered]@{Verified=$true};onlySystemAndAdministrators=$true};secondaryBackupVerified=$true;technicalPreflightPass=$true
    }
    $preflightPath=Join-Path $primary 'preflight.json';Write-Utf8 $preflightPath (($preflight|ConvertTo-Json -Depth 14)+[Environment]::NewLine)
    Get-ChildItem -LiteralPath $primary -Force|Copy-Item -Destination $secondary -Recurse -Force
    $required=@('driver\cruwblocker.inf','driver\CRUWBlocker.sys','driver\CRUWBlocker.cat','SYSTEM.before.hiv','disk-drivers-before.txt','winre-before.txt','filter-snapshot-before.json','implementation/Prepare-CRUWBlockerRemoval.ps1','implementation/CRUWBlockerPreflight.Core.ps1','implementation/CRUWStateMachine.Common.ps1','implementation/Invoke-CRUWBlockerRemoval.ps1','implementation/Test-CRUWBlockerPostboot.ps1','implementation/Repair-CRUWInterruptedRemoval.ps1','preflight.json')
    $records=@($required|ForEach-Object{$rel=$_;$ph=(Get-FileHash -LiteralPath (Resolve-CRUWSafeRelativeFilePath $primary $rel)-Algorithm SHA256).Hash;$sh=(Get-FileHash -LiteralPath (Resolve-CRUWSafeRelativeFilePath $secondary $rel)-Algorithm SHA256).Hash;[ordered]@{relativePath=$rel;primaryExists=$true;secondaryExists=$true;primarySha256=$ph;secondarySha256=$sh;hashesMatch=$ph-eq$sh}})
    $manifest=[ordered]@{schemaVersion=1;role='authoritative-removal-preflight-manifest';checkedAt=$Now.AddMinutes(-1).ToString('o');finalizedBeforeCopy=$true;recoveryPath=$primary;secondaryRecoveryPath=$secondary;bootIdentity=[ordered]@{lastBootUpTimeUtc=$bootUtc;markerSha256=$marker};implementation=[ordered]@{producerPerformsDriverMutation=$false;sealedBundleContainsBootCriticalMutation=$true;artifacts=$toolArtifacts};driverIdentity=[ordered]@{publishedName='oem42.inf';originalInf='cruwblocker.inf';provider='CRU Acquisition Group, LLC';className='DiskDrive';version='1.2.1.1';targetDeviceCount=2;exportedInfSha256=$infHash;exportedDriverSha256=$sysHash;exportedCatalogSha256=$catHash;infSignatureStatus='Valid';driverSignatureStatus='Valid';catalogSignatureStatus='Valid';signaturesValid=$true;installedBinaryMatchesExport=$true;knownPackageHashesVerified=$true};technicalPreflightPass=$true;requiredRelativePaths=@($required|Sort-Object);requiredFileCount=$required.Count;files=$records;allHashesMatch=$true;removalValidationContract=[ordered]@{trustPreflightJsonWithoutThisManifest=$false;recomputeEveryListedHash=$true;requirePrimarySecondaryManifestByteEquality=$true;requireSameBootMarker=$true;requireProtectedAcl=$true}}
    $manifestText=($manifest|ConvertTo-Json -Depth 8)+[Environment]::NewLine;Write-Utf8 (Join-Path $primary 'backup-integrity-final.json') $manifestText;Write-Utf8 (Join-Path $secondary 'backup-integrity-final.json') $manifestText
    return [ordered]@{preflightPath=$preflightPath;preflightHash=(Get-FileHash -LiteralPath $preflightPath -Algorithm SHA256).Hash;primary=$primary;secondary=$secondary;bootUtc=$bootUtc;marker=$marker;build=$Build;id0=$id0;id1=$id1;sysHash=$sysHash}
}

function New-Snapshot($Fixture,[ValidateSet('LEGACY_INTACT','LEGACY_REASSIGNED','CLEAN_PREBOOT','CLEAN','TRANSITION','BROKEN')]$State){
    $legacy=$State-in@('LEGACY_INTACT','LEGACY_REASSIGNED','TRANSITION');$legacyInf=if($State-eq'LEGACY_REASSIGNED'){'oem99.inf'}else{'oem42.inf'}
    $device={param($id)if($legacy){[ordered]@{instanceIdSha256=$id;status='OK';inf=$legacyInf;provider='CRU Acquisition Group, LLC';version='1.2.1.1';lowerFilters=@('CRUWBlocker','KeepLower');upperFilters=@('KeepUpper')}}else{[ordered]@{instanceIdSha256=$id;status='OK';inf='disk.inf';provider='Microsoft';version='10.0.0.0';lowerFilters=@('KeepLower');upperFilters=@('KeepUpper')}}}
    $packages=if($State-in@('LEGACY_INTACT','LEGACY_REASSIGNED','CLEAN_PREBOOT')){@([ordered]@{publishedName=$legacyInf;originalInf='cruwblocker.inf';provider='CRU Acquisition Group, LLC';className='DiskDrive';version='1.2.1.1'})}else{@()}
    $service=if($State-in@('LEGACY_INTACT','LEGACY_REASSIGNED','CLEAN_PREBOOT','TRANSITION')){[ordered]@{exists=$true;state='Running';start=0;type=1;errorControl=1;group='Pnp Filter';imagePath='System32\drivers\CRUWBlocker.sys';startOverride=@();binaryPresent=$true;binarySha256=$Fixture.sysHash;binarySignatureStatus='Valid'}}else{[ordered]@{exists=$false;state=$null;start=$null;type=$null;errorControl=$null;group=$null;imagePath=$null;startOverride=@();binaryPresent=$false;binarySha256=$null;binarySignatureStatus=$null}}
    $volumes=@([ordered]@{mountPoint='C:';diskNumber=0;deviceInstanceIdSha256=$Fixture.id0;healthStatus='Healthy';operationalStatus=@('OK');fileSystem='NTFS';readOnly=$false;offline=$false;diskHealthStatus='Healthy';diskOperationalStatus=@('Online');pnpStatus='OK';pnpProblemCode=0;parentServiceChain=@([ordered]@{service='mtinvme';instanceIdSha256=('1'*64)});parentChainTerminated=$true;parentChainNoCycle=$true;parentChainTruncated=$false},[ordered]@{mountPoint='D:';diskNumber=1;deviceInstanceIdSha256=$Fixture.id1;healthStatus='Healthy';operationalStatus=@('OK');fileSystem='NTFS';readOnly=$false;offline=$false;diskHealthStatus='Healthy';diskOperationalStatus=@('Online');pnpStatus='OK';pnpProblemCode=0;parentServiceChain=@([ordered]@{service='iaStorAC';instanceIdSha256=('2'*64)});parentChainTerminated=$true;parentChainNoCycle=$true;parentChainTruncated=$false});if($State-eq'BROKEN'){$volumes=@($volumes|Where-Object{$_.mountPoint-ne'D:'})}
    $native=@('partmgr','disk','mtinvme','iaStorAC'|ForEach-Object{$name=$_;$hash=Get-CRUWStringSha256 ('native-'+$name);[ordered]@{name=$name;state='Running';started=$true;status='OK';startMode='Boot';pathSha256=$hash;binaryPresent=$true;binarySha256=$hash;binarySignatureStatus='Valid';pathUnderSystemDrivers=$true;pathBasenameMatchesService=$true;registryImagePathSha256=$hash;registryImageMatchesCimPath=$true;registry=[ordered]@{start=0;type=1;errorControl=1;group='System Bus Extender';startOverride=$null}}})
    [ordered]@{publishedName='oem42.inf';filterName='cruwblocker';packages=$packages;service=$service;classFilters=if($legacy){[ordered]@{lowerFilters=@('CRUWBlocker','ClassKeep');upperFilters=@('ClassUpper')}}else{[ordered]@{lowerFilters=@('ClassKeep');upperFilters=@('ClassUpper')}};devices=@(&$device $Fixture.id0;&$device $Fixture.id1);physicalDisks=@([ordered]@{healthStatus='Healthy';operationalStatus=@('OK')},[ordered]@{healthStatus='Healthy';operationalStatus=@('OK')});volumes=$volumes;nativeFallbackPackagePresent=$true;nativeStorageServices=$native}
}

function New-BL([ValidateSet('On','Off')]$Protection){[ordered]@{mountPoint='C:';volumeStatus='FullyEncrypted';protectionStatus=$Protection;lockStatus='Unlocked';encryptionPercentage=100;recoveryPasswordProtectorCount=1;secretRecorded=$false}}
function New-Adapter($Now,$BootUtc,$Marker,$Build,$Snapshots,$BitLockerStates,$Events=@(),$ProbeFailure=$false,$PendingStates=@($false,$false,$false),$DeleteExitCode=0,$ProtectFailureAt=0,$RollbackExitCode=0,$MutexFailure=$false,$ResumeFailures=0,$ReadinessAges=@()){
    $s=[ordered]@{now=[DateTimeOffset]$Now;bootUtc=$BootUtc;marker=$Marker;build=$Build;snapshots=@($Snapshots);si=0;bl=@($BitLockerStates);bi=0;events=@($Events);probeFailure=$ProbeFailure;pending=@($PendingStates);pi=0;deleteExitCode=$DeleteExitCode;rollbackExitCode=$RollbackExitCode;mutexFailure=$MutexFailure;resumeFailures=$ResumeFailures;readinessAges=@($ReadinessAges);readinessIndex=0;protectFailureAt=$ProtectFailureAt;protectCount=0;calls=[Collections.ArrayList]::new()}
    $id0=Get-CRUWStringSha256 'SIMULATED-DISK-0';$id1=Get-CRUWStringSha256 'SIMULATED-DISK-1';$winReHash=Get-CRUWCanonicalWinReLocationSha256 '\\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE'
    $a=@{
        SimulationOnly=$true
        EnterPathAnchors={param($path,$base,$drive,$allowMissing)[void]$s.calls.Add('AnchorEnter');$exists=Test-Path -LiteralPath $path -PathType Container;if(-not$exists-and-not$allowMissing){throw 'simulated required anchor path missing'};[ordered]@{complete=$exists;anchors=@();simulated=$true;token=[guid]::NewGuid().ToString('N')}}.GetNewClosure()
        ExitPathAnchors={param($set)[void]$s.calls.Add('AnchorExit')}.GetNewClosure()
        IsAdministrator={$true};EnterOperationMutex={[void]$s.calls.Add('MutexEnter');if($s.mutexFailure){throw 'simulated mutex unavailable'};[ordered]@{acquired=$true;token='simulated'}}.GetNewClosure();ExitOperationMutex={param($h)[void]$s.calls.Add('MutexExit')}.GetNewClosure();GetNow={$v=$s.now;$s.now=$s.now.AddSeconds(1);$v}.GetNewClosure();GetBootIdentity={[ordered]@{lastBootUpTimeUtc=$s.bootUtc;operatingSystemBuild=$s.build;markerSha256=$s.marker}}.GetNewClosure();TestProtectedAcl={param($p)[void]$s.calls.Add('ACL');[ordered]@{verified=$true;checkedItemCount=99;failures=@()}}.GetNewClosure();ProtectFileAcl={param($p)[void]$s.calls.Add('ProtectACL');$s.protectCount++;if($s.protectFailureAt-gt0-and$s.protectCount-eq$s.protectFailureAt){throw 'simulated journal ACL failure'}}.GetNewClosure();GetPendingRebootState={$v=if($s.pi-lt$s.pending.Count){[bool]$s.pending[$s.pi]}else{$false};$s.pi++;[ordered]@{detected=$v}}.GetNewClosure()
        GetRecoveryRootEvidence={param($p)$isPrimary=(Split-Path -Leaf ([string]$p))-eq'primary';[ordered]@{mountPoint=if($isPrimary){'C:'}else{'D:'};diskNumber=if($isPrimary){0}else{1};deviceInstanceIdSha256=if($isPrimary){$id0}else{$id1};diskReadOnly=$false;diskOffline=$false;diskHealthStatus='Healthy';diskOperationalStatus=@('Online');diskBusType=if($isPrimary){'NVMe'}else{'SATA'}}}.GetNewClosure();GetRecoveryReadiness={$age=if($s.readinessAges.Count){$value=$s.readinessAges[[Math]::Min($s.readinessIndex,$s.readinessAges.Count-1)];$s.readinessIndex++;$value}else{1};[ordered]@{winReEnabled=$true;winReLocationPresent=$true;winReLocationSha256=$winReHash;restorePointPresent=$true;recentRestorePointPresent=$true;restorePointCount=1;restorePointQuerySucceeded=$true;latestRestorePointSequenceNumber=4242;latestRestorePointAgeHours=$age;systemRestoreRegistryQuerySucceeded=$true;policyDisableSR=$null;policyDisableConfig=1;disableConfigRecordedButNotUsedAsDisableSignal=$true;runtimeDisableSR=$null;systemRestoreReadyForTransaction=$true}}.GetNewClosure();GetAcPowerState={[ordered]@{online=$true;sourceCount=1}};GetStorageSnapshot={param($p,$f,$m,$i)[void]$s.calls.Add('Snapshot');$index=[Math]::Min($s.si,$s.snapshots.Count-1);$s.snapshots[$index]}.GetNewClosure();GetBitLockerState={param($m)$index=[Math]::Min($s.bi,$s.bl.Count-1);$s.bl[$index]}.GetNewClosure();SuspendBitLocker={param($m,$c)[void]$s.calls.Add("Suspend:$c");if($s.bl.Count-gt1){$s.bi=1}}.GetNewClosure();ResumeBitLocker={param($m)[void]$s.calls.Add('Resume');if($s.resumeFailures-gt0){$s.resumeFailures--;throw 'simulated Resume failure'};if($s.bl.Count-gt0){$s.bi=$s.bl.Count-1}}.GetNewClosure()
        DeleteDriver={param($p)[void]$s.calls.Add('Delete');if($s.si-lt($s.snapshots.Count-1)){$s.si++};[ordered]@{executable='pnputil.exe';arguments=@('/delete-driver',$p,'/uninstall');exitCode=$s.deleteExitCode;output='simulated'}}.GetNewClosure();ReinstallBackupDriver={param($p)[void]$s.calls.Add('Rollback');if($s.si-lt($s.snapshots.Count-1)){$s.si++};[ordered]@{executable='pnputil.exe';arguments=@('/add-driver',$p,'/install');exitCode=$s.rollbackExitCode;output='simulated'}}.GetNewClosure();GetSetupApiEvidence={[ordered]@{present=$true;pathSha256=('C'*64);length=4096;fullSha256=('E'*64);tailOffset=0;tailLength=4096;tailSha256=('D'*64);lastWriteTimeUtc=$s.now.UtcDateTime.ToString('o')}}.GetNewClosure();GetCriticalEventsSince={param($since)[void]$s.calls.Add('Events');$s.events}.GetNewClosure();ProbeVolume={param($m)[void]$s.calls.Add("Probe:$m");$ok=-not($s.probeFailure-and$m-eq'D:');$hash=('A'*64);[ordered]@{mountPoint=$m;writeSucceeded=$ok;readSucceeded=$ok;writeSha256=$hash;readSha256=$hash;hashMatches=$ok;deleteSucceeded=$ok;probePathSha256=('B'*64)}}.GetNewClosure()
    };[ordered]@{adapter=$a;state=$s}
}
function Invoke-Removal($Fixture,$Bundle){$sealed=Join-Path $Fixture.primary 'implementation\Invoke-CRUWBlockerRemoval.ps1';&$sealed -PreflightPath $Fixture.preflightPath -ConfirmationPhrase REMOVE-CRUWBLOCKER-WITHOUT-FORCE -OffMachineRecoveryKeyConfirmed -PhysicalConsoleAccessConfirmed -ManualRebootWindowConfirmed -ConfirmBootCriticalDriverRemoval -TestMode -TestAdapter $Bundle.adapter}
function New-InterruptedJournal($Fixture,$Bundle,$Context,[string[]]$Stages){$operation=[guid]::NewGuid();$sequence=0;$previous=$null;$terminal=$null;foreach($stage in $Stages){$terminal=Write-CRUWDualJournal $Fixture.primary $Fixture.secondary $operation $sequence $stage $previous $Context $Bundle.adapter;Set-CRUWPropertyValue $Context lastDualCommit ([ordered]@{sequence=[int]$terminal.sequence;stage=[string]$terminal.stage;payloadSha256=[string]$terminal.payloadSha256;primaryFileSha256=[string]$terminal.primarySha256;secondaryFileSha256=[string]$terminal.secondarySha256;primaryPathSha256=Get-CRUWStringSha256 ([string]$terminal.primaryPath);secondaryPathSha256=Get-CRUWStringSha256 ([string]$terminal.secondaryPath)});$previous=$terminal.payloadSha256;$sequence++};[ordered]@{operationId=$operation;terminal=$terminal}}
function New-RecoverySeedContext($Fixture,$SourceContext){
    $context=$SourceContext|ConvertTo-Json -Depth 20|ConvertFrom-Json
    $context.preflight.path=$Fixture.preflightPath
    $context.preflight.sha256=$Fixture.preflightHash
    $context.preflight.integrityManifestSha256=(Get-FileHash -LiteralPath (Join-Path $Fixture.primary 'backup-integrity-final.json') -Algorithm SHA256).Hash
    return $context
}
function Invoke-Recovery($Fixture,$OperationId,$Bundle){$sealed=Join-Path $Fixture.primary 'implementation\Repair-CRUWInterruptedRemoval.ps1';&$sealed -PreflightPath $Fixture.preflightPath -OperationId $OperationId -ConfirmationPhrase RECOVER-CRUW-WITHOUT-REPLAYING-DELETE -OffMachineRecoveryKeyConfirmed -PhysicalConsoleAccessConfirmed -ConfirmNoDeleteReplay -TestMode -TestAdapter $Bundle.adapter}
function Invoke-RecoveryFromSecondary($Fixture,$OperationId,$Bundle){$sealed=Join-Path $Fixture.secondary 'implementation\Repair-CRUWInterruptedRemoval.ps1';$secondaryPreflight=Join-Path $Fixture.secondary 'preflight.json';&$sealed -PreflightPath $secondaryPreflight -OperationId $OperationId -ConfirmationPhrase RECOVER-CRUW-WITHOUT-REPLAYING-DELETE -OffMachineRecoveryKeyConfirmed -PhysicalConsoleAccessConfirmed -ConfirmNoDeleteReplay -TestMode -TestAdapter $Bundle.adapter}
function Invoke-Postboot($Fixture,$CheckpointPath,$Bundle){$sealed=Join-Path $Fixture.primary 'implementation\Test-CRUWBlockerPostboot.ps1';&$sealed -RebootAuthorizedCheckpointPath $CheckpointPath -OffMachineRecoveryKeyConfirmed -PhysicalConsoleAccessConfirmed -ConfirmResumeBitLockerOnExit -TestMode -TestAdapter $Bundle.adapter}

$temp=Join-Path $PSScriptRoot ('.v3-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $temp|Out-Null
try{
    $now=[DateTimeOffset]::Parse('2026-08-22T01:00:00-03:00');$boot=$now.AddMinutes(-10)

    Enter-SimulatedCase 'native-bootstrap-anchor-regex-and-delete-share-smoke'
    $invokeAst = $null
    foreach ($entrypointPath in @($invokeScript,$repairScript,$postScript)) {
        $entrypointTokens = $null
        $entrypointErrors = $null
        $entrypointAst = [Management.Automation.Language.Parser]::ParseFile(
            $entrypointPath,
            [ref]$entrypointTokens,
            [ref]$entrypointErrors
        )
        Assert-Equal @($entrypointErrors).Count 0 "entrypoint parser accepts native anchor branch: $entrypointPath"
        $driveRegexNodes = @($entrypointAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
            $node.Value -ceq '^[A-Za-z]:\\'
        },$true))
        Assert-True ($driveRegexNodes.Count -ge 1) "entrypoint contains valid escaped local-drive regex: $entrypointPath"
        foreach ($regexNode in $driveRegexNodes) {
            $compiledRegex = [regex]::new([string]$regexNode.Value)
            Assert-True $compiledRegex.IsMatch('C:\safe') "native local-drive regex compiles and accepts a local path: $entrypointPath"
        }
        if ($entrypointPath -ceq $invokeScript) { $invokeAst = $entrypointAst }
    }
    foreach ($functionName in @('Initialize-CRUWBootstrapAnchorNative','Enter-CRUWBootstrapAnchorChain')) {
        $definition = @($invokeAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq $functionName
        }.GetNewClosure(),$true))
        Assert-Equal $definition.Count 1 "one production anchor function definition found: $functionName"
        . ([scriptblock]::Create($definition[0].Extent.Text))
    }
    $nativeAnchorBase = Join-Path $temp 'native-anchor-base'
    $nativeAnchorLeaf = Join-Path $nativeAnchorBase 'sealed-root'
    $nativeAnchorRenamed = Join-Path $nativeAnchorBase 'sealed-root-renamed'
    New-Item -ItemType Directory -Path $nativeAnchorLeaf -Force | Out-Null
    $nativeExpectedDrive = [IO.Path]::GetPathRoot($nativeAnchorLeaf).TrimEnd('\')
    $nativeAnchorSet = Enter-CRUWBootstrapAnchorChain `
        -DirectoryPath $nativeAnchorLeaf `
        -AnchorBasePath $nativeAnchorBase `
        -ExpectedDrive $nativeExpectedDrive
    $renameBlocked = $false
    try {
        Rename-Item -LiteralPath $nativeAnchorLeaf -NewName (Split-Path -Leaf $nativeAnchorRenamed) -ErrorAction Stop
    }
    catch { $renameBlocked = $true }
    finally {
        for ($anchorIndex=@($nativeAnchorSet.anchors).Count-1; $anchorIndex -ge 0; $anchorIndex--) {
            $nativeAnchorSet.anchors[$anchorIndex].Dispose()
        }
    }
    Assert-True $renameBlocked 'native directory handles deny rename while anchor chain is held'
    Rename-Item -LiteralPath $nativeAnchorLeaf -NewName (Split-Path -Leaf $nativeAnchorRenamed) -ErrorAction Stop
    Assert-True (Test-Path -LiteralPath $nativeAnchorRenamed -PathType Container) 'rename succeeds after all anchor handles are disposed'

    Enter-SimulatedCase 'schema-v3-integrity-sealed-identity-and-classifier-invariants'
    $case=Join-Path $temp 'clean';New-Item -ItemType Directory $case|Out-Null;$fixture=New-V3Fixture $case $now $boot
    $pre=Get-Content -LiteralPath $fixture.preflightPath -Raw|ConvertFrom-Json;$integrity=Test-CRUWBackupIntegrity $pre $fixture.preflightPath (New-Adapter $now $fixture.bootUtc $fixture.marker $fixture.build @() @()).adapter
    Assert-True $integrity.verified 'v3 dual manifest/hash/ACL';Assert-Equal $integrity.validatedFileCount 14 'all manifest files recomputed'
    $readinessAdapter = New-Adapter $now $fixture.bootUtc $fixture.marker $fixture.build @() @()
    $readinessEvidence = & $readinessAdapter.adapter.GetRecoveryReadiness
    Assert-True (Test-CRUWRecoveryReadiness $readinessEvidence $pre) 'sealed and live System Restore readiness passes even when DisableConfig is recorded as 1'
    $disabledPolicyEvidence = $readinessEvidence | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $disabledPolicyEvidence.policyDisableSR = 1
    $disabledPolicyEvidence.systemRestoreReadyForTransaction = $false
    Assert-True (-not (Test-CRUWRecoveryReadiness $disabledPolicyEvidence $pre)) 'live policy DisableSR blocks recovery readiness'
    $disabledRuntimeEvidence = $readinessEvidence | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $disabledRuntimeEvidence.runtimeDisableSR = 1
    $disabledRuntimeEvidence.systemRestoreReadyForTransaction = $false
    Assert-True (-not (Test-CRUWRecoveryReadiness $disabledRuntimeEvidence $pre)) 'live runtime DisableSR blocks recovery readiness'
    $queryFailureEvidence = $readinessEvidence | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $queryFailureEvidence.restorePointQuerySucceeded = $false
    $queryFailureEvidence.systemRestoreReadyForTransaction = $false
    Assert-True (-not (Test-CRUWRecoveryReadiness $queryFailureEvidence $pre)) 'live restore-point query failure blocks recovery readiness'
    $unreadyPreflight = $pre | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $unreadyPreflight.initialState.systemRestore.readyForTransaction = $false
    Assert-True (-not (Test-CRUWRecoveryReadiness $readinessEvidence $unreadyPreflight)) 'sealed System Restore not-ready state blocks recovery readiness'
    $rollbackCapabilityContract = Test-CRUWRollbackCapabilityContract $pre.rollbackCapability $pre -SimulationOnly
    Assert-True $rollbackCapabilityContract.verified 'fixture matches the exact producer rollbackCapability wire contract'
    $rollbackCapabilityPropertyNames = @(Get-CRUWPropertyNameArray $pre.rollbackCapability)
    foreach ($propertyName in $rollbackCapabilityPropertyNames) {
        $missingCapabilityProperty = $pre.rollbackCapability | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $missingCapabilityProperty.PSObject.Properties.Remove($propertyName)
        $missingCapabilityRejected = $false
        try {
            $missingCapabilityRejected = -not [bool](
                Test-CRUWRollbackCapabilityContract $missingCapabilityProperty $pre -SimulationOnly
            ).verified
        }
        catch { $missingCapabilityRejected = $true }
        Assert-True $missingCapabilityRejected "rollbackCapability rejects missing producer property $propertyName"
    }
    $reorderedCapability = $pre.rollbackCapability | Select-Object -Property @($rollbackCapabilityPropertyNames | Sort-Object -Descending)
    $reorderedCapabilityContract = Test-CRUWRollbackCapabilityContract $reorderedCapability $pre -SimulationOnly
    Assert-True $reorderedCapabilityContract.verified ('rollbackCapability validates an exact property set independent of JSON property order: ' + ($reorderedCapabilityContract.failures -join '; '))
    $unsafeCapability = $pre.rollbackCapability | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $unsafeCapability.infStartType = 0
    Assert-True (-not (Test-CRUWRollbackCapabilityContract $unsafeCapability $pre -SimulationOnly).verified) 'rollbackCapability rejects an INF StartType other than the sealed value 3'
    $unsafeCapability = $pre.rollbackCapability | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $unsafeCapability.setupApiTextIsAuthority = $true
    Assert-True (-not (Test-CRUWRollbackCapabilityContract $unsafeCapability $pre -SimulationOnly).verified) 'rollbackCapability never treats SetupAPI text as authority'
    $driverIdentityProperties = @(Get-CRUWPropertyNameArray $integrity.manifest.driverIdentity)
    foreach ($propertyName in $driverIdentityProperties) {
        $mutatedIdentity = $integrity.manifest.driverIdentity | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $mutatedIdentity.PSObject.Properties.Remove($propertyName)
        $identityContract = Test-CRUWManifestDriverIdentityContract $mutatedIdentity $pre -SimulationOnly
        Assert-True (-not [bool]$identityContract.verified) "driverIdentity rejects missing property $propertyName"
    }
    foreach ($signatureProperty in @('infSignatureStatus','driverSignatureStatus','catalogSignatureStatus')) {
        $mutatedIdentity = $integrity.manifest.driverIdentity | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $mutatedIdentity.$signatureProperty = 'UnknownError'
        $identityContract = Test-CRUWManifestDriverIdentityContract $mutatedIdentity $pre -SimulationOnly
        Assert-True (-not [bool]$identityContract.verified) "driverIdentity rejects $signatureProperty drift"
    }
    $mutatedIdentity = $integrity.manifest.driverIdentity | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $mutatedIdentity.exportedInfSha256 = '0' * 64
    Assert-True (-not [bool](Test-CRUWManifestDriverIdentityContract $mutatedIdentity $pre -SimulationOnly).verified) 'driverIdentity rejects exported INF hash drift'
    $badPublishedPreflight = $pre | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $badPublishedIdentity = $integrity.manifest.driverIdentity | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $badPublishedPreflight.driverExport.publishedName = '..\hostile.inf'
    $badPublishedIdentity.publishedName = '..\hostile.inf'
    Assert-True (-not [bool](Test-CRUWManifestDriverIdentityContract $badPublishedIdentity $badPublishedPreflight -SimulationOnly).verified) 'driverIdentity rejects non-oem published INF before pnputil arguments exist'
    $badOriginalPreflight = $pre | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $badOriginalIdentity = $integrity.manifest.driverIdentity | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $badOriginalPreflight.driverExport.originalInf = 'CRUWBlocker.inf'
    $badOriginalIdentity.originalInf = 'CRUWBlocker.inf'
    Assert-True (-not [bool](Test-CRUWManifestDriverIdentityContract $badOriginalIdentity $badOriginalPreflight -SimulationOnly).verified) 'driverIdentity requires exact lowercase cruwblocker.inf original name'
    $identity=(Get-CRUWPreflightIdentity $pre $integrity.manifest).document;Assert-Equal $identity.filterName CRUWBlocker 'filterName sealed'
    $legacyClassification=Get-CRUWStateClassification (New-Snapshot $fixture LEGACY_INTACT) $identity @('C:','D:') Preboot;Assert-Equal $legacyClassification.classification LEGACY_INTACT ('legacy classifier '+($legacyClassification.gates|ConvertTo-Json -Compress))
    $reassignedClassification=Get-CRUWStateClassification (New-Snapshot $fixture LEGACY_REASSIGNED) $identity @('C:','D:') Preboot;Assert-Equal $reassignedClassification.classification LEGACY_INTACT ('rollback accepts reassigned OEM published name '+($reassignedClassification.gates|ConvertTo-Json -Compress))
    Assert-Equal (Get-CRUWStateClassification (New-Snapshot $fixture CLEAN_PREBOOT) $identity @('C:','D:') Preboot).classification CLEAN_PREBOOT 'clean preboot allows loaded unreferenced artifacts'
    Assert-Equal (Get-CRUWStateClassification (New-Snapshot $fixture CLEAN) $identity @('C:','D:') Postboot).classification CLEAN 'postboot clean'
    Assert-Equal (Get-CRUWStateClassification (New-Snapshot $fixture TRANSITION) $identity @('C:','D:') Preboot).classification TRANSITION 'mixed transition'
    Assert-Equal (Get-CRUWStateClassification (New-Snapshot $fixture BROKEN) $identity @('C:','D:') Postboot).classification BROKEN 'broken topology'
    $wrongOrder=New-Snapshot $fixture CLEAN_PREBOOT;$wrongOrder.devices[0].lowerFilters=@('Second','KeepLower');$orderedIdentity=$identity|ConvertTo-Json -Depth 10|ConvertFrom-Json;$orderedIdentity.devices[0].lowerFilters=@('CRUWBlocker','KeepLower','Second');Assert-Equal (Get-CRUWStateClassification $wrongOrder $orderedIdentity @('C:','D:') Preboot).classification BROKEN 'filter order is significant'
    $extra=New-Snapshot $fixture CLEAN_PREBOOT;$extra.devices+=,[ordered]@{instanceIdSha256=(Get-CRUWStringSha256 'EXTRA');status='OK';inf='disk.inf';provider='Microsoft';version='10';lowerFilters=@();upperFilters=@()};Assert-Equal (Get-CRUWStateClassification $extra $identity @('C:','D:') Preboot).classification BROKEN 'extra DiskDrive breaks exact topology'
    $swapped=New-Snapshot $fixture CLEAN_PREBOOT;$first=$swapped.volumes[0].deviceInstanceIdSha256;$swapped.volumes[0].deviceInstanceIdSha256=$swapped.volumes[1].deviceInstanceIdSha256;$swapped.volumes[1].deviceInstanceIdSha256=$first;Assert-Equal (Get-CRUWStateClassification $swapped $identity @('C:','D:') Preboot).classification BROKEN 'C/D device identity swap breaks sealed mapping'

    Enter-SimulatedCase 'preboot-happy-path-authorizes-manual-reboot-with-dual-journal'
    $cleanAdapter=New-Adapter $now $fixture.bootUtc $fixture.marker $fixture.build @((New-Snapshot $fixture LEGACY_INTACT),(New-Snapshot $fixture CLEAN_PREBOOT)) @((New-BL On),(New-BL Off))
    $result=Invoke-Removal $fixture $cleanAdapter;$terminalPath=$result.terminalCheckpoint.primaryPath;$terminal=Read-CRUWJournalDocument $terminalPath
    Assert-True $result.authorized 'reboot authorized';Assert-Equal $terminal.payload.stage REBOOT_AUTHORIZED 'terminal stage';Assert-True $terminal.payload.context.prebootProbes.allGreen 'preboot C/D probes green';Assert-True ($cleanAdapter.state.calls-contains'Suspend:2') 'RebootCount 2';Assert-True (-not($cleanAdapter.state.calls-contains'Resume')) 'authorized reboot stays suspended';Assert-True ($cleanAdapter.state.calls-contains'ProtectACL') 'every journal checkpoint protected'
    Assert-Equal @($cleanAdapter.state.calls|Where-Object{$_-eq'AnchorEnter'}).Count 2 'both recovery roots are anchored'
    Assert-Equal @($cleanAdapter.state.calls|Where-Object{$_-eq'AnchorExit'}).Count 2 'both recovery-root anchor chains are released'
    Assert-True ($cleanAdapter.state.calls.LastIndexOf('AnchorExit') -gt $cleanAdapter.state.calls.IndexOf('Delete')) 'anchors remain held through driver mutation and journal completion'
    $chain=Test-CRUWJournalChain $terminalPath $fixture.primary $fixture.secondary $cleanAdapter.adapter;Assert-True $chain.verified ('dual append-only hash chain verifies: '+($chain.failures -join '; '));Assert-Equal $chain.entryCount 10 'exact success intent/gate/result stage count'

    Enter-SimulatedCase 'pnputil-3010-can-authorize-only-with-exact-clean-preboot-and-green-gates'
    $warnCase=Join-Path $temp 'warning';New-Item -ItemType Directory $warnCase|Out-Null;$wf=New-V3Fixture $warnCase $now $boot;$wa=New-Adapter $now $wf.bootUtc $wf.marker $wf.build @((New-Snapshot $wf LEGACY_INTACT),(New-Snapshot $wf CLEAN_PREBOOT)) @((New-BL On),(New-BL Off)) @() $false @($false,$false) 3010;$wr=Invoke-Removal $wf $wa;$wd=Read-CRUWJournalDocument $wr.terminalCheckpoint.primaryPath;Assert-True $wr.authorized '3010 plus exact CLEAN_PREBOOT authorizes';Assert-Equal $wd.payload.context.deleteDriver.exitCodePolicy SUCCESS_REBOOT_REQUIRED '3010 policy retained'

    Enter-SimulatedCase 'pnputil-delete-nonallowlisted-exit-codes-never-authorize-reboot'
    foreach ($blockedExitCode in @(259,1641,5)) {
        $blockedCase = Join-Path $temp ('delete-exit-' + $blockedExitCode)
        New-Item -ItemType Directory $blockedCase | Out-Null
        $blockedFixture = New-V3Fixture $blockedCase $now $boot
        $blockedAdapter = New-Adapter $now $blockedFixture.bootUtc $blockedFixture.marker $blockedFixture.build `
            @((New-Snapshot $blockedFixture LEGACY_INTACT),(New-Snapshot $blockedFixture CLEAN_PREBOOT)) `
            @((New-BL On),(New-BL Off),(New-BL On)) @() $false @($false,$false,$false) $blockedExitCode
        $blockedThrew = $false
        try { Invoke-Removal $blockedFixture $blockedAdapter | Out-Null } catch { $blockedThrew = $true }
        Assert-True $blockedThrew "delete exit $blockedExitCode aborts"
        Assert-Equal @(Get-ChildItem $blockedFixture.primary -Filter '*REBOOT_AUTHORIZED-*.json').Count 0 "delete exit $blockedExitCode cannot authorize reboot"
        Assert-True ($blockedAdapter.state.calls -contains 'Resume') "delete exit $blockedExitCode restores BitLocker Protection On"
    }

    Enter-SimulatedCase 'pre-mutation-storage-event-blocks-suspend-and-delete'
    $preEventCase = Join-Path $temp 'pre-event'
    New-Item -ItemType Directory $preEventCase | Out-Null
    $preEventFixture = New-V3Fixture $preEventCase $now $boot
    $preEventAdapter = New-Adapter $now $preEventFixture.bootUtc $preEventFixture.marker $preEventFixture.build `
        @((New-Snapshot $preEventFixture LEGACY_INTACT)) @((New-BL On)) `
        @([ordered]@{providerName='disk';id=153;level=3})
    $preEventThrew = $false
    try { Invoke-Removal $preEventFixture $preEventAdapter | Out-Null } catch { $preEventThrew = $true }
    Assert-True $preEventThrew 'pre-mutation storage event blocks removal'
    Assert-True (-not ($preEventAdapter.state.calls | Where-Object { $_ -like 'Suspend:*' })) 'pre-mutation event performs no BitLocker suspension'
    Assert-True (-not ($preEventAdapter.state.calls -contains 'Delete')) 'pre-mutation event performs no driver deletion'

    Enter-SimulatedCase 'mixed-state-rolls-back-to-reassigned-oem-and-resumes-bitlocker'
    $rollbackCase=Join-Path $temp 'rollback';New-Item -ItemType Directory $rollbackCase|Out-Null;$rf=New-V3Fixture $rollbackCase $now $boot;$ra=New-Adapter $now $rf.bootUtc $rf.marker $rf.build @((New-Snapshot $rf LEGACY_INTACT),(New-Snapshot $rf TRANSITION),(New-Snapshot $rf LEGACY_REASSIGNED)) @((New-BL On),(New-BL Off),(New-BL On));$rollbackThrew=$false;try{Invoke-Removal $rf $ra|Out-Null}catch{$rollbackThrew=$true};$abortPath=(Get-ChildItem $rf.primary -Filter '*ABORT_TERMINAL-*.json').FullName;$abort=Read-CRUWJournalDocument $abortPath
    Assert-True $rollbackThrew 'rollback run not authorized';Assert-Equal $abort.payload.stage ABORT_TERMINAL 'abort terminal';Assert-Equal $abort.payload.context.final.state.classification LEGACY_INTACT 'reassigned legacy restored';Assert-True $abort.payload.context.bitLocker.resumeOnAbortVerified 'BitLocker On after abort';Assert-True ($ra.state.calls-contains'Rollback'-and$ra.state.calls-contains'Resume') 'rollback and resume called'

    Enter-SimulatedCase 'preboot-probe-failure-blocks-authorization-and-resumes-bitlocker'
    $probeCase=Join-Path $temp 'preprobe';New-Item -ItemType Directory $probeCase|Out-Null;$pf=New-V3Fixture $probeCase $now $boot;$pfa=New-Adapter $now $pf.bootUtc $pf.marker $pf.build @((New-Snapshot $pf LEGACY_INTACT),(New-Snapshot $pf CLEAN_PREBOOT)) @((New-BL On),(New-BL Off),(New-BL On)) @() $true;$probeAbort=$false;try{Invoke-Removal $pf $pfa|Out-Null}catch{$probeAbort=$true};Assert-True $probeAbort 'preboot probe failure blocks authorization';Assert-True (-not($pfa.state.calls|Where-Object{$_-like'Suspend:*'})-and-not($pfa.state.calls-contains'Delete')-and-not($pfa.state.calls-contains'Resume')) 'failed pre-mutation proof performs no BitLocker or driver mutation'

    Enter-SimulatedCase 'pending-reboot-immediately-before-delete-blocks-delete-and-resumes'
    $pendingCase=Join-Path $temp 'pending';New-Item -ItemType Directory $pendingCase|Out-Null;$pendf=New-V3Fixture $pendingCase $now $boot;$penda=New-Adapter $now $pendf.bootUtc $pendf.marker $pendf.build @((New-Snapshot $pendf LEGACY_INTACT)) @((New-BL On),(New-BL Off),(New-BL On)) @() $false @($false,$false,$true);$pendingThrew=$false;try{Invoke-Removal $pendf $penda|Out-Null}catch{$pendingThrew=$true};Assert-True $pendingThrew 'live pending reboot before delete aborts';Assert-True (-not($penda.state.calls-contains'Delete')) 'pending gate prevents delete';Assert-True ($penda.state.calls-contains'Resume') 'pending abort resumes BitLocker'

    Enter-SimulatedCase 'pending-reboot-immediately-before-suspend-blocks-suspension'
    $suspendPendingCase=Join-Path $temp 'pending-suspend';New-Item -ItemType Directory $suspendPendingCase|Out-Null;$spf=New-V3Fixture $suspendPendingCase $now $boot;$spa=New-Adapter $now $spf.bootUtc $spf.marker $spf.build @((New-Snapshot $spf LEGACY_INTACT)) @((New-BL On)) @() $false @($false,$true);$suspendPendingThrew=$false;try{Invoke-Removal $spf $spa|Out-Null}catch{$suspendPendingThrew=$true};Assert-True $suspendPendingThrew 'live pending reboot immediately before suspend aborts';Assert-True (-not($spa.state.calls|Where-Object{$_-like'Suspend:*'})) 'suspend live gate prevents suspension'

    Enter-SimulatedCase 'journal-failure-after-suspend-allows-only-emergency-resume'
    $journalFailureCase=Join-Path $temp 'journal-failure';New-Item -ItemType Directory $journalFailureCase|Out-Null;$jff=New-V3Fixture $journalFailureCase $now $boot;$jfa=New-Adapter $now $jff.bootUtc $jff.marker $jff.build @((New-Snapshot $jff LEGACY_INTACT)) @((New-BL On),(New-BL Off),(New-BL On)) @() $false @($false,$false,$false) 0 7;$journalFailureThrew=$false;try{Invoke-Removal $jff $jfa|Out-Null}catch{$journalFailureThrew=$true};Assert-True $journalFailureThrew 'journal ACL failure aborts';Assert-True ($jfa.state.calls-contains'Resume') 'journal failure after suspension still performs emergency Resume-BitLocker';Assert-True (-not($jfa.state.calls-contains'Delete')) 'journal failure prevents delete mutation'

    Enter-SimulatedCase 'backup-tamper-fails-before-any-mutation'
    $tamperCase=Join-Path $temp 'tamper';New-Item -ItemType Directory $tamperCase|Out-Null;$tf=New-V3Fixture $tamperCase $now $boot;Write-Utf8 (Join-Path $tf.primary 'driver\CRUWBlocker.cat') tampered;$ta=New-Adapter $now $tf.bootUtc $tf.marker $tf.build @() @();$tamperThrew=$false;try{Invoke-Removal $tf $ta|Out-Null}catch{$tamperThrew=$true};Assert-True $tamperThrew 'tamper rejected';Assert-True (-not($ta.state.calls-contains'Delete')) 'tamper no delete';Assert-True (-not($ta.state.calls|Where-Object{$_-like'Suspend:*'})) 'tamper no suspend';Assert-Equal @($ta.state.calls|Where-Object{$_-eq'AnchorExit'}).Count 2 'pre-mutex integrity failure releases both anchor chains'

    Enter-SimulatedCase 'postboot-clean-all-green-resumes-bitlocker-last'
    $postBoot=$now.AddMinutes(5);$postUtc=$postBoot.UtcDateTime.ToString('o');$postMarker=Get-CRUWStringSha256 ($postUtc+'|'+$fixture.build);$pa=New-Adapter $now.AddMinutes(6) $postUtc $postMarker $fixture.build @((New-Snapshot $fixture CLEAN)) @((New-BL Off),(New-BL Off),(New-BL On));$pr=Invoke-Postboot $fixture $terminalPath $pa
    Assert-True $pr.safetyComplete 'postboot safety complete';Assert-True $pr.removalComplete 'removal complete';Assert-Equal $pr.classification CLEAN 'postboot clean';Assert-True ($pa.state.calls-contains'Probe:C:'-and$pa.state.calls-contains'Probe:D:') 'postboot probes C/D';Assert-True ($pa.state.calls.IndexOf('Resume')-gt$pa.state.calls.IndexOf('Events')) 'resume after events/probes'

    Enter-SimulatedCase 'postboot-orphan-artifact-is-storage-safe-but-not-removal-complete'
    $resCase=Join-Path $temp 'residual';New-Item -ItemType Directory $resCase|Out-Null;$resf=New-V3Fixture $resCase $now $boot;$resa=New-Adapter $now $resf.bootUtc $resf.marker $resf.build @((New-Snapshot $resf LEGACY_INTACT),(New-Snapshot $resf CLEAN_PREBOOT)) @((New-BL On),(New-BL Off));$resRun=Invoke-Removal $resf $resa;$resPostAdapter=New-Adapter $now.AddMinutes(6) $postUtc (Get-CRUWStringSha256 ($postUtc+'|'+$resf.build)) $resf.build @((New-Snapshot $resf CLEAN_PREBOOT)) @((New-BL Off),(New-BL Off),(New-BL On));$resPost=Invoke-Postboot $resf $resRun.terminalCheckpoint.primaryPath $resPostAdapter;Assert-True $resPost.safetyComplete 'residual storage safe resumes BitLocker';Assert-True (-not$resPost.removalComplete) 'residual not declared complete';Assert-Equal $resPost.classification TRANSITION 'residual classification transition'

    Enter-SimulatedCase 'postboot-critical-storage-event-blocks-resume'
    $eventCase=Join-Path $temp 'event';New-Item -ItemType Directory $eventCase|Out-Null;$ef=New-V3Fixture $eventCase $now $boot;$era=New-Adapter $now $ef.bootUtc $ef.marker $ef.build @((New-Snapshot $ef LEGACY_INTACT),(New-Snapshot $ef CLEAN_PREBOOT)) @((New-BL On),(New-BL Off));$er=Invoke-Removal $ef $era;$eventPost=New-Adapter $now.AddMinutes(6) $postUtc (Get-CRUWStringSha256 ($postUtc+'|'+$ef.build)) $ef.build @((New-Snapshot $ef CLEAN)) @((New-BL Off),(New-BL Off),(New-BL On)) @([ordered]@{providerName='disk';id=7});$eventThrew=$false;try{Invoke-Postboot $ef $er.terminalCheckpoint.primaryPath $eventPost|Out-Null}catch{$eventThrew=$true};Assert-True $eventThrew 'critical event blocks postboot';Assert-True ($eventPost.state.calls-contains'Resume') 'red event gate still resumes BitLocker'

    Enter-SimulatedCase 'postboot-diagnostic-hold-replay-preserves-cause-and-appends-nothing'
    $eventHoldPaths=@(Get-ChildItem -LiteralPath $ef.primary -File -Filter '*POSTBOOT_PROTECTED_DIAGNOSTIC_HOLD-*.json')
    Assert-Equal $eventHoldPaths.Count 1 'red postboot creates one protected diagnostic hold'
    $eventHold=Read-CRUWJournalDocument $eventHoldPaths[0].FullName
    $eventHoldContext=$eventHold.payload.context
    $eventReplayCountBefore=@(Get-ChildItem -LiteralPath $ef.primary -File -Filter 'removal-journal-*.json').Count
    $eventReplayAdapter=New-Adapter $now.AddMinutes(8) $postUtc (Get-CRUWStringSha256 ($postUtc+'|'+$ef.build)) $ef.build @() @((New-BL On))
    $eventReplay=Invoke-Postboot $ef $er.terminalCheckpoint.primaryPath $eventReplayAdapter
    $eventReplayCountAfter=@(Get-ChildItem -LiteralPath $ef.primary -File -Filter 'removal-journal-*.json').Count
    Assert-Equal $eventReplay.classification BROKEN 'diagnostic replay remains broken'
    Assert-True (-not $eventReplay.safetyComplete) 'diagnostic replay never becomes safety complete'
    Assert-Equal $eventReplay.storageSafe $eventHoldContext.storageSafe 'diagnostic replay preserves storage-safe evidence'
    Assert-Equal $eventReplay.removalComplete $eventHoldContext.removalComplete 'diagnostic replay preserves removal-complete evidence'
    Assert-True @($eventReplay.failedGates).Count 'diagnostic replay has a nonempty cause'
    Assert-Equal (@($eventReplay.failedGates)-join'|') (@($eventHoldContext.failedGates)-join'|') 'diagnostic replay preserves failed gates exactly'
    Assert-Equal $eventReplay.operatorActionRequired $eventHoldContext.operatorActionRequired 'diagnostic replay preserves operator action exactly'
    Assert-Equal $eventReplayCountAfter $eventReplayCountBefore 'diagnostic replay appends no journal entry'
    $eventReplayMutations=@($eventReplayAdapter.state.calls|Where-Object{$_-eq'Delete'-or$_-eq'Rollback'-or$_-eq'Resume'-or$_-like'Suspend:*'-or$_-like'Probe:*'})
    Assert-Equal $eventReplayMutations.Count 0 'diagnostic replay performs no boot-critical mutation or probe'

    Enter-SimulatedCase 'postboot-c-or-d-probe-failure-blocks-resume'
    $postProbeCase=Join-Path $temp 'post-probe';New-Item -ItemType Directory $postProbeCase|Out-Null;$ppf=New-V3Fixture $postProbeCase $now $boot;$ppra=New-Adapter $now $ppf.bootUtc $ppf.marker $ppf.build @((New-Snapshot $ppf LEGACY_INTACT),(New-Snapshot $ppf CLEAN_PREBOOT)) @((New-BL On),(New-BL Off));$ppr=Invoke-Removal $ppf $ppra;$ppa=New-Adapter $now.AddMinutes(6) $postUtc (Get-CRUWStringSha256 ($postUtc+'|'+$ppf.build)) $ppf.build @((New-Snapshot $ppf CLEAN)) @((New-BL Off),(New-BL Off),(New-BL On)) @() $true;$postProbeThrew=$false;try{Invoke-Postboot $ppf $ppr.terminalCheckpoint.primaryPath $ppa|Out-Null}catch{$postProbeThrew=$true};Assert-True $postProbeThrew 'failed postboot C/D probe blocks completion';Assert-True ($ppa.state.calls-contains'Resume') 'failed postboot probe still resumes BitLocker'

    Enter-SimulatedCase 'postboot-native-storage-service-drift-blocks-resume'
    $nativeDriftCase=Join-Path $temp 'native-drift';New-Item -ItemType Directory $nativeDriftCase|Out-Null;$ndf=New-V3Fixture $nativeDriftCase $now $boot;$ndra=New-Adapter $now $ndf.bootUtc $ndf.marker $ndf.build @((New-Snapshot $ndf LEGACY_INTACT),(New-Snapshot $ndf CLEAN_PREBOOT)) @((New-BL On),(New-BL Off));$ndr=Invoke-Removal $ndf $ndra;$driftSnapshot=New-Snapshot $ndf CLEAN;$driftSnapshot.nativeStorageServices[0].state='Stopped';$nda=New-Adapter $now.AddMinutes(6) $postUtc (Get-CRUWStringSha256 ($postUtc+'|'+$ndf.build)) $ndf.build @($driftSnapshot) @((New-BL Off),(New-BL Off),(New-BL On));$nativeDriftThrew=$false;try{Invoke-Postboot $ndf $ndr.terminalCheckpoint.primaryPath $nda|Out-Null}catch{$nativeDriftThrew=$true};Assert-True $nativeDriftThrew 'native storage service drift blocks completion';Assert-True ($nda.state.calls-contains'Resume') 'native storage service drift still resumes BitLocker'

    Enter-SimulatedCase 'same-boot-postboot-is-waiting-without-append-or-resume'
    $sameCase=Join-Path $temp 'same-boot';New-Item -ItemType Directory $sameCase|Out-Null;$sameFixture=New-V3Fixture $sameCase $now $boot;$sameRunAdapter=New-Adapter $now $sameFixture.bootUtc $sameFixture.marker $sameFixture.build @((New-Snapshot $sameFixture LEGACY_INTACT),(New-Snapshot $sameFixture CLEAN_PREBOOT)) @((New-BL On),(New-BL Off));$sameRun=Invoke-Removal $sameFixture $sameRunAdapter;$sameTerminal=$sameRun.terminalCheckpoint.primaryPath;$sameBootCountBefore=@(Get-ChildItem $sameFixture.primary -Filter 'removal-journal-*.json').Count;$sameBootAdapter=New-Adapter $now.AddMinutes(7) $sameFixture.bootUtc $sameFixture.marker $sameFixture.build @((New-Snapshot $sameFixture CLEAN_PREBOOT),(New-Snapshot $sameFixture CLEAN_PREBOOT)) @((New-BL Off),(New-BL Off));$sameBootResult=Invoke-Postboot $sameFixture $sameTerminal $sameBootAdapter;$sameBootCountAfter=@(Get-ChildItem $sameFixture.primary -Filter 'removal-journal-*.json').Count;Assert-Equal $sameBootResult.classification WAITING_FOR_REBOOT 'same boot waits';Assert-Equal $sameBootCountAfter $sameBootCountBefore 'same boot appends nothing';Assert-True (-not($sameBootAdapter.state.calls-contains'Resume')) 'same boot preserves bounded suspension'

    Enter-SimulatedCase 'mutex-unavailable-is-read-only-and-never-instructs-reboot'
    $mutexCountBefore = @(Get-ChildItem $sameFixture.primary -Filter 'removal-journal-*.json').Count
    $mutexAdapter = New-Adapter $now.AddMinutes(7) $sameFixture.bootUtc $sameFixture.marker $sameFixture.build `
        @((New-Snapshot $sameFixture CLEAN_PREBOOT),(New-Snapshot $sameFixture CLEAN_PREBOOT)) `
        @((New-BL Off),(New-BL Off)) @() $false @($false,$false) 0 0 0 $true 0 @(1.0,1.1)
    $mutexResult = Invoke-Postboot $sameFixture $sameTerminal $mutexAdapter
    $mutexCountAfter = @(Get-ChildItem $sameFixture.primary -Filter 'removal-journal-*.json').Count
    Assert-Equal $mutexResult.classification WAIT_FOR_ACTIVE_WRITER 'stable same-boot proof waits for active writer'
    Assert-True ($mutexResult.operatorActionRequired -match 'DO NOT REBOOT') 'mutex contention never instructs reboot'
    Assert-Equal $mutexCountAfter $mutexCountBefore 'mutex contention appends no journal'
    $mutexMutations = @($mutexAdapter.state.calls | Where-Object {
        $_ -eq 'Resume' -or $_ -eq 'Delete' -or $_ -eq 'Rollback' -or $_ -eq 'ProtectACL' -or
        $_ -like 'Suspend:*' -or $_ -like 'Probe:*'
    })
    Assert-Equal $mutexMutations.Count 0 'mutex contention performs zero mutation adapters including probes'

    Enter-SimulatedCase 'first-postboot-already-protected-reaches-stability-pending-without-resume'
    $allOnCase = Join-Path $temp 'postboot-all-on'
    New-Item -ItemType Directory $allOnCase | Out-Null
    $allOnFixture = New-V3Fixture $allOnCase $now $boot
    $allOnRunAdapter = New-Adapter $now $allOnFixture.bootUtc $allOnFixture.marker $allOnFixture.build `
        @((New-Snapshot $allOnFixture LEGACY_INTACT),(New-Snapshot $allOnFixture CLEAN_PREBOOT)) `
        @((New-BL On),(New-BL Off))
    $allOnRun = Invoke-Removal $allOnFixture $allOnRunAdapter
    $allOnPostAdapter = New-Adapter $now.AddMinutes(6) $postUtc `
        (Get-CRUWStringSha256 ($postUtc+'|'+$allOnFixture.build)) $allOnFixture.build `
        @((New-Snapshot $allOnFixture CLEAN)) @((New-BL On),(New-BL On))
    $allOnPost = Invoke-Postboot $allOnFixture $allOnRun.terminalCheckpoint.primaryPath $allOnPostAdapter
    $allOnTerminal = Read-CRUWJournalDocument $allOnPost.terminalCheckpoint.primaryPath
    Assert-True $allOnPost.safetyComplete 'already-protected postboot is storage safe'
    Assert-True $allOnPost.removalComplete 'already-protected postboot records removal complete'
    Assert-True (-not $allOnPost.maintenanceComplete) 'first green postboot keeps maintenance pending'
    Assert-Equal $allOnTerminal.payload.stage POSTBOOT_STABILITY_PENDING 'first green postboot never falsely completes maintenance'
    Assert-True (-not ($allOnPostAdapter.state.calls -contains 'Resume')) 'already-protected postboot never resumes or resuspends'

    Enter-SimulatedCase 'recovery-replay-of-stability-pending-is-safe-but-not-maintenance-complete'
    $stabilityReplayCountBefore=@(Get-ChildItem -LiteralPath $allOnFixture.primary -File -Filter 'removal-journal-*.json').Count
    $stabilityReplayAdapter=New-Adapter $now.AddMinutes(8) $postUtc `
        (Get-CRUWStringSha256 ($postUtc+'|'+$allOnFixture.build)) $allOnFixture.build @() @((New-BL On))
    $stabilityReplay=Invoke-Recovery $allOnFixture ([guid]$allOnPost.operationId) $stabilityReplayAdapter
    $stabilityReplayCountAfter=@(Get-ChildItem -LiteralPath $allOnFixture.primary -File -Filter 'removal-journal-*.json').Count
    Assert-True $stabilityReplay.completedSafe 'stability-pending recovery replay is storage safe'
    Assert-True (-not $stabilityReplay.diagnosticProtected) 'stability-pending replay is not a diagnostic hold'
    Assert-True $stabilityReplay.removalComplete 'stability-pending replay preserves removal complete'
    Assert-True (-not $stabilityReplay.maintenanceComplete) 'stability-pending replay never falsely completes maintenance'
    Assert-True $stabilityReplay.stabilityPending 'stability-pending replay remains explicitly pending'
    Assert-True ($stabilityReplay.operatorActionRequired -match 'later distinct stable MANUAL reboot') 'stability-pending replay preserves next action'
    Assert-Equal $stabilityReplayCountAfter $stabilityReplayCountBefore 'stability-pending recovery replay appends no journal entry'
    $stabilityReplayMutations=@($stabilityReplayAdapter.state.calls|Where-Object{$_-eq'Delete'-or$_-eq'Rollback'-or$_-eq'Resume'-or$_-like'Suspend:*'})
    Assert-Equal $stabilityReplayMutations.Count 0 'stability-pending recovery replay performs no boot-critical mutation'

    Enter-SimulatedCase 'postboot-terminal-replay-is-idempotent-and-protected'
    $idempotentCountBefore=@(Get-ChildItem $fixture.primary -Filter 'removal-journal-*.json').Count;$idempotentAdapter=New-Adapter $now.AddMinutes(8) $postUtc $postMarker $fixture.build @() @((New-BL On));$idempotentResult=Invoke-Postboot $fixture $terminalPath $idempotentAdapter;$idempotentCountAfter=@(Get-ChildItem $fixture.primary -Filter 'removal-journal-*.json').Count;Assert-True $idempotentResult.bitLockerProtected 'idempotent replay verifies Protection On';Assert-Equal $idempotentCountAfter $idempotentCountBefore 'idempotent replay appends nothing'

    Enter-SimulatedCase 'recovery-legacy-intact-closes-without-delete-replay'
    $legacyRecoveryCase=Join-Path $temp 'recovery-legacy';New-Item -ItemType Directory $legacyRecoveryCase|Out-Null;$lrf=New-V3Fixture $legacyRecoveryCase $now $boot;$seedContext=New-RecoverySeedContext $lrf $terminal.payload.context;$seedContext.deleteDriver=$null;$writer=New-Adapter $now $lrf.bootUtc $lrf.marker $lrf.build @() @();$interrupted=New-InterruptedJournal $lrf $writer $seedContext @('PREPARED','DELETE_INTENT');$legacyRecoveryAdapter=New-Adapter $now.AddMinutes(1) $lrf.bootUtc $lrf.marker $lrf.build @((New-Snapshot $lrf LEGACY_INTACT)) @((New-BL On),(New-BL On),(New-BL On));$legacyRecovery=Invoke-Recovery $lrf $interrupted.operationId $legacyRecoveryAdapter;Assert-True $legacyRecovery.completedSafe 'legacy recovery closes safely';Assert-True (-not($legacyRecoveryAdapter.state.calls-contains'Delete')) 'legacy recovery never replays delete';Assert-Equal (Read-CRUWJournalDocument $legacyRecovery.terminalCheckpoint.primaryPath).payload.stage ABORT_TERMINAL 'legacy recovery terminal'

    Enter-SimulatedCase 'recovery-clean-preboot-can-reauthorize-without-delete-replay'
    $cleanRecoveryCase=Join-Path $temp 'recovery-clean';New-Item -ItemType Directory $cleanRecoveryCase|Out-Null;$crf=New-V3Fixture $cleanRecoveryCase $now $boot;$cleanSeed=New-RecoverySeedContext $crf $terminal.payload.context;$cleanWriter=New-Adapter $now $crf.bootUtc $crf.marker $crf.build @() @();$cleanInterrupted=New-InterruptedJournal $crf $cleanWriter $cleanSeed @('PREPARED','DELETE_INTENT');$cleanRecoveryAdapter=New-Adapter $now.AddMinutes(1) $crf.bootUtc $crf.marker $crf.build @((New-Snapshot $crf CLEAN_PREBOOT),(New-Snapshot $crf CLEAN_PREBOOT)) @((New-BL Off),(New-BL Off));$cleanRecovery=Invoke-Recovery $crf $cleanInterrupted.operationId $cleanRecoveryAdapter;Assert-True $cleanRecovery.authorized 'clean recovered state reauthorizes';Assert-True (-not($cleanRecoveryAdapter.state.calls-contains'Delete')) 'clean recovery never replays delete';Assert-Equal (Read-CRUWJournalDocument $cleanRecovery.terminalCheckpoint.primaryPath).payload.stage REBOOT_AUTHORIZED 'clean recovery authorization terminal'

    Enter-SimulatedCase 'recovery-mixed-state-rolls-back-then-protects-without-delete'
    $mixedRecoveryCase=Join-Path $temp 'recovery-mixed';New-Item -ItemType Directory $mixedRecoveryCase|Out-Null;$mrf=New-V3Fixture $mixedRecoveryCase $now $boot;$mixedSeed=New-RecoverySeedContext $mrf $terminal.payload.context;$mixedSeed.deleteDriver=$null;$mixedWriter=New-Adapter $now $mrf.bootUtc $mrf.marker $mrf.build @() @();$mixedInterrupted=New-InterruptedJournal $mrf $mixedWriter $mixedSeed @('PREPARED','DELETE_INTENT','DELETE_LIVE_GATE');$mixedRecoveryAdapter=New-Adapter $now.AddMinutes(1) $mrf.bootUtc $mrf.marker $mrf.build @((New-Snapshot $mrf TRANSITION),(New-Snapshot $mrf LEGACY_REASSIGNED)) @((New-BL Off),(New-BL Off),(New-BL On),(New-BL On));$mixedRecovery=Invoke-Recovery $mrf $mixedInterrupted.operationId $mixedRecoveryAdapter;Assert-True $mixedRecovery.completedSafe 'mixed recovery closes after rollback';Assert-True ($mixedRecoveryAdapter.state.calls-contains'Rollback') 'mixed recovery uses validated backup';Assert-True (-not($mixedRecoveryAdapter.state.calls-contains'Delete')) 'mixed recovery never replays delete'

    Enter-SimulatedCase 'rollback-pending-evidence-produces-protected-diagnostic-hold'
    $pendingRollbackCase = Join-Path $temp 'recovery-pending-after-rollback'
    New-Item -ItemType Directory $pendingRollbackCase | Out-Null
    $pendingRollbackFixture = New-V3Fixture $pendingRollbackCase $now $boot
    $pendingRollbackSeed = New-RecoverySeedContext $pendingRollbackFixture $terminal.payload.context
    $pendingRollbackSeed.deleteDriver = $null
    $pendingRollbackWriter = New-Adapter $now $pendingRollbackFixture.bootUtc $pendingRollbackFixture.marker $pendingRollbackFixture.build @() @()
    $pendingRollbackInterrupted = New-InterruptedJournal $pendingRollbackFixture $pendingRollbackWriter $pendingRollbackSeed @('PREPARED','DELETE_INTENT','DELETE_LIVE_GATE')
    $pendingRollbackAdapter = New-Adapter $now.AddMinutes(1) $pendingRollbackFixture.bootUtc $pendingRollbackFixture.marker $pendingRollbackFixture.build `
        @((New-Snapshot $pendingRollbackFixture TRANSITION),(New-Snapshot $pendingRollbackFixture LEGACY_REASSIGNED)) `
        @((New-BL Off),(New-BL On)) @() $false @($false,$false,$true)
    $pendingRollbackResult = Invoke-Recovery $pendingRollbackFixture $pendingRollbackInterrupted.operationId $pendingRollbackAdapter
    $pendingRollbackTerminal = Read-CRUWJournalDocument $pendingRollbackResult.terminalCheckpoint.primaryPath
    Assert-True $pendingRollbackResult.diagnosticProtected 'pending evidence yields protected diagnostic result'
    Assert-True (-not $pendingRollbackResult.completedSafe) 'pending evidence cannot be terminally safe'
    Assert-Equal $pendingRollbackTerminal.payload.stage PENDING_DIAGNOSTIC_HOLD 'pending evidence is explicitly journaled'
    Assert-True ($pendingRollbackResult.terminalCheckpoint -and $pendingRollbackResult.failure -eq $null) 'pending hold returns bounded diagnostic outcome'

    Enter-SimulatedCase 'rollback-service-errorcontrol-drift-never-closes-terminally'
    $readbackCase = Join-Path $temp 'recovery-readback-drift'
    New-Item -ItemType Directory $readbackCase | Out-Null
    $readbackFixture = New-V3Fixture $readbackCase $now $boot
    $readbackSeed = New-RecoverySeedContext $readbackFixture $terminal.payload.context
    $readbackSeed.deleteDriver = $null
    $readbackWriter = New-Adapter $now $readbackFixture.bootUtc $readbackFixture.marker $readbackFixture.build @() @()
    $readbackInterrupted = New-InterruptedJournal $readbackFixture $readbackWriter $readbackSeed @('PREPARED','DELETE_INTENT','DELETE_LIVE_GATE')
    $driftedLegacy = New-Snapshot $readbackFixture LEGACY_REASSIGNED
    $driftedLegacy.service.errorControl = 2
    $readbackAdapter = New-Adapter $now.AddMinutes(1) $readbackFixture.bootUtc $readbackFixture.marker $readbackFixture.build `
        @((New-Snapshot $readbackFixture TRANSITION),$driftedLegacy) @((New-BL Off),(New-BL On))
    $readbackThrew = $false
    try { Invoke-Recovery $readbackFixture $readbackInterrupted.operationId $readbackAdapter | Out-Null } catch { $readbackThrew = $true }
    Assert-True $readbackThrew 'exact service readback drift blocks recovery completion'
    Assert-Equal @(Get-ChildItem $readbackFixture.primary -Filter '*ABORT_TERMINAL-*.json').Count 0 'service readback drift cannot emit ABORT_TERMINAL'
    Assert-True ($readbackAdapter.state.calls -contains 'Resume') 'service readback drift still protects BitLocker under mutex'

    Enter-SimulatedCase 'secondary-survivor-performs-rollback-only-when-primary-is-missing'
    $survivorCase = Join-Path $temp 'secondary-survivor'
    New-Item -ItemType Directory $survivorCase | Out-Null
    $survivorFixture = New-V3Fixture $survivorCase $now $boot
    $survivorSeed = New-RecoverySeedContext $survivorFixture $terminal.payload.context
    $survivorSeed.deleteDriver = $null
    $survivorWriter = New-Adapter $now $survivorFixture.bootUtc $survivorFixture.marker $survivorFixture.build @() @()
    $survivorInterrupted = New-InterruptedJournal $survivorFixture $survivorWriter $survivorSeed @('PREPARED','DELETE_INTENT','DELETE_LIVE_GATE','SNAPSHOT_CLASSIFIED')
    $offlinePrimary = $survivorFixture.primary + '.offline'
    Move-Item -LiteralPath $survivorFixture.primary -Destination $offlinePrimary
    $survivorAdapter = New-Adapter $now.AddMinutes(1) $survivorFixture.bootUtc $survivorFixture.marker $survivorFixture.build `
        @((New-Snapshot $survivorFixture TRANSITION),(New-Snapshot $survivorFixture LEGACY_REASSIGNED)) `
        @((New-BL Off),(New-BL On))
    $survivorResult = Invoke-RecoveryFromSecondary $survivorFixture $survivorInterrupted.operationId $survivorAdapter
    $survivorTerminal = Read-CRUWJournalDocument $survivorResult.terminalCheckpoint.singleRootPath
    Assert-True $survivorResult.degradedMode 'missing primary enters explicit degraded mode'
    Assert-True $survivorResult.completedSafe 'secondary survivor verifies protected legacy rollback'
    Assert-Equal $survivorTerminal.payload.stage DEGRADED_ROLLBACK_PROTECTED_TERMINAL 'single-root success has dedicated terminal'
    Assert-True ($survivorAdapter.state.calls -contains 'Rollback') 'single-root recovery permits exactly one sealed add/install'
    Assert-True (-not ($survivorAdapter.state.calls -contains 'Delete')) 'single-root recovery never deletes'
    Assert-True (-not ($survivorAdapter.state.calls | Where-Object { $_ -like 'Suspend:*' })) 'single-root recovery never suspends or authorizes reboot'
    Assert-Equal @(Get-ChildItem $survivorFixture.secondary -Filter '*REBOOT_AUTHORIZED-*.json').Count 0 'single-root recovery cannot authorize reboot'

    Enter-SimulatedCase 'divergent-intact-counterpart-blocks-single-root-mutation'
    $divergentCase = Join-Path $temp 'divergent-counterpart'
    New-Item -ItemType Directory $divergentCase | Out-Null
    $divergentFixture = New-V3Fixture $divergentCase $now $boot
    $divergentSeed = New-RecoverySeedContext $divergentFixture $terminal.payload.context
    $divergentSeed.deleteDriver = $null
    $divergentWriter = New-Adapter $now $divergentFixture.bootUtc $divergentFixture.marker $divergentFixture.build @() @()
    $divergentInterrupted = New-InterruptedJournal $divergentFixture $divergentWriter $divergentSeed @('PREPARED','DELETE_INTENT','DELETE_LIVE_GATE','SNAPSHOT_CLASSIFIED')
    $divergentManifestPath = Join-Path $divergentFixture.primary 'backup-integrity-final.json'
    $divergentManifest = Get-Content -LiteralPath $divergentManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $divergentManifest.checkedAt = $now.AddSeconds(1).ToString('o')
    Write-Utf8 $divergentManifestPath (($divergentManifest | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
    $divergentAdapter = New-Adapter $now.AddMinutes(1) $divergentFixture.bootUtc $divergentFixture.marker $divergentFixture.build `
        @((New-Snapshot $divergentFixture TRANSITION)) @((New-BL Off),(New-BL On))
    $divergentThrew = $false
    try { Invoke-RecoveryFromSecondary $divergentFixture $divergentInterrupted.operationId $divergentAdapter | Out-Null } catch { $divergentThrew = $true }
    Assert-True $divergentThrew 'internally valid divergent counterpart blocks degraded recovery'
    Assert-True (-not ($divergentAdapter.state.calls -contains 'Rollback')) 'divergent counterpart performs no rollback'
    Assert-True (-not ($divergentAdapter.state.calls -contains 'Delete')) 'divergent counterpart performs no delete'

    Enter-SimulatedCase 'unilateral-prepared-seq0-is-quarantined-and-closed-no-mutation'
    $seq0Case=Join-Path $temp 'recovery-seq0';New-Item -ItemType Directory $seq0Case|Out-Null;$s0f=New-V3Fixture $seq0Case $now $boot;$s0op=[guid]::NewGuid();$s0Writer=New-Adapter $now $s0f.bootUtc $s0f.marker $s0f.build @() @() @() $false @($false) 0 2;$s0Failed=$false;try{Write-CRUWDualJournal $s0f.primary $s0f.secondary $s0op 0 PREPARED $null ([ordered]@{test='seq0'}) $s0Writer.adapter|Out-Null}catch{$s0Failed=$true};Assert-True $s0Failed 'simulated crash leaves unilateral seq0';$s0Adapter=New-Adapter $now.AddMinutes(1) $s0f.bootUtc $s0f.marker $s0f.build @((New-Snapshot $s0f LEGACY_INTACT)) @((New-BL On));$s0Result=Invoke-Recovery $s0f $s0op $s0Adapter;Assert-True $s0Result.completedSafe 'unilateral PREPARED closed safely';Assert-True (-not($s0Adapter.state.calls-contains'Delete')-and-not($s0Adapter.state.calls-contains'Rollback')-and-not($s0Adapter.state.calls|Where-Object{$_-like'Suspend:*'})) 'seq0 recovery performs no boot-critical mutation';Assert-Equal @(Get-ChildItem $s0f.primary -Filter '*.json.q').Count 1 'unilateral evidence preserved as short quarantine'
    $s0Prefix = Get-CRUWJournalPrefixState $s0f.primary $s0f.secondary $s0op $s0Adapter.adapter
    $s0Quarantines = @(Get-CRUWJournalQuarantineEvidence $s0f.primary $s0f.secondary $s0op $s0Adapter.adapter)
    $s0Resolution = Test-CRUWJournalQuarantineResolution $s0Prefix $s0Quarantines
    Assert-True $s0Resolution.verified 'unilateral evidence is reconciled exactly once'
    Assert-Equal $s0Resolution.quarantineCount 1 'one quarantined file remains as evidence'
    Assert-Equal $s0Resolution.referenceCount 1 'one immutable journal reference owns the quarantine'

    Enter-SimulatedCase 'static-safety-no-force-reboot-registry-service-delete-or-caller-trust-root'
    $source=(Get-Content -LiteralPath $invokeScript -Raw)+(Get-Content -LiteralPath $postScript -Raw)+(Get-Content -LiteralPath $repairScript -Raw)+(Get-Content -LiteralPath (Join-Path $maintenanceRoot 'CRUWStateMachine.Common.ps1') -Raw)+(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-CrossEngineJournalWorker.ps1') -Raw)+(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Test-CRUWCrossEngineJournal.ps1') -Raw)
    Assert-True ($source-notmatch'(?i)/force') 'no force';Assert-True ($source-notmatch'(?i)Restart-Computer|shutdown\.exe|shutdown\.com') 'no reboot primitive';Assert-True ($source-notmatch'(?i)Remove-ItemProperty|Set-ItemProperty|New-ItemProperty|reg\.exe\s+(add|delete)|sc\.exe\s+(delete|stop)') 'no registry/service deletion primitive';Assert-True ($source-notmatch'ExpectedPreflightSha256|TransactionPath') 'no caller-selected trust root or arbitrary transaction path'
    $repairTokens=$null;$repairErrors=$null;$repairAst=[Management.Automation.Language.Parser]::ParseFile($repairScript,[ref]$repairTokens,[ref]$repairErrors)
    $repairAdapterCalls=@($repairAst.FindAll({param($node)return $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ieq 'Invoke-CRUWAdapter'},$true))
    $repairDynamicAdapterCalls=@($repairAdapterCalls|Where-Object{$_.CommandElements.Count -lt 3 -or -not($_.CommandElements[2] -is [Management.Automation.Language.StringConstantExpressionAst])})
    Assert-Equal $repairDynamicAdapterCalls.Count 0 'recovery adapter operation names are static literals'
    $repairDeleteCalls=@($repairAdapterCalls|Where-Object{[string]$_.CommandElements[2].Value -ieq 'DeleteDriver'})
    Assert-Equal $repairDeleteCalls.Count 0 'recovery source cannot replay delete'
    "PASS: $script:assertions v3 simulated assertions across $($script:caseNames.Count) named cases; native directory-anchor smoke executed, boot-critical native adapter not executed."
}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
