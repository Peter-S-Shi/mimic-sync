[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Config
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# ============================================================
# Mimic Sync V1
# Configuration-driven, one-way folder replication for Windows.
#
# Supported per-target modes:
#   - add-only
#   - update-only
#   - add-update
#
# Safety contract:
#   - No automatic deletion
#   - No purge / mirror semantics
#   - No target-only modification
#   - No write before explicit Y/n confirmation
# ============================================================

if ([string]::IsNullOrWhiteSpace($Config)) {
    $Config = Join-Path $PSScriptRoot "mimic-sync.config.json"
}

$script:SupportedModes = @(
    "add-only",
    "update-only",
    "add-update"
)

function Write-Section {
    param([string]$Title)

    Write-Host ""
    Write-Host ("=" * 64) -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ("=" * 64) -ForegroundColor Cyan
}

function Write-Fatal {
    param([string]$Message)

    Write-Host ""
    Write-Host "ERROR: $Message" -ForegroundColor Red
}

function Normalize-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)

    if ($full.Length -gt 3) {
        $full = $full.TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        )
    }

    return $full
}

function Resolve-ConfiguredPath {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$BaseDirectory
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($Value)

    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return Normalize-FullPath -Path $expanded
    }

    return Normalize-FullPath -Path (Join-Path $BaseDirectory $expanded)
}

function Test-PathEqual {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    return [string]::Equals(
        (Normalize-FullPath $Left),
        (Normalize-FullPath $Right),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Test-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Child,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    $childFull = Normalize-FullPath $Child
    $parentFull = Normalize-FullPath $Parent

    if (Test-PathEqual $childFull $parentFull) {
        return $false
    }

    $prefix = $parentFull + [System.IO.Path]::DirectorySeparatorChar

    return $childFull.StartsWith(
        $prefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Test-IsReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-FirstReparsePointInExistingPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    # V1 deliberately avoids Junction / symlink traversal. Checking only the
    # configured root is insufficient because a normal-looking child path may
    # itself live below a reparse-point ancestor. Walk upward through every
    # existing component and reject the first reparse point we encounter.
    $current = Normalize-FullPath -Path $Path
    $visited = @{}

    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $key = $current.ToLowerInvariant()
        if ($visited.ContainsKey($key)) {
            break
        }
        $visited[$key] = $true

        if (Test-Path -LiteralPath $current) {
            if (Test-IsReparsePoint -Path $current) {
                return $current
            }
        }

        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent)) {
            break
        }

        $parent = Normalize-FullPath -Path $parent
        if (Test-PathEqual -Left $parent -Right $current) {
            break
        }

        $current = $parent
    }

    return $null
}

function Test-RelativePathAtOrBelow {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    if ([string]::Equals($Path, $Parent, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $prefix = $Parent + [System.IO.Path]::DirectorySeparatorChar
    return $Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Read-SyncConfirmation {
    while ($true) {
        $answer = Read-Host "Proceed with sync? [Y/n]"

        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $true
        }

        switch ($answer.Trim().ToLowerInvariant()) {
            "y"   { return $true }
            "yes" { return $true }
            "n"   { return $false }
            "no"  { return $false }
            default {
                Write-Host "Please enter Y, Yes, N, No, or press Enter for Yes." -ForegroundColor Yellow
            }
        }
    }
}

function Get-RelativePathFromRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$FullPath
    )

    $rootFull = Normalize-FullPath $Root
    $itemFull = Normalize-FullPath $FullPath

    if (Test-PathEqual $rootFull $itemFull) {
        return ""
    }

    $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar

    if (-not $itemFull.StartsWith(
        $prefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Path '$itemFull' is not inside root '$rootFull'."
    }

    return $itemFull.Substring($prefix.Length)
}

function Get-Inventory {
    param(
        [Parameter(Mandatory = $true)][string]$Root
    )

    $directories = New-Object System.Collections.Generic.List[object]
    $files = New-Object System.Collections.Generic.List[object]
    $reparsePoints = New-Object System.Collections.Generic.List[object]

    $stack = New-Object System.Collections.Stack
    $stack.Push((Get-Item -LiteralPath $Root -Force))

    while ($stack.Count -gt 0) {
        $current = $stack.Pop()

        $children = Get-ChildItem -LiteralPath $current.FullName -Force

        foreach ($child in $children) {
            $isReparse = (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)

            if ($isReparse) {
                $reparsePoints.Add([pscustomobject]@{
                    FullPath     = $child.FullName
                    RelativePath = Get-RelativePathFromRoot -Root $Root -FullPath $child.FullName
                    IsDirectory  = [bool]$child.PSIsContainer
                })
                continue
            }

            if ($child.PSIsContainer) {
                $directories.Add([pscustomobject]@{
                    FullPath     = $child.FullName
                    RelativePath = Get-RelativePathFromRoot -Root $Root -FullPath $child.FullName
                })

                $stack.Push($child)
            }
            else {
                $files.Add([pscustomobject]@{
                    FullPath     = $child.FullName
                    RelativePath = Get-RelativePathFromRoot -Root $Root -FullPath $child.FullName
                    Length       = [int64]$child.Length
                })
            }
        }
    }

    return [pscustomobject]@{
        Directories   = $directories
        Files         = $files
        ReparsePoints = $reparsePoints
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Test-FileHashEquals {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedHash
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    return (Get-FileSha256 -Path $Path) -eq $ExpectedHash
}

function New-TemporarySiblingPath {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$Purpose
    )

    $parent = Split-Path -Parent $TargetPath
    $token = [Guid]::NewGuid().ToString('N')
    return Join-Path $parent ('.mimic-sync-{0}-{1}.tmp' -f $Purpose, $token)
}

function New-TargetPlan {
    param(
        [Parameter(Mandatory = $true)][object]$Target,
        [Parameter(Mandatory = $true)][object]$SourceInventory
    )

    $targetPath = $Target.ResolvedPath
    $mode = $Target.Mode

    $actions = New-Object System.Collections.Generic.List[object]
    $conflicts = New-Object System.Collections.Generic.List[object]

    $policySkippedMissing = 0
    $policySkippedDifferent = 0

    $targetInventory = Get-Inventory -Root $targetPath
    $blockedReparsePaths = @($targetInventory.ReparsePoints | ForEach-Object { $_.RelativePath })
    $reportedReparseConflicts = @{}

    # --------------------------------------------------------
    # Directory structure
    # --------------------------------------------------------
    foreach ($sourceDir in ($SourceInventory.Directories | Sort-Object RelativePath)) {
        $relative = $sourceDir.RelativePath
        $targetItem = Join-Path $targetPath $relative

        $blockingReparse = $null
        foreach ($reparsePath in $blockedReparsePaths) {
            if (Test-RelativePathAtOrBelow -Path $relative -Parent $reparsePath) {
                $blockingReparse = $reparsePath
                break
            }
        }

        if ($null -ne $blockingReparse) {
            $key = $blockingReparse.ToLowerInvariant()
            if (-not $reportedReparseConflicts.ContainsKey($key)) {
                $reportedReparseConflicts[$key] = $true
                $conflicts.Add([pscustomobject]@{
                    RelativePath = $blockingReparse
                    Reason       = "Target path is a reparse point. V1 will not traverse or write through it."
                })
            }
            continue
        }

        if (Test-Path -LiteralPath $targetItem) {
            $targetExisting = Get-Item -LiteralPath $targetItem -Force

            if (-not $targetExisting.PSIsContainer) {
                $conflicts.Add([pscustomobject]@{
                    RelativePath = $relative
                    Reason       = "Source expects a directory but Target contains a file."
                })
            }

            continue
        }

        if ($mode -eq "add-only" -or $mode -eq "add-update") {
            $actions.Add([pscustomobject]@{
                Action       = "ADD-DIR"
                RelativePath = $relative
                SourcePath   = $sourceDir.FullPath
                TargetPath   = $targetItem
            })
        }
        else {
            $policySkippedMissing++
        }
    }

    # --------------------------------------------------------
    # Files
    # --------------------------------------------------------
    foreach ($sourceFile in ($SourceInventory.Files | Sort-Object RelativePath)) {
        $relative = $sourceFile.RelativePath
        $targetItem = Join-Path $targetPath $relative

        $blockingReparse = $null
        foreach ($reparsePath in $blockedReparsePaths) {
            if (Test-RelativePathAtOrBelow -Path $relative -Parent $reparsePath) {
                $blockingReparse = $reparsePath
                break
            }
        }

        if ($null -ne $blockingReparse) {
            $key = $blockingReparse.ToLowerInvariant()
            if (-not $reportedReparseConflicts.ContainsKey($key)) {
                $reportedReparseConflicts[$key] = $true
                $conflicts.Add([pscustomobject]@{
                    RelativePath = $blockingReparse
                    Reason       = "Target path is a reparse point. V1 will not traverse or write through it."
                })
            }
            continue
        }

        if (-not (Test-Path -LiteralPath $targetItem)) {
            if ($mode -eq "add-only" -or $mode -eq "add-update") {
                $actions.Add([pscustomobject]@{
                    Action            = "ADD"
                    RelativePath      = $relative
                    SourcePath        = $sourceFile.FullPath
                    TargetPath        = $targetItem
                    PlannedSourceHash = Get-FileSha256 -Path $sourceFile.FullPath
                })
            }
            else {
                $policySkippedMissing++
            }

            continue
        }

        $targetExisting = Get-Item -LiteralPath $targetItem -Force

        if ($targetExisting.PSIsContainer) {
            $conflicts.Add([pscustomobject]@{
                RelativePath = $relative
                Reason       = "Source expects a file but Target contains a directory."
            })
            continue
        }

        $sourceHash = Get-FileSha256 -Path $sourceFile.FullPath
        $targetHash = Get-FileSha256 -Path $targetItem

        if ($sourceHash -eq $targetHash) {
            continue
        }

        if ($mode -eq "update-only" -or $mode -eq "add-update") {
            $actions.Add([pscustomobject]@{
                Action            = "UPDATE"
                RelativePath      = $relative
                SourcePath        = $sourceFile.FullPath
                TargetPath        = $targetItem
                PlannedSourceHash = $sourceHash
                PlannedTargetHash = $targetHash
            })
        }
        else {
            $policySkippedDifferent++
        }
    }

    # --------------------------------------------------------
    # Count target-only files for an informative, non-actionable
    # summary. Reparse points are skipped deliberately in V1.
    # --------------------------------------------------------
    $sourceFileSet = @{}
    foreach ($file in $SourceInventory.Files) {
        $sourceFileSet[$file.RelativePath.ToLowerInvariant()] = $true
    }

    $targetOnlyFiles = 0

    foreach ($targetFile in $targetInventory.Files) {
        $key = $targetFile.RelativePath.ToLowerInvariant()
        if (-not $sourceFileSet.ContainsKey($key)) {
            $targetOnlyFiles++
        }
    }

    return [pscustomobject]@{
        Name                   = $Target.Name
        Path                   = $targetPath
        Mode                   = $mode
        Actions                = $actions
        Conflicts              = $conflicts
        PolicySkippedMissing   = $policySkippedMissing
        PolicySkippedDifferent = $policySkippedDifferent
        TargetOnlyFiles        = $targetOnlyFiles
        SkippedReparsePoints   = $targetInventory.ReparsePoints.Count
    }
}

function Show-TargetPlan {
    param([Parameter(Mandatory = $true)][object]$Plan)

    Write-Host ""
    Write-Host ("Target: {0}" -f $Plan.Name) -ForegroundColor White
    Write-Host ("Path:   {0}" -f $Plan.Path) -ForegroundColor DarkGray
    Write-Host ("Mode:   {0}" -f $Plan.Mode) -ForegroundColor DarkGray

    if ($Plan.Conflicts.Count -gt 0) {
        Write-Host ""
        Write-Host "  PATH CONFLICTS" -ForegroundColor Red
        foreach ($conflict in $Plan.Conflicts) {
            Write-Host ("  [CONFLICT] {0}" -f $conflict.RelativePath) -ForegroundColor Red
            Write-Host ("             {0}" -f $conflict.Reason) -ForegroundColor DarkRed
        }
        return
    }

    $fileActions = @(
        $Plan.Actions |
            Where-Object { $_.Action -eq "ADD" -or $_.Action -eq "UPDATE" } |
            Sort-Object RelativePath, Action
    )
    $directoryActions = @(
        $Plan.Actions |
            Where-Object { $_.Action -eq "ADD-DIR" } |
            Sort-Object RelativePath
    )

    if ($fileActions.Count -eq 0 -and $directoryActions.Count -eq 0) {
        Write-Host "  No applicable changes." -ForegroundColor Green
    }
    else {
        # Show the exact relative path instead of collapsing actions to the
        # top-level folder. This avoids ambiguous plans such as:
        #   [ADD] 5
        #   [UPDATE] 5
        # when the real operations affect different files under folder 5.
        foreach ($action in $fileActions) {
            if ($action.Action -eq "ADD") {
                Write-Host ("  [ADD]    {0}" -f $action.RelativePath) -ForegroundColor Green
            }
            elseif ($action.Action -eq "UPDATE") {
                Write-Host ("  [UPDATE] {0}" -f $action.RelativePath) -ForegroundColor Yellow
            }
        }

        foreach ($action in $directoryActions) {
            Write-Host ("  [MKDIR]  {0}" -f $action.RelativePath) -ForegroundColor DarkCyan
        }

        $addFileCount = @($fileActions | Where-Object { $_.Action -eq "ADD" }).Count
        $updateFileCount = @($fileActions | Where-Object { $_.Action -eq "UPDATE" }).Count

        Write-Host ""
        Write-Host ("  Planned files: {0} add, {1} update" -f $addFileCount, $updateFileCount) -ForegroundColor DarkGray

        if ($directoryActions.Count -gt 0) {
            Write-Host ("  Planned directories to create: {0}" -f $directoryActions.Count) -ForegroundColor DarkGray
        }
    }

    if ($Plan.PolicySkippedMissing -gt 0) {
        Write-Host ("  Skipped missing items by policy: {0}" -f $Plan.PolicySkippedMissing) -ForegroundColor DarkGray
    }

    if ($Plan.PolicySkippedDifferent -gt 0) {
        Write-Host ("  Skipped differing files by policy: {0}" -f $Plan.PolicySkippedDifferent) -ForegroundColor DarkGray
    }

    if ($Plan.TargetOnlyFiles -gt 0) {
        Write-Host ("  Target-only files preserved: {0}" -f $Plan.TargetOnlyFiles) -ForegroundColor DarkGray
    }

    if ($Plan.SkippedReparsePoints -gt 0) {
        Write-Host ("  Reparse-point items skipped during scan: {0}" -f $Plan.SkippedReparsePoints) -ForegroundColor DarkGray
    }
}

function Invoke-TargetPlan {
    param([Parameter(Mandatory = $true)][object]$Plan)

    $added = New-Object System.Collections.Generic.List[string]
    $updated = New-Object System.Collections.Generic.List[string]
    $createdDirs = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[object]

    $orderedActions = @(
        $Plan.Actions |
            Sort-Object @{
                Expression = {
                    if ($_.Action -eq "ADD-DIR") { 0 } else { 1 }
                }
            }, RelativePath
    )

    foreach ($action in $orderedActions) {
        $stagedSource = $null
        $backupTarget = $null
        $targetWriteStarted = $false

        try {
            # Revalidate reparse-point safety at execution time. The filesystem
            # may have changed after the read-only scan and confirmation.
            $targetReparse = Get-FirstReparsePointInExistingPath -Path $action.TargetPath
            if ($null -ne $targetReparse) {
                throw "Target path changed after scan and now passes through a reparse point: $targetReparse"
            }

            switch ($action.Action) {
                "ADD-DIR" {
                    if (-not (Test-Path -LiteralPath $action.SourcePath -PathType Container)) {
                        throw "Source directory changed or disappeared after scan. Run Mimic Sync again."
                    }

                    if (Test-Path -LiteralPath $action.TargetPath) {
                        throw "Target state changed after scan: planned directory path now exists. Run Mimic Sync again."
                    }

                    [void][System.IO.Directory]::CreateDirectory($action.TargetPath)

                    if (-not (Test-Path -LiteralPath $action.TargetPath -PathType Container)) {
                        throw "Directory verification failed after creation."
                    }

                    if (Test-IsReparsePoint -Path $action.TargetPath) {
                        throw "Created directory unexpectedly resolves as a reparse point."
                    }

                    $createdDirs.Add($action.RelativePath)
                }

                "ADD" {
                    if (-not (Test-Path -LiteralPath $action.SourcePath -PathType Leaf)) {
                        throw "Source file changed or disappeared after scan. Run Mimic Sync again."
                    }

                    if (-not (Test-FileHashEquals -Path $action.SourcePath -ExpectedHash $action.PlannedSourceHash)) {
                        throw "Source file changed after scan: $($action.RelativePath). Run Mimic Sync again."
                    }

                    if (Test-Path -LiteralPath $action.TargetPath) {
                        throw "Target state changed after scan: planned ADD path now exists. Run Mimic Sync again."
                    }

                    $parent = Split-Path -Parent $action.TargetPath
                    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                        [void][System.IO.Directory]::CreateDirectory($parent)
                    }

                    $parentReparse = Get-FirstReparsePointInExistingPath -Path $parent
                    if ($null -ne $parentReparse) {
                        throw "Target parent path now passes through a reparse point: $parentReparse"
                    }

                    # Stage the file beside the destination first. This avoids
                    # leaving a partially copied target file if the source copy
                    # fails before the final move.
                    $stagedSource = New-TemporarySiblingPath -TargetPath $action.TargetPath -Purpose "add"
                    Copy-Item -LiteralPath $action.SourcePath -Destination $stagedSource -Force

                    if (-not (Test-FileHashEquals -Path $stagedSource -ExpectedHash $action.PlannedSourceHash)) {
                        throw "Staged ADD verification failed: source content changed during copy."
                    }

                    if (Test-Path -LiteralPath $action.TargetPath) {
                        throw "Target state changed during execution: planned ADD path now exists."
                    }

                    [System.IO.File]::Move($stagedSource, $action.TargetPath)
                    $stagedSource = $null

                    if (-not (Test-FileHashEquals -Path $action.TargetPath -ExpectedHash $action.PlannedSourceHash)) {
                        throw "File verification failed after ADD."
                    }

                    $added.Add($action.RelativePath)
                }

                "UPDATE" {
                    if (-not (Test-Path -LiteralPath $action.SourcePath -PathType Leaf)) {
                        throw "Source file changed or disappeared after scan. Run Mimic Sync again."
                    }

                    if (-not (Test-FileHashEquals -Path $action.SourcePath -ExpectedHash $action.PlannedSourceHash)) {
                        throw "Source file changed after scan: $($action.RelativePath). Run Mimic Sync again."
                    }

                    if (-not (Test-Path -LiteralPath $action.TargetPath -PathType Leaf)) {
                        throw "Target state changed after scan: planned UPDATE file is missing or changed type. Run Mimic Sync again."
                    }

                    if (-not (Test-FileHashEquals -Path $action.TargetPath -ExpectedHash $action.PlannedTargetHash)) {
                        throw "Target file changed after scan: $($action.RelativePath). Refusing to overwrite newer local changes."
                    }

                    $parent = Split-Path -Parent $action.TargetPath
                    $parentReparse = Get-FirstReparsePointInExistingPath -Path $parent
                    if ($null -ne $parentReparse) {
                        throw "Target parent path now passes through a reparse point: $parentReparse"
                    }

                    # Freeze the exact planned source bytes and keep a target
                    # backup so normal copy/verification failures can roll back.
                    $stagedSource = New-TemporarySiblingPath -TargetPath $action.TargetPath -Purpose "source"
                    $backupTarget = New-TemporarySiblingPath -TargetPath $action.TargetPath -Purpose "backup"

                    Copy-Item -LiteralPath $action.SourcePath -Destination $stagedSource -Force
                    if (-not (Test-FileHashEquals -Path $stagedSource -ExpectedHash $action.PlannedSourceHash)) {
                        throw "Staged UPDATE verification failed: source content changed during copy."
                    }

                    Copy-Item -LiteralPath $action.TargetPath -Destination $backupTarget -Force
                    if (-not (Test-FileHashEquals -Path $backupTarget -ExpectedHash $action.PlannedTargetHash)) {
                        throw "Target backup verification failed before UPDATE."
                    }

                    # One final optimistic-concurrency check immediately before
                    # the overwrite.
                    if (-not (Test-FileHashEquals -Path $action.TargetPath -ExpectedHash $action.PlannedTargetHash)) {
                        throw "Target file changed during execution: $($action.RelativePath). Refusing to overwrite it."
                    }

                    $targetWriteStarted = $true
                    Copy-Item -LiteralPath $stagedSource -Destination $action.TargetPath -Force

                    if (-not (Test-FileHashEquals -Path $action.TargetPath -ExpectedHash $action.PlannedSourceHash)) {
                        throw "File verification failed after UPDATE."
                    }

                    $targetWriteStarted = $false
                    $updated.Add($action.RelativePath)
                }

                default {
                    throw "Unsupported planned action '$($action.Action)'."
                }
            }
        }
        catch {
            $message = $_.Exception.Message

            if ($targetWriteStarted -and $null -ne $backupTarget -and (Test-Path -LiteralPath $backupTarget -PathType Leaf)) {
                try {
                    Copy-Item -LiteralPath $backupTarget -Destination $action.TargetPath -Force

                    if (-not (Test-FileHashEquals -Path $action.TargetPath -ExpectedHash $action.PlannedTargetHash)) {
                        throw "Rollback verification failed."
                    }

                    $message = $message + " Target content was restored from the pre-update backup."
                    $targetWriteStarted = $false
                }
                catch {
                    $message = $message + " ROLLBACK FAILED: " + $_.Exception.Message
                }
            }

            $failed.Add([pscustomobject]@{
                Action       = $action.Action
                RelativePath = $action.RelativePath
                Message      = $message
            })
        }
        finally {
            foreach ($tempPath in @($stagedSource, $backupTarget)) {
                if ($null -ne $tempPath -and (Test-Path -LiteralPath $tempPath -PathType Leaf)) {
                    try { Remove-Item -LiteralPath $tempPath -Force } catch {}
                }
            }
        }
    }

    return [pscustomobject]@{
        Name        = $Plan.Name
        Path        = $Plan.Path
        Mode        = $Plan.Mode
        Added       = $added
        Updated     = $updated
        CreatedDirs = $createdDirs
        Failed      = $failed
    }
}

function Show-ExecutionReport {
    param([Parameter(Mandatory = $true)][object[]]$Results)

    Write-Section "SYNC REPORT"

    foreach ($result in $Results) {
        Write-Host ""
        Write-Host ("Target: {0}" -f $result.Name) -ForegroundColor White
        Write-Host ("Mode:   {0}" -f $result.Mode) -ForegroundColor DarkGray

        if (
            $result.Added.Count -eq 0 -and
            $result.Updated.Count -eq 0 -and
            $result.CreatedDirs.Count -eq 0 -and
            $result.Failed.Count -eq 0
        ) {
            Write-Host "  No changes." -ForegroundColor Green
            continue
        }

        if ($result.Added.Count -gt 0) {
            Write-Host ("  Added files: {0}" -f $result.Added.Count) -ForegroundColor Green
            foreach ($item in $result.Added) {
                Write-Host ("    + {0}" -f $item)
            }
        }

        if ($result.Updated.Count -gt 0) {
            Write-Host ("  Updated files: {0}" -f $result.Updated.Count) -ForegroundColor Yellow
            foreach ($item in $result.Updated) {
                Write-Host ("    * {0}" -f $item)
            }
        }

        if ($result.CreatedDirs.Count -gt 0) {
            Write-Host ("  Created directories: {0}" -f $result.CreatedDirs.Count) -ForegroundColor DarkGray
            foreach ($item in ($result.CreatedDirs | Sort-Object)) {
                Write-Host ("    > {0}" -f $item) -ForegroundColor DarkGray
            }
        }

        if ($result.Failed.Count -gt 0) {
            Write-Host ("  Failed: {0}" -f $result.Failed.Count) -ForegroundColor Red
            foreach ($failure in $result.Failed) {
                Write-Host ("    ! [{0}] {1}" -f $failure.Action, $failure.RelativePath) -ForegroundColor Red
                Write-Host ("      {0}" -f $failure.Message) -ForegroundColor DarkRed
            }
        }
    }
}

# ============================================================
# Main
# ============================================================

try {
    Write-Section "MIMIC SYNC"

    $configPath = Normalize-FullPath $Config

    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw ("Config file does not exist: {0}`n" +
               "Use -Config <path>, drag a JSON config onto 'Mimic Sync.bat', " +
               "or place 'mimic-sync.config.json' beside the launcher.") -f $configPath
    }

    Write-Host ("Config: {0}" -f $configPath) -ForegroundColor DarkGray

    $configDirectory = Split-Path -Parent $configPath
    $rawConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8

    try {
        $profile = $rawConfig | ConvertFrom-Json
    }
    catch {
        throw "Config JSON is invalid: $($_.Exception.Message)"
    }

    if ($null -eq $profile.source -or [string]::IsNullOrWhiteSpace([string]$profile.source)) {
        throw "Config must define a non-empty 'source' path."
    }

    if ($null -eq $profile.targets) {
        throw "Config must define a 'targets' array."
    }

    $targetConfigs = @($profile.targets)

    if ($targetConfigs.Count -eq 0) {
        throw "Config must contain at least one target."
    }

    $sourcePath = Resolve-ConfiguredPath -Value ([string]$profile.source) -BaseDirectory $configDirectory

    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        throw "Source directory does not exist: $sourcePath"
    }

    $sourceReparse = Get-FirstReparsePointInExistingPath -Path $sourcePath
    if ($null -ne $sourceReparse) {
        throw "Source path cannot pass through a reparse point in V1: $sourceReparse"
    }

    Write-Host ("Source: {0}" -f $sourcePath) -ForegroundColor White

    $seenNames = @{}
    $seenPaths = @{}
    $targets = New-Object System.Collections.Generic.List[object]

    foreach ($targetConfig in $targetConfigs) {
        if ($null -eq $targetConfig.name -or [string]::IsNullOrWhiteSpace([string]$targetConfig.name)) {
            throw "Every target must define a non-empty 'name'."
        }

        if ($null -eq $targetConfig.path -or [string]::IsNullOrWhiteSpace([string]$targetConfig.path)) {
            throw "Target '$($targetConfig.name)' must define a non-empty 'path'."
        }

        if ($null -eq $targetConfig.mode -or [string]::IsNullOrWhiteSpace([string]$targetConfig.mode)) {
            throw "Target '$($targetConfig.name)' must define a synchronization 'mode'."
        }

        $name = ([string]$targetConfig.name).Trim()
        $mode = ([string]$targetConfig.mode).Trim().ToLowerInvariant()

        if ($script:SupportedModes -notcontains $mode) {
            throw "Target '$name' uses unsupported mode '$mode'. Supported modes: $($script:SupportedModes -join ', ')."
        }

        $targetPath = Resolve-ConfiguredPath -Value ([string]$targetConfig.path) -BaseDirectory $configDirectory

        if (-not (Test-Path -LiteralPath $targetPath -PathType Container)) {
            throw "Target directory does not exist for '$name': $targetPath"
        }

        $targetReparse = Get-FirstReparsePointInExistingPath -Path $targetPath
        if ($null -ne $targetReparse) {
            throw "Target path cannot pass through a reparse point in V1 for '$name': $targetReparse"
        }

        $nameKey = $name.ToLowerInvariant()
        if ($seenNames.ContainsKey($nameKey)) {
            throw "Duplicate target name: '$name'."
        }
        $seenNames[$nameKey] = $true

        $pathKey = $targetPath.ToLowerInvariant()
        if ($seenPaths.ContainsKey($pathKey)) {
            throw "Duplicate target path: '$targetPath'."
        }
        $seenPaths[$pathKey] = $true

        if (Test-PathEqual $sourcePath $targetPath) {
            throw "Source and Target '$name' cannot be the same directory."
        }

        if (Test-PathInside -Child $targetPath -Parent $sourcePath) {
            throw "Unsafe relationship: Target '$name' is inside the Source directory."
        }

        if (Test-PathInside -Child $sourcePath -Parent $targetPath) {
            throw "Unsafe relationship: Source is inside Target '$name'."
        }

        $targets.Add([pscustomobject]@{
            Name         = $name
            ResolvedPath = $targetPath
            Mode         = $mode
        })
    }

    # Reject overlapping targets because one target's writes could affect
    # another target's filesystem state during the same run.
    for ($i = 0; $i -lt $targets.Count; $i++) {
        for ($j = $i + 1; $j -lt $targets.Count; $j++) {
            $left = $targets[$i]
            $right = $targets[$j]

            if (
                (Test-PathInside -Child $left.ResolvedPath -Parent $right.ResolvedPath) -or
                (Test-PathInside -Child $right.ResolvedPath -Parent $left.ResolvedPath)
            ) {
                throw "Unsafe relationship: Targets '$($left.Name)' and '$($right.Name)' overlap by path."
            }
        }
    }

    Write-Section "READ-ONLY SCAN"
    Write-Host "Scanning Source and Targets. No files will be changed during this phase." -ForegroundColor Yellow

    $sourceInventory = Get-Inventory -Root $sourcePath

    if ($sourceInventory.ReparsePoints.Count -gt 0) {
        Write-Host ""
        Write-Host ("Source reparse-point items skipped in V1: {0}" -f $sourceInventory.ReparsePoints.Count) -ForegroundColor Yellow
        foreach ($item in $sourceInventory.ReparsePoints) {
            Write-Host ("  - {0}" -f $item.RelativePath) -ForegroundColor DarkYellow
        }
    }

    $plans = New-Object System.Collections.Generic.List[object]

    foreach ($target in $targets) {
        Write-Host ("Scanning {0}..." -f $target.Name) -ForegroundColor DarkGray
        $plans.Add(
            (New-TargetPlan -Target $target -SourceInventory $sourceInventory)
        )
    }

    Write-Section "SYNC PLAN"

    $hasConflict = $false
    $totalActionCount = 0

    foreach ($plan in $plans) {
        Show-TargetPlan -Plan $plan

        if ($plan.Conflicts.Count -gt 0) {
            $hasConflict = $true
        }

        $totalActionCount += $plan.Actions.Count
    }

    if ($hasConflict) {
        Write-Host ""
        Write-Host "Sync blocked because unsafe target-path conflicts were found." -ForegroundColor Red
        Write-Host "No files were changed." -ForegroundColor Red
        exit 2
    }

    if ($totalActionCount -eq 0) {
        Write-Host ""
        Write-Host "No applicable changes are required under the configured policies." -ForegroundColor Green
        Write-Host "No files were changed." -ForegroundColor Green
        exit 0
    }

    Write-Host ""
    $confirmed = Read-SyncConfirmation

    if (-not $confirmed) {
        Write-Host ""
        Write-Host "Sync cancelled. No files were changed." -ForegroundColor Yellow
        exit 0
    }

    Write-Section "SYNCING"

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($plan in $plans) {
        Write-Host ("Processing {0}..." -f $plan.Name) -ForegroundColor White
        $results.Add((Invoke-TargetPlan -Plan $plan))
    }

    # Windows PowerShell 5.1 can throw "Argument types do not match"
    # when an array subexpression wraps a Generic.List[object].
    # Convert explicitly to a real Object[] before parameter binding.
    $resultArray = [object[]]$results.ToArray()
    Show-ExecutionReport -Results $resultArray

    $failureCount = 0
    foreach ($result in $results) {
        $failureCount += $result.Failed.Count
    }

    Write-Host ""

    if ($failureCount -gt 0) {
        Write-Host ("Sync finished with {0} failed operation(s)." -f $failureCount) -ForegroundColor Red
        exit 1
    }

    Write-Host "Sync finished successfully." -ForegroundColor Green
    exit 0
}
catch {
    Write-Fatal -Message $_.Exception.Message

    if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
        Write-Host ("Location: line {0}" -f $_.InvocationInfo.ScriptLineNumber) -ForegroundColor DarkRed
        if (-not [string]::IsNullOrWhiteSpace($_.InvocationInfo.Line)) {
            Write-Host ("  {0}" -f $_.InvocationInfo.Line.Trim()) -ForegroundColor DarkRed
        }
    }

    Write-Host "No further synchronization actions will be performed." -ForegroundColor Red
    exit 2
}
