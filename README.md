# Triune Long-Duration Buffs

An optional buff-roster plugin for [Triune AutoCombat (TAC)](https://github.com/gennro/TriuneAutocombat), for MacroQuest and the Project Triune EverQuest server.

The plugin discovers eligible scribed class spells and trained class AAs across a character's three classes, recommends a starting roster (15 buffs by default, up to 40), and lets the user review and edit it. It keeps those buffs up on the character and the group, forces a short rebuff break so TAC does not keep pulling, and has a standalone mode.

> **Pre-release warning:** `v1.10.0` is experimental. Core casting, the rebuff break and Box Hub gathering have been exercised in a live session by the author; the newer roster recommendation, audience profiles and 15-40 limit have only passed source-level Lua parsing. Verify on a safe character before relying on it.

## Features

- **Recommended roster:** a confirmation dialog proposes buffs the caster can use at their current level, that someone in the group wants, and that stack with each other. Slots cover melee, defense, resist, mana and spell-haste effects first, then fill by level. The limit is 15 (recommended), adjustable to 40.
- **Who gets which buffs:** per-member profiles (Auto (recommended), Pure melee, Hybrid, Caster / healer, Everything, Custom) with per-category checkboxes. Auto reads each character's classes, so a pure-melee tank is not asked to hold INT/WIS, mana regen or spell haste.
- **Self-only vs group:** self-only buffs are cast once and again only if they fall off; group buffs are tracked on every living member.
- **Rebuff break:** when a roster buff is missing, TAC's pulls pause, the caster meds if low, and (with Box Hub) other boxes are paused and sent to the caster to get in range, then resumed afterward. No rebuff break starts while a named NPC is engaged.
- **Buffs button:** a dedicated **Buffs** button in the TAC header opens the roster without going through Settings.
- **Scribed-spell cache:** a per-character file avoids rescanning the spellbook; it refreshes every 15 minutes, on demand, or when a new spell is scribed.
- **Verbose debug log:** optional log at `<MacroQuest>\logs\triune_long_buffs_<character>.log`.
- **Standalone mode:** `long_buffs_standalone.lua` runs the same roster with its own window when TAC is not running.

## Requirements

- MacroQuest for EverQuest: Rain of Fear 2 (RoF2).
- Triune AutoCombat with a compatible plugin manager, spell/AA catalog, and downtime-buff integration.
- Project Triune character data. The suggested roster is only as complete as the class spell/AA data supplied by the installed TAC build.

The plugin needs TAC's plugin manager plus a small core hook in `triune.lua` (`runtime.nextLongBuffCast` in the downtime-buff path). Those hooks are not in upstream TAC yet; a pull request is open for them (see the repository description). Without the hooks the standalone script still works.

## Install

1. Install and start a compatible Triune AutoCombat build first.
2. Copy these files into the matching MacroQuest folders:

   ```text
   lua/tac/long_buffs.lua             ->  <MacroQuest>\lua\tac\long_buffs.lua
   lua/tac/long_buffs_standalone.lua  ->  <MacroQuest>\lua\tac\long_buffs_standalone.lua
   lua/tac_long_buffs_store.lua       ->  <MacroQuest>\lua\tac_long_buffs_store.lua
   ```

3. Restart or reload TAC. Use the **Buffs** button in the TAC header (or **Settings → Plugins → Long-Duration Buffs**).
4. To use it without TAC, run `/lua run tac/long_buffs_standalone`.

Do not overwrite your TAC installation with files from this repository; it only contains the plugin files and documentation.

## Build and review a roster

1. Open the **Buffs** window. A character with no roster is offered a recommended one automatically (this can be turned off).
2. Or choose **Build suggested roster**. The scan uses the caster's level (spells above your level are skipped even if scribed), the three classes, the spellbook, trained AAs, duration, who in the group wants each effect, and Spell stacking checks against everything already chosen.
3. Review the proposed buffs, uncheck any you do not want, then choose **Add selected buffs**. **Cancel** leaves the roster unchanged.
4. Set **Self only** or **Self + Group** per single-target buff, add or remove entries, and adjust the **Buff limit** slider (15 recommended, max 40).
5. Under **Who gets which buffs**, leave each member on **Auto (recommended)** or pick a profile / tick categories.

The recommendation is a heuristic, not a guarantee of the best possible server-specific buff. Unknown pairwise stacking results are disclosed in the review window, and live checks still gate casting.

## Casting behavior and safety

Roster generation and editing do not turn automatic casting on. To cast:

1. Enable **Automatically cast long buffs** in the plugin settings or use `/ac longbuff on`.
2. Start TAC and enable its main **Downtime Buffs** option.
3. Allow TAC to reach a safe downtime state. Long buffs are not cast during combat, movement, or an active med break.

The plugin checks the saved roster and only schedules a cast when the buff is explicitly reported missing, the target is valid/in range, the spell can stack, and the AA/spell is available. If buff state or stacking information is unavailable, the plugin does not treat the buff as missing. Spell casts are handed to TAC's downtime routine so its existing aggro checks and temporary gem restoration can apply.

- **Self-only effects** are checked on the player; they are not cast again while the effect is present.
- **Single-target effects** can be checked on the player only or on the player and current group members.
- **Group spells** are tracked across the current group, including the player, and can be scheduled when an in-range member is missing the effect.

In combat, only already-memorized spells are cast, and nothing is cast while a named NPC is engaged. The rebuff break is limited to 240 seconds, tries each target at most 3 times, and backs off for 10 minutes after a timeout. Gathering the group needs Box Hub on every box with remote commands enabled; without it the caster walks to out-of-range members instead. This version does not guarantee that every spell/AA in the server's database is represented.

## Commands

```text
/ac longbuff on       Enable automatic long-buff casting
/ac longbuff off      Disable automatic long-buff casting
/ac longbuff toggle   Toggle automatic long-buff casting
/ac longbuff scan     Re-scan eligible spells and trained AAs (requires long buffs enabled)
/ac longbuff debug    Toggle the verbose debug log
/longbuff ...         Same commands for the standalone script
```

`/ac autobuff` is an alias for `/ac longbuff`.

## Settings and persistence

The roster, minimum duration, buff limit, per-member profiles and the scribed-spell cache are saved per character in `<MacroQuest>\config\triune_long_buffs_<server>_<character>.lua`, shared by TAC and the standalone script. Other options (casting on/off, rebuff break, Box Hub gathering, debug log) are saved with the TAC loadout. Keep a backup of your TAC settings before testing prerelease builds.

## Troubleshooting

- **No suggestions:** confirm TAC detected your three classes, has the relevant class catalog data, and the spells are scribed or AAs trained. Wait for the spellbook scan to finish before generating again.
- **An unmemorized spell cannot be cast:** TAC needs a usable primary gem slot for its temporary gem swap. The plugin reports when it cannot find one.
- **Need more detail:** turn on **Verbose debug log** and read `<MacroQuest>\logs\triune_long_buffs_<character>.log` (`GATE`, `BREAK`, `GATHER`, `AUDIENCE`, `SUGGEST` lines explain each decision).
- **No casts occur:** confirm the roster is non-empty, plugin casting is enabled, TAC is running, and the main Downtime Buffs control is enabled. Check that the character is not in combat, moving, or in a med break.
- **A spell is skipped:** incompatible/unknown stacking results, missing targets, unavailable spells/AAs, and active effects can all prevent a cast. The plugin fails closed on unknown live buff state.
- **Unexpected targeting or server-specific behavior:** stop automatic casting and report the TAC/MacroQuest versions, character class combination, spell name, and relevant log output. Test with one roster entry first.

## Versioning

The plugin's `version` field and GitHub tags use semantic-version-style values. This preview is `1.10.0`; prerelease identifiers sort before the corresponding stable release. See [CHANGELOG.md](CHANGELOG.md) for the recorded changes.

## Attribution and licensing

This companion plugin uses TAC's plugin and downtime-buff APIs. Triune AutoCombat is maintained separately at [gennro/TriuneAutocombat](https://github.com/gennro/TriuneAutocombat); this repository is not an official TAC release. See [NOTICE.md](NOTICE.md). No license is included in this repository; public availability does not grant permission to reuse or redistribute the code.
