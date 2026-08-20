<#
.SYNOPSIS
Decodes every .brarchive under __brarchive/ directories into its matching
pack directory using brarchive-cli (bedrock-crustaceans/brarchive).

.DESCRIPTION
Intended workflow after a Preview update: VanillaFiles (wipe repo + robocopy
payload in) -> this script -> review, stage, commit.

Mapping rule: <pack>\__brarchive\<rel>\<name>.brarchive -> <pack>\<rel>\<name>\

Each archive is decoded separately into a fresh temp directory and the result
is overlaid onto its destination with robocopy (no purge). Per-archive decode
is deliberate: brarchive-cli refuses non-empty output directories and its -r
mode collides with its own output on nested archives (parent decoded after
child, e.g. cameras.brarchive after cameras/presets.brarchive).

JSON entries are pretty-printed by the tool in Mojang's current style
(2-space indent, "key": value, no trailing newline). Binary entries such as
compiled MCB blobs (magic \x7F MCB) are written unchanged. Zero-length
entries are manifest stubs for files Mojang still ships raw alongside the
archives (structure .nbt, store .jpg, ...) - the overlay uses /MIN:1 so a
stub never overwrites the real file.

Because older packs were shipped in different historical styles (tabs,
"key" : value, ...), a post-pass compares each decoded *.json against its
committed HEAD version token-by-token: if only whitespace differs, the HEAD
version is restored so unchanged files produce no diff at all. Only files
whose content really changed keep the new formatting.

Binary *.json files (MCB) are recorded in a generated .gitattributes block as
binary so CRLF normalization cannot corrupt them. Static binary formats
(*.png, *.fsb, ...) are hand-maintained lines in .gitattributes - keep those;
this script only manages its marked block.

.PARAMETER Root
Directory to scan for __brarchive directories. Defaults to the repository
root (parent of tools\).

.PARAMETER Cli
Path to brarchive-cli.exe. Defaults to tools\brarchive-cli.exe next to this
script.

.PARAMETER Raw
Decode without pretty-printing and skip the HEAD-restore and .gitattributes
passes; decoded files stay byte-identical to the archive contents.

.PARAMETER NoRestore
Keep the pretty formatting even for files whose content is unchanged vs HEAD.

.PARAMETER ThrottleLimit
How many archives to decode at the same time. 1 = one at a time (slowest,
simplest). Default 8.

.EXAMPLE
.\tools\Extract-Brarchives.ps1
#>
[CmdletBinding()]
param(
    [string]$Root = (Split-Path $PSScriptRoot -Parent),
    [string]$Cli = (Join-Path $PSScriptRoot 'brarchive-cli.exe'),
    [switch]$Raw,
    [switch]$NoRestore,
    [ValidateRange(1, 32)][int]$ThrottleLimit = 8
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Cli)) {
    throw "brarchive-cli.exe not found at '$Cli'. Download it from https://github.com/bedrock-crustaceans/brarchive/releases and place it there."
}

if (-not $Raw -and -not ('MojangJsonFormat' -as [type])) {
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
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$repoRoot = git -C $Root rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0) {
    $repoRoot = $null
    Write-Warning "'$Root' is not inside a git repository - the HEAD-restore and .gitattributes passes will be skipped."
}

function Get-RelPath([string]$full) {
    [IO.Path]::GetRelativePath($repoRoot, $full).Replace('\', '/')
}

# Destination directory for one archive: strip the __brarchive segment and extension.
function Get-DestDir([string]$archivePath) {
    ($archivePath -replace '\\__brarchive\\', '\') -replace '\.brarchive$', ''
}

$brDirs = @(Get-ChildItem -LiteralPath $Root -Recurse -Directory -Filter __brarchive)
if ($brDirs.Count -eq 0) {
    Write-Warning "No __brarchive directories found under '$Root'."
    return
}
$archives = @($brDirs | Get-ChildItem -Recurse -File -Filter *.brarchive)

# --- Decode each archive to temp, overlay onto its destination ---------------
$tmpBase = Join-Path ([IO.Path]::GetTempPath()) ('brarchive-decode-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmpBase | Out-Null
try {
    if ($ThrottleLimit -le 1) {
        $failed = @()
        $i = 0
        foreach ($a in $archives) {
            $i++
            Write-Progress -Activity 'Decoding brarchives' -Status "$i/$($archives.Count) $($a.Name)" -PercentComplete (100 * $i / $archives.Count)
            $out = Join-Path $tmpBase "$i"
            New-Item -ItemType Directory -Force -Path $out | Out-Null
            $cliArgs = @('decode') + $(if (-not $Raw) { @('-p') } else { @() }) + @($a.FullName, $out)
            $log = & $Cli @cliArgs 2>&1
            if ($LASTEXITCODE -ne 0) {
                $failed += [pscustomobject]@{ Archive = $a.FullName; Output = (($log | Select-Object -Last 2) -join '; ') }
                continue
            }
            # /MIN:1 skips zero-length manifest-stub entries so they never
            # overwrite the real files Mojang ships raw next to the archives.
            robocopy $out (Get-DestDir $a.FullName) /E /MIN:1 /NFL /NDL /NJH /NJS /NP | Out-Null
            if ($LASTEXITCODE -ge 8) {
                $failed += [pscustomobject]@{ Archive = $a.FullName; Output = "robocopy overlay failed with exit code $LASTEXITCODE" }
            }
        }
        Write-Progress -Activity 'Decoding brarchives' -Completed
    }
    else {
        # Each archive decodes into its own temp directory and overlays onto
        # its own destination, so archives are independent and safe to run
        # concurrently.
        $failed = @($archives | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            $a = $_
            $out = Join-Path $using:tmpBase ([Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $out | Out-Null
            $cliArgs = @('decode') + $(if (-not $using:Raw) { @('-p') } else { @() }) + @($a.FullName, $out)
            $log = & $using:Cli @cliArgs 2>&1
            if ($LASTEXITCODE -ne 0) {
                [pscustomobject]@{ Archive = $a.FullName; Output = (($log | Select-Object -Last 2) -join '; ') }
                return
            }
            $dest = ($a.FullName -replace '\\__brarchive\\', '\') -replace '\.brarchive$', ''
            # /MIN:1 skips zero-length manifest-stub entries so they never
            # overwrite the real files Mojang ships raw next to the archives.
            robocopy $out $dest /E /MIN:1 /NFL /NDL /NJH /NJS /NP | Out-Null
            if ($LASTEXITCODE -ge 8) {
                [pscustomobject]@{ Archive = $a.FullName; Output = "robocopy overlay failed with exit code $LASTEXITCODE" }
            }
        })
    }
}
finally {
    try { Remove-Item -LiteralPath $tmpBase -Recurse -Force -ErrorAction Stop } catch { }
}
Write-Host "Decoded $($archives.Count - $failed.Count)/$($archives.Count) archives ($($brDirs.Count) packs)."

# --- Classify decoded *.json: plain JSON vs binary (MCB) ---------------------
$binaryJson = @()      # repo-relative paths of MCB/binary .json files
$decodedJson = @{}     # repo-relative path -> full path, for the restore pass
if (-not $Raw -and $repoRoot) {
    foreach ($a in $archives) {
        $dest = Get-DestDir $a.FullName
        if (-not (Test-Path -LiteralPath $dest)) { continue }
        foreach ($jf in Get-ChildItem -LiteralPath $dest -File -Filter *.json) {
            $bytes = [IO.File]::ReadAllBytes($jf.FullName)
            if ($bytes.Length -gt 0 -and ($bytes[0..([Math]::Min(7999, $bytes.Length - 1))] -contains 0)) {
                $binaryJson += Get-RelPath $jf.FullName
            }
            else {
                $decodedJson[(Get-RelPath $jf.FullName)] = $jf.FullName
            }
        }
    }
}

# --- Restore MCB binary JSON to plain JSON (brax + Mojang BDS schemas) -------
# Uses brarchive-extractor (tools\brax) with schemas dumped from the official
# BDS build (tools\Dump-BdsSchema.ps1). Optional: if either is missing, MCB
# files simply stay binary and remain in the .gitattributes block.
if (-not $Raw -and $repoRoot -and $binaryJson.Count -gt 0) {
    $braxCli = Join-Path $PSScriptRoot 'brax\dist\src\cli.js'
    $schemaRoot = Join-Path $PSScriptRoot 'bds-schema'
    if ((Test-Path $braxCli) -and (Test-Path (Join-Path $schemaRoot 'exist.json'))) {
        $schemaVer = (Get-Content (Join-Path $schemaRoot 'exist.json') -Raw | ConvertFrom-Json).version
        # Stage the MCB files in a temp tree so brax never touches archives or
        # unrelated files, then overlay the restored JSON back onto the repo.
        $stage = Join-Path ([IO.Path]::GetTempPath()) ('mcb-restore-' + [Guid]::NewGuid().ToString('N'))
        try {
            foreach ($rel in $binaryJson) {
                $dst = Join-Path $stage ($rel -replace '/', '\')
                New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
                Copy-Item -LiteralPath (Join-Path $repoRoot ($rel -replace '/', '\')) -Destination $dst
            }
            # brax directory mode refuses to run without a .brarchive present;
            # seed an empty one (16-byte v1 header, zero entries) so it scans
            # the staged loose MCB files.
            [IO.File]::WriteAllBytes((Join-Path $stage '_seed.brarchive'),
                [byte[]](0x7D, 0x27, 0x25, 0xB1, 0xA0, 0x52, 0x70, 0x26, 0, 0, 0, 0, 1, 0, 0, 0))
            $braxLog = & node $braxCli $stage --in-place --mcb-only --list --schema $schemaRoot 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "brax exited with code $LASTEXITCODE (failed files stay binary). Failure details:"
                # --list appends per-entry failure details (kind, file, schema, reason)
                $braxLog | Where-Object { "$_" -match '\S' } | ForEach-Object { Write-Warning "  $_" }
            }
            # Re-classify: files brax restored are text now. Normalize them with
            # the same formatter as everything else, and drop them from the
            # binary list so the .gitattributes block shrinks.
            $stillBinary = @()
            foreach ($rel in $binaryJson) {
                $full = Join-Path $repoRoot ($rel -replace '/', '\')
                $staged = Join-Path $stage ($rel -replace '/', '\')
                $bytes = [IO.File]::ReadAllBytes($staged)
                if ($bytes.Length -gt 0 -and -not ($bytes[0..([Math]::Min(7999, $bytes.Length - 1))] -contains 0)) {
                    $fmt = [MojangJsonFormat]::Format([Text.Encoding]::UTF8.GetString($bytes))
                    [IO.File]::WriteAllText($full, $fmt, $utf8NoBom)
                    $decodedJson[$rel] = $full
                }
                else {
                    $stillBinary += $rel
                }
            }
            Write-Host "MCB restored to JSON (schema $schemaVer): $($binaryJson.Count - $stillBinary.Count) of $($binaryJson.Count); $($stillBinary.Count) kept binary."
            foreach ($rel in $stillBinary) { Write-Host "  kept binary: $rel" }
            $binaryJson = $stillBinary
        }
        finally {
            try { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop } catch { }
        }
    }
    else {
        Write-Warning "MCB restore skipped: install brax (git clone https://github.com/LPaicen/brarchive-extractor tools\brax; npm install; npm run build) and dump schemas (tools\Dump-BdsSchema.ps1 -Version <drop>). $($binaryJson.Count) MCB file(s) stay binary."
    }
}

# --- Restore HEAD formatting where only whitespace differs -------------------
if (-not $Raw -and -not $NoRestore -and $repoRoot -and $decodedJson.Count -gt 0) {
    $modified = @(git -C $repoRoot diff HEAD --name-only -- '*.json' 2>$null | Where-Object { $decodedJson.ContainsKey($_) })
    # Parallel: the per-file `git show` dominates the runtime of this pass.
    $restore = @($modified | ForEach-Object -Parallel {
        $rel = $_
        try {
            $headTxt = (git -C $using:repoRoot show "HEAD:$rel" 2>$null) -join "`n"
            if ($LASTEXITCODE -ne 0 -or -not $headTxt) { return }
            $headFmt = [MojangJsonFormat]::Format($headTxt)
            $curFmt = [MojangJsonFormat]::Format([IO.File]::ReadAllText(($using:decodedJson)[$rel]))
            if ($headFmt -eq $curFmt) { $rel }
        }
        catch { } # either side not plain JSON (comments etc.) -> keep new file
    } -ThrottleLimit 8)
    for ($k = 0; $k -lt $restore.Count; $k += 100) {
        $chunk = $restore[$k..([Math]::Min($k + 99, $restore.Count - 1))]
        # Retry: concurrent git activity (GUI clients) can hold .git/index.lock.
        for ($try = 1; $try -le 3; $try++) {
            git -C $repoRoot restore --source=HEAD --worktree -- @($chunk) 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { break }
            if ($try -eq 3) {
                Write-Warning "git restore failed for a chunk of $($chunk.Count) file(s) (repository busy?) - re-run this script to finish."
            }
            else { Start-Sleep -Milliseconds 500 }
        }
    }
    Write-Host "Whitespace-only changes reverted to HEAD formatting: $($restore.Count) of $($modified.Count) modified JSON files."
}

# --- Maintain .gitattributes block for binary *.json (MCB) files -------------
if (-not $Raw -and $repoRoot) {
    $attrPath = Join-Path $repoRoot '.gitattributes'
    $begin = '# >>> Extract-Brarchives binary json (auto-generated) >>>'
    $end = '# <<< Extract-Brarchives binary json <<<'
    $existing = @()
    $lines = @()
    if (Test-Path $attrPath) { $lines = @(Get-Content $attrPath) }
    $bi = $lines.IndexOf($begin); $ei = $lines.IndexOf($end)
    if ($bi -ge 0 -and $ei -gt $bi) {
        if ($ei - $bi -gt 1) {
            $existing = $lines[($bi + 1)..($ei - 1)] | ForEach-Object { ($_ -replace ' binary$', '') }
        }
        $pre = if ($bi -gt 0) { $lines[0..($bi - 1)] } else { @() }
        $post = if ($ei -lt $lines.Count - 1) { $lines[($ei + 1)..($lines.Count - 1)] } else { @() }
        $lines = @($pre) + @($post)
    }
    # keep prior entries unless the file now decodes as text or no longer
    # exists (removed upstream); add newly found binaries
    $set = [System.Collections.Generic.SortedSet[string]]::new()
    foreach ($p in $existing) {
        if (-not $decodedJson.ContainsKey($p) -and
            (Test-Path -LiteralPath (Join-Path $repoRoot ($p -replace '/', '\')))) { [void]$set.Add($p) }
    }
    foreach ($p in $binaryJson) { [void]$set.Add($p) }
    if ($set.Count -gt 0) {
        $lines = @($lines) + @($begin) + @($set | ForEach-Object { "$_ binary" }) + @($end)
    }
    # Retry: git GUIs/editors sometimes hold .gitattributes memory-mapped.
    $written = $false
    for ($try = 1; $try -le 5 -and -not $written; $try++) {
        try {
            [IO.File]::WriteAllText($attrPath, (($lines -join "`n") + "`n"), $utf8NoBom)
            $written = $true
        }
        catch {
            if ($try -eq 5) { throw }
            Start-Sleep -Milliseconds (300 * $try)
        }
    }
    Write-Host "Binary .json files (MCB) marked in .gitattributes: $($set.Count) total ($($binaryJson.Count) seen this run)."
}

if ($failed) {
    Write-Warning "$($failed.Count) archive(s) failed to decode:"
    foreach ($f in $failed) { Write-Warning "  $($f.Archive): $($f.Output)" }
    exit 1
}
