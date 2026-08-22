function Get-CruwPropertyValue {
    param(
        [AllowNull()] $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-CruwStringEqual {
    param(
        [AllowNull()] $Left,
        [AllowNull()] $Right
    )

    return [string]::Equals([string]$Left, [string]$Right, [StringComparison]::OrdinalIgnoreCase)
}

function Get-CruwSha256Text {
    param([Parameter(Mandatory)] [string] $Text)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $sha.Dispose()
    }
}

function Resolve-CruwDriverIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $DiskBindings,
        [Parameter(Mandatory)] [object[]] $DriverPackages,
        [string] $ExpectedFilter = 'CRUWBlocker',
        [string] $ExpectedOriginalInf = 'cruwblocker.inf',
        [string] $ExpectedProvider = 'CRU Acquisition Group, LLC',
        [string] $ExpectedClass = 'DiskDrive',
        [string] $ExpectedVersion = '1.2.1.1'
    )

    $targetBindings = @($DiskBindings | Where-Object {
        $filters = @(Get-CruwPropertyValue -InputObject $_ -Name 'LowerFilters')
        @($filters | Where-Object { Test-CruwStringEqual $_ $ExpectedFilter }).Count -gt 0
    })
    if ($targetBindings.Count -eq 0) {
        throw "No present disk binding contains the expected lower filter '$ExpectedFilter'"
    }

    $publishedNames = @($targetBindings | ForEach-Object {
        [string](Get-CruwPropertyValue -InputObject $_ -Name 'PublishedName')
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if ($publishedNames.Count -ne 1) {
        throw "Target bindings do not resolve to exactly one published driver package: $($publishedNames -join ', ')"
    }
    $publishedName = $publishedNames[0]
    if ($publishedName -notmatch '(?i)^oem\d+\.inf$') {
        throw "Resolved published driver name is not an OEM INF: $publishedName"
    }

    $packageBindings = @($DiskBindings | Where-Object {
        Test-CruwStringEqual (Get-CruwPropertyValue -InputObject $_ -Name 'PublishedName') $publishedName
    })
    if ($packageBindings.Count -ne $targetBindings.Count) {
        throw "At least one disk bound to $publishedName does not expose the $ExpectedFilter lower filter"
    }

    foreach ($binding in $targetBindings) {
        $status = Get-CruwPropertyValue -InputObject $binding -Name 'Status'
        $provider = Get-CruwPropertyValue -InputObject $binding -Name 'Provider'
        $className = Get-CruwPropertyValue -InputObject $binding -Name 'ClassName'
        $version = Get-CruwPropertyValue -InputObject $binding -Name 'Version'
        if (-not (Test-CruwStringEqual $status 'OK')) { throw "A target disk binding is not healthy: $status" }
        if (-not (Test-CruwStringEqual $provider $ExpectedProvider)) { throw "Unexpected target device provider: $provider" }
        if (-not (Test-CruwStringEqual $className $ExpectedClass)) { throw "Unexpected target device class: $className" }
        if (-not (Test-CruwStringEqual $version $ExpectedVersion)) { throw "Unexpected target device driver version: $version" }
    }

    $matchingPackages = @($DriverPackages | Where-Object {
        Test-CruwStringEqual (Get-CruwPropertyValue -InputObject $_ -Name 'PublishedName') $publishedName
    })
    if ($matchingPackages.Count -ne 1) {
        throw "Published package $publishedName did not resolve to exactly one online driver package"
    }
    $package = $matchingPackages[0]
    $originalInf = [IO.Path]::GetFileName([string](Get-CruwPropertyValue -InputObject $package -Name 'OriginalInf'))
    $packageProvider = Get-CruwPropertyValue -InputObject $package -Name 'Provider'
    $packageClass = Get-CruwPropertyValue -InputObject $package -Name 'ClassName'
    $packageVersion = Get-CruwPropertyValue -InputObject $package -Name 'Version'
    if (-not (Test-CruwStringEqual $originalInf $ExpectedOriginalInf)) { throw "Unexpected original INF: $originalInf" }
    if (-not (Test-CruwStringEqual $packageProvider $ExpectedProvider)) { throw "Unexpected driver package provider: $packageProvider" }
    if (-not (Test-CruwStringEqual $packageClass $ExpectedClass)) { throw "Unexpected driver package class: $packageClass" }
    if (-not (Test-CruwStringEqual $packageVersion $ExpectedVersion)) { throw "Unexpected driver package version: $packageVersion" }

    return [pscustomobject]@{
        PublishedName = $publishedName
        OriginalInf = $originalInf
        Provider = [string]$packageProvider
        ClassName = [string]$packageClass
        Version = [string]$packageVersion
        Filter = $ExpectedFilter
        TargetBindings = $targetBindings
    }
}

function Test-CruwVolumeLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $VolumeLayouts,
        [Parameter(Mandatory)] [string[]] $TargetDeviceInstanceIds,
        [string[]] $RequiredDriveLetters = @('C', 'D')
    )

    $failures = [Collections.Generic.List[string]]::new()
    $requiredLayouts = @()
    foreach ($letter in $RequiredDriveLetters) {
        $matches = @($VolumeLayouts | Where-Object {
            Test-CruwStringEqual (Get-CruwPropertyValue -InputObject $_ -Name 'DriveLetter') $letter
        })
        if ($matches.Count -ne 1) {
            $failures.Add("Drive $letter must resolve to exactly one layout record")
            continue
        }
        $layout = $matches[0]
        $requiredLayouts += $layout
        if (-not [bool](Get-CruwPropertyValue -InputObject $layout -Name 'Mounted')) { $failures.Add("Drive $letter is not mounted") }
        if ([bool](Get-CruwPropertyValue -InputObject $layout -Name 'IsOffline')) { $failures.Add("Drive $letter is on an offline disk") }
        if ([bool](Get-CruwPropertyValue -InputObject $layout -Name 'IsReadOnly')) { $failures.Add("Drive $letter is on a read-only disk") }
        if (-not (Test-CruwStringEqual (Get-CruwPropertyValue -InputObject $layout -Name 'DiskHealth') 'Healthy')) { $failures.Add("Drive $letter disk is not healthy") }
        if (-not (Test-CruwStringEqual (Get-CruwPropertyValue -InputObject $layout -Name 'VolumeHealth') 'Healthy')) { $failures.Add("Drive $letter volume is not healthy") }
        if (@(Get-CruwPropertyValue -InputObject $layout -Name 'DiskOperationalStatus' | Where-Object { Test-CruwStringEqual $_ 'Online' }).Count -eq 0) { $failures.Add("Drive $letter disk is not online") }
        if (@(Get-CruwPropertyValue -InputObject $layout -Name 'VolumeOperationalStatus' | Where-Object { Test-CruwStringEqual $_ 'OK' }).Count -eq 0) { $failures.Add("Drive $letter volume is not operational") }
        if ([string]::IsNullOrWhiteSpace([string](Get-CruwPropertyValue -InputObject $layout -Name 'FileSystem'))) { $failures.Add("Drive $letter has no mounted filesystem") }
        if ([string]::IsNullOrWhiteSpace([string](Get-CruwPropertyValue -InputObject $layout -Name 'DeviceInstanceId'))) { $failures.Add("Drive $letter could not be mapped to a PnP disk") }
    }

    $diskNumbers = @($requiredLayouts | ForEach-Object { [string](Get-CruwPropertyValue -InputObject $_ -Name 'DiskNumber') } | Sort-Object -Unique)
    if ($diskNumbers.Count -ne $RequiredDriveLetters.Count) {
        $failures.Add('Required recovery volumes are not on distinct physical disks')
    }

    $layoutIds = @($requiredLayouts | ForEach-Object {
        [string](Get-CruwPropertyValue -InputObject $_ -Name 'DeviceInstanceId')
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $targetIds = @($TargetDeviceInstanceIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if ($layoutIds.Count -ne $targetIds.Count -or @($layoutIds | Where-Object { $candidate = $_; @($targetIds | Where-Object { Test-CruwStringEqual $_ $candidate }).Count -eq 0 }).Count -gt 0) {
        $failures.Add('The CRUWBlocker-bound devices do not exactly match the C: and D: physical disks')
    }

    return [pscustomobject]@{
        Verified = $failures.Count -eq 0
        RequiredDriveLetters = $RequiredDriveLetters
        DistinctPhysicalDiskCount = $diskNumbers.Count
        Failures = @($failures)
    }
}

function Test-CruwFallbackReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [bool] $DiskInfFilePresent,
        [Parameter(Mandatory)] [bool] $DiskInfPackageVerified,
        [Parameter(Mandatory)] [object[]] $DeviceChecks,
        [int] $ExpectedDeviceCount = 2
    )

    $failures = [Collections.Generic.List[string]]::new()
    if (-not $DiskInfFilePresent) { $failures.Add('Windows INF\disk.inf is missing') }
    if (-not $DiskInfPackageVerified) { $failures.Add('The Microsoft DiskDrive disk.inf package was not verified') }
    if ($DeviceChecks.Count -ne $ExpectedDeviceCount) { $failures.Add("Fallback evidence was not collected for exactly $ExpectedDeviceCount devices") }
    foreach ($check in $DeviceChecks) {
        if ([int](Get-CruwPropertyValue -InputObject $check -Name 'ExitCode') -ne 0) { $failures.Add('PnP fallback inventory returned a non-zero exit code') }
        if (-not [bool](Get-CruwPropertyValue -InputObject $check -Name 'DiskInfPresent')) { $failures.Add('disk.inf is not listed as a matching driver for a target disk') }
    }
    return [pscustomobject]@{ Verified = $failures.Count -eq 0; Failures = @($failures) }
}

function Set-CruwProtectedRecoveryAcl {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $full = [Security.AccessControl.FileSystemRights]::FullControl
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($system)
    [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($system, $full, $inheritance, $propagation, $allow))
    [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($administrators, $full, $inheritance, $propagation, $allow))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Set-CruwProtectedFileAcl {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $full = [Security.AccessControl.FileSystemRights]::FullControl
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($system)
    [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($system, $full, $allow))
    [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($administrators, $full, $allow))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Set-CruwProtectedRecoveryTreeAcl {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    Set-CruwProtectedRecoveryAcl -Path $Path
    $children = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop | Sort-Object { $_.FullName.Length })
    foreach ($child in $children) {
        if ($child.PSIsContainer) { Set-CruwProtectedRecoveryAcl -Path $child.FullName }
        else { Set-CruwProtectedFileAcl -Path $child.FullName }
    }
}

function Test-CruwProtectedRecoveryAcl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [switch] $Recurse
    )

    $allowedSids = @('S-1-5-18', 'S-1-5-32-544')
    $failures = [Collections.Generic.List[string]]::new()
    $items = @((Get-Item -LiteralPath $Path -ErrorAction Stop))
    if ($Recurse) { $items += @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop) }
    foreach ($item in $items) {
        $acl = Get-Acl -LiteralPath $item.FullName
        $seenSids = @{}
        if (-not $acl.AreAccessRulesProtected) { $failures.Add("ACL inheritance is still enabled on $($item.Name)") }
        try { $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate([Security.Principal.SecurityIdentifier]).Value }
        catch {
            try { $ownerSid = ([Security.Principal.SecurityIdentifier]$acl.Owner).Value }
            catch { $ownerSid = [string]$acl.Owner }
        }
        if ($ownerSid -ne 'S-1-5-18') { $failures.Add("Owner is not SYSTEM on $($item.Name)") }
        foreach ($rule in @($acl.Access)) {
            try { $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
            catch { $sid = [string]$rule.IdentityReference }
            $seenSids[$sid] = $true
            if ($allowedSids -notcontains $sid) { $failures.Add("Unauthorized ACL identity $sid on $($item.Name)") }
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { $failures.Add("Non-Allow ACL entry on $($item.Name)") }
            if (($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl) {
                $failures.Add("Non-FullControl ACL entry on $($item.Name)")
            }
        }
        foreach ($requiredSid in $allowedSids) {
            if (-not $seenSids.ContainsKey($requiredSid)) {
                $failures.Add("Required ACL identity $requiredSid is missing on $($item.Name)")
            }
        }
    }
    return [pscustomobject]@{
        Verified = $failures.Count -eq 0
        CheckedItemCount = $items.Count
        RequiredOwnerSid = 'S-1-5-18'
        AllowedAccessSids = $allowedSids
        EveryItemAclProtected = $failures.Count -eq 0
        Failures = @($failures)
    }
}
