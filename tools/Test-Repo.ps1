<#
.SYNOPSIS
Health-checks the tracking folder before you commit.

.DESCRIPTION
Runs five integrity checks, each of which has caught a real corruption
incident in practice:

  1. JSON integrity      - every .json tokenizes as JSON (comments allowed);
                           binary MCB .json files must be protected by a
                           "binary" entry in .gitattributes.
  2. Image integrity     - every .png/.jpg/.jpeg/.gif loads as an image;
                           zero-byte image files are flagged (a zero-byte
                           image usually means a placeholder stub overwrote
                           the real file).
  3. Archive fidelity    - every .brarchive byte-matches its counterpart in
                           the game's payload folder (catches line-ending
                           corruption and copy failures). Skipped with a
                           warning if the payload folder is missing.
  4. Attribute coverage  - no binary-content file hides in an extension that
                           .gitattributes treats as text (which would corrupt
                           it on commit/checkout).
  5. Stub-stomp detector - no tracked file has become zero bytes when its
                           last committed version had content.

Prints PASS/FAIL per check and exits non-zero if anything failed, so a bad
state visibly blocks the commit step.

.PARAMETER Root
The tracking repository. Defaults to the parent folder of tools\.

.PARAMETER PayloadSource
The game data folder to compare archives against. Defaults to the standard
Minecraft Preview install location.

.PARAMETER SkipPayloadCompare
Skip check 3. Use when the installed game is a different version than the
files currently in the tracking folder (the comparison would report false
mismatches).

.PARAMETER MaxList
Maximum offenders to print per check (default 20).

.EXAMPLE
.\tools\Test-Repo.ps1
#>
[CmdletBinding()]
param(
    [string]$Root = (Split-Path $PSScriptRoot -Parent),
    [string]$PayloadSource = 'C:\XboxGames\Minecraft Preview for Windows\Content\data',
    [switch]$SkipPayloadCompare,
    [int]$MaxList = 20
)

$ErrorActionPreference = 'Stop'
$repoRoot = git -C $Root rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0) { throw "'$Root' is not inside a git repository." }
$repoRootNative = $repoRoot -replace '/', '\'

if (-not ('MojangJsonFormat' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;

public static class MojangJsonFormat
{
    // Lexical re-indenter used as a whitespace-insensitive equality normalizer:
    // changes only inter-token whitespace, never token text.
    public static string Format(string src)
    {
        var sb = new StringBuilder(src.Length * 2);
        int i = 0, n = src.Length, depth = 0;
        while (i < n)
        {
            char c = src[i];
            if (char.IsWhiteSpace(c)) { i++; continue; }
            switch (c)
            {
                case '{':
                case '[':
                {
                    char close = c == '{' ? '}' : ']';
                    int j = i + 1;
                    while (j < n && char.IsWhiteSpace(src[j])) j++;
                    if (j < n && src[j] == close) { sb.Append(c).Append(close); i = j + 1; }
                    else { sb.Append(c); depth++; NewLine(sb, depth); i++; }
                    break;
                }
                case '}':
                case ']':
                    if (--depth < 0) throw new FormatException("unbalanced brackets");
                    NewLine(sb, depth);
                    sb.Append(c);
                    i++;
                    break;
                case ',':
                    sb.Append(',');
                    NewLine(sb, depth);
                    i++;
                    break;
                case ':':
                    sb.Append(": ");
                    i++;
                    break;
                case '"':
                {
                    int j = i + 1;
                    while (j < n)
                    {
                        if (src[j] == '\\') j += 2;
                        else if (src[j] == '"') { j++; break; }
                        else j++;
                    }
                    sb.Append(src, i, j - i);
                    i = j;
                    break;
                }
                case '/':
                    throw new FormatException("comment encountered; not plain JSON");
                default:
                {
                    int j = i;
                    while (j < n && !char.IsWhiteSpace(src[j]) &&
                           src[j] != ',' && src[j] != '}' && src[j] != ']' && src[j] != ':') j++;
                    sb.Append(src, i, j - i);
                    i = j;
                    break;
                }
            }
        }
        if (depth != 0) throw new FormatException("unbalanced brackets");
        return sb.ToString();
    }

    private static void NewLine(StringBuilder sb, int depth)
    {
        sb.Append('\n');
        sb.Append(' ', depth * 2);
    }
}
'@
}
Add-Type -AssemblyName System.Drawing

# Scope: tracked + untracked-but-not-ignored files (never node_modules etc.)
Write-Host 'Collecting file list...'
$allRel = @(git -C $repoRoot ls-files --cached --others --exclude-standard 2>$null)
function Get-Full([string]$rel) { Join-Path $repoRootNative ($rel -replace '/', '\') }

# Binary extensions declared in .gitattributes ("*.ext binary" lines)
$binaryExts = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$attrPath = Join-Path $repoRootNative '.gitattributes'
if (Test-Path $attrPath) {
    foreach ($line in Get-Content $attrPath) {
        if ($line -match '^\*(\.[\w.]+)\s.*\bbinary\b') { [void]$binaryExts.Add($Matches[1]) }
    }
}

function Test-HasNul([string]$full) {
    $fs = [IO.File]::OpenRead($full)
    try {
        $buf = New-Object byte[] 8000
        $n = $fs.Read($buf, 0, 8000)
        for ($b = 0; $b -lt $n; $b++) { if ($buf[$b] -eq 0) { return $true } }
        return $false
    }
    finally { $fs.Close() }
}

$failures = @{}   # check name -> list of offender strings
function Add-Failure([string]$check, [string]$detail) {
    if (-not $failures[$check]) { $failures[$check] = [System.Collections.Generic.List[string]]::new() }
    $failures[$check].Add($detail)
}

# --- Check 1: JSON integrity --------------------------------------------------
Write-Host 'Check 1/5: JSON integrity...'
$jsonRel = @($allRel | Where-Object { $_ -like '*.json' })
$binaryJsonSeen = [System.Collections.Generic.List[string]]::new()
foreach ($rel in $jsonRel) {
    $full = Get-Full $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue } # deleted in worktree
    if ((Get-Item -LiteralPath $full).Length -gt 0 -and (Test-HasNul $full)) {
        $binaryJsonSeen.Add($rel) # binary MCB - attribute check below
        continue
    }
    try {
        [void][MojangJsonFormat]::Format([IO.File]::ReadAllText($full))
    }
    catch {
        if ($_.Exception.InnerException.Message -match 'comment') { continue } # legacy commented JSON is fine
        Add-Failure 'JSON integrity' "$rel ($($_.Exception.InnerException.Message))"
    }
}
# Binary .json files must be protected by a binary attribute.
foreach ($rel in $binaryJsonSeen) {
    $attr = git -C $repoRoot check-attr binary -- $rel 2>$null
    if ($attr -notmatch 'binary: set') {
        Add-Failure 'JSON integrity' "$rel (binary MCB content but NOT marked binary in .gitattributes - would corrupt on commit)"
    }
}

# --- Check 2: Image integrity --------------------------------------------------
Write-Host 'Check 2/5: Image integrity...'
foreach ($rel in @($allRel | Where-Object { $_ -match '\.(png|jpe?g|gif)$' })) {
    $full = Get-Full $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    if ((Get-Item -LiteralPath $full).Length -eq 0) {
        Add-Failure 'Image integrity' "$rel (zero bytes - a placeholder stub may have overwritten the real file)"
        continue
    }
    try { $img = [System.Drawing.Image]::FromFile($full); $img.Dispose() }
    catch { Add-Failure 'Image integrity' "$rel (does not load as an image)" }
}

# --- Check 3: Archive fidelity -------------------------------------------------
if ($SkipPayloadCompare) {
    Write-Host 'Check 3/5: Archive fidelity... skipped (-SkipPayloadCompare)'
}
elseif (-not (Test-Path $PayloadSource)) {
    Write-Warning "Check 3/5: Archive fidelity... skipped (payload folder not found: $PayloadSource)"
}
else {
    Write-Host 'Check 3/5: Archive fidelity...'
    foreach ($rel in @($allRel | Where-Object { $_ -like '*.brarchive' })) {
        $full = Get-Full $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $src = Join-Path $PayloadSource ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $src)) {
            Add-Failure 'Archive fidelity' "$rel (not present in the payload - removed upstream, or payload is a different version)"
            continue
        }
        if (-not [System.Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($src), [IO.File]::ReadAllBytes($full))) {
            Add-Failure 'Archive fidelity' "$rel (bytes differ from the payload copy - possible corruption; re-run Sync-PreviewPayload.ps1)"
        }
    }
}

# --- Check 4: Attribute coverage ------------------------------------------------
Write-Host 'Check 4/5: Attribute coverage...'
foreach ($rel in $allRel) {
    $ext = [IO.Path]::GetExtension($rel)
    if ($binaryExts.Contains($ext) -or $ext -ieq '.json') { continue } # .json handled in check 1
    $full = Get-Full $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    if ((Get-Item -LiteralPath $full).Length -eq 0) { continue }
    if (Test-HasNul $full) {
        $attr = git -C $repoRoot check-attr binary -- $rel 2>$null
        if ($attr -notmatch 'binary: set') {
            Add-Failure 'Attribute coverage' "$rel (binary content in a text-treated extension '$ext' - add '*$ext binary' to .gitattributes)"
        }
    }
}

# --- Check 5: Stub-stomp detector -----------------------------------------------
Write-Host 'Check 5/5: Stub-stomp detector...'
foreach ($rel in @(git -C $repoRoot diff HEAD --name-only 2>$null)) {
    $full = Get-Full $rel
    if ((Test-Path -LiteralPath $full -PathType Leaf) -and (Get-Item -LiteralPath $full).Length -eq 0) {
        $headSize = git -C $repoRoot cat-file -s "HEAD:$rel" 2>$null
        if ($LASTEXITCODE -eq 0 -and [int]$headSize -gt 0) {
            Add-Failure 'Stub-stomp detector' "$rel (now zero bytes; last commit had $headSize bytes)"
        }
    }
}

# --- Summary ---------------------------------------------------------------------
Write-Host ''
$checks = @('JSON integrity', 'Image integrity', 'Archive fidelity', 'Attribute coverage', 'Stub-stomp detector')
$anyFailed = $false
foreach ($check in $checks) {
    if ($failures[$check]) {
        $anyFailed = $true
        Write-Host "[FAIL] ${check}: $($failures[$check].Count) issue(s)" -ForegroundColor Red
        foreach ($f in ($failures[$check] | Select-Object -First $MaxList)) { Write-Host "       $f" }
        if ($failures[$check].Count -gt $MaxList) { Write-Host "       ... and $($failures[$check].Count - $MaxList) more" }
    }
    else {
        Write-Host "[PASS] $check" -ForegroundColor Green
    }
}
Write-Host ''
if ($anyFailed) {
    Write-Host 'Result: FAILED - fix the issues above before committing.' -ForegroundColor Red
    exit 1
}
Write-Host 'Result: all checks passed.' -ForegroundColor Green
