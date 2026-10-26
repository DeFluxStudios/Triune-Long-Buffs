# Triune Long-Duration Buffs

An optional buff-roster plugin for [Triune AutoCombat (TAC)](https://github.com/gennro/TriuneAutocombat), for MacroQuest and the Project Triune EverQuest server.

The plugin discovers eligible scribed class spells and trained class AAs across a character's three classes, proposes up to 15 starting roster entries, and lets the user review and edit the roster. Automatic casting is separately opt-in and uses TAC's downtime-buffing path.

> **Pre-release warning:** `v1.1.1-pre.1` is experimental. It has passed source-level Lua parsing and focused static checks, but has not been tested in a live MacroQuest/EverQuest session. Verify behavior on a safe character before relying on it.

## Requirements

- MacroQuest for EverQuest: Rain of Fear 2 (RoF2).
- Triune AutoCombat with a compatible plugin manager, spell/AA catalog, and downtime-buff integration.
- Project Triune character data. The suggested roster is only as complete as the class spell/AA data supplied by the installed TAC build.

This is **not a standalone MacroQuest script**. Installing this file does not install TAC, MacroQuest, class data, or TAC's core downtime integration. A TAC build without the corresponding `long_buffs` integration may load no plugin UI or may not perform automatic casts.

## Install

1. Install and start a compatible Triune AutoCombat build first.
2. Copy `lua/tac/long_buffs.lua` from this repository into the matching MacroQuest folder:

   ```text
   <MacroQuest folder>\lua\tac\long_buffs.lua
   ```

3. Use the same TAC version/build as the plugin integration. Restart or reload TAC using that build's supported procedure.
4. Open **Settings → Plugins → Long-Duration Buffs**.

Do not overwrite your TAC installation with files from this standalone repository; it only contains the plugin and its documentation.

## Build and review a roster

1. Open **Settings → Plugins → Long-Duration Buffs**.
2. Choose **Build suggested roster (up to 15)**. The scan considers known class buffs, the character's level and three classes, spells in the spellbook, trained AAs, duration, and available spell-stacking information.
3. Review the proposed spell, source, duration, and target scope in the confirmation window.
4. Uncheck any entries you do not want, then choose **Add selected buffs**. Choosing **Cancel** leaves the roster unchanged.
5. Change single-target spell scope to **Self only** or **Self + Group** in the roster. Use **Add Another Eligible Buff** to add more entries individually, or **Remove** to delete one.

The generated list is limited to 15 entries; manual additions can take the saved roster beyond that limit. The recommendation is a heuristic, not a guarantee of the best possible server-specific buff. Unknown pairwise stacking comparisons are disclosed in the review window. Live checks still gate casting.

## Casting behavior and safety

Roster generation and editing do not turn automatic casting on. To cast:

1. Enable **Automatically cast long buffs** in the plugin settings or use `/ac longbuff on`.
2. Start TAC and enable its main **Downtime Buffs** option.
3. Allow TAC to reach a safe downtime state. Long buffs are not cast during combat, movement, or an active med break.

The plugin checks the saved roster and only schedules a cast when the buff is explicitly reported missing, the target is valid/in range, the spell can stack, and the AA/spell is available. If buff state or stacking information is unavailable, the plugin does not treat the buff as missing. Spell casts are handed to TAC's downtime routine so its existing aggro checks and temporary gem restoration can apply.

- **Self-only effects** are checked on the player; they are not cast again while the effect is present.
- **Single-target effects** can be checked on the player only or on the player and current group members.
- **Group spells** are tracked across the current group, including the player, and can be scheduled when an in-range member is missing the effect.

This version does not add med-break rebuffing, nor does it guarantee that every spell/AA in the server's database is represented.

## Commands

```text
/ac longbuff on       Enable automatic long-buff casting
/ac longbuff off      Disable automatic long-buff casting
/ac longbuff toggle   Toggle automatic long-buff casting
/ac longbuff scan     Re-scan eligible spells and trained AAs (requires long buffs enabled)
```

`/ac autobuff` is an alias for `/ac longbuff`.

## Settings and persistence

The enable state, minimum duration, roster entries, and single-target scopes are saved with the TAC loadout. Keep a backup of your TAC settings before testing prerelease builds.

## Troubleshooting

- **No suggestions:** confirm TAC detected your three classes, has the relevant class catalog data, and the spells are scribed or AAs trained. Wait for the spellbook scan to finish before generating again.
- **An unmemorized spell cannot be cast:** TAC needs a usable primary gem slot for its temporary gem swap. The plugin reports when it cannot find one.
- **No casts occur:** confirm the roster is non-empty, plugin casting is enabled, TAC is running, and the main Downtime Buffs control is enabled. Check that the character is not in combat, moving, or in a med break.
- **A spell is skipped:** incompatible/unknown stacking results, missing targets, unavailable spells/AAs, and active effects can all prevent a cast. The plugin fails closed on unknown live buff state.
- **Unexpected targeting or server-specific behavior:** stop automatic casting and report the TAC/MacroQuest versions, character class combination, spell name, and relevant log output. Test with one roster entry first.

## Versioning

The plugin's `version` field and GitHub tags use semantic-version-style values. This preview is `1.1.1-pre.1`; prerelease identifiers sort before the corresponding stable release. See [CHANGELOG.md](CHANGELOG.md) for the recorded changes.

## Attribution and licensing

This companion plugin uses TAC's plugin and downtime-buff APIs. Triune AutoCombat is maintained separately at [gennro/TriuneAutocombat](https://github.com/gennro/TriuneAutocombat); this repository is not an official TAC release. See [NOTICE.md](NOTICE.md). No license is included in this repository; public availability does not grant permission to reuse or redistribute the code.
