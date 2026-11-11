# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `github-pr-review`: claims check (§3.11) and opportunistic head-vs-base
  behavioral probes (§3.12). Findings require a concrete case, probes run only
  with tooling already present (never installed mid-review), and the review
  summary carries a `Not checked:` list naming what was skipped and why.

### Removed

- RepoMan-specific skills and plugin entries: `repoman`, link-health scanner
  and fixer, dep-bump scanner and fixer, automation-health dashboard, GitHub
  weekly report, and repo-sync. These are maintained in
  [rossoctl/repoman](https://github.com/rossoctl/repoman) instead, avoiding
  duplication and staleness.
- The old bundled RepoMan engine, provenance stamp, and engine-vendoring script
  and test. Engine distribution and vendoring now belong to `rossoctl/repoman`.

### Changed

- Installation documentation directs RepoMan users to `rossoctl-repoman` and
  describes migrating existing installs without deleting `~/.repoman/` state.
- `github-pr-review` remains available here as a standalone plugin. HyperShift
  and BYO Cortex skills are unaffected.

## [0.1.0] - 2026-10-23

First tagged release of RepoMan, distributed through the `rossoctl-agent-skills`
marketplace.

RepoMan runs automated maintenance **programs** across a set of GitHub repos you
enroll once, handling the capability checks and output wiring for you. `/repoman` is
a single intent-dispatching entrypoint that infers whether you are setting up,
enabling a program, or running one.

### Added

- **Self-contained `repoman` plugin.** One install bundles the `/repoman` entrypoint,
  every program skill, and the engine scripts, so you install once and enable more
  programs on the fly. The engine is vendored into the plugin and resolved at runtime
  via `${CLAUDE_PLUGIN_ROOT}` — no separate automation checkout is required.
- **Six programs** ship ready to enable: `link-health` (scanner + fixer),
  `dep-bump` (scanner + fixer), `pr-review`, `repo-sync`, `automation-health`, and
  `weekly-report`.
- **Standalone program plugins** remain installable on their own, for using a single
  program (for example a one-off PR review) without the full RepoMan bundle.
- **Provenance stamp** (`_vendor.json`) records the exact `rossoctl/automation` commit
  the bundled engine was vendored from, so a shipped bundle is traceable to its source.

### Changed

- `marketplace.json` version reconciled to `0.1.0`.
- All skills now declare `bash` 3.2+ and run on the macOS system default.

### Notes

- Engine development lives in `rossoctl/automation`; engine fixes reach every RepoMan
  user through a single `repoman` plugin update.

### Contributors

Gloire Rubambiza, Aleksander Slominski, Mariusz Sabath, Jim Cadden.

[0.1.0]: https://github.com/rossoctl/agent-skills/releases/tag/v0.1.0
