<#
.SYNOPSIS
Builds the release zip: dist/PSVsCommand-<version>.zip with a single top-level PSVsCommand/ folder inside.

.DESCRIPTION
The zip is what a GitHub Release carries and what the Scoop manifest downloads. Scoop's
`extract_dir: "PSVsCommand"` strips the top-level folder, so the install dir IS the module folder
(PSVsCommand.psd1 at its root), the `psmodule` junction ~/scoop/modules/PSVsCommand points straight at it,
and the `bin` shim runs vs.ps1 from it.
The version comes from src/PSVsCommand/PSVsCommand.psd1 - stamp it first with scripts/set-version.ps1.
Prints the zip path and its SHA256 (the value bucket/psvscommand.json needs).
Run it with pwsh, as `task pack`, CI and the release do: under Windows PowerShell 5.1 the .NET
Framework writes the zip's entry names with backslashes.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$src = Join-Path $root 'src\PSVsCommand'
$version = (Import-PowerShellDataFile -LiteralPath (Join-Path $src 'PSVsCommand.psd1')).ModuleVersion

$dist = Join-Path $root 'dist'
$stage = Join-Path $dist 'PSVsCommand'
# Literal paths throughout: a checkout under a folder with [ or ] in its name would otherwise be
# read as a wildcard pattern - an incomplete zip, or none.
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Get-ChildItem -LiteralPath $src | Copy-Item -Destination $stage -Recurse
Copy-Item -LiteralPath (Join-Path $root 'LICENSE'), (Join-Path $root 'NOTICE') -Destination $stage

$zip = Join-Path $dist "PSVsCommand-$version.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
# Not Compress-Archive: it reads -DestinationPath as a wildcard pattern. The base directory goes
# in, so the zip holds one PSVsCommand/ folder - what the manifest's extract_dir expects.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
Write-Host "packed $zip" -ForegroundColor Green
Write-Host "sha256 $hash"
[pscustomobject]@{ Version = $version; Zip = $zip; Sha256 = $hash }
