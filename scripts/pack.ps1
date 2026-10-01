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
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$src = Join-Path $root 'src\PSVsCommand'
$version = (Test-ModuleManifest (Join-Path $src 'PSVsCommand.psd1')).Version.ToString()

$dist = Join-Path $root 'dist'
$stage = Join-Path $dist 'PSVsCommand'
if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item (Join-Path $src '*') $stage
Copy-Item (Join-Path $root 'LICENSE'), (Join-Path $root 'NOTICE') $stage

$zip = Join-Path $dist "PSVsCommand-$version.zip"
if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path $stage -DestinationPath $zip
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash
Write-Host "packed $zip" -ForegroundColor Green
Write-Host "sha256 $hash"
[pscustomobject]@{ Version = $version; Zip = $zip; Sha256 = $hash }
