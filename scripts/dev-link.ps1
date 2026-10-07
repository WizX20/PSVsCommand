<#
.SYNOPSIS
Links src/PSVsCommand into your CurrentUser module path so `Import-Module PSVsCommand` loads the working copy.

.DESCRIPTION
Creates a directory junction <CurrentUser modules>\PSVsCommand -> <repo>\src\PSVsCommand (no admin rights
needed). Edits in the checkout are live after `Import-Module PSVsCommand -Force`. A junction that points at
another checkout - a removed worktree, say - is pointed at this one. Refuses to replace a real directory; a
Scoop install lives in ~/scoop/modules, so the two do not collide, but the junction shadows it while
present. -Remove takes the junction away again.

.PARAMETER Remove
Remove the junction instead of creating it.

.PARAMETER ModulesPath
The module folder to link into. Defaults to the CurrentUser module path of the PowerShell running the
script (Documents\PowerShell\Modules for pwsh, as `task link` runs it; Documents\WindowsPowerShell\Modules
for Windows PowerShell 5.1); tests point it into a scratch folder.
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [string]$ModulesPath
)
$ErrorActionPreference = 'Stop'
$src = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\PSVsCommand'
if (-not $ModulesPath) { $ModulesPath = Join-Path (Split-Path $PROFILE.CurrentUserAllHosts -Parent) 'Modules' }
$link = Join-Path $ModulesPath 'PSVsCommand'
# Get-Item -Force also finds a junction whose target is gone (Test-Path says True for it too, which
# is why it used to count as "already linked").
$item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue

if ($Remove) {
    if (-not $item) { Write-Host "no link at $link" -ForegroundColor DarkGray; return }
    if (-not $item.LinkType) { throw "$link is a real directory, not a junction - not touching it" }
    $item.Delete()
    Write-Host "removed $link" -ForegroundColor Green
    return
}
if ($item) {
    if (-not $item.LinkType) { throw "$link already exists as a real directory - remove it first" }
    # A string on PowerShell 7, a one-element array on Windows PowerShell 5.1.
    $target = @($item.Target)[0]
    if ($target -and (Test-Path -LiteralPath $target) -and
        (Resolve-Path -LiteralPath $target).ProviderPath.TrimEnd('\') -eq (Resolve-Path -LiteralPath $src).ProviderPath.TrimEnd('\')) {
        Write-Host "already linked: $link -> $src" -ForegroundColor DarkGray
        return
    }
    # Another checkout, or one that no longer exists: point it here. Delete() removes the junction
    # itself, never what it points at.
    $item.Delete()
    Write-Host "re-pointing $link (was -> $target)" -ForegroundColor Yellow
}
New-Item -ItemType Directory -Force -Path $ModulesPath | Out-Null
New-Item -ItemType Junction -Path $link -Target $src | Out-Null
Write-Host "linked $link -> $src" -ForegroundColor Green
Write-Host 'now: Import-Module PSVsCommand -Force' -ForegroundColor DarkGray
