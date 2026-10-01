<p align="center">
  <a href="https://github.com/WizX20">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="docs/wizx20.png">
      <img src="docs/wizx20-transparent.png" alt="WizX20" height="140">
    </picture>
  </a>
</p>

# PSVsCommand

[![CI](https://github.com/WizX20/PSVsCommand/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/WizX20/PSVsCommand/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/WizX20/PSVsCommand?label=release)](https://github.com/WizX20/PSVsCommand/releases/latest)

Open the right solution in the right Visual Studio from the command line. One command, `vs`: type it in a repo and it finds every solution below you — not just the first one — gives you a picker when there are several, and opens your pick in the Visual Studio install that fits it.

- **Finds them all.** `vs` in a repo with `backend\Backend.sln` and `admin-tools\cli\AdminTools.sln` offers both. A folder that holds a solution is not searched further down, so the service solutions nested under `backend\` stay out of the way (`-All` brings them in). Deep inside a project with nothing below you, it finds the solution above you instead.
- **Knows your Visual Studio installs.** They are scanned once (vswhere, the registry for 2015 and older) and cached; `vs scan` looks again.
- **Matches each solution to one.** An SSRS report project goes to the install that has the Reporting Services extension, an `.slnx` to one new enough to read it, everything else to the newest. `vs list` shows the choice and why; `-Use 2019` or Tab in the picker overrides it.
- **`vs .` like `code .`** — opens the current folder itself in Visual Studio.

> See the [Changelog](CHANGELOG.md) for updates.

## License

This project is licensed under the [Business Source License 1.1](LICENSE) (BUSL-1.1). Free for personal, internal, academic, and non-commercial redistribution use; resale or paid commercial distribution is not permitted. Converts to Apache 2.0 on the Change Date (2030-10-01). All copies and forks must retain the [NOTICE](NOTICE) file.

## Requirements

- **Windows** 10 / 11 with Visual Studio (2010 or newer; 2017+ is found through vswhere)
- **PowerShell 7** (recommended) or **Windows PowerShell 5.1**

## Install

### Windows — Scoop (recommended)

```powershell
scoop bucket add psvscommand https://github.com/WizX20/PSVsCommand
scoop install psvscommand
```

(This repo doubles as its own Scoop bucket. The first `psvscommand` is just the local name you give that bucket; the second is the app, from `bucket/psvscommand.json`.)

That is the whole setup. The install:

1. drops the `PSVsCommand` module in `~/scoop/modules/` and adds that folder to your `PSModulePath`;
2. puts a `vs` shim on your PATH (`~/scoop/shims`) that runs the module's `vs.ps1` — so `vs` works right away in PowerShell, cmd and Git Bash, no profile change and no restart.

Opening Visual Studio needs no `cd`, so the shim does everything the PowerShell function does. The one thing it cannot give you is Tab completion before the module is loaded; for that, import it from your profile:

```powershell
vs install profile     # adds: Import-Module PSVsCommand -ErrorAction SilentlyContinue
```

That line also makes `vs` resolve to the module before anything else named `vs` on your PATH (an older `vs.ps1` script, say). It goes into the profile of the PowerShell you run it from; if you use both PowerShell 7 and Windows PowerShell 5.1, run it once in each.

Through the shim — from cmd, Git Bash or a script — `vs` exits with 1 when nothing was found, opened or changed as asked, so `vs Backend.sln || echo failed` works.

Update with `vs update` (or `scoop update; scoop update psvscommand` — the bare `scoop update` refreshes the bucket, without it Scoop can miss a release that is only minutes old).

### Windows — winget

Coming later. Until then use Scoop or the manual install.

### Manual

1. Download `PSVsCommand-<version>.zip` from [GitHub Releases](https://github.com/WizX20/PSVsCommand/releases/latest).
2. Extract the `PSVsCommand` folder into a directory on your `PSModulePath` — for PowerShell 7 that is `$HOME\Documents\PowerShell\Modules\`, for Windows PowerShell 5.1 `$HOME\Documents\WindowsPowerShell\Modules\`.
3. Run `Import-Module PSVsCommand; vs install profile`, or add `Import-Module PSVsCommand` to your profile yourself (`notepad $PROFILE`).

### From a checkout

```powershell
git clone https://github.com/WizX20/PSVsCommand.git
cd PSVsCommand
task link          # junctions src/PSVsCommand into your CurrentUser module path
Import-Module PSVsCommand -Force
```

## Getting started

```powershell
vs                       # solutions below here: one -> confirm, several -> picker
vs .                     # this folder itself, in Open Folder mode
vs admin                 # the solution whose name matches (fuzzy: 'vs bknd' finds Backend.sln)
vs list                  # what vs would offer, which Visual Studio each one gets, and why
vs installs              # the Visual Studio installs found; vs scan looks again
vs Reports.sln -Use 2019 # this one, in Visual Studio 2019
```

In the picker: Up/Down, Enter to open, type to filter, Tab to send the highlighted solution to another Visual Studio, Esc to cancel. A single match asks first — Enter opens, Tab switches the install, Esc cancels; `-Yes` (or `vs config confirm off`) skips the question.

## Which Visual Studio opens what

`vs` reads each solution before it picks an install:

| The solution… | goes to |
|---|---|
| has an SSRS (`.rptproj`), SSIS (`.dtproj`) or SSAS (`.smproj`, `.dwproj`) project — by path or, in old SSRS solutions, by project type GUID alone | an install with that extension (found under `Common7\IDE\CommonExtensions\Microsoft`, or as a VSIX installed per user or per machine) |
| is an `.slnx`, or declares a `MinimumVisualStudioVersion` above 10 | an install at least that new |
| anything else | the newest stable install |

With `vs config match solution` it prefers the install of the version that saved the solution (`# Visual Studio Version 16` → 2019) whenever that one is installed. `-Use <year|major|edition|id>` overrides all of it for one call. When no install meets a requirement, `vs` says so and opens in the best one it has.

## `vs --help`

```text
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
  - 'install profile' writes $PROFILE.CurrentUserAllHosts of the PowerShell running it:
    run it once in each edition you use (pwsh, Windows PowerShell 5.1).
  - through vs.ps1 - the Scoop shim in cmd, Git Bash or a script - vs exits with 1 when
    nothing was found, opened or changed as asked, else 0.
  - the picker and the confirm need a console: PowerShell or Git Bash in Windows Terminal
    have one. Git Bash in its own window (mintty) hands vs pipes instead, so there it
    prints the list - open one with 'vs <name>'.
  - nothing goes online unless you ask: 'vs update' checks once, 'vs update notify on'
    daily, in the background - its answer shows after a later command. It is one HEAD
    request to GitHub's releases page; no telemetry.
  - settings and caches: C:\Users\you\AppData\Local\PSVsCommand
  - module: C:\Users\you\scoop\apps\psvscommand\current
  - project: https://github.com/WizX20/PSVsCommand
```

## Updates and privacy

`vs` never goes online on its own. `vs update` checks once, when you type it; `vs update notify on` lets it check at most once a day — in a hidden background process, so no command ever waits for GitHub — and print one line after a later command when a newer release is out (`vs update notify off` stops that and the weekly reminder that the option exists). The check is a single HEAD request to `https://github.com/WizX20/PSVsCommand/releases/latest` — GitHub sees an IP address and a user agent, nothing else is sent.

`vs update` knows how `vs` was installed: with Scoop it offers to run `scoop update; scoop update psvscommand` (in a child process, so the update can replace the module that is running; a global install gets the command to run from an elevated shell instead) and then checks which version Scoop really installed, in a git checkout it tells you to `git pull`, and for a manual install it points at the download.

## Uninstall

- **Scoop:** `scoop uninstall psvscommand`. If you ran `vs install profile`, the `Import-Module PSVsCommand` line is harmless afterwards (it carries `-ErrorAction SilentlyContinue`); run `vs uninstall profile` first, or delete it when convenient.
- **Manual:** `vs uninstall profile`, then delete the `PSVsCommand` folder from your modules directory.
- Settings and the install cache live in `%LOCALAPPDATA%\PSVsCommand`; delete that folder too if you want nothing left.

## Contributing

Bug reports, feature ideas, and pull requests welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) to get started. Running from source, tests, and the release pipeline are documented in [DEVGUIDE.md](DEVGUIDE.md). All participants are expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
