# Developer Guide

Contributor reference for PSVsCommand (`vs`). End-user install and usage live in [README.md](README.md).

## Layout

```
src/PSVsCommand/PSVsCommand.psm1   the module: all helpers + the `vs` dispatcher + completers
src/PSVsCommand/PSVsCommand.psd1   module manifest (ModuleVersion is the release version)
src/PSVsCommand/vs.ps1             entry script for shells without the module (the Scoop shim runs it)
tests/PSVsCommand.Tests.ps1        Pester 5+ suite; fake Visual Studio installs under $TestDrive
tests/Scripts.Tests.ps1            Pester tests for the dev scripts in scripts/
changelog.d/                       one release-notes fragment per pull request; the release folds them into CHANGELOG.md
scripts/                           lint / test / pack / set-version / cut-changelog / dev-link
bucket/psvscommand.json            Scoop manifest; this repo doubles as the Scoop bucket
.github/workflows/ci.yml           lint + test on pwsh and Windows PowerShell 5.1, pack, release-token expiry; also weekly
.github/workflows/release.yml      weekly/manual release: stamp, test, pack, bump bucket, tag, GitHub Release
.gitconfig                         maintainer-only: makes this clone talk to GitHub as WizX20
Taskfile.yml                       `task --list`
```

## Running from source

```powershell
task link                       # junction src/PSVsCommand into your CurrentUser module path
Import-Module PSVsCommand -Force # after every edit
task unlink                     # remove the junction
```

`task link` in another checkout or worktree points the junction there (it says `re-pointing`); one left pointing at a deleted worktree is fixed the same way. Or skip the junction and load by path: `Import-Module ./src/PSVsCommand -Force`. To try the shim path, run the entry script the way Scoop's `vs.cmd` does: `pwsh -NoProfile -File src/PSVsCommand/vs.ps1 list -All`.

Set `PSVSCOMMAND_HOME` to a scratch folder to keep your experiments away from your real settings and install cache (`%LOCALAPPDATA%\PSVsCommand`).

Requires PowerShell 7 or Windows PowerShell 5.1 and [Task](https://taskfile.dev) for the `task` shortcuts (every task is a one-liner you can also run by hand).

## Tests and lint

```powershell
task check                  # lint + test, what CI runs
task lint                   # PSScriptAnalyzer over src/, scripts/, tests/
task test                   # Pester; `task test -- tests/PSVsCommand.Tests.ps1` for one file
task help                   # print `vs --help` (the README quotes it verbatim)
```

- Tests need **Pester 5+** (`Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck`) and lint needs **PSScriptAnalyzer** (`Install-Module PSScriptAnalyzer -Scope CurrentUser`). On CI both are installed on the fly when missing. The Pester 3.4 that ships with Windows cannot run the suite.
- No test needs Visual Studio. `New-FakeVs` builds an install folder with an empty `devenv.exe` and the extension folders it should have, and describes it the way vswhere does; `Invoke-VsWhere`, `Find-VsLegacyInstalls` and `Get-VsInstancesStamp` are mocked to hand those over. `Start-VsProcess` is mocked everywhere a test opens something — assert on its `-Exe` and `-Argument`.
- Every test gets its own `PSVSCOMMAND_HOME` under `$TestDrive`; the update tests mock `Get-VsLatestRelease` (a mock that must not be called asserts `-Times 0`), `Start-VsUpdateCheck` (the hidden child process of the daily check — never let the suite start one) and `Get-VsNow` for the once-a-day/once-a-week throttles.
- Exit codes: failures go through `Write-VsFail`, which sets `$script:VsExitCode`; `vs.ps1` exits with it. The `vs.ps1` tests start the entry script as a child process of the same edition, the way Scoop's `vs.cmd` does.
- `vs` prints through `Write-Host`; tests capture it with `6>&1` (the `Get-VsOutput { vs ... }` helper). Call `vs` with real switches inside the block — splatting `'-Yes'` as a string would bind it positionally.
- The picker and the confirm prompt read the console directly and are not under test (`Test-VsConsole` is mocked to `$false`, which takes the plain-text paths); try them by hand in a folder with a few solutions.
- When `task help` changes, paste it into the README's `vs --help` block. Two lines differ per machine — keep `settings and caches: C:\Users\you\AppData\Local\PSVsCommand` and `module: C:\Users\you\scoop\apps\psvscommand\current` there. A test compares the two with those lines normalised, so a help change without the README fails `task test`.

## GitHub account: everything as WizX20

This repo is published from a machine that also has a work GitHub account logged in to `gh`. Rather than `gh auth switch` back and forth, the repo carries a [`.gitconfig`](.gitconfig) that a maintainer includes once per clone:

```powershell
task setup      # = git config --local include.path ../.gitconfig
```

From then on, inside this clone:

- commits are authored as `WizX20 <…>`;
- `git push` / `git fetch` authenticate as WizX20 — the credential helper obtains that account's token from the keyring at call time via `gh auth token --user WizX20` and hands it to `gh auth git-credential` through `GH_TOKEN` (the CLI's helper otherwise only serves the *active* account);
- `git gh <anything>` (or `task gh -- <anything>`) runs the GitHub CLI the same way: `git gh pr create`, `git gh run watch`, …

Nothing is written to disk and the active `gh` account is untouched. Plain `gh` still uses whatever account is active — use `git gh` in this repo. Contributors never need any of this; without the include the file is inert.

## Release process

Releases are cut by `.github/workflows/release.yml`. It runs **once a week, Tuesday 06:00 UTC**, and on manual dispatch — nothing else triggers it:

```powershell
task release                    # release now: next patch version (or the manifest's version if that was never released)
task release VERSION=1.1.0      # release now with an explicit version
```

The `check` job decides first, on `main`:

1. **Anything to release?** If `main` is exactly the commit of the latest `v*` tag, stop quietly (the weekly run is a no-op on a quiet week) — unless that tag has no published GitHub Release: then fail with the command that publishes its draft (see below).
2. **Which version?** The dispatch input if given; else the manifest's `ModuleVersion` when no tag for it exists yet (first release, or a bump made in a PR); else the next patch of it. For a **minor/major** bump, raise `ModuleVersion` in `src/PSVsCommand/PSVsCommand.psd1` in your PR — the next release ships exactly that.
3. **Validate** — plain `x.y.z`, no such tag yet, not below the manifest version.
4. **Release token** — the `PSVSCOMMAND_RELEASE_TOKEN` secret must exist.
5. **Gate on CI** — the CI run of the exact commit being released must be `success` (it waits up to 20 minutes for a run still going). An API error, or no CI run after five minutes, refuses the release rather than letting it through: the release job only tests on PowerShell 7, so without CI a Windows PowerShell 5.1 regression could ship.

Then the `release` job, on the commit step 5 verified — not whatever `main` is by then (a merge during the CI wait would otherwise ship untested, or stamp the next patch over a minor bump that just landed):

6. **Stamp** — `scripts/set-version.ps1` writes `ModuleVersion`; `scripts/cut-changelog.ps1 -FallbackFromGit` folds the `changelog.d/` fragments (and any lines still under `## [Unreleased]`) into a new `## [x.y.z] - <date>` section, grouped per Keep a Changelog section, deletes the fragments and extracts that section as the release notes. With no entries at all it uses the commit subjects since the last tag, so write readable subjects even when a change needs no fragment.
7. **Lint + test** the stamped module.
8. **Pack** — `scripts/pack.ps1` builds `dist/PSVsCommand-x.y.z.zip` (top-level `PSVsCommand/` folder with `PSVsCommand.psd1`, `PSVsCommand.psm1`, `vs.ps1`, `LICENSE`, `NOTICE`) and prints its SHA256.
9. **Bump the bucket** — `bucket/psvscommand.json` gets the new `version`, `url` and `hash`, edited in place.
10. **Commit** `chore: release vx.y.z` (as `github-actions[bot]`).
11. **Draft the GitHub Release** `vx.y.z` with the zip attached and the changelog section as body — before anything reaches `main`.
12. **Tag + push** — the commit and the `vx.y.z` tag go to `main` with the release token, atomically: branch and tag land together or not at all. When `main` moved meanwhile the push is refused, the draft is deleted and nothing is published; run the release again.
13. **Publish** the draft, as the latest release (Scoop's `checkver` and `vs update` follow `releases/latest`).

If step 13 fails after step 12 pushed, `main`'s manifest points at a zip nobody can download yet. Publish the draft by hand: `git gh release edit vx.y.z --draft=false --latest`. Do **not** re-pack and upload a zip from the tag: a rebuilt zip has another SHA256 than the hash the pushed manifest carries, and every `scoop install` would fail on it. As long as `main` is still at that tag, every later run — weekly or dispatched — stops in step 1 with that same command, instead of reporting "nothing to release". If the draft is gone, its zip went with it: merge anything to `main` and release again; the next version carries a fresh zip and hash.

### First release

`bucket/psvscommand.json` ships with a placeholder hash (all zeros) until the first release has run; `scoop install psvscommand` fails with a hash mismatch before that. Run `task release` once the repo is on GitHub, the release token is set and CI is green — it ships the manifest's `1.0.0`.

### Required secret: `PSVSCOMMAND_RELEASE_TOKEN`

`main` is protected by a ruleset (pull requests only, squash merges only, CI checks required, no force-push; only the repository admin may bypass). `GITHUB_TOKEN` cannot bypass rulesets on a user-owned repository, so the release commit is pushed with a maintainer token. Only the push step sees it: both checkouts persist no credentials, so lint, the tests and the modules they install never run next to a token that may bypass the ruleset. `GITHUB_TOKEN` gets per-job permissions only — `check` reads contents and actions (the CI runs), `release` writes contents (the GitHub Release). To create the token:

1. GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate. Resource owner `WizX20`, repository access: only `PSVsCommand` (PSWorktree has its own token, `PSWORKTREE_RELEASE_TOKEN`), permissions: **Contents: Read and write** (Metadata: Read is added automatically). Expiry: 90 days (the current token's lifetime; one year at most).
2. Copy the token and, inside this clone, pipe it in — `git gh` is the repo's alias (see above), plain `gh` would act as the wrong account, and the value stays out of the shell history:

   ```powershell
   Get-Clipboard | git gh secret set PSVSCOMMAND_RELEASE_TOKEN -R WizX20/PSVsCommand
   ```

3. Re-run the **release token expiry** job (or push anything): its log and run summary show the expiry GitHub reports. Put that date, and a rotate-by date two weeks before it, in the title of the rotation issue ([#1](https://github.com/WizX20/PSVsCommand/issues/1)).

The `check` job fails early with a clear message when the secret is missing. CI's required **release token expiry** job reads the token's real expiry from the API (`GitHub-Authentication-Token-Expiration` header) on every PR and push, and in a weekly scheduled CI run on Mondays 05:00 UTC: a warning 30 days out, a failure 14 days out, and a failure when the secret is missing — so an expiring token blocks merges until it is rotated, and no date has to be maintained by hand. A failed scheduled run emails the maintainer, so a quiet week no longer hides a token that lapses before Tuesday's release. GitHub disables scheduled workflows after 60 days without repository activity; in a stretch that quiet, the dated rotation issue and GitHub's own expiry mail are the reminders left. Pull requests from forks and from Dependabot get no repository secrets, so the job skips them (a skipped job counts as passed for the required check). Rotating is the same three steps as above; the issue keeps the checklist. A push with this token also triggers CI on `main` for the release commit — expected, one extra run per release. Without expiry the same can be done with a GitHub App added to the ruleset's bypass list; not worth it for one maintainer.

### Branch rules (ruleset `main`)

Managed on GitHub: **Settings → Rules → Rulesets → main**. Pull request required, `squash` the only merge method, required checks `lint + test (pwsh)`, `lint + test (powershell)`, `pack module zip` and `release token expiry`, deletion and force-push blocked; bypass list: repository admin only. Direct pushes to `main` are therefore impossible for everyone but the owner, and a PR cannot be squash-merged before CI is green.

### Repo visibility

Scoop fetches release assets over unauthenticated HTTPS, and `vs update` reads the `releases/latest` redirect the same way. `WizX20/PSVsCommand` must stay **public** for both to work.

## Scoop bucket maintenance

- Manifest: `bucket/psvscommand.json`. The release workflow bumps `version`/`url`/`hash`; `checkver: github` + `autoupdate` let `scoop update` find new releases.
- Users subscribe to the bucket straight from this repo: `scoop bucket add psvscommand https://github.com/WizX20/PSVsCommand`. The bucket name is a local alias for the repo URL; each WizX20 tool has its own (`psworktree`, `psvscommand`). If the number of tools grows, the manifests belong together in one `WizX20/scoop-bucket` repo that the release workflows push into (PSWorktree#8).
- `bin: vs.ps1` makes Scoop write `vs.ps1`, `vs.cmd` and a bash `vs` into `~/scoop/shims`, all pointing at `apps\psvscommand\current\vs.ps1` — the `current` junction, so updates keep them valid. From PowerShell the `.ps1` shim runs in-process (the module stays imported afterwards); from cmd and Git Bash it starts pwsh (else powershell.exe) with `-File`, which hands the switches through intact.
- `psmodule.name: PSVsCommand` makes Scoop junction `~/scoop/modules/PSVsCommand` to the install dir and put `~/scoop/modules` on the user's `PSModulePath` (registry); `post_install` patches `PSModulePath` in the running process too. The profile is left alone: `vs install profile` adds the import for those who want Tab completion. `post_uninstall` only unloads the module: it also runs on every update, so anything it prints shows up there too. A leftover profile line is harmless thanks to `-ErrorAction SilentlyContinue`; the README's Uninstall section says so.
- Scoop refreshes its local copy of the bucket only on a bare `scoop update` (or when its last update is a few hours old), so `vs update` runs `scoop update; scoop update psvscommand` and then reads the version in `apps\psvscommand\current` instead of trusting Scoop's exit code.
- To try a manifest change before a release, test the hook script on its own: load `bucket/psvscommand.json`, `[scriptblock]::Create($m.post_install -join "`r`n")`, and invoke it with `$dir` and `$global` defined.

## winget

Not yet. winget has no notion of PowerShell modules; publishing `vs` there means wrapping the module in an installer or a portable that also puts the shim on PATH. Tracked as a later addition — the README says so.

## Conventions

- **Changelog** — a user-visible change adds a fragment `changelog.d/<branch>.<section>.md` ([format](changelog.d/README.md)); `scripts/cut-changelog.ps1` folds the fragments into `CHANGELOG.md` at release and deletes them. Never edit released sections.
- **Help text** — `Show-VsHelp` is the contract; the README quotes it. Change both.
- **Commits** — new commits, no amends of published commits, no skipped hooks.
- **Starting Visual Studio** — always through `Start-VsProcess` (one place to mock, one place that quotes), never `Start-Process devenv` inline.
