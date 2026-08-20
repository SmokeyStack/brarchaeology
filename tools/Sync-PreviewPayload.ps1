<#
.SYNOPSIS
Refreshes the tracking folder with the current Minecraft Preview game files.

.DESCRIPTION
Deletes everything in the tracking folder EXCEPT the items on the preserve
list (version-control data, the tools folder, and repository config files),
then copies the current Minecraft Preview data payload in with robocopy.

Run this first after every Minecraft Preview update, then run
Extract-Brarchives.ps1.

WARNING: this script deletes files. Double-check -Destination before running.

.PARAMETER Source
The Minecraft Preview data folder. The default is the standard Xbox app /
Microsoft Store install location.

.PARAMETER Destination
The tracking folder to refresh. Defaults to the parent folder of tools\
(i.e. this script assumes it lives in <your-tracking-folder>\tools\).

.PARAMETER Preserve
Top-level items in the destination that must never be deleted.

.EXAMPLE
.\tools\Sync-PreviewPayload.ps1
#>
[CmdletBinding()]
param(
    [string]$Source = 'C:\XboxGames\Minecraft Preview for Windows\Content\data',
    [string]$Destination = (Split-Path $PSScriptRoot -Parent),
    [string[]]$Preserve = @('.git', 'tools', '.gitattributes', '.gitignore', 'README.md')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Source)) {
    throw "Minecraft Preview data folder not found at '$Source'. Is Minecraft Preview installed?"
}

Write-Host "Cleaning out $Destination (preserving $($Preserve -join ', '))"
# Everything preserved lives at the top level, so removing only top-level
# items is sufficient (children are deleted with their parent).
Get-ChildItem -Path $Destination -Force | Where-Object { $Preserve -notcontains $_.Name } | Remove-Item -Recurse -Force

Write-Host 'Copying Minecraft Preview files into the tracking folder'
robocopy $Source $Destination /e /w:5 /r:2 /MT:8
if ($LASTEXITCODE -ge 8) {
    throw "robocopy reported a failure (exit code $LASTEXITCODE). Re-run this script."
}
Write-Host 'Done. Next step: .\tools\Extract-Brarchives.ps1'
