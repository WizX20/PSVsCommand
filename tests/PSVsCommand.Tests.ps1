# Pester 5+ suite for the PSVsCommand module. Nothing here needs Visual Studio: installs are fake
# folders under $TestDrive (a devenv.exe that is an empty file, extension folders where the
# real ones would be) handed to the module through a mocked vswhere, and Start-VsProcess is
# mocked, so no devenv is ever started. Settings and caches go to a fresh PSVSCOMMAND_HOME per
# test. `vs` prints through Write-Host, so output is captured from the information stream (6>&1).

BeforeAll {
    $script:ModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\PSVsCommand\PSVsCommand.psd1'
    Import-Module $script:ModulePath -Force
    # No update tips or checks unless a test asks for them.
    $env:PSVSCOMMAND_NO_UPDATE_CHECK = '1'

    function script:Get-VsOutput {
        # Runs the block (a real `vs ...` call line, switches included) and returns everything
        # it printed as one string.
        param([scriptblock]$Call)
        (& $Call 6>&1 | Out-String)
    }

    function script:New-TestDir {
        # A fresh, empty folder under $TestDrive.
        $p = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $p | Out-Null
        $p
    }

    function script:New-TestFile {
        param([string]$Path, [string]$Text = '')
        New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
        [System.IO.File]::WriteAllText($Path, $Text)
        $Path
    }

    function script:New-Sln {
        # A solution file as Visual Studio writes it; -Extra lands after the header (projects).
        param([string]$Path, [int]$Version = 17, [string]$Min = '10.0.40219.1', [string]$Extra = '')
        $text = "`r`nMicrosoft Visual Studio Solution File, Format Version 12.00`r`n# Visual Studio Version $Version`r`n" +
        "VisualStudioVersion = $Version.0.31903.59`r`nMinimumVisualStudioVersion = $Min`r`n$Extra`r`nGlobal`r`nEndGlobal`r`n"
        New-TestFile $Path $text
    }

    function script:New-FakeVs {
        # A Visual Studio install as vswhere describes it, backed by a folder with an empty
        # devenv.exe and the extension folders named in -Caps.
        param([string]$Id, [string]$Version, [string]$DisplayName, [string]$Edition = 'Enterprise', [string[]]$Caps = @(), [switch]$Prerelease, [string]$Exe = 'devenv.exe')
        $dir = Join-Path $TestDrive "vs\$Id"
        $exePath = New-TestFile (Join-Path $dir "Common7\IDE\$Exe")
        foreach ($c in $Caps) { New-Item -ItemType Directory -Force -Path (Join-Path $dir "Common7\IDE\CommonExtensions\Microsoft\$c") | Out-Null }
        [pscustomobject]@{
            instanceId = $Id; displayName = $DisplayName; installationVersion = $Version
            productId = "Microsoft.VisualStudio.Product.$Edition"; productPath = $exePath; installationPath = $dir
            isPrerelease = [bool]$Prerelease; catalog = [pscustomobject]@{ productDisplayVersion = ($Version -replace '^(\d+\.\d+)\..*$', '$1.0') }
        }
    }

    $script:vs2019 = New-FakeVs 'aaaa2019' '16.11.36631.11' 'Visual Studio Professional 2019' -Edition Professional -Caps SSRS
    $script:vs2026 = New-FakeVs 'bbbb2026' '18.7.11925.98' 'Visual Studio Enterprise 2026'
    $script:fakeInstances = @($script:vs2019, $script:vs2026)
}

AfterAll {
    Remove-Item Env:\PSVSCOMMAND_NO_UPDATE_CHECK -ErrorAction SilentlyContinue
    Remove-Item Env:\PSVSCOMMAND_HOME -ErrorAction SilentlyContinue
    Remove-Module PSVsCommand -Force -ErrorAction SilentlyContinue
}

Describe 'module surface' {
    It 'exports exactly one command: vs' {
        $m = Get-Module PSVsCommand
        $m.ExportedFunctions.Keys | Should -Be @('vs')
        $m.ExportedAliases.Count | Should -Be 0
    }

    It 'resolves vs to the module function' {
        (Get-Command vs).CommandType | Should -Be 'Function'
        (Get-Command vs).Source | Should -Be 'PSVsCommand'
    }

    It 'prints help for --help, -h, help and /?' {
        Get-VsOutput { vs --help } | Should -Match 'USAGE:'
        Get-VsOutput { vs -h } | Should -Match 'USAGE:'
        Get-VsOutput { vs help } | Should -Match 'USAGE:'
        Get-VsOutput { vs /? } | Should -Match 'USAGE:'
    }

    It 'prints its version from the manifest' {
        $v = (Import-PowerShellDataFile $script:ModulePath).ModuleVersion
        Get-VsOutput { vs version } | Should -Match ([regex]::Escape("vs $v"))
    }

    It 'ships an entry script that runs vs with its arguments' {
        $entry = Join-Path (Split-Path $script:ModulePath -Parent) 'vs.ps1'
        $entry | Should -Exist
        Get-Content $entry -Raw | Should -Match 'vs @args'
    }
}

Describe 'pure helpers' {
    It 'fuzzy-matches the filter as a subsequence, ignoring case and spaces' {
        InModuleScope PSVsCommand {
            Test-VsFuzzyMatch 'Backend.sln' 'bknd' | Should -BeTrue
            Test-VsFuzzyMatch 'AdminTools.sln' 'ADMIN tools' | Should -BeTrue
            Test-VsFuzzyMatch 'Backend.sln' 'dnek' | Should -BeFalse
        }
    }

    It 'lists literal name hits before loose ones' {
        InModuleScope PSVsCommand {
            $items = @(
                [pscustomobject]@{ Name = 'MailService.sln'; Dir = 'backend\MailService' }
                [pscustomobject]@{ Name = 'Mail.sln'; Dir = 'mail' }
                [pscustomobject]@{ Name = 'Other.sln'; Dir = 'x' }
            )
            $r = @(Get-VsFilterMatches $items 'mail')
            $r.Count | Should -Be 2
            ($r.Name -join ',') | Should -Be 'MailService.sln,Mail.sln'
            @(Get-VsFilterMatches $items 'msvc').Name | Should -Be @('MailService.sln')
        }
    }

    It 'quotes a devenv argument and doubles trailing backslashes' {
        InModuleScope PSVsCommand {
            ConvertTo-VsArgument 'C:\Repos\SID INs\SID INs.sln' | Should -Be '"C:\Repos\SID INs\SID INs.sln"'
            ConvertTo-VsArgument 'C:\' | Should -Be '"C:\\"'
        }
    }

    It 'names folders relative to the search root' {
        InModuleScope PSVsCommand {
            Get-VsRelativePath 'C:\Repos\x' 'C:\Repos\x' | Should -Be '.'
            Get-VsRelativePath 'C:\Repos\x\' 'C:\Repos\x\backend\api' | Should -Be 'backend\api'
            Get-VsRelativePath 'C:\' 'C:\Repos' | Should -Be 'Repos'
        }
    }

    It 'reads old solution headers that name the year' {
        InModuleScope PSVsCommand {
            ConvertTo-VsMajor '2013' | Should -Be 12
            ConvertTo-VsMajor '14' | Should -Be 14
        }
    }

    It 'clips cells with a visible marker' {
        InModuleScope PSVsCommand {
            Format-VsCell 'abcdef' 4 | Should -Be 'ab..'
            Format-VsCell 'ab' 4 | Should -Be 'ab  '
        }
    }
}

Describe 'what a target asks for' {
    BeforeAll { $script:dir = New-TestDir }

    It 'reads the version that saved a solution and ignores the stock minimum version' {
        $sln = New-Sln (Join-Path $script:dir 'a\A.sln') -Version 17
        InModuleScope PSVsCommand -Parameters @{ Sln = $sln } {
            $i = Get-VsTargetInfo $Sln
            $i.Kind | Should -Be 'solution'
            $i.Saved | Should -Be 17
            $i.MinVersion | Should -BeNullOrEmpty
            $i.Needs.Count | Should -Be 0
        }
    }

    It 'honours a MinimumVisualStudioVersion above 10' {
        $sln = New-Sln (Join-Path $script:dir 'b\B.sln') -Min '17.0.31903.59'
        InModuleScope PSVsCommand -Parameters @{ Sln = $sln } {
            (Get-VsTargetInfo $Sln).MinVersion | Should -Be ([version]'17.0.31903.59')
        }
    }

    It 'reads a pre-2015 header that names the year' {
        $sln = New-TestFile (Join-Path $script:dir 'c\C.sln') "Microsoft Visual Studio Solution File, Format Version 12.00`r`n# Visual Studio 2013`r`n"
        InModuleScope PSVsCommand -Parameters @{ Sln = $sln } {
            (Get-VsTargetInfo $Sln).Saved | Should -Be 12
        }
    }

    It 'spots an SSRS solution by project path and by project type GUID alone' {
        $byPath = New-Sln (Join-Path $script:dir 'd\D.sln') -Extra 'Project("{F14B399A-7131-4C87-9E4B-1186C45EF12D}") = "R", "R\R.rptproj", "{0}"'
        $byGuid = New-TestFile (Join-Path $script:dir 'e\E.sln') "Microsoft Visual Studio Solution File, Format Version 13.00`r`n# Visual Studio 2013`r`nProject(`"{F14B399A-7131-4C87-9E4B-1186C45EF12D}`") = `"R`", `"R`", `"{0}`"`r`n"
        InModuleScope PSVsCommand -Parameters @{ A = $byPath; B = $byGuid } {
            (Get-VsTargetInfo $A).Needs | Should -Be @('SSRS')
            (Get-VsTargetInfo $B).Needs | Should -Be @('SSRS')
        }
    }

    It 'gives an .slnx its minimum version and reads its projects' {
        $slnx = New-TestFile (Join-Path $script:dir 'f\F.slnx') '<Solution><Project Path="Pkg/Pkg.dtproj" /></Solution>'
        InModuleScope PSVsCommand -Parameters @{ P = $slnx } {
            $i = Get-VsTargetInfo $P
            $i.Kind | Should -Be 'solution'
            $i.MinVersion | Should -Be ([version]'17.13')
            $i.Needs | Should -Be @('SSIS')
        }
    }

    It 'judges a solution filter by its solution' {
        New-Sln (Join-Path $script:dir 'g\G.sln') -Extra '"x\x.rptproj"' | Out-Null
        $slnf = New-TestFile (Join-Path $script:dir 'g\sub\G.slnf') '{ "solution": { "path": "..\\G.sln", "projects": [] } }'
        InModuleScope PSVsCommand -Parameters @{ P = $slnf } {
            $i = Get-VsTargetInfo $P
            $i.Kind | Should -Be 'filter'
            $i.Saved | Should -Be 17
            $i.Needs | Should -Be @('SSRS')
        }
    }

    It 'knows projects, other files and folders' {
        $rpt = New-TestFile (Join-Path $script:dir 'h\R.rptproj')
        $cs = New-TestFile (Join-Path $script:dir 'h\Program.cs')
        InModuleScope PSVsCommand -Parameters @{ Rpt = $rpt; Cs = $cs; Dir = $script:dir } {
            $r = Get-VsTargetInfo $Rpt
            $r.Kind | Should -Be 'project'
            $r.Needs | Should -Be @('SSRS')
            (Get-VsTargetInfo $Cs).Kind | Should -Be 'file'
            (Get-VsTargetInfo $Dir).Kind | Should -Be 'folder'
        }
    }
}

Describe 'install scan' {
    BeforeEach {
        $env:PSVSCOMMAND_HOME = New-TestDir
        $script:vswhereList = @($script:vs2019, $script:vs2026)
        Mock -ModuleName PSVsCommand Get-VsWherePath { 'vswhere.exe' }
        Mock -ModuleName PSVsCommand Invoke-VsWhere { $script:vswhereList }
        Mock -ModuleName PSVsCommand Find-VsLegacyInstalls { }
        Mock -ModuleName PSVsCommand Get-VsInstancesStamp { [long]0 }
    }

    It 'keeps products with devenv.exe and drops the rest (SSMS, Build Tools)' {
        $script:vswhereList += New-FakeVs 'ssms22' '22.10.12210.168' 'SQL Server Management Studio 22' -Edition Ssms -Exe 'SSMS.exe'
        InModuleScope PSVsCommand {
            $list = @(Get-VsInstalls)
            $list.Count | Should -Be 2
            $list[0].Name | Should -Be 'Visual Studio Enterprise 2026'
            $list[0].Label | Should -Be '2026 Enterprise'
            $list[1].Label | Should -Be '2019 Professional'
        }
    }

    It 'finds the workload extensions an install carries' {
        InModuleScope PSVsCommand {
            $list = @(Get-VsInstalls)
            ($list | Where-Object Major -EQ 16).Capabilities | Should -Be @('SSRS')
            ($list | Where-Object Major -EQ 18).Capabilities.Count | Should -Be 0
        }
    }

    It 'leaves out Team Explorer and installs an update left half done' {
        $te = New-FakeVs 'tttt2019' '16.11.1.0' 'Visual Studio Team Explorer 2019' -Edition TeamExplorer
        $broken = New-FakeVs 'xxxx2022' '17.14.0.0' 'Visual Studio Enterprise 2022'
        $broken | Add-Member isComplete $false
        $stuck = New-FakeVs 'yyyy2022' '17.13.0.0' 'Visual Studio Professional 2022' -Edition Professional
        $stuck | Add-Member isComplete $true
        $stuck | Add-Member isLaunchable $false
        $script:vswhereList = @($te, $broken, $stuck, $script:vs2026)
        InModuleScope PSVsCommand { (@(Get-VsInstalls) | ForEach-Object { $_.Id }) | Should -Be @('bbbb2026') }
    }

    It 'finds an extension installed as a VSIX, per user or per machine, by its display name' {
        $user = New-FakeVs 'uuuu2026' '18.1.0.0' 'Visual Studio Community 2026' -Edition Community
        $machine = New-FakeVs 'mmmm2022' '17.14.0.0' 'Visual Studio Professional 2022' -Edition Professional
        $appData = New-TestDir
        # The real manifests: a bare GUID as identity, the product in the DisplayName.
        $manifest = '<PackageManifest><Metadata><Identity Id="{0}" Version="1.0" /><DisplayName>{1}</DisplayName></Metadata></PackageManifest>'
        New-TestFile (Join-Path $appData 'Microsoft\VisualStudio\18.0_uuuu2026\Extensions\k3j2h1\extension.vsixmanifest') ($manifest -f 'f1a2b3c4-0000-4000-8000-000000000001', 'Microsoft Reporting Services Projects') | Out-Null
        New-TestFile (Join-Path $machine.installationPath 'Common7\IDE\Extensions\Microsoft\SSIS\1.0\extension.vsixmanifest') ($manifest -f 'f1a2b3c4-0000-4000-8000-000000000002', 'SQL Server Integration Services Projects 2022') | Out-Null
        $script:vswhereList = @($user, $machine)
        $saved = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $appData
        try {
            InModuleScope PSVsCommand {
                $list = @(Get-VsInstalls)
                ($list | Where-Object Id -EQ 'uuuu2026').Capabilities | Should -Be @('SSRS')
                ($list | Where-Object Id -EQ 'mmmm2022').Capabilities | Should -Be @('SSIS')
            }
        }
        finally { $env:LOCALAPPDATA = $saved }
    }

    It 'falls back to the year map when the display name carries none' {
        InModuleScope PSVsCommand {
            $i = ConvertFrom-VsWhere ([pscustomobject]@{ instanceId = 'x'; displayName = 'Visual Studio Community'; installationVersion = '17.14.1.0'; productId = 'Microsoft.VisualStudio.Product.Community'; productPath = 'C:\x\devenv.exe'; installationPath = 'C:\x'; isPrerelease = $false; catalog = $null })
            $i.Year | Should -Be '2022'
            $i.Label | Should -Be '2022 Community'
        }
    }

    It 'scans once and answers from the cache after that' {
        InModuleScope PSVsCommand { Get-VsInstalls | Out-Null; Get-VsInstalls | Out-Null }
        Should -Invoke -ModuleName PSVsCommand Invoke-VsWhere -Times 1 -Exactly
        Join-Path $env:PSVSCOMMAND_HOME 'installs.json' | Should -Exist
    }

    It 'rescans on its own when a cached devenv.exe is gone' {
        $gone = New-FakeVs 'cccc2022' '17.14.0.0' 'Visual Studio Community 2022' -Edition Community
        $script:vswhereList = @($gone, $script:vs2026)
        InModuleScope PSVsCommand { @(Get-VsInstalls).Count | Should -Be 2 }
        Remove-Item -LiteralPath $gone.productPath
        $script:vswhereList = @($script:vs2026)
        InModuleScope PSVsCommand { @(Get-VsInstalls).Count | Should -Be 1 }
        Should -Invoke -ModuleName PSVsCommand Invoke-VsWhere -Times 2 -Exactly
    }

    It 'rescans when the Visual Studio Installer changed something after the last scan' {
        InModuleScope PSVsCommand { Get-VsInstalls | Out-Null }
        Mock -ModuleName PSVsCommand Get-VsInstancesStamp { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 60 }
        InModuleScope PSVsCommand { Get-VsInstalls | Out-Null }
        Should -Invoke -ModuleName PSVsCommand Invoke-VsWhere -Times 2 -Exactly
    }

    It 'vs scan looks again even with a good cache' {
        Get-VsOutput { vs installs } | Should -Match 'Enterprise 2026'
        $out = Get-VsOutput { vs scan }
        $out | Should -Match 'Professional 2019'
        $out | Should -Match 'SSRS'
        Should -Invoke -ModuleName PSVsCommand Invoke-VsWhere -Times 2 -Exactly
    }

    It 'finds installs in the default folders when there is no vswhere' {
        $root = New-TestDir
        New-TestFile (Join-Path $root 'Microsoft Visual Studio\2022\Community\Common7\IDE\devenv.exe') | Out-Null
        New-TestFile (Join-Path $root 'Microsoft Visual Studio\2022\Empty\readme.txt') | Out-Null
        InModuleScope PSVsCommand -Parameters @{ Root = $root } {
            $list = @(Find-VsFolderInstalls -Roots $Root)
            $list.Count | Should -Be 1
            $list[0].Edition | Should -Be 'Community'
            $list[0].Year | Should -Be '2022'
        }
    }
}

Describe 'install cache freshness' {
    It 'notices an update within a major through the instances state.json' {
        # Seen for real: the _Instances folder dated February, Visual Studio 2026 updated in July,
        # and only its state.json moved.
        $dir = New-TestDir
        $state = New-TestFile (Join-Path $dir 'aaaa2019\state.json') '{}'
        (Get-Item $dir).LastWriteTimeUtc = [datetime]'2026-02-02T08:00:00Z'
        (Get-Item $state).LastWriteTimeUtc = [datetime]'2026-07-02T14:00:00Z'
        InModuleScope PSVsCommand -Parameters @{ D = $dir } {
            Get-VsInstancesStamp -Dir $D | Should -Be ([DateTimeOffset]'2026-07-02T14:00:00Z').ToUnixTimeSeconds()
            Get-VsInstancesStamp -Dir (Join-Path $D 'missing') | Should -Be 0
        }
    }
}

Describe 'which install opens what' {
    BeforeAll {
        $script:installs = InModuleScope PSVsCommand -Parameters @{ L = $script:fakeInstances } {
            $list = @($L | ForEach-Object { ConvertFrom-VsWhere $_ })
            foreach ($i in $list) { $i.Capabilities = @(Get-VsCapabilities $i) }
            , $list
        }
    }

    It 'sends a plain solution to the newest install' {
        InModuleScope PSVsCommand -Parameters @{ I = $script:installs } {
            $m = Select-VsInstall ([pscustomobject]@{ Name = 'a.sln'; Saved = 16; MinVersion = $null; Needs = @() }) $I
            $m.Install.Major | Should -Be 18
            $m.Reason | Should -Be 'newest install'
        }
    }

    It 'sends an SSRS project to the install with the Reporting Services extension' {
        InModuleScope PSVsCommand -Parameters @{ I = $script:installs } {
            $m = Select-VsInstall ([pscustomobject]@{ Name = 'r.sln'; Saved = 17; MinVersion = $null; Needs = @('SSRS') }) $I
            $m.Install.Major | Should -Be 16
            $m.Reason | Should -Match 'Reporting Services'
            $m.Warning | Should -BeNullOrEmpty
        }
    }

    It 'warns when no install has the extension, and opens in the newest anyway' {
        InModuleScope PSVsCommand -Parameters @{ I = $script:installs } {
            $m = Select-VsInstall ([pscustomobject]@{ Name = 'p.sln'; Saved = 17; MinVersion = $null; Needs = @('SSIS') }) $I
            $m.Install.Major | Should -Be 18
            $m.Warning | Should -Match 'Integration Services'
        }
    }

    It 'keeps a solution away from installs older than its minimum version' {
        InModuleScope PSVsCommand -Parameters @{ I = $script:installs } {
            $info = [pscustomobject]@{ Name = 'x.slnx'; Saved = 0; MinVersion = [version]'17.13'; Needs = @('SSRS') }
            $m = Select-VsInstall $info $I
            $m.Install.Major | Should -Be 18
            $m.Warning | Should -Match 'Reporting Services'
            $m = Select-VsInstall ([pscustomobject]@{ Name = 'y.sln'; Saved = 0; MinVersion = [version]'19.0'; Needs = @() }) $I
            $m.Warning | Should -Match 'needs Visual Studio 19.0'
        }
    }

    It "prefers the saving version with match = solution, and falls back to newest" {
        InModuleScope PSVsCommand -Parameters @{ I = $script:installs } {
            $m = Select-VsInstall ([pscustomobject]@{ Name = 'a.sln'; Saved = 16; MinVersion = $null; Needs = @() }) $I -Match solution
            $m.Install.Major | Should -Be 16
            $m.Reason | Should -Match 'saved by Visual Studio 2019'
            (Select-VsInstall ([pscustomobject]@{ Name = 'b.sln'; Saved = 17; MinVersion = $null; Needs = @() }) $I -Match solution).Install.Major | Should -Be 18
        }
    }

    It 'resolves -Use by year, major, edition prefix and id - and refuses a miss' {
        InModuleScope PSVsCommand -Parameters @{ I = $script:installs } {
            $info = [pscustomobject]@{ Name = 'r.sln'; Saved = 0; MinVersion = $null; Needs = @('SSRS') }
            (Select-VsInstall $info $I -Use '2026').Install.Major | Should -Be 18
            (Select-VsInstall $info $I -Use '18').Install.Major | Should -Be 18
            (Select-VsInstall $info $I -Use 'ent').Install.Major | Should -Be 18
            (Select-VsInstall $info $I -Use 'aaaa2019').Install.Major | Should -Be 16
            (Select-VsInstall $info $I -Use '2019 pro').Install.Major | Should -Be 16
            $m = Select-VsInstall $info $I -Use '2022'
            $m.Install | Should -BeNullOrEmpty
            $m.Warning | Should -Match "fits '2022'"
        }
    }

    It 'breaks a version tie by edition: Enterprise, Professional, Community' {
        InModuleScope PSVsCommand {
            $v = [version]'17.14.3.0'
            $c = New-VsInstall -Id c -Edition Community -Version $v -Path 'C:\c\devenv.exe'
            $e = New-VsInstall -Id e -Edition Enterprise -Version $v -Path 'C:\e\devenv.exe'
            $p = New-VsInstall -Id p -Edition Professional -Version $v -Path 'C:\p\devenv.exe'
            (Select-VsNewest @($c, $p, $e)).Id | Should -Be 'e'
            (Select-VsNewest @($c, $p)).Id | Should -Be 'p'
        }
    }

    It 'prefers a stable release over a newer preview' {
        InModuleScope PSVsCommand -Parameters @{ I = $script:installs } {
            $preview = New-VsInstall -Id 'p' -Edition Enterprise -Version ([version]'19.0.1.0') -Path 'C:\p\devenv.exe' -Prerelease $true
            (Select-VsNewest (@($I) + $preview)).Major | Should -Be 18
            (Resolve-VsInstall 'preview' (@($I) + $preview)).Major | Should -Be 19
        }
    }
}

Describe 'finding solutions' {
    BeforeAll {
        # repo\admin-tools\cli\AdminTools.sln, repo\backend\Backend.sln with services below it,
        # plus things the search must not see.
        $script:repo = Join-Path (New-TestDir) 'repo'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:repo '.git') | Out-Null
        New-Sln (Join-Path $script:repo 'admin-tools\cli\AdminTools.sln') | Out-Null
        New-Sln (Join-Path $script:repo 'backend\Backend.sln') | Out-Null
        New-Sln (Join-Path $script:repo 'backend\MailService\MailService.sln') | Out-Null
        New-TestFile (Join-Path $script:repo 'backend\MailService\Api\Api.csproj') | Out-Null
        New-Sln (Join-Path $script:repo '.claude\worktrees\feature\backend\Backend.sln') | Out-Null
        New-Sln (Join-Path $script:repo 'frontend\node_modules\pkg\Pkg.sln') | Out-Null
        New-Sln (Join-Path $script:repo 'tools\bin\Debug\Tool.sln') | Out-Null
        New-Sln (Join-Path $script:repo 'deep\a\b\c\Deep.sln') | Out-Null
        New-TestFile (Join-Path $script:repo 'scripts\Only.csproj') | Out-Null
        # A junction into a folder outside the repo, holding a solution of its own.
        $script:elsewhere = New-TestDir
        New-Sln (Join-Path $script:elsewhere 'Linked.sln') | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $script:repo 'linked') -Target $script:elsewhere | Out-Null
    }

    It 'does not follow junctions' {
        InModuleScope PSVsCommand -Parameters @{ R = $script:repo } {
            (Find-VsCandidates $R 3 -All).Items.Name | Should -Not -Contain 'Linked.sln'
            Test-VsLinkDir (Get-Item (Join-Path $R 'linked')) | Should -BeTrue
            Test-VsLinkDir (Get-Item (Join-Path $R 'backend')) | Should -BeFalse
        }
    }

    It 'searches a reparse-point folder that is not a link (OneDrive Files On-Demand)' {
        # A placeholder folder cannot be made here; the junction stands in for one, with the
        # link check saying what it says for OneDrive: not a link.
        Mock -ModuleName PSVsCommand Test-VsLinkDir { $false }
        InModuleScope PSVsCommand -Parameters @{ R = $script:repo } {
            (Find-VsCandidates $R 3 -All).Items.Name | Should -Contain 'Linked.sln'
        }
        Should -Invoke -ModuleName PSVsCommand Test-VsLinkDir -Times 1 -Exactly
    }

    It 'offers the top solution of every subtree, not only the first one found' {
        InModuleScope PSVsCommand -Parameters @{ R = $script:repo } {
            $f = Find-VsCandidates $R 3
            $f.Source | Should -Be 'below'
            ($f.Items.Name -join ',') | Should -Be 'AdminTools.sln,Backend.sln'
        }
    }

    It 'offers the nested ones too with -All, and goes deeper with -Depth' {
        InModuleScope PSVsCommand -Parameters @{ R = $script:repo } {
            (Find-VsCandidates $R 3 -All).Items.Name | Should -Contain 'MailService.sln'
            (Find-VsCandidates $R 3).Items.Name | Should -Not -Contain 'Deep.sln'
            (Find-VsCandidates $R 4).Items.Name | Should -Contain 'Deep.sln'
        }
    }

    It 'skips dot-folders (worktrees), node_modules and bin' {
        InModuleScope PSVsCommand -Parameters @{ R = $script:repo } {
            $names = (Find-VsCandidates $R 8 -All).Items
            @($names | Where-Object Name -EQ 'Backend.sln').Count | Should -Be 1
            $names.Name | Should -Not -Contain 'Pkg.sln'
            $names.Name | Should -Not -Contain 'Tool.sln'
        }
    }

    It 'looks upward from inside a project, but not past the repository top' {
        InModuleScope PSVsCommand -Parameters @{ R = $script:repo } {
            $f = Find-VsCandidates (Join-Path $R 'backend\MailService\Api') 3
            $f.Source | Should -Be 'above'
            $f.Items.Name | Should -Be @('MailService.sln')
            $f.Items[0].Dir | Should -Be '..'
        }
    }

    It 'falls back to project files when there is no solution at all' {
        InModuleScope PSVsCommand -Parameters @{ R = $script:repo } {
            $f = Find-VsCandidates (Join-Path $R 'scripts') 3
            $f.Source | Should -Be 'projects'
            $f.Items.Name | Should -Be @('Only.csproj')
        }
    }
}

Describe 'vs (opening)' {
    BeforeAll {
        $script:work = New-TestDir
        $script:one = New-Sln (Join-Path $script:work 'one\Single App.sln')
        New-Sln (Join-Path $script:work 'two\admin-tools\AdminTools.sln') | Out-Null
        New-Sln (Join-Path $script:work 'two\backend\Backend.sln') | Out-Null
        New-Sln (Join-Path $script:work 'two\backend-tests\BackendTests.sln') | Out-Null
        $script:reports = New-Sln (Join-Path $script:work 'reports\Reports.sln') -Extra '"Reports\Reports.rptproj"'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:work 'empty') | Out-Null
    }

    BeforeEach {
        $env:PSVSCOMMAND_HOME = New-TestDir
        Mock -ModuleName PSVsCommand Get-VsWherePath { 'vswhere.exe' }
        Mock -ModuleName PSVsCommand Invoke-VsWhere { $script:fakeInstances }
        Mock -ModuleName PSVsCommand Find-VsLegacyInstalls { }
        Mock -ModuleName PSVsCommand Get-VsInstancesStamp { [long]0 }
        Mock -ModuleName PSVsCommand Start-VsProcess { }
        Mock -ModuleName PSVsCommand Test-VsConsole { $false }
    }

    It 'opens the only solution in the newest install' {
        Push-Location (Join-Path $script:work 'one')
        try { $out = Get-VsOutput { vs -Yes } } finally { Pop-Location }
        $out | Should -Match 'opened Single App.sln in Visual Studio Enterprise 2026'
        $want = '"' + $script:one + '"'
        Should -Invoke -ModuleName PSVsCommand Start-VsProcess -Times 1 -Exactly -ParameterFilter { $Exe -eq $script:vs2026.productPath -and $Argument -eq $want }
    }

    It 'opens an SSRS solution in the install with the extension' {
        $out = Get-VsOutput { vs (Join-Path $script:work 'reports') -Yes }
        $out | Should -Match 'Professional 2019'
        Should -Invoke -ModuleName PSVsCommand Start-VsProcess -Times 1 -Exactly -ParameterFilter { $Exe -eq $script:vs2019.productPath }
    }

    It 'vs . opens the current folder itself' {
        $here = Join-Path $script:work 'two'
        Push-Location $here
        try { Get-VsOutput { vs . -Yes } | Out-Null } finally { Pop-Location }
        $want = '"' + $here + '"'
        Should -Invoke -ModuleName PSVsCommand Start-VsProcess -Times 1 -Exactly -ParameterFilter { $Argument -eq $want }
    }

    It 'opens a file given by path, in the install -Use names' {
        Get-VsOutput { vs $script:one -Use 2019 -Yes } | Should -Match 'Professional 2019'
        Should -Invoke -ModuleName PSVsCommand Start-VsProcess -Times 1 -Exactly -ParameterFilter { $Exe -eq $script:vs2019.productPath }
    }

    It 'opens the one solution whose name matches' {
        Push-Location $script:work
        try { Get-VsOutput { vs admin -Yes } | Should -Match 'opened AdminTools.sln' } finally { Pop-Location }
        Should -Invoke -ModuleName PSVsCommand Start-VsProcess -Times 1 -Exactly
    }

    It 'lets an exact name win over longer names that contain it' {
        Push-Location $script:work
        try {
            Get-VsOutput { vs backend -Yes } | Should -Match 'opened Backend.sln'
            Get-VsOutput { vs BackendTests.sln -Yes } | Should -Match 'opened BackendTests.sln'
            # No exact name, two literal hits: the choice is the user's.
            Get-VsOutput { vs back -Yes } | Should -Match 'several found'
        }
        finally { Pop-Location }
        Should -Invoke -ModuleName PSVsCommand Start-VsProcess -Times 2 -Exactly
    }

    It 'says a path is not there instead of searching for it as a name' {
        $missing = Join-Path $script:work 'nope\Missing.sln'
        Get-VsOutput { vs $missing -Yes } | Should -Match 'no such file or folder'
        Get-VsOutput { vs .\nope -Yes } | Should -Match 'no such file or folder'
        Should -Invoke -ModuleName PSVsCommand Start-VsProcess -Times 0 -Exactly
    }

    It 'lists several matches instead of guessing when there is no console for the picker' {
        Push-Location (Join-Path $script:work 'two')
        try { $out = Get-VsOutput { vs -Yes } } finally { Pop-Location }
        $out | Should -Match 'AdminTools.sln'
        $out | Should -Match 'Backend.sln'
        $out | Should -Match 'several found'
        Should -Invoke -ModuleName PSVsCommand Start-VsProcess -Times 0 -Exactly
    }

    It 'says so when nothing matches a name' {
        Push-Location $script:work
        try { Get-VsOutput { vs nosuchthing -Yes } | Should -Match "no solution matching 'nosuchthing'" } finally { Pop-Location }
        Should -Invoke -ModuleName PSVsCommand Start-VsProcess -Times 0 -Exactly
    }

    It 'says so when a folder holds nothing to open' {
        Get-VsOutput { vs (Join-Path $script:work 'empty') -Yes } | Should -Match 'no solution or project file'
    }

    It 'asks before opening unless -Yes or confirm is off' {
        Mock -ModuleName PSVsCommand Read-Host { 'n' }
        Get-VsOutput { vs $script:one } | Should -Match 'cancelled'
        Should -Invoke -ModuleName PSVsCommand Start-VsProcess -Times 0 -Exactly
        Get-VsOutput { vs config confirm off } | Out-Null
        Get-VsOutput { vs $script:one } | Should -Match 'opened'
        Should -Invoke -ModuleName PSVsCommand Read-Host -Times 1 -Exactly
    }

    It 'stops early when there is no Visual Studio at all' {
        Mock -ModuleName PSVsCommand Invoke-VsWhere { }
        Get-VsOutput { vs $script:one -Yes } | Should -Match 'no Visual Studio found'
    }

    It 'vs list prints each solution with its install and the reason' {
        $out = Get-VsOutput { vs list $script:work -All }
        $out | Should -Match 'Reports\.sln\s+2019 Professional'
        $out | Should -Match 'Backend\.sln\s+2026 Enterprise'
        $out | Should -Match 'SSRS project'
        Should -Invoke -ModuleName PSVsCommand Start-VsProcess -Times 0 -Exactly
    }
}

Describe 'vs config' {
    BeforeEach { $env:PSVSCOMMAND_HOME = New-TestDir }

    It 'shows the defaults' {
        $out = Get-VsOutput { vs config }
        $out | Should -Match 'match\s+newest'
        $out | Should -Match 'depth\s+3'
        $out | Should -Match 'confirm\s+on'
    }

    It 'sets, reads back and resets a value' {
        Get-VsOutput { vs config match solution } | Should -Match 'match = solution'
        Get-VsOutput { vs config match } | Should -Match 'solution'
        InModuleScope PSVsCommand { (Get-VsConfig).match | Should -Be 'solution' }
        Get-VsOutput { vs config match default } | Should -Match 'back to its default: newest'
        InModuleScope PSVsCommand { (Get-VsConfig).match | Should -Be 'newest' }
    }

    It 'refuses unknown keys and values' {
        Get-VsOutput { vs config colour blue } | Should -Match "unknown setting 'colour'"
        Get-VsOutput { vs config depth 99 } | Should -Match "'99' is not a value for depth"
        InModuleScope PSVsCommand { (Get-VsConfig).depth | Should -Be '3' }
    }

    It 'treats a damaged settings file as no settings' {
        New-TestFile (Join-Path $env:PSVSCOMMAND_HOME 'config.json') '{ not json' | Out-Null
        InModuleScope PSVsCommand { (Get-VsConfig).depth | Should -Be '3' }
    }
}

Describe 'updates' {
    BeforeEach {
        $env:PSVSCOMMAND_HOME = New-TestDir
        Mock -ModuleName PSVsCommand Get-VsLatestRelease { [version]'99.0.0' }
    }

    It 'tells the install method from the module folder' {
        $base = New-TestDir
        $scoop = Join-Path $base 'scoop\apps\psvscommand\current'
        $clone = Join-Path $base 'clone'
        $manual = Join-Path $base 'Modules\PSVsCommand'
        foreach ($d in $scoop, (Join-Path $clone '.git'), (Join-Path $clone 'src\PSVsCommand'), $manual) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        $junction = Join-Path $base 'scoop\modules\PSVsCommand'
        New-Item -ItemType Directory -Force -Path (Split-Path $junction) | Out-Null
        New-Item -ItemType Junction -Path $junction -Target $scoop | Out-Null
        InModuleScope PSVsCommand -Parameters @{ Scoop = $scoop; Clone = $clone; Manual = $manual; Junction = $junction } {
            (Get-VsInstallMethod $Scoop).Method | Should -Be 'scoop'
            (Get-VsInstallMethod $Junction).Method | Should -Be 'scoop'
            $c = Get-VsInstallMethod (Join-Path $Clone 'src\PSVsCommand')
            $c.Method | Should -Be 'checkout'
            $c.Clone | Should -Be $Clone
            (Get-VsInstallMethod $Manual).Method | Should -Be 'manual'
        }
    }

    It 'vs update on a checkout says to pull, and runs nothing' {
        Mock -ModuleName PSVsCommand Get-VsInstallMethod { [pscustomobject]@{ Method = 'checkout'; Path = 'C:\c\src\PSVsCommand'; Clone = 'C:\c' } }
        Mock -ModuleName PSVsCommand Invoke-VsScoopUpdate { 0 }
        $out = Get-VsOutput { vs update }
        $out | Should -Match 'vs 99\.0\.0 is out'
        $out | Should -Match "git -C 'C:\\c' pull"
        Should -Invoke -ModuleName PSVsCommand Invoke-VsScoopUpdate -Times 0 -Exactly
    }

    It 'vs update with Scoop asks, then runs scoop update in a child process' {
        Mock -ModuleName PSVsCommand Get-VsInstallMethod { [pscustomobject]@{ Method = 'scoop'; Path = 'C:\s'; Clone = '' } }
        Mock -ModuleName PSVsCommand Invoke-VsScoopUpdate { 0 }
        Mock -ModuleName PSVsCommand Read-Host { 'n' }
        Get-VsOutput { vs update } | Should -Match 'later: scoop update psvscommand'
        Should -Invoke -ModuleName PSVsCommand Invoke-VsScoopUpdate -Times 0 -Exactly
        Get-VsOutput { vs update -Yes } | Should -Match 'updated'
        Should -Invoke -ModuleName PSVsCommand Invoke-VsScoopUpdate -Times 1 -Exactly
    }

    It 'vs update says when this is the latest, and when GitHub cannot be reached' {
        Mock -ModuleName PSVsCommand Get-VsLatestRelease { [version]'0.0.1' }
        Get-VsOutput { vs update } | Should -Match 'is the latest release'
        Mock -ModuleName PSVsCommand Get-VsLatestRelease { $null }
        Get-VsOutput { vs update } | Should -Match 'could not reach GitHub'
    }

    It 'vs update notify on|off sets the opt-in' {
        Get-VsOutput { vs update notify on } | Out-Null
        InModuleScope PSVsCommand { (Get-VsConfig).updateCheck | Should -Be 'on' }
        Get-VsOutput { vs update notify off } | Out-Null
        InModuleScope PSVsCommand { (Get-VsConfig).updateCheck | Should -Be 'off' }
        Get-VsOutput { vs update notify maybe } | Should -Match 'usage: vs update'
    }

    Context 'the notice after a command' {
        BeforeEach {
            $script:savedCi = $env:CI
            Remove-Item Env:\CI -ErrorAction SilentlyContinue
            Remove-Item Env:\PSVSCOMMAND_NO_UPDATE_CHECK -ErrorAction SilentlyContinue
            $script:now = [long]1800000000
            Mock -ModuleName PSVsCommand Test-VsConsole { $true }
            Mock -ModuleName PSVsCommand Get-VsNow { $script:now }
            Mock -ModuleName PSVsCommand Get-VsInstallMethod { [pscustomobject]@{ Method = 'scoop'; Path = 'C:\s'; Clone = '' } }
        }
        AfterEach {
            $env:PSVSCOMMAND_NO_UPDATE_CHECK = '1'
            if ($script:savedCi) { $env:CI = $script:savedCi }
        }

        It 'unset: never goes online, and tips at most once a week' {
            InModuleScope PSVsCommand { (Invoke-VsUpdateNotice 6>&1 | Out-String) | Should -Match 'tip: vs can tell you' }
            InModuleScope PSVsCommand { (Invoke-VsUpdateNotice 6>&1 | Out-String) | Should -BeNullOrEmpty }
            $script:now += 8 * 86400
            InModuleScope PSVsCommand { (Invoke-VsUpdateNotice 6>&1 | Out-String) | Should -Match 'tip:' }
            Should -Invoke -ModuleName PSVsCommand Get-VsLatestRelease -Times 0 -Exactly
        }

        It 'on: asks GitHub at most once a day and names the update command' {
            # Not `vs config updateCheck on`: that command runs the notice itself on the way out.
            Get-VsOutput { vs update notify on } | Out-Null
            InModuleScope PSVsCommand { (Invoke-VsUpdateNotice 6>&1 | Out-String) | Should -Match 'vs 99\.0\.0 is out .* scoop update psvscommand' }
            $script:now += 3600
            InModuleScope PSVsCommand { (Invoke-VsUpdateNotice 6>&1 | Out-String) | Should -BeNullOrEmpty }
            Should -Invoke -ModuleName PSVsCommand Get-VsLatestRelease -Times 1 -Exactly
            $script:now += 86400
            InModuleScope PSVsCommand { (Invoke-VsUpdateNotice 6>&1 | Out-String) | Should -Match 'is out' }
            Should -Invoke -ModuleName PSVsCommand Get-VsLatestRelease -Times 2 -Exactly
        }

        It 'off: silent and offline' {
            Get-VsOutput { vs update notify off } | Out-Null
            InModuleScope PSVsCommand { (Invoke-VsUpdateNotice 6>&1 | Out-String) | Should -BeNullOrEmpty }
            Should -Invoke -ModuleName PSVsCommand Get-VsLatestRelease -Times 0 -Exactly
        }

        It 'stays quiet in CI' {
            $env:CI = 'true'
            InModuleScope PSVsCommand { (Invoke-VsUpdateNotice 6>&1 | Out-String) | Should -BeNullOrEmpty }
            Remove-Item Env:\CI
        }
    }
}

Describe 'vs install profile' {
    BeforeEach {
        $script:profilePath = Join-Path (New-TestDir) 'profile.ps1'
        Mock -ModuleName PSVsCommand Get-VsProfilePath { $script:profilePath }
    }

    It 'adds the import line once and keeps what was there' {
        New-TestFile $script:profilePath "Set-Alias g git`r`n" | Out-Null
        Get-VsOutput { vs install profile } | Should -Match 'added'
        Get-VsOutput { vs install profile } | Should -Match 'already in your profile'
        $text = Get-Content $script:profilePath -Raw
        $text | Should -Match 'Set-Alias g git'
        ([regex]::Matches($text, 'Import-Module PSVsCommand')).Count | Should -Be 1
    }

    It 'creates a missing profile' {
        Get-VsOutput { vs install profile } | Out-Null
        Get-Content $script:profilePath -Raw | Should -Match '^Import-Module PSVsCommand'
    }

    It 'takes the line out again and leaves the rest' {
        New-TestFile $script:profilePath "Set-Alias g git`r`nImport-Module PSVsCommand -ErrorAction SilentlyContinue  # older comment`r`n" | Out-Null
        Get-VsOutput { vs uninstall profile } | Should -Match 'removed'
        $text = Get-Content $script:profilePath -Raw
        $text | Should -Not -Match 'PSVsCommand'
        $text | Should -Match 'Set-Alias g git'
        Get-VsOutput { vs uninstall profile } | Should -Match 'no .Import-Module PSVsCommand. line'
    }
}
