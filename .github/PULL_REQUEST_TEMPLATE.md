<!--
Thanks for the PR! Fill in the sections below — the checklist at the bottom catches the things that bounce most often in review.
-->

## What

<!-- One or two sentences on the change. -->

## Why

<!-- The user-facing problem or use case. Link the issue if there is one: `Fixes #123`. -->

## How it works

<!-- Brief technical note on the approach if non-obvious. Skip for trivial changes. -->

## Testing

<!-- How you verified this. -->

- [ ] `task lint` and `task test` pass locally
- [ ] Tried it for real in a folder with several solutions (the picker and the confirm prompt are interactive — Pester covers the non-interactive paths)
- [ ] Checked on Windows PowerShell 5.1 too, if the change touches console handling
- [ ] Checked through the Scoop shim (`vs` from cmd or Git Bash), if the change touches argument handling

## Checklist

- [ ] A changelog fragment in `changelog.d/` (user-visible changes only; see `changelog.d/README.md`) — not an edit to `CHANGELOG.md`.
- [ ] `vs --help` (in `Show-VsHelp`) updated if a command, flag or behaviour changed — the README quotes it.
- [ ] No new dependency: the module stays a single `.psm1` that only needs PowerShell 5.1+ (and Visual Studio to open things in).
- [ ] Commits follow the conventions in [CONTRIBUTING.md](../CONTRIBUTING.md) (imperative subject ≤72 chars, new commits not amends, hooks not skipped).
