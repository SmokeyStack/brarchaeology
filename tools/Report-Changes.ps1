<#
.SYNOPSIS
Summarizes what changed in the tracking folder since the last commit.

.DESCRIPTION
Reads the pending (uncommitted) changes with git and prints a digest:
counts by change type, the busiest packs, added and deleted files, and any
new "identifier" values that appeared in JSON files - a quick way to spot
new blocks, items, entities, and biomes in a Preview drop.

Run it after Extract-Brarchives.ps1, before committing.

.PARAMETER Root
The tracking repository. Defaults to the parent folder of tools\.

.PARAMETER OutFile
Optional path to also write the report as a text file (for pasting into
notes or a changelog draft).

.PARAMETER MaxList
Maximum entries to print per list (default 40).

.EXAMPLE
.\tools\Report-Changes.ps1
#>
[CmdletBinding()]
param(
    [string]$Root = (Split-Path $PSScriptRoot -Parent),
    [string]$OutFile,
    [int]$MaxList = 40
)

$ErrorActionPreference = 'Stop'
$repoRoot = git -C $Root rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0) { throw "'$Root' is not inside a git repository." }

$lines = [System.Collections.Generic.List[string]]::new()
function Out-Line([string]$text = '') { $lines.Add($text); Write-Host $text }

function Format-List([string]$title, [string[]]$items) {
    if ($items.Count -eq 0) { return }
    Out-Line ''
    Out-Line "${title}: $($items.Count)"
    foreach ($item in ($items | Select-Object -First $MaxList)) { Out-Line "  $item" }
    if ($items.Count -gt $MaxList) { Out-Line "  ... and $($items.Count - $MaxList) more" }
}

# --- Tracked changes (modified/added/deleted vs last commit) ------------------
$nameStatus = @(git -C $repoRoot diff HEAD --name-status -M 2>$null)
$modified = @(); $added = @(); $deleted = @(); $renamed = @()
foreach ($row in $nameStatus) {
    $parts = $row -split "`t"
    switch -regex ($parts[0]) {
        '^M' { $modified += $parts[1] }
        '^A' { $added += $parts[1] }
        '^D' { $deleted += $parts[1] }
        '^R' { $renamed += "$($parts[1]) -> $($parts[2])" }
    }
}
$untracked = @(git -C $repoRoot ls-files --others --exclude-standard 2>$null)

Out-Line "=== Pending changes vs last commit ($(git -C $repoRoot log -1 --format='%s' 2>$null)) ==="
Out-Line "Modified: $($modified.Count)   New (tracked): $($added.Count)   New (untracked): $($untracked.Count)   Deleted: $($deleted.Count)   Renamed: $($renamed.Count)"

# --- Busiest packs -------------------------------------------------------------
$byPack = ($modified + $added + $deleted + $untracked) |
    ForEach-Object { ($_ -split '/')[0..([Math]::Min(1, ($_ -split '/').Count - 1))] -join '/' } |
    Group-Object | Sort-Object Count -Descending | Select-Object -First 12
Out-Line ''
Out-Line 'Busiest packs:'
foreach ($g in $byPack) { Out-Line ('  {0,6}  {1}' -f $g.Count, $g.Name) }

# --- Added / deleted files ------------------------------------------------------
Format-List 'New files' (@($added) + @($untracked) | Sort-Object)
Format-List 'Deleted files' ($deleted | Sort-Object)
Format-List 'Renamed files' ($renamed | Sort-Object)

# --- New identifiers in JSON ----------------------------------------------------
# Compares "identifier" values added vs removed in JSON diffs; what remains is
# genuinely new (blocks, items, entities, biomes, ...).
$diffText = git -C $repoRoot diff HEAD -U0 -- '*.json' 2>$null
$addedIds = [System.Collections.Generic.HashSet[string]]::new()
$removedIds = [System.Collections.Generic.HashSet[string]]::new()
foreach ($row in $diffText) {
    if ($row -match '^\+.*"identifier"\s*:\s*"([^"]+)"') { [void]$addedIds.Add($Matches[1]) }
    elseif ($row -match '^-.*"identifier"\s*:\s*"([^"]+)"') { [void]$removedIds.Add($Matches[1]) }
}
$newIds = @($addedIds | Where-Object { -not $removedIds.Contains($_) } | Sort-Object)
$goneIds = @($removedIds | Where-Object { -not $addedIds.Contains($_) } | Sort-Object)
Format-List 'New identifiers' $newIds
Format-List 'Removed identifiers' $goneIds

if ($OutFile) {
    [IO.File]::WriteAllText($OutFile, ($lines -join [Environment]::NewLine) + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    Write-Host ''
    Write-Host "Report written to $OutFile"
}
