# Contributing

Thanks for taking the time to contribute to PSVsCommand (`vs`).

This document covers how to file issues, propose changes, and get a pull request merged. For running from source, the tests, and the release pipeline, see [DEVGUIDE.md](DEVGUIDE.md).

By participating in this project you agree to abide by the [Code of Conduct](CODE_OF_CONDUCT.md).

## Reporting bugs

Open a [GitHub issue](https://github.com/WizX20/PSVsCommand/issues/new/choose) with:

- What you did (the exact `vs` command line, numbered steps)
- What you expected
- What happened — full console output as text; if it is about which solution or which Visual Studio was picked, the output of `vs list` in that folder
- The output of `vs installs` and `vs version`, and the shell you ran it from

If you can reproduce on the latest release from [Releases](https://github.com/WizX20/PSVsCommand/releases/latest), say so.

## Suggesting features

Open an issue describing the use case before writing code. Small fixes can go straight to a PR, but anything that changes which solutions `vs` offers, which Visual Studio it picks for them, or the picker's key handling benefits from a short design discussion first so the PR doesn't bounce on that.

## Security issues

Do **not** open a public issue for security-sensitive bugs. Use GitHub's [private security advisory](https://github.com/WizX20/PSVsCommand/security/advisories/new) on this repo instead.

## Issue labels

Besides the type (`bug`, `enhancement`, `triage`, `maintenance`), an issue carries at most one status label:

- `status/planned` — accepted and on the list; nobody has started.
- `status/in-progress` — a branch or PR exists. Swap `status/planned` for it when work starts.

Closing the issue (usually through `Fixes #n` in the PR) ends the status; there is no `done` label.

## Submitting a pull request

1. Fork the repo and create a topic branch off `main`.
2. Make your change. Keep the diff focused — one concern per PR.
3. Run `task check` (PSScriptAnalyzer + Pester). Add or extend a test in `tests/PSVsCommand.Tests.ps1` for behaviour you changed; fake installs and solution files under `$TestDrive` cover most things without Visual Studio.
4. Try it for real in a folder with a few solutions. The picker and the confirm prompt are interactive and not covered by Pester.
5. For any user-visible change, add a changelog fragment: `changelog.d/<branch>.<section>.md` with a `- ` bullet ([how](changelog.d/README.md)). Do not edit `CHANGELOG.md` itself: one file per PR means no PR conflicts with another over it.
6. Update `Show-VsHelp` in `src/PSVsCommand/PSVsCommand.psm1` if a command, flag or behaviour changed, and paste the new `task help` output into the README's `vs --help` block.
7. Push and open a PR against `main`. Reference any related issue (`Fixes #123`).

CI runs lint + tests on PowerShell 7 and Windows PowerShell 5.1 for every PR — make sure both pass before requesting review.

### Branch naming

- `feature/<short-description>` — new functionality
- `fix/<short-description>` — bug fixes
- `chore/<short-description>` — refactors, build/CI, docs, dependency bumps

### Commit messages

- Imperative subject, ≤72 characters, no trailing period (`Add -Folder to vs`, not `Added -Folder to vs.`).
- Optional `feat:` / `fix:` / `chore:` prefix when it adds clarity — match the existing `git log` style.
- Body (when needed): wrap at 72 columns, explain **why** more than what.
- Create new commits — do not amend or force-push published commits.
- Do not skip hooks (`--no-verify`) or signing.

### Code style

- The module is a single file, `src/PSVsCommand/PSVsCommand.psm1`, in sections: storage, settings, installs, what a solution asks for, finding solutions, console, opening, updates, profile, then `Show-VsHelp`, the `vs` dispatcher and its argument completers at the bottom. Only `vs` is exported.
- Must run on Windows PowerShell 5.1 as well as PowerShell 7: no ternaries, no `??`, no `-Parallel`, nothing that needs .NET Core.
- No dependencies beyond PowerShell. `vs` is meant to be one small module you can read in a sitting.
- Keep the source ASCII: PSScriptAnalyzer wants a BOM on anything else, and 5.1 reads a BOM-less non-ASCII file in the ANSI code page.
- Console output goes through `Write-Host` with the existing colour conventions: green for done, yellow for refused/needs attention, red for errors, dark gray for hints, cyan for news (a new release).
- Visual Studio is started through `Start-VsProcess` only; anything that goes online goes through `Get-VsLatestRelease` only — both are the seams the tests mock.
- Comments explain *why*, not what; keep them terse.
- 4-space indentation, `PascalCase` Verb-Noun helpers with a `Vs` noun prefix, `$camelCase` locals. `task lint` must stay clean; rule exclusions live in `PSScriptAnalyzerSettings.psd1` with a reason each.

## Releasing

Maintainers only. See [DEVGUIDE.md → Release process](DEVGUIDE.md#release-process).

## Licence

By contributing you agree that your contribution is licensed under the [Business Source License 1.1](LICENSE) (BUSL-1.1), and that the [NOTICE](NOTICE) file is preserved in any redistribution.
