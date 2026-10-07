# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

**PSVsCommand** — a PowerShell module (`src/PSVsCommand/`) exporting one command, `vs`: it finds every solution (`.sln`, `.slnx`) below the current folder, offers a picker when there are several, and opens the pick in the Visual Studio install that fits it (SSRS/SSIS projects → an install with that extension, `.slnx`/`MinimumVisualStudioVersion` → one new enough, else the newest). Installs come from vswhere / the registry / the default folders and are cached in `%LOCALAPPDATA%\PSVsCommand` (`PSVSCOMMAND_HOME` overrides). Users reach it through Scoop's `vs` shim, which runs `vs.ps1` (any shell; opening VS needs no cd), and optionally as the module function from their profile (`vs install profile`, for Tab completion). Windows only; PowerShell 7 **and** Windows PowerShell 5.1. Read [DEVGUIDE.md](DEVGUIDE.md) for layout, tests and the release pipeline; [CONTRIBUTING.md](CONTRIBUTING.md) for conventions.

## GitHub account — always WizX20

This repo is published under the **WizX20** account from a machine whose active `gh` account is a work account. Never run `gh auth switch`. Inside this clone:

- `git push` / `git fetch` already authenticate as WizX20 through the included [`.gitconfig`](.gitconfig) (`task setup` once per clone — check with `git config user.name`, it must print `WizX20`).
- Use **`git gh …`** (or `task gh -- …`) instead of `gh …` for PRs, releases, workflow runs, API calls. Plain `gh` acts as the wrong account.
- Commits must be authored as `WizX20 <nerdsonwaves@outlook.com>`; if `git config user.email` shows anything else, run `task setup` before committing.

## Commands

```powershell
task check        # lint + test — run before every push
task test         # Pester (needs Pester 5+); `task test -- tests/PSVsCommand.Tests.ps1`
task lint         # PSScriptAnalyzer; exclusions + reasons in PSScriptAnalyzerSettings.psd1
task help         # `vs --help` from the working copy — README quotes it, keep both in sync
task link         # dev junction into the CurrentUser module path; `task unlink` undoes
task pack         # dist/PSVsCommand-<version>.zip + sha256
task release [VERSION=x.y.z] # dispatch the Release workflow now; it also runs weekly (Tuesday 06:00 UTC) and auto-bumps the patch version
```

## Rules

- **Behaviour changes need a Pester test.** No test needs Visual Studio: `New-FakeVs` builds fake installs, `Invoke-VsWhere`/`Find-VsLegacyInstalls`/`Get-VsInstancesStamp` are mocked, and `Start-VsProcess` is mocked wherever something is opened. Call `vs` with real switches inside `Get-VsOutput { vs -Yes }` — never splat `'-Yes'` as a string, it binds positionally. Mock `Test-VsConsole` to `$false` around anything that could reach the picker or the prompt.
- **5.1-compatible only**: no ternary, no `??`, no `.ForEach{}` on null, nothing .NET-Core-only. Keep the source ASCII.
- **Seams**: Visual Studio starts only through `Start-VsProcess`; the network is touched only by `Get-VsLatestRelease`, and only after `vs update` or an opt-in (`updateCheck = on`) — never by default. The opt-in daily check runs in a hidden child process started by `Start-VsUpdateCheck`: mock it in any test that can reach `Invoke-VsUpdateNotice`, or the suite starts real processes.
- **Exit code**: anything that did not happen as asked goes through `Write-VsFail` (sets `$script:VsExitCode`, which `vs.ps1` exits with); a warning that still lets the command succeed stays a plain `Write-Host`.
- **Changelog**: a user-visible change adds a fragment `changelog.d/<branch>.<section>.md` (see `changelog.d/README.md`) — never edit `CHANGELOG.md` in a PR; the release folds the fragments in and stamps the version (with no entries at all it falls back to commit subjects, so keep subjects readable). Do not touch released sections.
- **Versions**: patch bumps are automatic. For a minor/major, raise `ModuleVersion` in `src/PSVsCommand/PSVsCommand.psd1` in the PR; the next release ships that version.
- **Help is the contract**: change `Show-VsHelp` and paste `task help` into the README block (replace the machine paths in the last NOTES lines with the `C:\Users\you\…` placeholders).
- **Commits**: imperative subject ≤72 chars, new commits (no amend), no `--no-verify`. Branches `feature/…`, `fix/…`, `chore/…` off `main`.
- **Do not commit or push without asking**; never push to `main` directly — open a PR.
