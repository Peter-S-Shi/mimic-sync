[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# ============================================================
# Mimic Sync V1 Integration Test Harness
#
# Expected repository layout:
#
# mimic-sync/
# ├── mimic-sync.ps1
# └── tests/
#     ├── run-tests.ps1
#     └── fixtures/
#         ├── mimic/
#         ├── target-a/
#         ├── target-b/
#         └── target-c/
#
# This harness never uses personal directories. It copies the
# checked-in fixtures into tests/tmp/ and mutates only tmp/.
# ============================================================

$TestsRoot = $PSScriptRoot
$RepoRoot = Split-Path -Parent $TestsRoot
$Engine = Join-Path $RepoRoot "mimic-sync.ps1"
$Fixtures = Join-Path $TestsRoot "fixtures"
$Tmp = Join-Path $TestsRoot "tmp"

$script:Passed = 0
$script:Failed = 0

function Write-TestHeader {
    param([string]$Name)

    Write-Host ""
    Write-Host ("-" * 72) -ForegroundColor DarkCyan
    Write-Host ("TEST: {0}" -f $Name) -ForegroundColor Cyan
    Write-Host ("-" * 72) -ForegroundColor DarkCyan
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if ($Condition) {
        $script:Passed++
        Write-Host ("PASS  {0}" -f $Message) -ForegroundColor Green
    }
    else {
        $script:Failed++
        Write-Host ("FAIL  {0}" -f $Message) -ForegroundColor Red
    }
}

function Assert-FileExists {
    param(
        [string]$Path,
        [string]$Message
    )

    Assert-True -Condition (Test-Path -LiteralPath $Path -PathType Leaf) -Message $Message
}

function Assert-FileMissing {
    param(
        [string]$Path,
        [string]$Message
    )

    Assert-True -Condition (-not (Test-Path -LiteralPath $Path)) -Message $Message
}

function Assert-FileContent {
    param(
        [string]$Path,
        [string]$Expected,
        [string]$Message
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Assert-True -Condition $false -Message $Message
        return
    }

    $actual = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    Assert-True -Condition ($actual -eq $Expected) -Message $Message
}

function Reset-WorkingTree {
    if (Test-Path -LiteralPath $Tmp) {
        Remove-Item -LiteralPath $Tmp -Recurse -Force
    }

    [void](New-Item -ItemType Directory -Path $Tmp -Force)

    $source = Join-Path $Tmp "Mimic Source"
    $targetA = Join-Path $Tmp "Target A Folder"
    $targetB = Join-Path $Tmp "Target B Folder"
    $targetC = Join-Path $Tmp "目标 C"

    Copy-Item -LiteralPath (Join-Path $Fixtures "mimic") -Destination $source -Recurse
    Copy-Item -LiteralPath (Join-Path $Fixtures "target-a") -Destination $targetA -Recurse
    Copy-Item -LiteralPath (Join-Path $Fixtures "target-b") -Destination $targetB -Recurse
    Copy-Item -LiteralPath (Join-Path $Fixtures "target-c") -Destination $targetC -Recurse

    # Build the Unicode fixture at runtime instead of relying exclusively on a
    # Unicode-named ZIP entry. Some archive/extraction paths can omit or alter
    # non-ASCII fixture names without causing the test process itself to fail.
    # Creating it here ensures this test is measuring Mimic Sync's Windows
    # filesystem behavior, not the transport format used to deliver the repo.
    $unicodeDir = Join-Path $source "nested folder\深层"
    [void](New-Item -ItemType Directory -Path $unicodeDir -Force)
    [System.IO.File]::WriteAllText(
        (Join-Path $unicodeDir "guide.txt"),
        "nested-unicode-content`n",
        (New-Object System.Text.UTF8Encoding($false))
    )

    return [pscustomobject]@{
        Source  = $source
        TargetA = $targetA
        TargetB = $targetB
        TargetC = $targetC
    }
}

function Write-ConfigFile {
    param(
        [string]$Path,
        [object]$Profile
    )

    $json = $Profile | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText(
        $Path,
        $json,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Get-CurrentPowerShellExecutable {
    try {
        $process = Get-Process -Id $PID
        if ($process.Path -and (Test-Path -LiteralPath $process.Path -PathType Leaf)) {
            return $process.Path
        }
    }
    catch {}

    $windowsPowerShell = Join-Path $PSHOME "powershell.exe"
    if (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf) {
        return $windowsPowerShell
    }

    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) {
        return $pwsh.Source
    }

    $powershell = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($powershell) {
        return $powershell.Source
    }

    throw "Could not determine a PowerShell executable for child test runs."
}

function Quote-ProcessArgument {
    param([string]$Value)

    return '"' + ($Value -replace '"', '\"') + '"'
}

function Invoke-MimicChild {
    param(
        [string]$ConfigPath,
        [ValidateSet("Y","n")]
        [string]$Answer = "Y"
    )

    $exe = Get-CurrentPowerShellExecutable

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", (Quote-ProcessArgument $Engine),
        "-Config", (Quote-ProcessArgument $ConfigPath)
    ) -join " "

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    [void]$process.Start()

    # Start asynchronous reads before waiting to avoid pipe deadlocks.
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    try {
        $process.StandardInput.WriteLine($Answer)
    }
    catch {
        # Validation-failure cases may exit before input is consumed.
    }
    finally {
        try { $process.StandardInput.Close() } catch {}
    }

    $process.WaitForExit()

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

function Assert-NoMimicTempFiles {
    param(
        [string]$Root,
        [string]$Message
    )

    $tempFiles = @(
        Get-ChildItem -LiteralPath $Root -Recurse -Force -File -Filter ".mimic-sync-*.tmp" -ErrorAction SilentlyContinue
    )

    Assert-True -Condition ($tempFiles.Count -eq 0) -Message $Message
}

function Try-NewDirectoryJunction {
    param(
        [string]$LinkPath,
        [string]$DestinationPath
    )

    try {
        if (Test-Path -LiteralPath $LinkPath) {
            Remove-Item -LiteralPath $LinkPath -Recurse -Force
        }

        [void](New-Item -ItemType Directory -Path $DestinationPath -Force)

        $command = 'mklink /J "{0}" "{1}"' -f $LinkPath, $DestinationPath
        $output = & cmd.exe /d /c $command 2>&1

        return (Test-Path -LiteralPath $LinkPath)
    }
    catch {
        return $false
    }
}

function New-MixedPolicyProfile {
    param([object]$Paths)

    return [ordered]@{
        source = $Paths.Source
        targets = @(
            [ordered]@{
                name = "Add Only Target"
                path = $Paths.TargetA
                mode = "add-only"
            },
            [ordered]@{
                name = "Update Only Target"
                path = $Paths.TargetB
                mode = "update-only"
            },
            [ordered]@{
                name = "Add + Update Target 中文"
                path = $Paths.TargetC
                mode = "add-update"
            }
        )
    }
}

if (-not (Test-Path -LiteralPath $Engine -PathType Leaf)) {
    throw "mimic-sync.ps1 was not found at expected path: $Engine"
}

foreach ($required in @("mimic","target-a","target-b","target-c")) {
    $fixturePath = Join-Path $Fixtures $required
    if (-not (Test-Path -LiteralPath $fixturePath -PathType Container)) {
        throw "Required fixture directory missing: $fixturePath"
    }
}

# ============================================================
# TEST 1: Mixed-policy synchronization
# ============================================================

Write-TestHeader "Mixed policies: Add Only / Update Only / Add + Update"

$paths = Reset-WorkingTree

Assert-True `
    -Condition (Test-Path -LiteralPath (Join-Path $paths.Source "nested folder\深层\guide.txt") -PathType Leaf) `
    -Message "Unicode Source fixture exists before synchronization."

$config = Join-Path $Tmp "mixed-policy.config.json"
Write-ConfigFile -Path $config -Profile (New-MixedPolicyProfile -Paths $paths)

# Give SAME files a sentinel timestamp so the test can detect needless rewrites.
$sameSentinel = [datetime]::SpecifyKind([datetime]"2020-01-02T03:04:05", [System.DateTimeKind]::Utc)
foreach ($samePath in @(
    (Join-Path $paths.TargetA "shared-same\same.txt"),
    (Join-Path $paths.TargetB "shared-same\same.txt"),
    (Join-Path $paths.TargetC "shared-same\same.txt")
)) {
    (Get-Item -LiteralPath $samePath).LastWriteTimeUtc = $sameSentinel
}

$result = Invoke-MimicChild -ConfigPath $config -Answer "Y"

Assert-True ($result.ExitCode -eq 0) "CLI exits successfully for the valid mixed-policy profile."
Assert-True ($result.StdOut -match [regex]::Escape("shared-add\new.txt")) "Sync Plan reports exact relative file paths."
Assert-True ($result.StdOut -match "\[MKDIR\]") "Sync Plan reports planned directory creation explicitly."

# Add Only
Assert-FileExists `
    (Join-Path $paths.TargetA "shared-add\new.txt") `
    "Add Only adds missing content."

Assert-FileExists `
    (Join-Path $paths.TargetA "nested folder\深层\guide.txt") `
    "Add Only preserves nested structure and Unicode names when adding."

Assert-FileContent `
    (Join-Path $paths.TargetA "shared-update\version.txt") `
    "target-old`n" `
    "Add Only does not overwrite differing existing content."

Assert-FileContent `
    (Join-Path $paths.TargetA "local-only\private.txt") `
    "target-a-private`n" `
    "Add Only preserves target-only content."

# Update Only
Assert-FileMissing `
    (Join-Path $paths.TargetB "shared-add\new.txt") `
    "Update Only does not add missing Source content."

Assert-FileMissing `
    (Join-Path $paths.TargetB "nested folder\深层\guide.txt") `
    "Update Only does not introduce a missing nested subtree."

Assert-True `
    -Condition (-not (Test-Path -LiteralPath (Join-Path $paths.TargetB "nested folder"))) `
    -Message "Update Only does not create missing directories."

Assert-FileContent `
    (Join-Path $paths.TargetB "shared-update\version.txt") `
    "source-v2`n" `
    "Update Only updates differing existing content."

Assert-FileContent `
    (Join-Path $paths.TargetB "local-only\private.txt") `
    "target-b-private`n" `
    "Update Only preserves target-only content."

# Add + Update
Assert-FileExists `
    (Join-Path $paths.TargetC "shared-add\new.txt") `
    "Add + Update adds missing content."

Assert-FileExists `
    (Join-Path $paths.TargetC "nested folder\深层\guide.txt") `
    "Add + Update adds nested Unicode content."

Assert-FileContent `
    (Join-Path $paths.TargetC "shared-update\version.txt") `
    "source-v2`n" `
    "Add + Update updates differing existing content."

Assert-FileContent `
    (Join-Path $paths.TargetC "local-only\private.txt") `
    "target-c-private`n" `
    "Add + Update preserves target-only content."

Assert-NoMimicTempFiles -Root $paths.TargetA -Message "Successful Add Only run leaves no Mimic Sync temp files."
Assert-NoMimicTempFiles -Root $paths.TargetB -Message "Successful Update Only run leaves no Mimic Sync temp files."
Assert-NoMimicTempFiles -Root $paths.TargetC -Message "Successful Add + Update run leaves no Mimic Sync temp files."

foreach ($samePath in @(
    (Join-Path $paths.TargetA "shared-same\same.txt"),
    (Join-Path $paths.TargetB "shared-same\same.txt"),
    (Join-Path $paths.TargetC "shared-same\same.txt")
)) {
    Assert-True `
        -Condition ((Get-Item -LiteralPath $samePath).LastWriteTimeUtc -eq $sameSentinel) `
        -Message ("SAME content is not rewritten: {0}" -f $samePath)
}

# Root-level source file behavior
Assert-FileExists `
    (Join-Path $paths.TargetA "root-source.txt") `
    "Add Only adds a missing root-level file."

Assert-FileMissing `
    (Join-Path $paths.TargetB "root-source.txt") `
    "Update Only skips a missing root-level file."

Assert-FileExists `
    (Join-Path $paths.TargetC "root-source.txt") `
    "Add + Update adds a missing root-level file."

# ============================================================
# TEST 2: Cancellation gate
# ============================================================

Write-TestHeader "Cancellation prevents mutation"

$paths = Reset-WorkingTree
$config = Join-Path $Tmp "cancel.config.json"
Write-ConfigFile -Path $config -Profile (New-MixedPolicyProfile -Paths $paths)

$beforeA = Get-Content -LiteralPath (Join-Path $paths.TargetA "shared-update\version.txt") -Raw -Encoding UTF8
$beforeB = Get-Content -LiteralPath (Join-Path $paths.TargetB "shared-update\version.txt") -Raw -Encoding UTF8
$beforeC = Get-Content -LiteralPath (Join-Path $paths.TargetC "shared-update\version.txt") -Raw -Encoding UTF8

$result = Invoke-MimicChild -ConfigPath $config -Answer "n"

Assert-True ($result.ExitCode -eq 0) "Cancellation returns a non-error exit code."

Assert-FileMissing `
    (Join-Path $paths.TargetA "shared-add\new.txt") `
    "Cancellation prevents Add Only additions."

Assert-FileMissing `
    (Join-Path $paths.TargetC "shared-add\new.txt") `
    "Cancellation prevents Add + Update additions."

Assert-True `
    -Condition (-not (Test-Path -LiteralPath (Join-Path $paths.TargetC "nested folder"))) `
    -Message "Cancellation prevents directory creation before confirmation."

Assert-FileContent `
    (Join-Path $paths.TargetA "shared-update\version.txt") `
    $beforeA `
    "Cancellation leaves Add Only target unchanged."

Assert-FileContent `
    (Join-Path $paths.TargetB "shared-update\version.txt") `
    $beforeB `
    "Cancellation prevents Update Only writes."

Assert-FileContent `
    (Join-Path $paths.TargetC "shared-update\version.txt") `
    $beforeC `
    "Cancellation prevents Add + Update writes."

# ============================================================
# TEST 3: Repeat run / no-change behavior for applicable policy
# ============================================================

Write-TestHeader "Repeated synchronization remains safe"

$paths = Reset-WorkingTree
$config = Join-Path $Tmp "repeat.config.json"
Write-ConfigFile -Path $config -Profile (New-MixedPolicyProfile -Paths $paths)

$first = Invoke-MimicChild -ConfigPath $config -Answer "Y"
$second = Invoke-MimicChild -ConfigPath $config -Answer "Y"

Assert-True ($first.ExitCode -eq 0) "First synchronization succeeds."
Assert-True ($second.ExitCode -eq 0) "Repeated synchronization succeeds."

Assert-FileContent `
    (Join-Path $paths.TargetA "local-only\private.txt") `
    "target-a-private`n" `
    "Repeated runs continue preserving Add Only target-only content."

Assert-FileContent `
    (Join-Path $paths.TargetB "local-only\private.txt") `
    "target-b-private`n" `
    "Repeated runs continue preserving Update Only target-only content."

Assert-FileContent `
    (Join-Path $paths.TargetC "local-only\private.txt") `
    "target-c-private`n" `
    "Repeated runs continue preserving Add + Update target-only content."

# ============================================================
# TEST 4: Invalid source
# ============================================================

Write-TestHeader "Invalid Source fails before mutation"

$paths = Reset-WorkingTree
$config = Join-Path $Tmp "invalid-source.config.json"

$invalidProfile = [ordered]@{
    source = (Join-Path $Tmp "does-not-exist")
    targets = @(
        [ordered]@{
            name = "Target"
            path = $paths.TargetA
            mode = "add-update"
        }
    )
}

Write-ConfigFile -Path $config -Profile $invalidProfile

$before = Get-Content -LiteralPath (Join-Path $paths.TargetA "shared-update\version.txt") -Raw -Encoding UTF8
$result = Invoke-MimicChild -ConfigPath $config -Answer "Y"

Assert-True ($result.ExitCode -ne 0) "Missing Source returns a failure exit code."

Assert-FileContent `
    (Join-Path $paths.TargetA "shared-update\version.txt") `
    $before `
    "Missing Source causes no Target mutation."

Assert-FileMissing `
    (Join-Path $paths.TargetA "shared-add\new.txt") `
    "Missing Source does not add files."

# ============================================================
# TEST 5: Unsafe Source/Target nesting
# ============================================================

Write-TestHeader "Unsafe path relationship is rejected"

$paths = Reset-WorkingTree
$unsafeTarget = Join-Path $paths.Source "Target Inside Source"
[void](New-Item -ItemType Directory -Path $unsafeTarget -Force)

$config = Join-Path $Tmp "unsafe.config.json"
$unsafeProfile = [ordered]@{
    source = $paths.Source
    targets = @(
        [ordered]@{
            name = "Unsafe Target"
            path = $unsafeTarget
            mode = "add-update"
        }
    )
}

Write-ConfigFile -Path $config -Profile $unsafeProfile
$result = Invoke-MimicChild -ConfigPath $config -Answer "Y"

Assert-True ($result.ExitCode -ne 0) "Target inside Source is rejected."


# ============================================================
# TEST 6: Malformed JSON
# ============================================================

Write-TestHeader "Malformed JSON is rejected"

$paths = Reset-WorkingTree
$config = Join-Path $Tmp "malformed.config.json"
[System.IO.File]::WriteAllText($config, '{ "source": ', (New-Object System.Text.UTF8Encoding($false)))
$result = Invoke-MimicChild -ConfigPath $config -Answer "Y"

Assert-True ($result.ExitCode -ne 0) "Malformed JSON returns a failure exit code."
Assert-FileMissing (Join-Path $paths.TargetA "shared-add\new.txt") "Malformed JSON causes no Target mutation."

# ============================================================
# TEST 7: Unsupported mode
# ============================================================

Write-TestHeader "Unsupported synchronization mode is rejected"

$paths = Reset-WorkingTree
$config = Join-Path $Tmp "bad-mode.config.json"
$badModeProfile = [ordered]@{
    source = $paths.Source
    targets = @(
        [ordered]@{
            name = "Target"
            path = $paths.TargetA
            mode = "mirror"
        }
    )
}
Write-ConfigFile -Path $config -Profile $badModeProfile
$result = Invoke-MimicChild -ConfigPath $config -Answer "Y"

Assert-True ($result.ExitCode -ne 0) "Unsupported mode returns a failure exit code."
Assert-FileMissing (Join-Path $paths.TargetA "shared-add\new.txt") "Unsupported mode causes no Target mutation."

# ============================================================
# TEST 8: File/directory path-type conflict
# ============================================================

Write-TestHeader "Path-type conflict blocks the run before mutation"

$paths = Reset-WorkingTree
$conflictPath = Join-Path $paths.TargetC "shared-add"
[System.IO.File]::WriteAllText($conflictPath, "conflict-file", (New-Object System.Text.UTF8Encoding($false)))
$config = Join-Path $Tmp "path-conflict.config.json"
$conflictProfile = [ordered]@{
    source = $paths.Source
    targets = @(
        [ordered]@{
            name = "Conflict Target"
            path = $paths.TargetC
            mode = "add-update"
        }
    )
}
Write-ConfigFile -Path $config -Profile $conflictProfile
$result = Invoke-MimicChild -ConfigPath $config -Answer "Y"

Assert-True ($result.ExitCode -ne 0) "File/directory collision returns a failure exit code."
Assert-FileContent (Join-Path $paths.TargetC "shared-update\version.txt") "target-old`n" "Conflict blocks unrelated updates in the same run."

# ============================================================
# TEST 9: Source equals Target
# ============================================================

Write-TestHeader "Source and Target cannot be identical"

$paths = Reset-WorkingTree
$config = Join-Path $Tmp "same-path.config.json"
$samePathProfile = [ordered]@{
    source = $paths.Source
    targets = @(
        [ordered]@{
            name = "Same Path"
            path = $paths.Source
            mode = "add-update"
        }
    )
}
Write-ConfigFile -Path $config -Profile $samePathProfile
$result = Invoke-MimicChild -ConfigPath $config -Answer "Y"
Assert-True ($result.ExitCode -ne 0) "Source == Target is rejected."

# ============================================================
# TEST 10: Source inside Target
# ============================================================

Write-TestHeader "Source inside Target is rejected"

$paths = Reset-WorkingTree
$outerTarget = Split-Path -Parent $paths.Source
$config = Join-Path $Tmp "source-inside-target.config.json"
$sourceInsideProfile = [ordered]@{
    source = $paths.Source
    targets = @(
        [ordered]@{
            name = "Outer Target"
            path = $outerTarget
            mode = "add-update"
        }
    )
}
Write-ConfigFile -Path $config -Profile $sourceInsideProfile
$result = Invoke-MimicChild -ConfigPath $config -Answer "Y"
Assert-True ($result.ExitCode -ne 0) "Source inside Target is rejected."

# ============================================================
# TEST 11: Overlapping Targets
# ============================================================

Write-TestHeader "Overlapping Targets are rejected"

$paths = Reset-WorkingTree
$nestedTarget = Join-Path $paths.TargetA "Nested Target"
[void](New-Item -ItemType Directory -Path $nestedTarget -Force)
$config = Join-Path $Tmp "overlap.config.json"
$overlapProfile = [ordered]@{
    source = $paths.Source
    targets = @(
        [ordered]@{
            name = "Outer"
            path = $paths.TargetA
            mode = "add-update"
        },
        [ordered]@{
            name = "Inner"
            path = $nestedTarget
            mode = "add-update"
        }
    )
}
Write-ConfigFile -Path $config -Profile $overlapProfile
$result = Invoke-MimicChild -ConfigPath $config -Answer "Y"
Assert-True ($result.ExitCode -ne 0) "Nested/overlapping Targets are rejected."

# ============================================================
# TEST 12: Duplicate Target definitions
# ============================================================

Write-TestHeader "Duplicate Target definitions are rejected"

$paths = Reset-WorkingTree
$config = Join-Path $Tmp "duplicate-target.config.json"
$duplicateProfile = [ordered]@{
    source = $paths.Source
    targets = @(
        [ordered]@{
            name = "Duplicate"
            path = $paths.TargetA
            mode = "add-only"
        },
        [ordered]@{
            name = "Duplicate"
            path = $paths.TargetB
            mode = "add-update"
        }
    )
}
Write-ConfigFile -Path $config -Profile $duplicateProfile
$result = Invoke-MimicChild -ConfigPath $config -Answer "Y"
Assert-True ($result.ExitCode -ne 0) "Duplicate Target names are rejected."

$duplicatePathProfile = [ordered]@{
    source = $paths.Source
    targets = @(
        [ordered]@{
            name = "First"
            path = $paths.TargetA
            mode = "add-only"
        },
        [ordered]@{
            name = "Second"
            path = $paths.TargetA
            mode = "add-update"
        }
    )
}
Write-ConfigFile -Path $config -Profile $duplicatePathProfile
$result = Invoke-MimicChild -ConfigPath $config -Answer "Y"
Assert-True ($result.ExitCode -ne 0) "Duplicate Target paths are rejected."

# ============================================================
# TEST 13: Empty Source is a safe no-op
# ============================================================

Write-TestHeader "Empty Source preserves Target-only content"

$paths = Reset-WorkingTree
$emptySource = Join-Path $Tmp "Empty Source"
[void](New-Item -ItemType Directory -Path $emptySource -Force)
$config = Join-Path $Tmp "empty-source.config.json"
$emptyProfile = [ordered]@{
    source = $emptySource
    targets = @(
        [ordered]@{
            name = "Existing Target"
            path = $paths.TargetA
            mode = "add-update"
        }
    )
}
Write-ConfigFile -Path $config -Profile $emptyProfile
$privateBefore = Get-Content -LiteralPath (Join-Path $paths.TargetA "local-only\private.txt") -Raw -Encoding UTF8
$result = Invoke-MimicChild -ConfigPath $config -Answer "Y"
Assert-True ($result.ExitCode -eq 0) "Empty Source completes as a no-op."
Assert-FileContent (Join-Path $paths.TargetA "local-only\private.txt") $privateBefore "Empty Source preserves Target-only content."

# ============================================================
# TEST 14: Locked update fails without corrupting the Target
# ============================================================

Write-TestHeader "Execution failure reports safely and preserves locked Target"

$paths = Reset-WorkingTree
$config = Join-Path $Tmp "locked-target.config.json"
$lockedProfile = [ordered]@{
    source = $paths.Source
    targets = @(
        [ordered]@{
            name = "Locked Target"
            path = $paths.TargetB
            mode = "update-only"
        }
    )
}
Write-ConfigFile -Path $config -Profile $lockedProfile
$lockedPath = Join-Path $paths.TargetB "shared-update\version.txt"
$lockedBefore = Get-Content -LiteralPath $lockedPath -Raw -Encoding UTF8
$stream = [System.IO.File]::Open($lockedPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
try {
    $result = Invoke-MimicChild -ConfigPath $config -Answer "Y"
}
finally {
    $stream.Dispose()
}
Assert-True ($result.ExitCode -ne 0) "Locked Target produces a failure exit code."
Assert-FileContent $lockedPath $lockedBefore "Locked Target content remains intact after failed UPDATE."
Assert-NoMimicTempFiles -Root $paths.TargetB -Message "Failed UPDATE cleans up Mimic Sync temp files."

# ============================================================
# TEST 15: Reparse-point ancestor rejection (NTFS/Junction capable)
# ============================================================

Write-TestHeader "Reparse-point ancestors are rejected"

$paths = Reset-WorkingTree
$realContainer = Join-Path $Tmp "Real Junction Container"
$realTarget = Join-Path $realContainer "Target Through Junction"
[void](New-Item -ItemType Directory -Path $realTarget -Force)
$junctionRoot = Join-Path $Tmp "Junction Root"

if (Try-NewDirectoryJunction -LinkPath $junctionRoot -DestinationPath $realContainer) {
    $junctionTarget = Join-Path $junctionRoot "Target Through Junction"
    $config = Join-Path $Tmp "junction-ancestor.config.json"
    $junctionProfile = [ordered]@{
        source = $paths.Source
        targets = @(
            [ordered]@{
                name = "Junction Target"
                path = $junctionTarget
                mode = "add-update"
            }
        )
    }
    Write-ConfigFile -Path $config -Profile $junctionProfile
    $result = Invoke-MimicChild -ConfigPath $config -Answer "Y"
    Assert-True ($result.ExitCode -ne 0) "Target path below a Junction ancestor is rejected."
    Assert-FileMissing (Join-Path $realTarget "shared-add\new.txt") "Junction rejection prevents writes to the physical destination."
}
else {
    Write-Host "SKIP  Junction creation is unavailable on this filesystem/environment." -ForegroundColor Yellow
}

# ============================================================
# TEST 16: Nested Target Junction blocks the complete run
# ============================================================

Write-TestHeader "Nested Target reparse point blocks writes"

$paths = Reset-WorkingTree
$external = Join-Path $Tmp "External Destination"
$junction = Join-Path $paths.TargetC "shared-add"

if (Try-NewDirectoryJunction -LinkPath $junction -DestinationPath $external) {
    $config = Join-Path $Tmp "nested-junction.config.json"
    $junctionProfile = [ordered]@{
        source = $paths.Source
        targets = @(
            [ordered]@{
                name = "Nested Junction Target"
                path = $paths.TargetC
                mode = "add-update"
            }
        )
    }
    Write-ConfigFile -Path $config -Profile $junctionProfile
    $result = Invoke-MimicChild -ConfigPath $config -Answer "Y"
    Assert-True ($result.ExitCode -ne 0) "Nested Target Junction blocks the run before mutation."
    Assert-FileMissing (Join-Path $external "new.txt") "Nested Junction is not traversed or written through."
    Assert-FileContent (Join-Path $paths.TargetC "shared-update\version.txt") "target-old`n" "Junction conflict blocks unrelated updates in the same run."
}
else {
    Write-Host "SKIP  Junction creation is unavailable on this filesystem/environment." -ForegroundColor Yellow
}

# ============================================================
# Summary
# ============================================================

Write-Host ""
Write-Host ("=" * 72) -ForegroundColor Cyan
Write-Host "TEST SUMMARY" -ForegroundColor Cyan
Write-Host ("=" * 72) -ForegroundColor Cyan
Write-Host ("Passed assertions: {0}" -f $script:Passed) -ForegroundColor Green

if ($script:Failed -gt 0) {
    Write-Host ("Failed assertions: {0}" -f $script:Failed) -ForegroundColor Red
    Write-Host ""
    Write-Host "Mimic Sync V1 verification FAILED." -ForegroundColor Red
    exit 1
}

Write-Host "Failed assertions: 0" -ForegroundColor Green
Write-Host ""
Write-Host "Mimic Sync V1 fixture verification PASSED." -ForegroundColor Green
exit 0
