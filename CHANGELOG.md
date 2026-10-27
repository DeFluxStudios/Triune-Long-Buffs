# Changelog

Notable changes to the Triune Long-Duration Buffs plugin are recorded here. This changelog follows semantic-version-style numbering. Prerelease tags (for example, `1.1.1-pre.1`) are experimental builds and are not stable releases.

## [1.10.0] - 2026-10-26

- Each character automatically gets a recommended roster to review when it has none (setting "Offer a recommended roster when this character has none", on by default). The confirmation dialog is unchanged; nothing is added until you accept, and the list stays fully editable.
- Selection now: skips spells above the caster's current level, skips buffs nobody in the group wants (uses the 1.9.0 audiences; self-only buffs use the caster), checks stacking against everything already chosen, and fills slots by covering each effect category first (melee, defense, resists, mana, spell haste) before filling the rest by level.
- Stacking check fixed: it now uses `Spell.WillStack` and evaluates the TLO result (the old check never evaluated it and treated every pair as unknown). Pair results are cached per run.
- New "Buff limit" slider: 15 recommended, up to 40. Internal ceiling is 60 (`ROSTER_HARD_MAX`) so more slots can be enabled later. The limit and auto-offer setting are saved in the per-character shared file, so TAC and the standalone agree.
- Debug log gains a `SUGGEST:` line with counts of skipped spells.

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
