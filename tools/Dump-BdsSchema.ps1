<#
.SYNOPSIS
Downloads the Bedrock Dedicated Server from Mojang and dumps its JSON schemas
into a schema root usable by brarchive-extractor (brax) for MCB restoration.

.DESCRIPTION
Relies only on Mojang: fetches bedrock-server-<version>.zip from minecraft.net,
runs it once with a test_config.json that sets generate_documentation /
generate_api_metadata, waits for the docs\ dump, then packages it as:

  <OutDir>\exist.json                {"version": "<version>", ...}
  <OutDir>\contents.json             sorted file list (marker file)
  <OutDir>\metadata\json_schemas\**  the schemas BDS wrote to docs\json_schemas
  <OutDir>\metadata\contents.json    same list (bds-docs layout parity)

Version-volatile keys (minecraft_version, x-minecraft-version) are stripped
from the JSON files, and spaces in file names become underscores, mirroring
the bedrock-apis/bds-docs export layout that brax was built against.

Run this once per Preview drop (the schema version should match the payload).

.PARAMETER Version
BDS version to download, e.g. 1.26.50.22. If omitted, the newest available
BDS version is looked up from Mojang's official download service. Because
Mojang often publishes BDS before the matching game update reaches players,
omitting -Version lets you dump schemas for an update you cannot install yet.

.PARAMETER OutDir
Schema root to write. Defaults to tools\bds-schema next to this script.

.PARAMETER Stable
Download the stable BDS instead of preview.

.EXAMPLE
.\tools\Dump-BdsSchema.ps1 -Version 1.26.50.22

.EXAMPLE
.\tools\Dump-BdsSchema.ps1   # newest available BDS preview
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$OutDir = (Join-Path $PSScriptRoot 'bds-schema'),
    [switch]$Stable
)

$ErrorActionPreference = 'Stop'
$channel = if ($Stable) { 'bin-win' } else { 'bin-win-preview' }

if (-not $Version) {
    # Ask Mojang's official download service for the newest published BDS.
    $downloadType = if ($Stable) { 'serverBedrockWindows' } else { 'serverBedrockPreviewWindows' }
    $links = (Invoke-RestMethod 'https://net-secondary.web.minecraft-services.net/api/v1.0/download/links').result.links
    $link = ($links | Where-Object downloadType -eq $downloadType).downloadUrl
    if ($link -notmatch 'bedrock-server-([\d.]+)\.zip') {
        throw "Could not determine the latest BDS version from Mojang's download service (got: $link). Pass -Version explicitly."
    }
    $Version = $Matches[1]
    Write-Host "Latest published BDS version ($downloadType): $Version"
}

$url = "https://www.minecraft.net/bedrockdedicatedserver/$channel/bedrock-server-$Version.zip"
$work = Join-Path ([IO.Path]::GetTempPath()) "bds-dump-$Version"
$zip = "$work.zip"
$bds = Join-Path $work 'server'

# --- Download (Mojang CDN requires a browser-ish user agent) -----------------
if (-not (Test-Path $zip)) {
    Write-Host "Downloading $url"
    curl.exe -L --fail -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -o "$zip.part" $url
    if ($LASTEXITCODE -ne 0) { throw "Download failed (HTTP error) for $url" }
    Move-Item "$zip.part" $zip
}
else {
    Write-Host "Using cached $zip"
}

# --- Extract ------------------------------------------------------------------
if (Test-Path $bds) { Remove-Item -LiteralPath $bds -Recurse -Force }
New-Item -ItemType Directory -Force -Path $bds | Out-Null
Write-Host 'Extracting BDS...'
[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $bds)

# --- Run BDS once with documentation dumping enabled ---------------------------
@'
{
    "generate_documentation": true,
    "generate_api_metadata": true
}
'@ | Set-Content -LiteralPath (Join-Path $bds 'test_config.json') -Encoding ascii

$docs = Join-Path $bds 'docs'
Write-Host 'Starting bedrock_server.exe to dump docs...'
$proc = Start-Process -FilePath (Join-Path $bds 'bedrock_server.exe') -WorkingDirectory $bds `
    -RedirectStandardOutput (Join-Path $work 'bds-stdout.log') `
    -RedirectStandardError (Join-Path $work 'bds-stderr.log') -PassThru -NoNewWindow
try {
    # Wait until docs\json_schemas exists and its file count is steady, max 90s.
    # (Careful: $stable would collide with the [switch]$Stable parameter.)
    $deadline = (Get-Date).AddSeconds(90)
    $lastCount = -1
    $steady = 0
    while ((Get-Date) -lt $deadline -and $steady -lt 3) {
        Start-Sleep -Seconds 1
        $count = if (Test-Path (Join-Path $docs 'json_schemas')) {
            (Get-ChildItem -LiteralPath $docs -Recurse -File | Measure-Object).Count
        } else { -1 }
        if ($count -ge 0 -and $count -eq $lastCount) { $steady++ } else { $steady = 0 }
        $lastCount = $count
    }
}
finally {
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
}
if (-not (Test-Path (Join-Path $docs 'json_schemas'))) {
    throw "BDS did not produce docs\json_schemas - see $work\bds-stdout.log"
}
Write-Host "BDS dumped $lastCount doc files."

# --- Package as a brax-compatible schema root ---------------------------------
if (Test-Path $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
$meta = Join-Path $OutDir 'metadata'
New-Item -ItemType Directory -Force -Path $meta | Out-Null

$contents = [System.Collections.Generic.List[string]]::new()
foreach ($f in Get-ChildItem -LiteralPath $docs -Recurse -File) {
    $rel = [IO.Path]::GetRelativePath($docs, $f.FullName).Replace('\', '/').Replace(' ', '_')
    $destFile = Join-Path $meta ($rel -replace '/', '\')
    New-Item -ItemType Directory -Force -Path (Split-Path $destFile -Parent) | Out-Null
    if ($f.Extension -eq '.json') {
        try {
            $obj = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json -AsHashtable -Depth 100
            $obj.Remove('minecraft_version') | Out-Null
            $obj.Remove('x-minecraft-version') | Out-Null
            ($obj | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $destFile -Encoding utf8NoBOM
        }
        catch {
            Copy-Item -LiteralPath $f.FullName -Destination $destFile
        }
    }
    else {
        Copy-Item -LiteralPath $f.FullName -Destination $destFile
    }
    $contents.Add($rel)
}
$contents.Sort()
$contentsJson = ConvertTo-Json @($contents) -Depth 5
$contentsJson | Set-Content -LiteralPath (Join-Path $meta 'contents.json') -Encoding utf8NoBOM
$contentsJson | Set-Content -LiteralPath (Join-Path $OutDir 'contents.json') -Encoding utf8NoBOM
@{ 'version' = $Version; 'build-version' = $Version } | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $OutDir 'exist.json') -Encoding utf8NoBOM

Write-Host "Schema root written to $OutDir ($($contents.Count) files, version $Version)."
Write-Host "You can delete the cached download at $zip when done."
