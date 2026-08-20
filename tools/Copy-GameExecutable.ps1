<#
.SYNOPSIS
Makes a readable copy of the Minecraft Preview executable for text searching.

.DESCRIPTION
The Minecraft Preview executable installed by the Xbox app / Microsoft Store
is encrypted on disk, so search tools like Agent Ransack cannot read it
directly. Windows only decrypts it for the app itself. This script runs a
copy command *inside* the app's own context, which produces a normal,
readable copy named decrypted.exe in the current folder.

This reads your own installed game for personal analysis. Do not share the
copied executable.

.PARAMETER OutFile
Where to put the readable copy. Defaults to decrypted.exe in the current
folder.

.EXAMPLE
.\tools\Copy-GameExecutable.ps1
#>
[CmdletBinding()]
param(
    [string]$OutFile = (Join-Path (Get-Location) 'decrypted.exe')
)

$gameExe = 'C:\XboxGames\Minecraft Preview for Windows\Content\Minecraft.Windows.exe'
if (-not (Test-Path $gameExe)) {
    throw "Minecraft Preview executable not found at '$gameExe'. Is Minecraft Preview installed?"
}

Invoke-CommandInDesktopPackage -PackageFamilyName 'Microsoft.MinecraftWindowsBeta_8wekyb3d8bbwe' -AppId Game `
    -Command 'pwsh' -Args "-Command Copy-Item '$gameExe' '$OutFile'"

Write-Host "Requested a readable copy at: $OutFile"
Write-Host 'The copy runs in a separate window and may take a few seconds to appear.'
