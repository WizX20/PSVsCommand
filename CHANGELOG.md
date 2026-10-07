# Changelog

All notable changes to PSVsCommand (`vs`) are listed here, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are [semantic](https://semver.org/).
New entries go in [changelog.d/](changelog.d/README.md), one file per pull request — the Release workflow folds them in here under the new version and date.

## [Unreleased]

### Fixed

- Release pipeline: a release ships exactly the commit CI verified, pushes the release commit and tag atomically, and
  drafts the GitHub Release before the push and publishes it after — so the Scoop manifest on `main` never points at a
  zip that is not there. It refuses to release when CI's verdict is unknown, and keeps the release token out of every
  step but the push. A weekly CI run catches an expiring release token in a quiet week.

## [1.0.2] - 2026-10-06

### Fixed

- `vs update` no longer says "updated" while Scoop kept the old version: it refreshes the bucket first
  (`scoop update; scoop update psvscommand` — minutes after a release Scoop's copy of the bucket can still be the old
  one) and then reads the version Scoop really installed. The update notice names the same command.
- A Scoop update no longer prints the "Gone for good?" uninstall hint: the hook runs on every update too.

## [1.0.1] - 2026-10-01

### Fixed

- Solutions in folders under OneDrive (Files On-Demand) are found: the search skipped every folder with the
  reparse-point attribute, which OneDrive sets on all of them. Only real junctions and symlinks are skipped now.
- An SSRS or SSIS extension installed as a VSIX — per user, or per machine under the install — is recognised by
  its display name; before, only the extension's folder under `CommonExtensions` counted.
- Team Explorer and installs an update left half done are no longer picked to open a solution; on equal versions
  Enterprise goes before Professional before Community.
- Updating Visual Studio within a major (17.12 → 17.14) refreshes the install cache on its own; until now only
  adding or removing an install did, so an `.slnx` could be refused until `vs scan`.
- `vs <name>` opens an exact name straight away (`vs Backend` with `Backend.sln` and `BackendTests.sln` next to it),
  and a path that does not exist says so instead of being searched for as a name.
- `vs update` on a global Scoop install (`scoop install -g`) says to run `scoop update psvscommand --global` from an
  elevated shell instead of running a plain `scoop update` that cannot touch it.
- `-Depth 0` is refused instead of quietly meaning the default, and `vs /?` from Git Bash (which turns it into a path)
  shows the help.

### Added

- SSAS projects (`.smproj`, `.dwproj`) are recognised and go to an install with the Analysis Services extension.
- Through the Scoop shim (cmd, Git Bash, scripts) `vs` exits with 1 when nothing was found, opened or changed as asked.

### Changed

- Loading the module (the profile line) is about 200 ms faster: the version is read when it is needed, not at
  import.
- A plain file (`vs Program.cs`) opens in a Visual Studio that is already running (`devenv /Edit`) instead of a new one.
- The opt-in daily update check runs in a hidden background process; no command waits for GitHub any more, and the
  news shows after a later command.
- Repeated `vs` calls are faster (the list ~30% warm; rows and table two to three times), Tab completion reuses the
  names it found for 15 seconds, and the search skips hidden folders (`AppData`), `artifacts` and `dist`, and at a
  drive root the Windows and program folders.
- Only a `devenv.exe` is ever started from the install cache.

## [1.0.0] - 2026-10-01

### Added

- First public release of `vs`, the Visual Studio launcher that lived in a `vs.ps1` script until now.
- `vs` looks for solutions (`.sln`, `.slnx`) below the current folder and keeps going after the first one: one
  match opens after a confirm, several get an interactive picker (Up/Down, Enter, type to filter). A folder that
  holds a solution is not searched further down unless `-All`, so a repo with `backend\Backend.sln` and
  `admin-tools\cli\AdminTools.sln` offers exactly those two. Nothing below: the nearest solution above, up to the
  repository top. No solution at all: the project files.
- `vs .` opens the current folder itself in Visual Studio (Open Folder), like `code .`; `vs <dir>` searches
  `<dir>`, `vs <file>` opens it, `vs <name>` opens the solution whose name matches (or the filtered picker).
- Visual Studio installs are found once — vswhere, the registry for 2015 and older, the default folders without
  either — and cached; `vs installs` lists them, `vs scan` looks again, and a stale cache (an install gone, or
  the Visual Studio Installer changed something) rescans on its own.
- Each solution goes to the install that fits it: SSRS (`.rptproj`) and SSIS (`.dtproj`) projects to an install
  with that extension, `.slnx` and a `MinimumVisualStudioVersion` to one new enough, everything else to the newest
  stable install. `-Use 2019|18|Pro|<id>` overrides, Tab in the picker and the confirm switches installs, and
  `vs list` shows the choice and the reason for every solution. `vs config match solution` prefers the version
  that saved the solution instead.
- `vs config` (`match`, `depth`, `confirm`), `vs version`, `-Yes`, `-Admin`, `-Depth`, `-Folder`.
- `vs update` checks GitHub for a newer release and knows how `vs` was installed (Scoop: offers to run
  `scoop update psvscommand`; checkout: `git pull`; manual: the download). `vs update notify on` opts in to a check
  at most once a day; nothing goes online without that or an explicit `vs update`.
- `vs install profile` / `vs uninstall profile` for the `Import-Module` line behind Tab completion.
- Packaged as the `PSVsCommand` PowerShell module with a `vs.ps1` entry script; installable with Scoop from this
  repo's bucket, which puts a `vs` shim on PATH for PowerShell, cmd and Git Bash alike.

