# PSVsCommand - open the right solution in the right Visual Studio from the command line.
# Exports one command, `vs`. It looks for solutions (.sln, .slnx) below the current folder - all
# of them, not just the first - offers a picker when there are several, and opens the pick in the
# Visual Studio install that fits it: one with the Reporting Services extension for an SSRS
# project, one new enough for an .slnx or a MinimumVisualStudioVersion, else the newest. Installs
# are found once (vswhere; the registry for 2015 and older; the default folders without either)
# and cached; `vs scan` looks again. Reached as the `vs` function once a profile imports the
# module, and from any shell through vs.ps1 (Scoop's shim): opening Visual Studio needs no cd, so
# a child process does everything the function does. Windows only. Commands:
#   vs                       find solutions below here: one -> confirm and open, several -> picker
#   vs .                     open this folder itself in Visual Studio (Open Folder), like `code .`
#   vs <dir|file|name>       search <dir>, open <file>, or the solutions whose name matches
#   vs list [dir]            what `vs` would offer, with the Visual Studio each one gets and why
#   vs installs | scan       the Visual Studio installs found (scan looks again)
#   vs config [key [value]]  settings: match, depth, confirm, updateCheck
#   vs update [notify on|off]   check for a new release / opt in to a daily check
#   vs version               version, install method, module folder
#   vs install|uninstall profile   the Import-Module line behind Tab completion

# Module functions look preferences up here before the caller's global scope. Windows
# PowerShell 5.1 turns native stderr into errors even behind 2>$null, so a profile (or a test
# runner) with 'Stop' would make a chatty vswhere throw.
$ErrorActionPreference = 'Continue'
$script:Repo = 'WizX20/PSVsCommand'
$script:ProjectUrl = "https://github.com/$script:Repo"

# Major version -> the year in the product name. Visual Studio 2026 (18) dropped the year from
# its catalog's productLineVersion, so the display name is read first and this is the fallback.
$script:VsYears = @{ 10 = '2010'; 11 = '2012'; 12 = '2013'; 14 = '2015'; 15 = '2017'; 16 = '2019'; 17 = '2022'; 18 = '2026' }
# Project types that only load in a Visual Studio carrying an extension. Folder is where the
# extension lands under Common7\IDE\CommonExtensions\Microsoft; Manifest matches the DisplayName
# of a VSIX install ("Microsoft Reporting Services Projects" - its identity is a bare GUID). The
# GUID is the project type in a .sln: old SSRS solutions (Format Version 13, "# Visual Studio
# 2013") name it without a .rptproj path that would give it away.
$script:VsWorkloads = @(
    @{ Cap = 'SSRS'; Label = 'Reporting Services'; Extensions = @('.rptproj'); Guids = @('{F14B399A-7131-4C87-9E4B-1186C45EF12D}'); Folder = 'SSRS'; Manifest = '<DisplayName>[^<]*Reporting\s*Services' }
    @{ Cap = 'SSIS'; Label = 'Integration Services'; Extensions = @('.dtproj'); Guids = @(); Folder = 'SSIS'; Manifest = '<DisplayName>[^<]*Integration\s*Services' }
    @{ Cap = 'SSAS'; Label = 'Analysis Services'; Extensions = @('.smproj', '.dwproj'); Guids = @(); Folder = 'SSAS'; Manifest = '<DisplayName>[^<]*Analysis\s*Services' }
)
# Rank on equal versions: the edition with the most in it first.
$script:VsEditionRank = @{ Enterprise = 0; Professional = 1; Community = 2 }
$script:VsSolutionExtensions = @('.sln', '.slnx')
$script:VsProjectExtensions = @('.csproj', '.vbproj', '.fsproj', '.vcxproj', '.sqlproj', '.rptproj', '.dtproj', '.smproj', '.dwproj')
# Never worth a look. Every dot-folder is skipped as well (.git, .vs, .idea), which also keeps the
# copies of the repo in git worktrees under .claude/worktrees or .worktrees out of the list, and so
# is every hidden folder (AppData, ProgramData, $Recycle.Bin).
$script:VsSkipDirs = @('node_modules', 'bin', 'obj', 'packages', 'TestResults', 'artifacts', 'dist')
# At a drive root only: nobody keeps solutions there, and walking them costs seconds.
$script:VsDriveRootSkipDirs = @('Windows', 'Program Files', 'Program Files (x86)', 'PerfLogs', 'Recovery')
# 1 once something did not happen as asked (nothing found, cancelled, a refused value); vs.ps1
# exits with it, so cmd, bash and scripts can tell. Reset by every `vs` call.
$script:VsExitCode = 0
# The XML solution format opens from Visual Studio 2022 17.13 on.
$script:SlnxMinVersion = [version]'17.13'
$script:VsCommands = @('list', 'installs', 'scan', 'config', 'update', 'version', 'install', 'uninstall', 'help')
$script:VsConfigKeys = [ordered]@{
    match       = @{ Default = 'newest'; Values = @('newest', 'solution') }
    depth       = @{ Default = '3'; Values = @('1', '2', '3', '4', '5', '6', '7', '8') }
    confirm     = @{ Default = 'on'; Values = @('on', 'off') }
    updateCheck = @{ Default = ''; Values = @('on', 'off') }
}

# --- storage --------------------------------------------------------------------------------
function Get-VsHome {
    # Settings, the install cache and the update-check state live outside the module folder,
    # which an update replaces. PSVSCOMMAND_HOME moves them (the tests point it at $TestDrive).
    if ($env:PSVSCOMMAND_HOME) { return $env:PSVSCOMMAND_HOME }
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PSVsCommand'
}
function Read-VsJson {
    param([string]$Name)
    $path = Join-Path (Get-VsHome) $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    # A damaged file is as good as none: the next write replaces it.
    try { [System.IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { $null }
}
function Write-VsJson {
    param([string]$Name, [object]$Value)
    $dir = Get-VsHome
    [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    $json = ConvertTo-Json -InputObject $Value -Depth 6
    [System.IO.File]::WriteAllText((Join-Path $dir $Name), $json, (New-Object System.Text.UTF8Encoding $false))
}
function ConvertTo-VsHashtable {
    param([object]$Object)
    $h = @{}
    if ($Object) { foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    $h
}
function Get-VsNow { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
function Write-VsFail {
    # Says what did not happen as asked, and makes the exit code of vs.ps1 say so too.
    param([string]$Message, [string]$Color = 'Yellow')
    $script:VsExitCode = 1
    Write-Host $Message -ForegroundColor $Color
}
function Get-VsVersion {
    # The module's own version, looked up when needed: reading the manifest at load time cost
    # every shell with the profile line ~200 ms. Loaded without its manifest the module has no
    # version of its own, so the manifest is the fallback.
    $v = $MyInvocation.MyCommand.Module.Version
    if (-not $v -or $v -eq [version]'0.0') { $v = [version](Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'PSVsCommand.psd1')).ModuleVersion }
    $v
}

# --- settings -------------------------------------------------------------------------------
$script:VsConfigCache = $null
function Get-VsConfig {
    # Saved values over the defaults; a value the file should not hold reads as the default.
    # Parsed once per version of the file: one `vs` call asks several times.
    $path = Join-Path (Get-VsHome) 'config.json'
    $stamp = [System.IO.File]::GetLastWriteTimeUtc($path).Ticks
    $c = $script:VsConfigCache
    if ($c -and $c.Path -eq $path -and $c.Stamp -eq $stamp) { return $c.Value }
    $saved = ConvertTo-VsHashtable (Read-VsJson 'config.json')
    $cfg = [ordered]@{}
    foreach ($k in $script:VsConfigKeys.Keys) {
        $v = [string]$saved[$k]
        if ($v -and $script:VsConfigKeys[$k].Values -contains $v) { $cfg[$k] = $v.ToLowerInvariant() }
        else { $cfg[$k] = $script:VsConfigKeys[$k].Default }
    }
    $script:VsConfigCache = @{ Path = $path; Stamp = $stamp; Value = $cfg }
    $cfg
}
function Set-VsConfigValue {
    param([string]$Key, [string]$Value)
    $k = @($script:VsConfigKeys.Keys) | Where-Object { $_ -eq $Key } | Select-Object -First 1
    if (-not $k) { Write-VsFail "unknown setting '$Key' - one of: $(@($script:VsConfigKeys.Keys) -join ', ')"; return }
    $spec = $script:VsConfigKeys[$k]
    $saved = ConvertTo-VsHashtable (Read-VsJson 'config.json')
    if ($Value -in 'default', 'reset') {
        $saved.Remove($k)
        $shown = if ($spec.Default) { $spec.Default } else { '(unset)' }
        Write-VsJson 'config.json' $saved
        Write-Host "$k is back to its default: $shown" -ForegroundColor Green
        return
    }
    $v = $spec.Values | Where-Object { $_ -eq $Value } | Select-Object -First 1
    if (-not $v) { Write-VsFail "'$Value' is not a value for $k - one of: $($spec.Values -join ', '), default"; return }
    $saved[$k] = $v
    Write-VsJson 'config.json' $saved
    Write-Host "$k = $v" -ForegroundColor Green
}
function Show-VsConfig {
    $cfg = Get-VsConfig
    $about = @{
        match       = 'newest: the newest install that can open it | solution: the version that saved it'
        depth       = 'folder levels searched below the current one'
        confirm     = 'ask before opening a single match'
        updateCheck = 'on: look for a new release once a day | off: never (vs update notify on|off)'
    }
    Write-Host ''
    foreach ($k in $cfg.Keys) {
        $v = if ($cfg[$k]) { $cfg[$k] } else { '(unset)' }
        Write-Host ('  {0,-12} ' -f $k) -NoNewline -ForegroundColor Green
        Write-Host ('{0,-9} ' -f $v) -NoNewline
        Write-Host $about[$k] -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host "  change one: vs config <key> <value>  ('default' resets it) - $(Join-Path (Get-VsHome) 'config.json')" -ForegroundColor DarkGray
}
function Invoke-VsConfig {
    param([string]$Key, [string]$Value)
    if (-not $Key) { Show-VsConfig; return }
    if (-not $Value) {
        $cfg = Get-VsConfig
        if (-not $cfg.Contains($Key)) { Set-VsConfigValue $Key ''; return }   # says what the keys are
        $v = $cfg[$Key]
        if ($v) { Write-Host $v } else { Write-Host '(unset)' }
        return
    }
    Set-VsConfigValue $Key $Value
}

# --- Visual Studio installs -----------------------------------------------------------------
function New-VsInstall {
    param([string]$Id, [string]$Name, [string]$Year, [string]$Edition, [version]$Version, [string]$Display,
        [string]$Path, [string]$InstallPath, [bool]$Prerelease, [string[]]$Capabilities, [string]$Source)
    if (-not $Version) { $Version = [version]'0.0' }
    if (-not $Year -and $script:VsYears.ContainsKey($Version.Major)) { $Year = $script:VsYears[$Version.Major] }
    if (-not $Display) { $Display = $Version.ToString() }
    if (-not $Name) { $Name = (@('Visual Studio', $Edition, $Year) | Where-Object { $_ }) -join ' ' }
    $label = (@($Year, $Edition) | Where-Object { $_ }) -join ' '
    if (-not $label) { $label = $Version.ToString() }
    if ($Prerelease) { $label += ' preview' }
    [pscustomobject]@{
        Id = $Id; Name = $Name; Year = $Year; Edition = $Edition; Major = $Version.Major; Version = $Version
        Display = $Display; Label = $label; Path = $Path; InstallPath = $InstallPath; Prerelease = $Prerelease
        Capabilities = @($Capabilities | Where-Object { $_ }); Source = $Source
    }
}
function Get-VsWherePath {
    $p = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    $c = Get-Command vswhere.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { $c.Source }
}
function Invoke-VsWhere {
    # vswhere's instances, parsed. -utf8 plus a UTF-8 decoder keep non-ASCII paths intact on
    # Windows PowerShell 5.1, which decodes native output with the OEM code page.
    param([string]$Exe)
    $enc = $null
    try { $enc = [Console]::OutputEncoding; [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { $enc = $null }
    try { $json = (& $Exe -all -prerelease -products '*' -format json -utf8 2>$null) -join "`n" }
    finally { if ($enc) { try { [Console]::OutputEncoding = $enc } catch { $enc = $null } } }
    if (-not $json -or -not $json.Trim()) { return }
    try { $parsed = ConvertFrom-Json $json } catch { return }
    foreach ($i in $parsed) { $i }
}
function ConvertFrom-VsWhere {
    # One vswhere instance -> an install; nothing for products without devenv.exe (Build Tools,
    # SQL Server Management Studio: vswhere lists those too), for Team Explorer (a devenv.exe
    # that opens no solution), or for an install an update left half done (isComplete or
    # isLaunchable false; older vswhere versions leave the fields out, which counts as fine).
    param([object]$Instance)
    $exe = [string]$Instance.productPath
    if (-not $exe -or [System.IO.Path]::GetFileName($exe) -ne 'devenv.exe') { return }
    if ([string]$Instance.productId -like '*.TeamExplorer') { return }
    foreach ($flag in 'isComplete', 'isLaunchable') {
        if ($Instance.PSObject.Properties[$flag] -and -not $Instance.$flag) { return }
    }
    $name = [string]$Instance.displayName
    $version = $null
    if (-not [version]::TryParse([string]$Instance.installationVersion, [ref]$version)) { return }
    $p = @{
        Id = [string]$Instance.instanceId; Name = $name; Edition = ([string]$Instance.productId -replace '^.*\.', '')
        Version = $version; Display = [string]$Instance.catalog.productDisplayVersion; Path = $exe
        InstallPath = [string]$Instance.installationPath; Prerelease = [bool]$Instance.isPrerelease; Source = 'vswhere'
    }
    if ($name -match '\b(20\d\d)\b') { $p.Year = $Matches[1] }
    New-VsInstall @p
}
function Get-VsFileVersion {
    param([string]$Path)
    $fv = (Get-Item -LiteralPath $Path).VersionInfo
    $v = $null
    if ([version]::TryParse(('{0}.{1}.{2}.{3}' -f $fv.FileMajorPart, $fv.FileMinorPart, $fv.FileBuildPart, $fv.FilePrivatePart), [ref]$v)) { return $v }
    [version]'0.0'
}
function Find-VsFolderInstalls {
    # Without vswhere (no Visual Studio Installer on the machine) look where the installer would
    # have put them: <Program Files>\Microsoft Visual Studio\<year or major>\<edition>.
    param([string[]]$Roots = @([Environment]::GetFolderPath('ProgramFiles'), [Environment]::GetFolderPath('ProgramFilesX86')))
    foreach ($r in ($Roots | Where-Object { $_ } | Select-Object -Unique)) {
        $base = Join-Path $r 'Microsoft Visual Studio'
        if (-not (Test-Path -LiteralPath $base)) { continue }
        foreach ($line in @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue)) {
            foreach ($ed in @(Get-ChildItem -LiteralPath $line.FullName -Directory -ErrorAction SilentlyContinue)) {
                $exe = Join-Path $ed.FullName 'Common7\IDE\devenv.exe'
                if (-not (Test-Path -LiteralPath $exe)) { continue }
                $p = @{ Id = "$($line.Name)-$($ed.Name)"; Edition = $ed.Name; Version = (Get-VsFileVersion $exe); Path = $exe; InstallPath = $ed.FullName; Source = 'folder' }
                if ($line.Name -match '^20\d\d$') { $p.Year = $line.Name }
                New-VsInstall @p
            }
        }
    }
}
function Find-VsLegacyInstalls {
    # Visual Studio 2015 and older predate vswhere's catalog; the registry has their InstallDir.
    foreach ($v in '14.0', '12.0', '11.0', '10.0') {
        $dir = $null
        foreach ($hive in 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio', 'HKLM:\SOFTWARE\Microsoft\VisualStudio') {
            $dir = (Get-ItemProperty -LiteralPath "$hive\$v" -Name InstallDir -ErrorAction SilentlyContinue).InstallDir
            if ($dir) { break }
        }
        if (-not $dir) { continue }
        $exe = Join-Path $dir 'devenv.exe'
        if (-not (Test-Path -LiteralPath $exe)) { continue }
        # InstallDir is <root>\Common7\IDE\
        New-VsInstall -Id "legacy-$v" -Version (Get-VsFileVersion $exe) -Path $exe -InstallPath (Split-Path (Split-Path (Split-Path $exe))) -Source 'registry'
    }
}
function Find-VsManifests {
    # extension.vsixmanifest files below an Extensions folder, at most Depth levels down; a folder
    # that holds one is not searched further. A plain walk: Get-ChildItem -Recurse over Visual
    # Studio's own Extensions tree took seconds on a cold disk.
    param([string]$Root, [int]$Depth = 3)
    if (-not $Root -or -not [System.IO.Directory]::Exists($Root)) { return }
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push(@($Root, 0))
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        $file = [System.IO.Path]::Combine($node[0], 'extension.vsixmanifest')
        if ([System.IO.File]::Exists($file)) { $file; continue }
        if ($node[1] -ge $Depth) { continue }
        try { foreach ($d in [System.IO.Directory]::EnumerateDirectories($node[0])) { $stack.Push(@($d, ($node[1] + 1))) } }
        catch { continue }   # unreadable folder: skip it
    }
}
function Get-VsExtensionDirs {
    # Where an install's VSIX extensions land: per machine below the install, per user in
    # %LOCALAPPDATA%\Microsoft\VisualStudio\<major>.0_<instance id>.
    param([object]$Install)
    if ($Install.InstallPath) { Join-Path $Install.InstallPath 'Common7\IDE\Extensions' }
    if ($Install.Id -and $env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "Microsoft\VisualStudio\$($Install.Major).0_$($Install.Id)\Extensions" }
}
function Get-VsCapabilities {
    # The workload extensions an install carries (SSRS, SSIS): those decide where an SSRS or SSIS
    # project goes, wherever Visual Studio's version would otherwise send it. The extension's own
    # folder answers cheaply; the VSIX manifests are read (once per install) only when it does not.
    param([object]$Install)
    $manifests = $null
    foreach ($w in $script:VsWorkloads) {
        if ($Install.InstallPath -and (Test-Path -LiteralPath (Join-Path $Install.InstallPath "Common7\IDE\CommonExtensions\Microsoft\$($w.Folder)"))) { $w.Cap; continue }
        if ($null -eq $manifests) {
            $manifests = @(foreach ($dir in @(Get-VsExtensionDirs $Install)) {
                    foreach ($f in @(Find-VsManifests $dir)) { try { [System.IO.File]::ReadAllText($f) } catch { '' } }
                })
        }
        foreach ($text in $manifests) { if ($text -match $w.Manifest) { $w.Cap; break } }
    }
}
function Find-VsInstalls {
    $list = @()
    $vw = Get-VsWherePath
    if ($vw) { $list += @(Invoke-VsWhere $vw | ForEach-Object { ConvertFrom-VsWhere $_ }) }
    else { $list += @(Find-VsFolderInstalls) }
    $known = @($list | ForEach-Object { $_.Path })
    $list += @(Find-VsLegacyInstalls | Where-Object { $known -notcontains $_.Path })
    foreach ($i in $list) { $i.Capabilities = @(Get-VsCapabilities $i) }
    $list | Sort-Object Version -Descending
}
function Get-VsInstancesStamp {
    # The Visual Studio Installer keeps a folder per instance here, with a state.json it rewrites
    # on every install, update and repair. The newest write time among those - and the folder's
    # own, which moves when an instance comes or goes - is how a stale cache gets noticed. The
    # folder alone missed updates within a major (17.12 -> 17.14).
    param([string]$Dir = (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Microsoft\VisualStudio\Packages\_Instances'))
    if (-not (Test-Path -LiteralPath $Dir)) { return [long]0 }
    $newest = (Get-Item -LiteralPath $Dir).LastWriteTimeUtc
    foreach ($s in @(Get-ChildItem -LiteralPath $Dir -Filter 'state.json' -Recurse -Depth 1 -File -ErrorAction SilentlyContinue)) {
        if ($s.LastWriteTimeUtc -gt $newest) { $newest = $s.LastWriteTimeUtc }
    }
    ([DateTimeOffset]$newest).ToUnixTimeSeconds()
}
function Save-VsInstalls {
    param([object[]]$Installs)
    $rows = @(foreach ($i in $Installs) {
            [ordered]@{
                Id = $i.Id; Name = $i.Name; Year = $i.Year; Edition = $i.Edition; Version = $i.Version.ToString(); Display = $i.Display
                Path = $i.Path; InstallPath = $i.InstallPath; Prerelease = [bool]$i.Prerelease; Capabilities = @($i.Capabilities); Source = $i.Source
            }
        })
    Write-VsJson 'installs.json' ([ordered]@{ scannedAt = Get-VsNow; installs = $rows })
}
function Read-VsInstallCache {
    # The cached installs; -Cache takes installs.json already parsed. Only a devenv.exe is taken
    # from it: the file says what gets started, so an edited path is not run.
    param([object]$Cache = (Read-VsJson 'installs.json'))
    if (-not $Cache -or -not $Cache.installs) { return }
    foreach ($r in $Cache.installs) {
        $v = $null
        if ([System.IO.Path]::GetFileName([string]$r.Path) -ne 'devenv.exe') { continue }
        if (-not [version]::TryParse([string]$r.Version, [ref]$v)) { continue }
        $p = @{
            Id = [string]$r.Id; Name = [string]$r.Name; Year = [string]$r.Year; Edition = [string]$r.Edition; Version = $v; Display = [string]$r.Display
            Path = [string]$r.Path; InstallPath = [string]$r.InstallPath; Prerelease = [bool]$r.Prerelease; Capabilities = @($r.Capabilities); Source = [string]$r.Source
        }
        New-VsInstall @p
    }
}
function Get-VsInstalls {
    # The cache, unless told to look again - or it is empty, names a devenv.exe that is gone, or
    # predates the installer's last change: those rescan on their own.
    param([switch]$Refresh)
    if (-not $Refresh) {
        $c = Read-VsJson 'installs.json'
        $cached = @(Read-VsInstallCache $c)
        $fresh = $c -and ([long]$c.scannedAt -ge (Get-VsInstancesStamp))
        if ($cached -and $fresh -and -not $cached.Where({ -not [System.IO.File]::Exists($_.Path) })) { return $cached }
    }
    $found = @(Find-VsInstalls)
    Save-VsInstalls $found
    $found
}
function Select-VsNewest {
    # Stable releases before previews, then the highest version, then the biggest edition. One
    # pass, no Sort-Object: this runs for every row of a list.
    param([object[]]$Installs)
    $best = $null; $bestRank = 0
    foreach ($i in $Installs) {
        if (-not $i) { continue }
        $rank = $script:VsEditionRank[[string]$i.Edition]
        if ($null -eq $rank) { $rank = 9 }
        $better = $false
        if (-not $best) { $better = $true }
        elseif ([bool]$i.Prerelease -ne [bool]$best.Prerelease) { $better = -not $i.Prerelease }
        elseif ($i.Version -ne $best.Version) { $better = $i.Version -gt $best.Version }
        else { $better = $rank -lt $bestRank }
        if ($better) { $best = $i; $bestRank = $rank }
    }
    $best
}
function Test-VsInstallWord {
    param([object]$Install, [string]$Word)
    if ($Word -match '^\d{4}$') { return $Install.Year -eq $Word }
    if ($Word -match '^\d{1,2}$') { return $Install.Major -eq [int]$Word }
    if ($Word -eq 'preview') { return [bool]$Install.Prerelease }
    if ($Install.Id -and $Install.Id -eq $Word) { return $true }
    [bool]($Install.Edition -and $Install.Edition.StartsWith($Word, [System.StringComparison]::OrdinalIgnoreCase))
}
function Resolve-VsInstall {
    # -Use <spec>: every word must fit - a year (2019), a major version (16), an edition (Pro,
    # Enterprise: a prefix will do), an instance id, or 'preview'. Newest of the fits.
    param([string]$Spec, [object[]]$Installs)
    $words = @(($Spec -split '[\s,]+').Where({ $_ }))
    $fits = @(@($Installs).Where({
                $i = $_
                -not $words.Where({ -not (Test-VsInstallWord $i $_) })
            }))
    if ($fits) { Select-VsNewest $fits }
}

# --- what a solution asks for ---------------------------------------------------------------
function ConvertTo-VsMajor {
    # '# Visual Studio 2013' (older headers name the year) or '# Visual Studio 14' -> major.
    param([string]$Text)
    if ($Text -match '^20\d\d$') {
        foreach ($k in $script:VsYears.Keys) { if ($script:VsYears[$k] -eq $Text) { return [int]$k } }
        return 0
    }
    [int]$Text
}
function Get-VsSolutionNeeds {
    param([string]$Text)
    foreach ($w in $script:VsWorkloads) {
        $hit = $false
        foreach ($e in $w.Extensions) { if ($Text -match ([regex]::Escape($e) + '"')) { $hit = $true } }
        foreach ($g in $w.Guids) { if ($Text.IndexOf($g, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true } }
        if ($hit) { $w.Cap }
    }
}
function Get-VsTargetInfo {
    # What a path asks of Visual Studio: Kind (folder, solution, filter, project, file), the major
    # version that saved it (Saved, 0 = unknown), the minimum version it declares (MinVersion)
    # and the workload extensions it needs (Needs: SSRS, SSIS).
    param([string]$Path)
    $info = [pscustomobject]@{ Path = $Path; Name = (Split-Path $Path -Leaf); Kind = 'file'; Saved = 0; MinVersion = $null; Needs = @() }
    if (-not $info.Name) { $info.Name = $Path }
    if (Test-Path -LiteralPath $Path -PathType Container) { $info.Kind = 'folder'; return $info }
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    $text = ''
    if ($ext -in '.sln', '.slnx', '.slnf') { try { $text = [System.IO.File]::ReadAllText($Path) } catch { $text = '' } }
    switch ($ext) {
        '.sln' {
            $info.Kind = 'solution'
            if ($text -match '(?m)^\s*VisualStudioVersion\s*=\s*(\d+)\.') { $info.Saved = [int]$Matches[1] }
            elseif ($text -match '(?m)^#\s*Visual Studio Version\s+(\d+)') { $info.Saved = [int]$Matches[1] }
            elseif ($text -match '(?m)^#\s*Visual Studio\s+(\d+)') { $info.Saved = ConvertTo-VsMajor $Matches[1] }
            if ($text -match '(?m)^\s*MinimumVisualStudioVersion\s*=\s*([\d.]+)') {
                $min = $null
                # 10.0.40219.1 is what nearly every solution says since 2010: no information.
                if ([version]::TryParse($Matches[1], [ref]$min) -and $min.Major -gt 10) { $info.MinVersion = $min }
            }
            $info.Needs = @(Get-VsSolutionNeeds $text)
        }
        '.slnx' {
            $info.Kind = 'solution'
            $info.MinVersion = $script:SlnxMinVersion
            $info.Needs = @(Get-VsSolutionNeeds $text)
        }
        '.slnf' {
            # A solution filter opens its solution, so that one decides.
            $info.Kind = 'filter'
            $sln = $null
            try { $sln = [string](ConvertFrom-Json $text).solution.path } catch { $sln = $null }
            if ($sln) {
                $full = Join-Path (Split-Path $Path -Parent) $sln
                if (Test-Path -LiteralPath $full -PathType Leaf) {
                    $base = Get-VsTargetInfo $full
                    $info.Saved = $base.Saved; $info.MinVersion = $base.MinVersion; $info.Needs = $base.Needs
                }
            }
        }
        default {
            if ($script:VsProjectExtensions -contains $ext) { $info.Kind = 'project' }
            $info.Needs = @($script:VsWorkloads.Where({ $_.Extensions -contains $ext }) | ForEach-Object { $_.Cap })
        }
    }
    $info
}
function Select-VsInstall {
    # Which install opens a target, and why: @{ Install; Reason; Warning }. -Use wins outright;
    # otherwise the workload extensions narrow the field first, then the minimum version, then
    # (match = solution) the version that saved it; the newest stable install of what is left.
    param([object]$Info, [object[]]$Installs, [string]$Use, [string]$Match = 'newest')
    $r = [pscustomobject]@{ Install = $null; Reason = ''; Warning = '' }
    if (-not $Installs) { $r.Warning = 'no Visual Studio found - vs scan looks again'; return $r }
    if ($Use) {
        $r.Install = Resolve-VsInstall $Use $Installs
        if ($r.Install) { $r.Reason = "-Use $Use" } else { $r.Warning = "no Visual Studio install fits '$Use' - see: vs installs" }
        return $r
    }
    $pool = @($Installs); $why = @()
    # The minimum version first: an older install cannot open the solution at all, while one
    # without an extension still opens it, minus the projects that need the extension.
    if ($Info.MinVersion) {
        $min = "$($Info.MinVersion.Major).$($Info.MinVersion.Minor)"
        $fit = @($pool.Where({ $_.Version -ge $Info.MinVersion }))
        if ($fit) {
            if ($fit.Count -lt $pool.Count) { $why += "needs $min or newer" }
            $pool = $fit
        }
        else { $r.Warning = "'$($Info.Name)' needs Visual Studio $min or newer - none installed" }
    }
    foreach ($cap in $Info.Needs) {
        $w = $script:VsWorkloads.Where({ $_.Cap -eq $cap }, 'First')[0]
        $fit = @($pool.Where({ $_.Capabilities -contains $cap }))
        if ($fit) { $pool = $fit; $why += "$cap project, needs the $($w.Label) extension" }
        else { $r.Warning = "no Visual Studio that can open it has the $($w.Label) extension ($cap) - those projects may not load" }
    }
    if ($Match -eq 'solution' -and $Info.Saved) {
        $fit = @($pool.Where({ $_.Major -eq $Info.Saved }))
        if ($fit) {
            $pool = $fit
            $year = if ($script:VsYears.ContainsKey($Info.Saved)) { $script:VsYears[$Info.Saved] } else { $Info.Saved }
            $why += "saved by Visual Studio $year"
        }
    }
    $r.Install = Select-VsNewest $pool
    $r.Reason = if ($why) { $why -join '; ' } else { 'newest install' }
    $r
}

# --- finding solutions ----------------------------------------------------------------------
function Get-VsRelativePath {
    param([string]$Base, [string]$Path)
    $b = $Base.TrimEnd('\', '/'); $p = $Path.TrimEnd('\', '/')
    if ($p -eq $b) { return '.' }
    if ($p.StartsWith($b + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $p.Substring($b.Length + 1) }
    $p
}
function Test-VsLinkDir {
    # A junction or symbolic link: not followed, a link can loop or lead back into the tree. The
    # ReparsePoint attribute alone does not tell - OneDrive's Files On-Demand folders carry it
    # without being links - so it is only the reason to ask.
    param([System.IO.DirectoryInfo]$Dir)
    (Get-Item -LiteralPath $Dir.FullName -Force -ErrorAction SilentlyContinue).LinkType -in 'Junction', 'SymbolicLink'
}
function Test-VsDriveRoot {
    param([string]$Path)
    $Path.TrimEnd('\', '/') -match '^[A-Za-z]:$'
}
function Find-VsFiles {
    # Breadth-first walk below Root, Depth folder levels deep, for files with one of the given
    # extensions. A folder that holds a match is not searched further down unless -All: the
    # solution at the top of a subtree is the one meant, the ones nested below it are its parts
    # (backend\Backend.sln, not every backend\<service>\<service>.sln). Skipped: dot-folders, the
    # skip list, hidden folders (Hidden only - Windows marks customised folders System or
    # ReadOnly), the Windows and program folders at a drive root, and links.
    param([string]$Root, [string[]]$Extensions, [int]$Depth = 3, [switch]$All)
    $atDriveRoot = Test-VsDriveRoot $Root
    $hidden = [System.IO.FileAttributes]::Hidden
    $reparse = [System.IO.FileAttributes]::ReparsePoint
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue(@($Root, 0))
    while ($queue.Count -gt 0) {
        $node = $queue.Dequeue()
        $dir = $node[0]; $level = $node[1]
        $hits = @()
        try {
            $di = New-Object System.IO.DirectoryInfo $dir
            foreach ($f in $di.EnumerateFiles()) { if ($Extensions -contains $f.Extension) { $hits += $f } }
        }
        catch { continue }   # unreadable folder: skip it, keep walking the rest
        foreach ($f in $hits) {
            [pscustomobject]@{ Name = $f.Name; Path = $f.FullName; Dir = (Get-VsRelativePath $Root $f.DirectoryName); Level = $level }
        }
        if (($hits -and -not $All) -or $level -ge $Depth) { continue }
        try {
            foreach ($d in $di.EnumerateDirectories()) {
                $name = $d.Name
                if ($name.StartsWith('.') -or $script:VsSkipDirs -contains $name) { continue }
                $attr = $d.Attributes
                if ($attr -band $hidden) { continue }
                if ($atDriveRoot -and $level -eq 0 -and $script:VsDriveRootSkipDirs -contains $name) { continue }
                if (($attr -band $reparse) -and (Test-VsLinkDir $d)) { continue }
                $queue.Enqueue(@($d.FullName, ($level + 1)))
            }
        }
        catch { continue }
    }
}
function Find-VsSolutionsUp {
    # Nothing below: maybe we are inside a project. The nearest folder above that holds a
    # solution, but not past the top of the git repository, and at most 5 levels up.
    param([string]$Root)
    $cur = New-Object System.IO.DirectoryInfo $Root
    for ($i = 1; $i -le 5; $i++) {
        if (Test-Path -LiteralPath (Join-Path $cur.FullName '.git')) { return }
        $cur = $cur.Parent
        if (-not $cur) { return }
        $hits = @()
        try { $hits = @($cur.EnumerateFiles() | Where-Object { $script:VsSolutionExtensions -contains $_.Extension }) } catch { $hits = @() }
        if ($hits) {
            $up = (@('..') * $i) -join '\'
            foreach ($f in ($hits | Sort-Object Name)) { [pscustomobject]@{ Name = $f.Name; Path = $f.FullName; Dir = $up; Level = -$i } }
            return
        }
    }
}
function Find-VsCandidates {
    # What `vs` offers for a folder: its solutions; failing that the nearest solution above it;
    # failing that its project files. Returns @{ Items; Source = below | above | projects }.
    param([string]$Root, [int]$Depth, [switch]$All)
    $order = @{ Expression = { $_.Level -gt 0 } }, 'Dir', 'Name'
    $items = @(Find-VsFiles $Root $script:VsSolutionExtensions $Depth -All:$All | Sort-Object $order)
    if ($items) { return @{ Items = $items; Source = 'below' } }
    $items = @(Find-VsSolutionsUp $Root)
    if ($items) { return @{ Items = $items; Source = 'above' } }
    $items = @(Find-VsFiles $Root $script:VsProjectExtensions $Depth -All:$All | Sort-Object $order)
    @{ Items = $items; Source = 'projects' }
}
function Test-VsFuzzyMatch {
    # Subsequence match, case-insensitive: every character of the filter occurs in the text in
    # order, not necessarily next to each other - 'bknd' finds 'Backend.sln'. Spaces are skipped.
    param([string]$Text, [string]$Filter)
    if (-not $Filter) { return $true }
    $t = $Text.ToLowerInvariant()
    $i = 0
    foreach ($c in $Filter.ToLowerInvariant().ToCharArray()) {
        if ([char]::IsWhiteSpace($c)) { continue }
        $i = $t.IndexOf($c, $i)
        if ($i -lt 0) { return $false }
        $i++
    }
    return $true
}
function Test-VsPrefix {
    # Prefix match on typed text, taken literally (-like would read '[' and '*' as wildcards).
    param([string]$Text, [string]$Prefix)
    $Text.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)
}
function Get-VsFilterMatches {
    # Name and folder are matched as one string. Names that carry the filter literally lead, so
    # a loose subsequence hit cannot outrank the solution that actually reads that way.
    param([object[]]$Items, [string]$Filter)
    $hits = @(@($Items).Where({ Test-VsFuzzyMatch "$($_.Name) $($_.Dir)" $Filter }))
    $needle = $Filter.Replace(' ', '').ToLowerInvariant()
    if (-not $needle) { return $hits }
    $direct = @($hits.Where({ $_.Name.ToLowerInvariant().Contains($needle) }))
    $loose = @($hits.Where({ -not $_.Name.ToLowerInvariant().Contains($needle) }))
    $direct + $loose
}

# --- console --------------------------------------------------------------------------------
function Test-VsConsole {
    # The picker and the prompt drive the console directly; without one to drive (another host,
    # redirected input or output) they fall back to plain text.
    if ($Host.Name -ne 'ConsoleHost') { return $false }
    try { -not ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) } catch { $false }
}
function Get-VsConsoleWidth {
    # WindowWidth throws when stdout is redirected (no console handle); fall back so a row
    # still prints instead of taking the picker down.
    $w = try { [Console]::WindowWidth - 1 } catch { $Host.UI.RawUI.WindowSize.Width - 1 }
    if (-not $w -or $w -lt 1) { $w = 119 }
    $w
}
function Get-VsConsoleHeight {
    $h = try { [Console]::WindowHeight } catch { 30 }
    if (-not $h -or $h -lt 10) { $h = 30 }
    $h
}
function Format-VsCell {
    # Pad or clip to an exact column width; '..' marks a cut.
    param([string]$Text, [int]$Width)
    if ($Width -lt 1) { return '' }
    if ($Text.Length -le $Width) { return $Text.PadRight($Width) }
    if ($Width -le 2) { return $Text.Substring(0, $Width) }
    $Text.Substring(0, $Width - 2) + '..'
}
function Write-VsTable {
    # Format-Table -AutoSize drops whole trailing columns once the wide ones fill the console.
    # Clip the columns named in -Clip instead (in that order), so every column stays on screen.
    param([object[]]$Rows, [string[]]$Columns, [string[]]$Clip = @())
    if (-not $Rows) { return }
    $w = @{}
    $gap = 2
    $over = $gap * ($Columns.Count - 1) - (Get-VsConsoleWidth)
    foreach ($c in $Columns) {
        $max = $c.Length
        foreach ($r in $Rows) { $len = ([string]$r.$c).Length; if ($len -gt $max) { $max = $len } }
        $w[$c] = $max
        $over += $max
    }
    foreach ($c in $Clip) {
        if ($over -le 0 -or -not $w.ContainsKey($c)) { continue }
        $take = [Math]::Max(0, [Math]::Min($over, $w[$c] - 10)); $w[$c] -= $take; $over -= $take
    }
    $sep = ' ' * $gap
    $head = @(); $rule = @()
    foreach ($c in $Columns) { $head += Format-VsCell $c $w[$c]; $rule += '-' * $w[$c] }
    Write-Host ''
    Write-Host (($head -join $sep).TrimEnd()) -ForegroundColor Green
    Write-Host (($rule -join $sep).TrimEnd()) -ForegroundColor Green
    foreach ($r in $Rows) {
        $cells = foreach ($c in $Columns) { Format-VsCell ([string]$r.$c) $w[$c] }
        Write-Host (($cells -join $sep).TrimEnd())
    }
    Write-Host ''
}
function Write-VsLine {
    # One console row written as coloured segments - @{ T = text; F = fg; B = bg } - and blanked
    # to the console width, so a shorter frame cannot leave the previous one showing.
    param([object[]]$Segments)
    $w = Get-VsConsoleWidth
    $used = 0
    foreach ($s in $Segments) {
        if ($used -ge $w) { break }
        $text = [string]$s.T
        if ($used + $text.Length -gt $w) { $text = $text.Substring(0, $w - $used) }
        $p = @{ Object = $text; NoNewline = $true }
        if ($s.F) { $p.ForegroundColor = $s.F }
        if ($s.B) { $p.BackgroundColor = $s.B }
        Write-Host @p
        $used += $text.Length
    }
    Write-Host (' ' * ($w - $used))
}
function Get-VsKeySegments {
    # A key bar: keys lit, labels dim, so it reads as controls rather than as one more row.
    param([string[]]$Pairs)
    $out = @()
    for ($i = 0; $i -lt $Pairs.Count; $i += 2) {
        $out += @{ T = $(if ($i -eq 0) { '  ' } else { '   ' }) + $Pairs[$i]; F = 'Yellow' }
        $out += @{ T = ' ' + $Pairs[$i + 1]; F = 'DarkGray' }
    }
    $out
}

# --- opening --------------------------------------------------------------------------------
function ConvertTo-VsArgument {
    # One command-line argument for devenv: quoted (Start-Process passes it verbatim and paths
    # carry spaces), trailing backslashes doubled so 'C:\' cannot escape the closing quote.
    param([string]$Path)
    '"' + ($Path -replace '(\\+)$', '$1$1') + '"'
}
function Start-VsProcess {
    # A process of its own: Visual Studio outlives the shell and does not hold it up.
    param([string]$Exe, [string]$Argument, [switch]$Admin)
    $p = @{ FilePath = $Exe; ArgumentList = $Argument; ErrorAction = 'Stop' }
    if ($Admin) { $p.Verb = 'RunAs' }
    Start-Process @p
}
function Open-VsTarget {
    # Solutions, projects and folders open in a Visual Studio of their own; a plain file goes to
    # one that is already running (/Edit), the way double-clicking it would.
    param([object]$Info, [object]$Install, [switch]$Admin)
    $argument = ConvertTo-VsArgument $Info.Path
    if ($Info.Kind -eq 'file') { $argument = "/Edit $argument" }
    try { Start-VsProcess $Install.Path $argument -Admin:$Admin }
    catch { Write-VsFail "could not start $($Install.Path): $($_.Exception.Message)" Red; return }
    $as = if ($Admin) { ' as administrator' } else { '' }
    Write-Host "opened $($Info.Name) in $($Install.Name)$as" -ForegroundColor Green
}
function Confirm-VsOpen {
    # Enter opens, Tab tries the next install (Shift+Tab the previous), Esc cancels. Returns the
    # install to open with, or $null.
    param([object]$Info, [object]$Match, [object[]]$Installs)
    $what = if ($Info.Kind -eq 'folder') { "the folder $($Info.Path)" } else { "'$($Info.Name)'" }
    if (-not (Test-VsConsole)) {
        $a = Read-Host "open $what in $($Match.Install.Name)? [Y/n]"
        if ($a.Trim().ToLowerInvariant() -in '', 'y', 'yes') { return $Match.Install }
        return $null
    }
    $list = @($Installs)
    $idx = [Math]::Max(0, [array]::IndexOf($list, $Match.Install))
    $reason = $Match.Reason
    # Reserve the rows first so the buffer scrolls once, then redraw them in place.
    for ($i = 0; $i -lt 3; $i++) { Write-Host '' }
    $top = [Math]::Max(0, [Console]::CursorTop - 3)
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            $inst = $list[$idx]
            [Console]::SetCursorPosition(0, $top)
            Write-VsLine @(@{ T = "open $what in " }, @{ T = $inst.Name; F = 'Cyan' }, @{ T = " ($($inst.Display))"; F = 'DarkGray' })
            Write-VsLine @(@{ T = "  $reason"; F = 'DarkGray' })
            $keys = @('enter', 'open')
            if ($list.Count -gt 1) { $keys += 'tab', 'other Visual Studio' }
            Write-VsLine (Get-VsKeySegments ($keys + @('esc', 'cancel')))
            $k = [Console]::ReadKey($true)
            switch ($k.Key) {
                'Enter' { return $inst }
                'Y' { return $inst }
                'Escape' { return $null }
                'N' { return $null }
                'Tab' {
                    if ($list.Count -gt 1) {
                        $step = if ($k.Modifiers -band [ConsoleModifiers]::Shift) { -1 } else { 1 }
                        $idx = ($idx + $step + $list.Count) % $list.Count
                        $reason = if ($list[$idx] -eq $Match.Install) { $Match.Reason } else { 'picked by hand' }
                    }
                }
            }
        }
    }
    finally {
        # Keep the question, drop the key bar.
        [Console]::SetCursorPosition(0, $top + 2)
        Write-VsLine @(@{ T = '' })
        [Console]::SetCursorPosition(0, $top + 2)
        [Console]::CursorVisible = $true
    }
}
function Open-VsOne {
    # One target: work out the install, ask unless told not to, open.
    param([object]$Info, [object[]]$Installs, [string]$Use, [string]$Match, [bool]$Ask, [switch]$Admin)
    $m = Select-VsInstall $Info $Installs $Use $Match
    if (-not $m.Install) { Write-VsFail "warning: $($m.Warning)"; return }
    if ($m.Warning) { Write-Host "warning: $($m.Warning)" -ForegroundColor Yellow }
    $inst = $m.Install
    if ($Ask) {
        $inst = Confirm-VsOpen $Info $m $Installs
        if (-not $inst) { Write-VsFail 'cancelled' DarkGray; return }
    }
    Open-VsTarget $Info $inst -Admin:$Admin
}
function ConvertTo-VsRows {
    # Candidates plus the install each one gets: what the picker and `vs list` show.
    param([object[]]$Items, [object[]]$Installs, [string]$Use, [string]$Match)
    foreach ($i in $Items) {
        $m = Select-VsInstall (Get-VsTargetInfo $i.Path) $Installs $Use $Match
        $label = if ($m.Install) { $m.Install.Label } else { '-' }
        [pscustomobject]@{ Name = $i.Name; Path = $i.Path; Dir = $i.Dir; Match = $m; Install = $m.Install; VS = $label; Why = $(if ($m.Warning) { $m.Warning } else { $m.Reason }) }
    }
}
function Show-VsPicker {
    # Draw the list and return the pick - @{ Row; Install } - or $null. Tab swaps the Visual
    # Studio of the highlighted row through the installs; the VS column shows the choice.
    param([object[]]$All, [object[]]$Installs, [string]$Filter = '')
    $nameW = [Math]::Max(4, ($All | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum)
    $vsW = [Math]::Max(2, ($Installs | ForEach-Object { $_.Label.Length } | Measure-Object -Maximum).Maximum)
    $dirW = [Math]::Max(6, ($All | ForEach-Object { $_.Dir.Length } | Measure-Object -Maximum).Maximum)
    # Keep the block inside the console: the folder column gives way first, the name after.
    $over = ($nameW + $vsW + $dirW + 8) - (Get-VsConsoleWidth)
    if ($over -gt 0) { $take = [Math]::Max(0, [Math]::Min($over, $dirW - 10)); $dirW -= $take; $over -= $take }
    if ($over -gt 0) { $nameW = [Math]::Max(10, $nameW - $over) }
    # Long lists scroll inside a window that fits the console.
    $view = [Math]::Min($All.Count, [Math]::Max(3, (Get-VsConsoleHeight) - 9))
    $rows = $view + 6
    $rule = '  ' + ('-' * ($nameW + $vsW + $dirW + 4))
    $rowsShown = @(Get-VsFilterMatches $All $Filter)
    $sel = 0; $off = 0
    $pick = @{}   # Path -> install picked with Tab
    [Console]::CursorVisible = $false
    for ($i = 0; $i -lt $rows; $i++) { Write-Host '' }
    $top = [Math]::Max(0, [Console]::CursorTop - $rows)
    $result = $null
    $done = $false
    try {
        while (-not $done) {
            if ($sel -lt $off) { $off = $sel }
            if ($sel -ge $off + $view) { $off = $sel - $view + 1 }
            [Console]::SetCursorPosition(0, $top)
            Write-VsLine @(@{ T = '' })
            if ($Filter) {
                Write-VsLine (@(@{ T = '  filter '; F = 'DarkGray' }, @{ T = " $Filter "; F = 'Black'; B = 'Yellow' }, @{ T = "  $($rowsShown.Count)/$($All.Count) match"; F = 'Gray' }) +
                    (Get-VsKeySegments @('backspace', 'deletes', 'esc', 'clears', 'enter', 'open')))
            }
            else {
                Write-VsLine (Get-VsKeySegments @('up/down', 'move', 'enter', 'open', 'tab', 'other Visual Studio', 'esc', 'cancel', 'type', 'to filter'))
            }
            Write-VsLine @(@{ T = '' })
            Write-VsLine @(@{ T = '  ' + (Format-VsCell 'NAME' $nameW) + '  ' + (Format-VsCell 'VS' $vsW) + '  FOLDER'; F = 'DarkGray' })
            Write-VsLine @(@{ T = $rule; F = 'DarkGray' })
            for ($i = $off; $i -lt [Math]::Min($rowsShown.Count, $off + $view); $i++) {
                $r = $rowsShown[$i]
                $inst = if ($pick.ContainsKey($r.Path)) { $pick[$r.Path] } else { $r.Install }
                $vsText = if ($inst) { $inst.Label } else { '-' }
                $nameCell = (Format-VsCell $r.Name $nameW) + '  '
                $vsCell = (Format-VsCell $vsText $vsW) + '  '
                $dirCell = Format-VsCell $r.Dir $dirW
                if ($i -eq $sel) {
                    Write-VsLine @(@{ T = '  ' + $nameCell + $vsCell + $dirCell; F = 'Black'; B = 'Cyan' })
                }
                else {
                    $vsColor = if ($pick.ContainsKey($r.Path)) { 'Magenta' } elseif ($r.Match.Warning) { 'Yellow' } else { 'Gray' }
                    Write-VsLine @(@{ T = '  ' + $nameCell; F = 'White' }, @{ T = $vsCell; F = $vsColor }, @{ T = $dirCell; F = 'DarkGray' })
                }
            }
            $drawn = [Math]::Max(0, [Math]::Min($rowsShown.Count - $off, $view))
            if (-not $rowsShown.Count) { Write-VsLine @(@{ T = "  nothing matches '$Filter'"; F = 'Yellow' }); $drawn = 1 }
            for ($i = $drawn; $i -lt $view; $i++) { Write-VsLine @(@{ T = '' }) }
            $foot = ''
            if ($rowsShown.Count -gt $view) { $foot = "  $($sel + 1)/$($rowsShown.Count) - pgup/pgdn page" }
            elseif ($rowsShown.Count -and $sel -ge 0) {
                $cur = $rowsShown[$sel]
                $foot = if ($pick.ContainsKey($cur.Path)) { '  picked by hand' } else { "  $($cur.Why)" }
            }
            Write-VsLine @(@{ T = $foot; F = 'DarkGray' })
            $k = [Console]::ReadKey($true)
            $before = $Filter
            $count = $rowsShown.Count
            switch ($k.Key) {
                'UpArrow' { if ($count) { $sel = ($sel - 1 + $count) % $count } }
                'DownArrow' { if ($count) { $sel = ($sel + 1) % $count } }
                'PageUp' { $sel = [Math]::Max(0, $sel - $view) }
                'PageDown' { $sel = [Math]::Max(0, [Math]::Min($count - 1, $sel + $view)) }
                'Home' { $sel = 0 }
                'End' { $sel = [Math]::Max(0, $count - 1) }
                'Enter' {
                    if ($count) {
                        $r = $rowsShown[$sel]
                        $inst = if ($pick.ContainsKey($r.Path)) { $pick[$r.Path] } else { $r.Install }
                        if ($inst) { $result = @{ Row = $r; Install = $inst }; $done = $true }
                    }
                }
                'Tab' {
                    if ($count -and $Installs.Count -gt 1) {
                        $r = $rowsShown[$sel]
                        $now = if ($pick.ContainsKey($r.Path)) { $pick[$r.Path] } else { $r.Install }
                        $step = if ($k.Modifiers -band [ConsoleModifiers]::Shift) { -1 } else { 1 }
                        $next = $Installs[([Math]::Max(0, [array]::IndexOf($Installs, $now)) + $step + $Installs.Count) % $Installs.Count]
                        if ($next -eq $r.Install) { $pick.Remove($r.Path) } else { $pick[$r.Path] = $next }
                    }
                }
                'Escape' { if ($Filter) { $Filter = '' } else { $done = $true } }
                'Backspace' { if ($Filter) { $Filter = $Filter.Substring(0, $Filter.Length - 1) } }
                default { if ($k.KeyChar -and -not [char]::IsControl($k.KeyChar)) { $Filter += $k.KeyChar } }
            }
            if ($Filter -ne $before) {
                # Keep the highlight on the row it was on while the set shrinks around it.
                $keep = if ($count) { $rowsShown[$sel].Path } else { '' }
                $rowsShown = @(Get-VsFilterMatches $All $Filter)
                $sel = 0; $off = 0
                for ($i = 0; $i -lt $rowsShown.Count; $i++) { if ($rowsShown[$i].Path -eq $keep) { $sel = $i } }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $true
        [Console]::SetCursorPosition(0, $top)
        $blank = ' ' * (Get-VsConsoleWidth)
        for ($i = 0; $i -lt $rows; $i++) { Write-Host $blank }
        [Console]::SetCursorPosition(0, $top)
    }
    $result
}
function Select-VsSolution {
    param([object[]]$Items, [object[]]$Installs, [string]$Use, [string]$Match, [string]$Filter, [switch]$Admin)
    $rows = @(ConvertTo-VsRows $Items $Installs $Use $Match)
    if (-not (Test-VsConsole)) {
        Write-VsTable $rows 'Name', 'VS', 'Dir' -Clip 'Dir', 'Name'
        Write-VsFail 'several found - open one with: vs <name or path>' DarkGray
        return
    }
    # Last object only: a stray write inside the picker must not turn this into an array.
    $r = Show-VsPicker $rows @($Installs) $Filter | Select-Object -Last 1
    if (-not $r) { Write-VsFail 'cancelled' DarkGray; return }
    if ($r.Row.Match.Warning -and $r.Install -eq $r.Row.Install) { Write-Host "warning: $($r.Row.Match.Warning)" -ForegroundColor Yellow }
    Open-VsTarget (Get-VsTargetInfo $r.Row.Path) $r.Install -Admin:$Admin
}
function Get-VsHere {
    # The current folder as a file-system path, or $null in another provider (HKLM:, Env:).
    $loc = Get-Location
    if ($loc.Provider.Name -ne 'FileSystem') { return $null }
    $loc.ProviderPath
}
function Resolve-VsRoot {
    # Where to search: the given folder, else the current one. $null (after saying why) when
    # there is no such folder.
    param([string]$Path)
    if (-not $Path) {
        $here = Get-VsHere
        if (-not $here) { Write-VsFail "not a folder on disk: $(Get-Location) - cd somewhere first" }
        return $here
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Write-VsFail "no such folder: $Path"; return $null }
    (Get-Item -LiteralPath $Path -Force).FullName
}
function Invoke-VsOpen {
    param([string]$Target, [string]$Use, [int]$Depth, [switch]$All, [switch]$Yes, [switch]$Folder, [switch]$Admin)
    $cfg = Get-VsConfig
    if (-not $Depth) { $Depth = [int]$cfg.depth }
    $ask = -not $Yes -and $cfg.confirm -ne 'off'
    $installs = @(Get-VsInstalls)
    if (-not $installs) { Write-VsFail 'no Visual Studio found on this machine - installed since? vs scan looks again' Red; return }

    # `vs .` is `code .`: this folder itself, in Open Folder mode.
    if ($Target -in '.', '.\', './') { $Folder = $true; $Target = '' }
    $filter = ''
    if ($Target -and (Test-Path -LiteralPath $Target -PathType Leaf)) {
        Open-VsOne (Get-VsTargetInfo (Get-Item -LiteralPath $Target -Force).FullName) $installs $Use $cfg.match $ask -Admin:$Admin
        return
    }
    if ($Target -and -not (Test-Path -LiteralPath $Target)) {
        # Something with a slash or a drive in it was meant as a path: say it is not there,
        # rather than look for a solution by that name.
        if ($Target -match '[\\/:]') { Write-VsFail "no such file or folder: $Target"; return }
        $filter = $Target; $Target = ''
    }
    $root = Resolve-VsRoot $Target
    if (-not $root) { return }
    if ($Folder) { Open-VsOne (Get-VsTargetInfo $root) $installs $Use $cfg.match $ask -Admin:$Admin; return }

    # Looking for a name: nested solutions count too, the one named may sit below another.
    $found = Find-VsCandidates $root $Depth -All:($All -or [bool]$filter)
    $items = @($found.Items)
    if ($filter) {
        $hits = @(Get-VsFilterMatches $items $filter)
        if (-not $hits) {
            Write-VsFail "no solution matching '$filter' below $root"
            Write-Host '  vs list -All shows every solution vs can see here' -ForegroundColor DarkGray
            return
        }
        # An exact name wins outright (Backend over BackendTests), then a single literal hit,
        # then a single loose one; anything else goes to the picker, filtered.
        $exact = @($hits | Where-Object { $_.Name -eq $filter -or [System.IO.Path]::GetFileNameWithoutExtension($_.Name) -eq $filter })
        $needle = $filter.Replace(' ', '').ToLowerInvariant()
        $direct = @($hits | Where-Object { $_.Name.ToLowerInvariant().Contains($needle) })
        if ($exact.Count -eq 1) { $items = $exact }
        elseif ($direct.Count -eq 1) { $items = $direct }
        elseif ($hits.Count -eq 1) { $items = $hits }
    }
    if (-not $items) {
        Write-VsFail "no solution or project file below $root (depth $Depth)"
        Write-Host '  vs . opens the folder itself; -Depth <n> searches deeper' -ForegroundColor DarkGray
        return
    }
    if ($found.Source -eq 'above') { Write-Host "nothing below $root - found above it" -ForegroundColor DarkGray }
    elseif ($found.Source -eq 'projects') { Write-Host "no solution below $root - showing project files" -ForegroundColor DarkGray }
    if ($items.Count -eq 1) { Open-VsOne (Get-VsTargetInfo $items[0].Path) $installs $Use $cfg.match $ask -Admin:$Admin; return }
    Select-VsSolution $items $installs $Use $cfg.match $filter -Admin:$Admin
}
function Show-VsSolutions {
    param([string]$Path, [string]$Use, [int]$Depth, [switch]$All)
    $cfg = Get-VsConfig
    if (-not $Depth) { $Depth = [int]$cfg.depth }
    $root = Resolve-VsRoot $Path
    if (-not $root) { return }
    $installs = @(Get-VsInstalls)
    $found = Find-VsCandidates $root $Depth -All:$All
    if (-not $found.Items) { Write-VsFail "no solution or project file below $root (depth $Depth)"; return }
    if ($found.Source -eq 'above') { Write-Host "nothing below $root - found above it" -ForegroundColor DarkGray }
    elseif ($found.Source -eq 'projects') { Write-Host "no solution below $root - project files" -ForegroundColor DarkGray }
    $rows = @(ConvertTo-VsRows $found.Items $installs $Use $cfg.match)
    Write-VsTable $rows 'Name', 'VS', 'Dir', 'Why' -Clip 'Why', 'Dir', 'Name'
}
function Show-VsInstalls {
    param([switch]$Refresh)
    if ($Refresh) { Write-Host 'looking for Visual Studio installs...' -ForegroundColor DarkGray }
    $list = @(Get-VsInstalls -Refresh:$Refresh)
    if (-not $list) {
        Write-VsFail 'no Visual Studio found: not through vswhere, the registry or the default install folders'
        return
    }
    $default = Select-VsNewest $list
    $rows = foreach ($i in $list) {
        $mark = if ($i -eq $default) { '*' } else { '' }
        [pscustomobject]@{ Def = $mark; Name = $i.Name; Version = $i.Display; Id = $i.Id; Ext = (@($i.Capabilities) -join ','); Path = $i.Path }
    }
    Write-VsTable @($rows) 'Def', 'Name', 'Version', 'Id', 'Ext', 'Path' -Clip 'Path', 'Name'
    $c = Read-VsJson 'installs.json'
    $when = if ($c -and $c.scannedAt) { [DateTimeOffset]::FromUnixTimeSeconds([long]$c.scannedAt).LocalDateTime.ToString('yyyy-MM-dd HH:mm') } else { '?' }
    Write-Host "  * opens whatever has no reason to go elsewhere. Ext: workload extensions found (SSRS, SSIS)." -ForegroundColor DarkGray
    Write-Host "  scanned $when, cached in $(Join-Path (Get-VsHome) 'installs.json') - vs scan looks again" -ForegroundColor DarkGray
}

# --- version and updates --------------------------------------------------------------------
function Get-VsInstallMethod {
    # How this copy got here, from the module folder: Scoop (apps\psvscommand, or the modules
    # junction pointing there), a checkout (src\PSVsCommand of a git clone, junctioned by
    # `task link` or loaded by path), or anything else - a manual zip install.
    param([string]$Root = $PSScriptRoot)
    $dir = $Root
    $item = Get-Item -LiteralPath $Root -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType -and $item.Target) { $dir = [string](@($item.Target)[0]) }
    $r = [pscustomobject]@{ Method = 'manual'; Path = $dir; Clone = ''; Global = $false }
    $slash = $dir -replace '\\', '/'
    if ($slash -match '/apps/psvscommand(/|$)') {
        # `scoop install -g` lands in SCOOP_GLOBAL, by default ProgramData\scoop; updating that
        # takes -g and an elevated shell.
        $r.Method = 'scoop'
        $globalDir = if ($env:SCOOP_GLOBAL) { $env:SCOOP_GLOBAL } else { Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'scoop' }
        $r.Global = $dir.StartsWith($globalDir.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)
        return $r
    }
    $parent = Split-Path $dir -Parent
    if ($parent -and (Split-Path $parent -Leaf) -eq 'src') {
        $clone = Split-Path $parent -Parent
        if ($clone -and (Test-Path -LiteralPath (Join-Path $clone '.git'))) { $r.Method = 'checkout'; $r.Clone = $clone }
    }
    $r
}
# Scoop refreshes its copy of a bucket only on a bare `scoop update` (or once its last one is a few
# hours old): right after a release, `scoop update psvscommand` alone still reads the old manifest
# and calls the old version the latest.
$script:VsScoopUpdate = 'scoop update; scoop update psvscommand'
function Get-VsUpdateCommand {
    param([object]$How)
    switch ($How.Method) {
        'scoop' { if ($How.Global) { "$script:VsScoopUpdate --global (as administrator)" } else { $script:VsScoopUpdate } }
        'checkout' { "git -C '$($How.Clone)' pull" }
        default { 'vs update' }
    }
}
function Get-VsLatestRelease {
    # The newest release's version, read from where github.com/<repo>/releases/latest redirects
    # (.../releases/tag/v1.2.0): one HEAD request, no API and so no rate limit, a short timeout.
    # $null when offline, blocked, or there is no release yet.
    param([int]$TimeoutMs = 2500)
    try {
        if ($PSVersionTable.PSEdition -ne 'Core') {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        }
        $req = [System.Net.HttpWebRequest]::Create("$script:ProjectUrl/releases/latest")
        $req.Method = 'HEAD'; $req.AllowAutoRedirect = $false; $req.Timeout = $TimeoutMs
        $req.UserAgent = "PSVsCommand/$(Get-VsVersion)"
        $res = $req.GetResponse()
        try { $loc = [string]$res.Headers['Location'] } finally { $res.Close() }
        if ($loc -match '/tag/v?(\d+\.\d+\.\d+)$') { return [version]$Matches[1] }
    }
    catch { return $null }
    $null
}
function Invoke-VsScoopUpdate {
    # In a child process: Scoop runs in-process in PowerShell, and its uninstall step would
    # unload the very module that is calling it. -EncodedCommand keeps the ';' in one piece.
    $exe = if (Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script:VsScoopUpdate))
    $p = Start-Process -FilePath $exe -ArgumentList "-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded" -NoNewWindow -Wait -PassThru
    $p.ExitCode
}
function Get-VsScoopInstalledVersion {
    # The version in apps\psvscommand\current - after an update, what Scoop really installed.
    param([object]$How)
    $app = $How.Path -replace '(?i)([\\/]apps[\\/]psvscommand)([\\/].*)?$', '$1'
    $psd1 = Join-Path $app 'current\PSVsCommand.psd1'
    if (-not (Test-Path -LiteralPath $psd1)) { return $null }
    try { [version](Import-PowerShellDataFile -LiteralPath $psd1).ModuleVersion } catch { $null }
}
function Update-VsCommand {
    param([switch]$Yes)
    Write-Host 'asking GitHub for the latest release...' -ForegroundColor DarkGray
    $latest = Get-VsLatestRelease -TimeoutMs 5000
    $state = ConvertTo-VsHashtable (Read-VsJson 'state.json')
    $state.lastCheck = Get-VsNow
    if ($latest) { $state.latest = $latest.ToString() }
    Write-VsJson 'state.json' $state
    if (-not $latest) { Write-VsFail "could not reach GitHub, or there is no release yet - $script:ProjectUrl/releases"; return }
    $have = Get-VsVersion
    if ($latest -le $have) { Write-Host "vs $have is the latest release" -ForegroundColor Green; return }
    Write-Host "vs $latest is out (you have $have)" -ForegroundColor Cyan
    $how = Get-VsInstallMethod
    switch ($how.Method) {
        'scoop' {
            if ($how.Global) {
                Write-Host "this is a global Scoop install - from an elevated shell: $script:VsScoopUpdate --global" -ForegroundColor DarkGray
                return
            }
            if (-not $Yes -and (Read-Host "run '$script:VsScoopUpdate' now? [y/N]").Trim().ToLowerInvariant() -notin 'y', 'yes') {
                Write-Host "later: $script:VsScoopUpdate" -ForegroundColor DarkGray
                return
            }
            $code = Invoke-VsScoopUpdate
            # Scoop's exit code says little ("latest version" is a success too): what is installed now?
            $now = Get-VsScoopInstalledVersion $how
            if ($now -and $now -ge $latest) { Write-Host "updated to $now - new shells have it; for this one: Import-Module PSVsCommand -Force" -ForegroundColor Green }
            elseif ($code -ne 0) { Write-VsFail "'$script:VsScoopUpdate' failed (exit code $code)" Red }
            else { Write-VsFail "Scoop still has $now installed, not $latest - try again in a minute: $script:VsScoopUpdate" }
        }
        'checkout' {
            Write-Host "this copy is a git checkout - update it yourself: git -C '$($how.Clone)' pull" -ForegroundColor DarkGray
        }
        default {
            Write-Host "download PSVsCommand-$latest.zip from $script:ProjectUrl/releases/latest" -ForegroundColor DarkGray
            Write-Host "and extract its PSVsCommand folder over $($how.Path)" -ForegroundColor DarkGray
        }
    }
}
function Invoke-VsUpdate {
    param([string]$Sub, [string]$Value, [switch]$Yes)
    if (-not $Sub) { Update-VsCommand -Yes:$Yes; return }
    if ($Sub -eq 'notify' -and $Value -in 'on', 'off') {
        Set-VsConfigValue 'updateCheck' $Value
        if ($Value -eq 'on') { Write-Host 'vs now asks GitHub for a new release at most once a day, after a command' -ForegroundColor DarkGray }
        return
    }
    Write-VsFail 'usage: vs update | vs update notify on|off'
}
function Save-VsLatestRelease {
    # What the background check runs: ask GitHub, record the answer for the next command.
    $latest = Get-VsLatestRelease -TimeoutMs 10000
    if (-not $latest) { return }
    $state = ConvertTo-VsHashtable (Read-VsJson 'state.json')
    $state.latest = $latest.ToString()
    Write-VsJson 'state.json' $state
}
function Get-VsUpdateCheckArguments {
    # The command line of the background check: this module, imported by path, records the latest
    # release. -EncodedCommand, so no path or quote in it needs escaping on the way through.
    $psd1 = (Join-Path $PSScriptRoot 'PSVsCommand.psd1').Replace("'", "''")
    $command = "Import-Module '$psd1'; & (Get-Module PSVsCommand) { Save-VsLatestRelease }"
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
    "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
}
function Start-VsUpdateCheck {
    # The daily check runs in a windowless child process of the same PowerShell: the request -
    # DNS included, which the timeout does not cover on 5.1 - never holds the prompt up, and it
    # outlives the shim's process. Process.Start rather than Start-Process: ~170 ms cold
    # instead of ~450.
    $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $psi = New-Object System.Diagnostics.ProcessStartInfo -ArgumentList $exe, (Get-VsUpdateCheckArguments)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    [System.Diagnostics.Process]::Start($psi).Dispose()
}
function Invoke-VsUpdateNotice {
    # After a command. Opted in: at most once a day, start a check in the background, and say so
    # when the last one found a newer release. Unset: never online, but a tip at most once a
    # week. Off: nothing at all.
    if ($env:CI -or $env:PSVSCOMMAND_NO_UPDATE_CHECK) { return }
    if (-not (Test-VsConsole)) { return }
    $mode = (Get-VsConfig).updateCheck
    if ($mode -eq 'off') { return }
    $state = ConvertTo-VsHashtable (Read-VsJson 'state.json')
    $now = Get-VsNow
    if ($mode -ne 'on') {
        if ($now - [long]$state.lastHint -lt 7 * 86400) { return }
        $state.lastHint = $now
        Write-VsJson 'state.json' $state
        Write-Host 'tip: vs can tell you when a new version is out - vs update notify on (asks GitHub at most once a day), or check now: vs update' -ForegroundColor DarkGray
        return
    }
    if ($now - [long]$state.lastCheck -ge 86400) {
        # Recorded before the child starts, so the next command does not start another.
        $state.lastCheck = $now
        Write-VsJson 'state.json' $state
        try { Start-VsUpdateCheck }
        catch { $state.lastCheck = 0; Write-VsJson 'state.json' $state }   # no child: try again next time
    }
    $v = $null
    $have = Get-VsVersion
    if (-not [version]::TryParse([string]$state.latest, [ref]$v) -or $v -le $have) { return }
    if ($now - [long]$state.lastNotice -lt 86400) { return }
    $state.lastNotice = $now
    Write-VsJson 'state.json' $state
    Write-Host "vs $v is out (you have $have) - update: $(Get-VsUpdateCommand (Get-VsInstallMethod))   (or: vs update)" -ForegroundColor Cyan
}
function Show-VsVersion {
    $how = Get-VsInstallMethod
    Write-Host "vs $(Get-VsVersion)" -ForegroundColor Green
    Write-Host "  installed: $($how.Method) - $($how.Path)" -ForegroundColor DarkGray
    Write-Host "  PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))" -ForegroundColor DarkGray
}

# --- profile --------------------------------------------------------------------------------
# The profile line behind the `vs` function (and its Tab completion), and how to find it again.
$script:VsProfileLine = 'Import-Module PSVsCommand -ErrorAction SilentlyContinue  # vs: open solutions in Visual Studio (vs uninstall profile removes this)'
$script:VsProfilePattern = '(?im)^[ \t]*Import-Module[ \t]+PSVsCommand\b[^\n]*(\n|\z)'
function Get-VsProfilePath { $PROFILE.CurrentUserAllHosts }
function Read-VsTextFile {
    # A startup file's text plus the encoding to write it back in. A BOM is kept (UTF-8, or the
    # UTF-16 that Windows PowerShell's '>' leaves); without one the file goes through Latin-1,
    # which maps every byte to itself, so UTF-8 and ANSI text alike survive the ASCII line.
    param([string]$Path)
    $enc = [System.Text.Encoding]::GetEncoding(28591)
    if (-not (Test-Path -LiteralPath $Path)) { return @{ Text = ''; Encoding = $enc } }
    $reader = New-Object System.IO.StreamReader -ArgumentList $Path, $enc, $true
    try { @{ Text = $reader.ReadToEnd(); Encoding = $reader.CurrentEncoding } }
    finally { $reader.Dispose() }
}
function Test-VsModuleOnPath {
    # The profile imports by name, which only works from a folder on PSModulePath. The user's
    # registry value counts: Scoop extends that one, for shells started after the install.
    $sep = [System.IO.Path]::PathSeparator
    $dirs = (@($env:PSModulePath, [Environment]::GetEnvironmentVariable('PSModulePath', 'User')) -join $sep) -split $sep
    foreach ($d in ($dirs | Where-Object { $_ })) {
        try { if (Test-Path -LiteralPath (Join-Path $d 'PSVsCommand')) { return $true } }
        catch { continue }   # a folder we may not read says nothing either way
    }
    $false
}
function Install-VsProfile {
    $path = Get-VsProfilePath
    $p = Read-VsTextFile $path
    if ($p.Text -match $script:VsProfilePattern) { Write-Host "already in your profile: $path" -ForegroundColor DarkGray; return }
    $text = $p.Text
    if ($text -and -not $text.EndsWith("`n")) { $text += "`r`n" }
    [System.IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null
    [System.IO.File]::WriteAllText($path, $text + $script:VsProfileLine + "`r`n", $p.Encoding)
    Write-Host "added 'Import-Module PSVsCommand' to your profile: $path" -ForegroundColor Green
    if (-not (Test-VsModuleOnPath)) {
        Write-Host 'warning: PSVsCommand is not in a PSModulePath folder, so that line will not find it - see Install in the README' -ForegroundColor Yellow
    }
}
function Uninstall-VsProfile {
    $path = Get-VsProfilePath
    $p = Read-VsTextFile $path
    $text = [regex]::Replace($p.Text, $script:VsProfilePattern, '')
    if ($text -ceq $p.Text) { Write-Host "no 'Import-Module PSVsCommand' line in $path" -ForegroundColor DarkGray; return }
    [System.IO.File]::WriteAllText($path, $text, $p.Encoding)
    Write-Host "removed 'Import-Module PSVsCommand' from your profile: $path" -ForegroundColor Green
}
function Invoke-VsSetup {
    param([string]$Verb, [string]$What)
    switch ("$Verb $What") {
        'install profile' { Install-VsProfile }
        'uninstall profile' { Uninstall-VsProfile }
        default { Write-VsFail "usage: vs $Verb profile" }
    }
}

# --- help and the command -------------------------------------------------------------------
function Show-VsHelp {
    @"
vs - open solutions in the right Visual Studio

USAGE:
  vs                        look for solutions (.sln, .slnx) below this folder: one is
                            opened after a confirm, several get a picker. A folder that
                            holds a solution is not searched further down (-All does).
                            Nothing below: the nearest solution above, up to the repo
                            top. No solution at all: the project files.
  vs .                      open this folder itself in Visual Studio (Open Folder), the
                            way 'code .' does
  vs <dir>                  search <dir> instead
  vs <file>                 open a .sln, .slnx, .slnf or project in a Visual Studio of its
                            own; any other file in one that is already running (/Edit)
  vs <name>                 the solutions below here whose name matches: an exact name or
                            a single match is opened, several get the picker, filtered
                            ('vs admin', 'vs bknd')
       -Use <vs>      open in that install: a year (2019), a major version (18), an
                      edition (Pro, Enterprise), an instance id, or 'preview'
       -All           also offer solutions nested below another solution's folder
       -Depth <n>     folder levels to search below (default 3, see vs config)
       -Folder        open <dir> itself instead of searching it
       -Yes           no confirm for a single match
       -Admin         start Visual Studio as administrator
  vs list [dir]             what 'vs' would offer, the Visual Studio each one gets and
                            why; takes -All, -Depth and -Use (alias: vs ls)
  vs installs               the Visual Studio installs found (* = the default pick)
  vs scan                   look for installs again and cache the result
  vs config                 show the settings
  vs config <key> <value>   change one ('default' resets it):
       match    newest     each solution in the newest install that can open it
                solution   prefer the version that saved it ('# Visual Studio
                           Version 17' -> 2022), else as newest
       depth    3          folder levels to search below (1-8)
       confirm  on|off     ask before opening a single match
  vs update                 ask GitHub for the latest release and say how to update -
                            with Scoop it offers to run 'scoop update; scoop update
                            psvscommand' and checks what got installed
  vs update notify on|off   opt in to (or out of) a check at most once a day
  vs version                version, how it was installed, where it runs from
  vs install profile        add 'Import-Module PSVsCommand' to your PowerShell profile:
                            Tab completion, and 'vs' is this module before anything on
                            PATH
  vs uninstall profile      take that line out again
  vs help | -h | --help     show this help

PICKER:
  Up/Down move, PgUp/PgDn page, Enter open, Tab (Shift+Tab) changes the Visual Studio of
  the highlighted row, typing filters - the letters in order, not necessarily adjacent -
  Esc clears the filter, a second Esc cancels. The confirm for a single match takes
  Enter, Tab and Esc the same way.

NOTES:
  - which install: an SSRS (.rptproj), SSIS (.dtproj) or SSAS (.smproj, .dwproj) project
    goes to an install with that extension; an .slnx needs 17.13 or newer, and a
    MinimumVisualStudioVersion above 10 is honoured; everything else goes to the newest
    stable install. 'vs list' shows the choice and the reason for each solution.
  - installs come from vswhere (Visual Studio 2017 and newer), the registry (2015 and
    older) or, without vswhere, the default install folders; Team Explorer and installs
    an update left half done are left out. They are cached and scanned again when a
    cached devenv.exe is gone, when the Visual Studio Installer adds, updates or removes
    an instance, or on 'vs scan'.
  - the search skips dot-folders (.git, .vs, .claude worktrees), hidden folders
    (AppData), bin, obj, node_modules, packages, artifacts, dist and TestResults - at a
    drive root also Windows and the program folders - and does not follow junctions or
    symlinks (OneDrive folders are searched).
  - a sub-command wins over a folder of the same name: 'vs .\list' searches .\list.
  - 'install profile' writes `$PROFILE.CurrentUserAllHosts of the PowerShell running it:
    run it once in each edition you use (pwsh, Windows PowerShell 5.1).
  - through vs.ps1 - the Scoop shim in cmd, Git Bash or a script - vs exits with 1 when
    nothing was found, opened or changed as asked, else 0.
  - the picker and the confirm need a console: PowerShell or Git Bash in Windows Terminal
    have one. Git Bash in its own window (mintty) hands vs pipes instead, so there it
    prints the list - open one with 'vs <name>'.
  - nothing goes online unless you ask: 'vs update' checks once, 'vs update notify on'
    daily, in the background - its answer shows after a later command. It is one HEAD
    request to GitHub's releases page; no telemetry.
  - settings and caches: $(Get-VsHome)
  - module: $PSScriptRoot
  - project: $script:ProjectUrl
"@ | Write-Host
}
function vs {
    param([Parameter(Position = 0)][string]$Command, [Parameter(Position = 1)][string]$Arg, [Parameter(Position = 2)][string]$Arg2,
        [string]$Use, [int]$Depth, [switch]$All, [switch]$Folder, [switch]$Yes, [switch]$Admin, [Alias('h')][switch]$Help)
    $script:VsExitCode = 0
    # Git Bash hands '/?' over as a path: C:/Program Files/Git/?
    if ($Help -or $Command -in '--help', 'help', '-h', '/?' -or $Command -match '^[A-Za-z]:/.*/\?$') { Show-VsHelp; return }
    if ($PSBoundParameters.ContainsKey('Depth') -and $Depth -lt 1) { Write-VsFail "-Depth takes 1 or more (default $((Get-VsConfig).depth))"; return }
    switch ($Command) {
        { $_ -in 'list', 'ls' } { Show-VsSolutions $Arg -Use $Use -Depth $Depth -All:$All }
        'installs' { Show-VsInstalls }
        'scan' { Show-VsInstalls -Refresh }
        'config' { Invoke-VsConfig $Arg $Arg2 }
        'update' { Invoke-VsUpdate $Arg $Arg2 -Yes:$Yes; return }
        { $_ -in 'version', '--version' } { Show-VsVersion }
        { $_ -in 'install', 'uninstall' } { Invoke-VsSetup $Command $Arg }
        default { Invoke-VsOpen $Command -Use $Use -Depth $Depth -All:$All -Yes:$Yes -Folder:$Folder -Admin:$Admin }
    }
    Invoke-VsUpdateNotice
}
$script:VsNameCache = $null
function Get-VsCompletionNames {
    # Solution names below the current folder, for `vs <name>` completion; kept 15 seconds per
    # folder, so a burst of Tabs walks the tree once. Errors stay quiet: a completer that throws
    # gives the user nothing at all.
    try {
        $here = Get-VsHere
        if (-not $here) { return }
        $depth = [int](Get-VsConfig).depth
        $now = [DateTime]::UtcNow
        $c = $script:VsNameCache
        if ($c -and $c.Dir -eq $here -and $c.Depth -eq $depth -and ($now - $c.Time).TotalSeconds -lt 15) { return $c.Names }
        $names = @(foreach ($f in Find-VsFiles $here $script:VsSolutionExtensions $depth -All) { $f.Name })
        $script:VsNameCache = @{ Dir = $here; Depth = $depth; Time = $now; Names = $names }
        $names
    }
    catch { return }
}
Register-ArgumentCompleter -CommandName vs -ParameterName Command -ScriptBlock {
    param($c, $p, $word)
    # A path being typed gets PowerShell's own file completion: returning nothing hands over.
    if ($word -match '[\\/:]' -or $word.StartsWith('.')) { return }
    $dirs = @()
    $here = Get-VsHere
    if ($here) { $dirs = @(Get-ChildItem -LiteralPath $here -Directory -ErrorAction SilentlyContinue | ForEach-Object { '.\' + $_.Name }) }
    $names = @($script:VsCommands) + @(Get-VsCompletionNames)
    $hits = @($names | Where-Object { Test-VsPrefix $_ $word } | Select-Object -Unique) +
        @($dirs | Where-Object { Test-VsPrefix $_.Substring(2) $word })
    $hits | ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
}
Register-ArgumentCompleter -CommandName vs -ParameterName Arg -ScriptBlock {
    param($c, $p, $word, $ast, $bound)
    $names = switch ($bound['Command']) {
        'config' { @($script:VsConfigKeys.Keys) }
        'update' { @('notify') }
        { $_ -in 'install', 'uninstall' } { @('profile') }
        default { @() }
    }
    $names | Where-Object { Test-VsPrefix $_ $word } | ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
}
Register-ArgumentCompleter -CommandName vs -ParameterName Arg2 -ScriptBlock {
    param($c, $p, $word, $ast, $bound)
    $names = @()
    if ($bound['Command'] -eq 'config' -and $script:VsConfigKeys.Contains([string]$bound['Arg'])) { $names = @($script:VsConfigKeys[[string]$bound['Arg']].Values) + 'default' }
    elseif ($bound['Command'] -eq 'update' -and $bound['Arg'] -eq 'notify') { $names = @('on', 'off') }
    $names | Where-Object { Test-VsPrefix $_ $word } | ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
}
Register-ArgumentCompleter -CommandName vs -ParameterName Use -ScriptBlock {
    param($c, $p, $word)
    $words = @(Read-VsInstallCache | ForEach-Object { $_.Year; [string]$_.Major; $_.Edition; $_.Id }) | Where-Object { $_ } | Select-Object -Unique
    $words | Where-Object { Test-VsPrefix $_ $word } | ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
}
Export-ModuleMember -Function vs
