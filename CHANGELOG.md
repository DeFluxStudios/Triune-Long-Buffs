# Changelog

Notable changes to the Triune Long-Duration Buffs plugin are recorded here. This changelog follows semantic-version-style numbering. Prerelease tags (for example, `1.1.1-pre.1`) are experimental builds and are not stable releases.

## [1.1.1-pre.1] - 2026-10-26

### Fixed

- Fail closed when TAC cannot determine whether a target has a buff. Unknown or non-boolean buff state is no longer treated as a confirmed missing effect, preventing an unsafe recast decision.

### Documentation

- Added installation, roster, casting-safety, command, troubleshooting, and versioning guidance for the standalone plugin package.
- Marked the build as a prerelease; no live MacroQuest/EverQuest validation is claimed.

## [1.1.0] - Baseline in the local plugin source

This version number was present in the plugin before the standalone `1.1.1-pre.1` package. It is included as a source-history reference; this repository does not claim that `1.1.0` was independently tagged or published.

### Features present in the baseline

- Suggested roster generation from the character's class spell catalog, scribed spells, and trained class AAs.
- Review-and-confirm flow for generated suggestions, capped at 15 generated entries.
- Editable saved roster, manual additions/removals, single-target scope selection, and duration display.
- Self, single-target group, and group-spell tracking using TAC/MacroQuest buff and stacking checks.
- Optional automatic casting through TAC's downtime-buff path, disabled until explicitly enabled.
