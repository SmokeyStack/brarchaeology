<#
.SYNOPSIS
Runs the whole Preview-update workflow with one command.

.DESCRIPTION
Orchestrates the individual scripts in order - it contains no logic of its
own, so each step can still be run (or re-run) separately:

  1. Sync-PreviewPayload.ps1   - wipe the tracking folder, copy game files in
  2. Dump-BdsSchema.ps1        - dump MCB schemas from the matching BDS build
  3. Extract-Brarchives.ps1    - unpack archives, restore MCB, format, tidy
  4. Test-Repo.ps1             - integrity checks (JSON, images, archives, ...)
  5. Report-Changes.ps1        - print a digest of what changed

Stops at the first failing step.

.PARAMETER Version
BDS version for the schema dump. If omitted, the newest published BDS is
used automatically.

.PARAMETER SkipSync
Skip step 1 (use when the game files are already copied in).

.PARAMETER SkipSchema
Skip step 2 (use when tools\bds-schema already matches this version).

.PARAMETER SkipVerify
Skip step 4 (the integrity checks add a couple of minutes).

.PARAMETER ThrottleLimit
Passed to Extract-Brarchives.ps1 (parallel archive decoding, default 8).

.EXAMPLE
.\tools\Update-All.ps1

.EXAMPLE
.\tools\Update-All.ps1 -Version 1.26.50.25 -SkipSync
#>
[CmdletBinding()]
param(
    [string]$Version,
    [switch]$SkipSync,
    [switch]$SkipSchema,
    [switch]$SkipVerify,
    [ValidateRange(1, 32)][int]$ThrottleLimit = 8
)

$ErrorActionPreference = 'Stop'

if (-not $SkipSync) {
    Write-Host '=== Step 1/5: Sync game files ==='
    & (Join-Path $PSScriptRoot 'Sync-PreviewPayload.ps1')
}
else { Write-Host '=== Step 1/5: Sync skipped ===' }

if (-not $SkipSchema) {
    Write-Host '=== Step 2/5: Dump BDS schemas ==='
    $dumpArgs = @{}
    if ($Version) { $dumpArgs.Version = $Version }
    & (Join-Path $PSScriptRoot 'Dump-BdsSchema.ps1') @dumpArgs
}
else { Write-Host '=== Step 2/5: Schema dump skipped ===' }

Write-Host '=== Step 3/5: Extract and restore ==='
& (Join-Path $PSScriptRoot 'Extract-Brarchives.ps1') -ThrottleLimit $ThrottleLimit
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    throw "Extract-Brarchives.ps1 reported failures (exit code $LASTEXITCODE) - review the warnings above."
}

if (-not $SkipVerify) {
    Write-Host '=== Step 4/5: Integrity checks ==='
    & (Join-Path $PSScriptRoot 'Test-Repo.ps1')
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw 'Test-Repo.ps1 found integrity problems - fix them before committing.'
    }
}
else { Write-Host '=== Step 4/5: Integrity checks skipped ===' }

Write-Host '=== Step 5/5: Change report ==='
& (Join-Path $PSScriptRoot 'Report-Changes.ps1')

Write-Host ''
Write-Host 'Done. Review the changes (e.g. in GitHub Desktop), then commit.'
