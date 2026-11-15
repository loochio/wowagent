# wowagent

Live-development setup for two World of Warcraft: Forever addons (`_forever_`, interface `16001`):

| Path | Purpose |
|---|---|
| `DevAgent/` | Scaffold addon: makes build loads and Lua errors observable |
| `DevMap/` | Feature addon: quest log buttons + objective tracker sections |
| `agent.py` | Watcher that stamps builds, syncs files, and tails SavedVariables |

---

## DevAgent

A minimal scaffold whose only job is making the edit → sync → `/reload` loop verifiable.

- Prints `DevAgent: loaded, build <BUILD_VERSION>` in chat at every login, so a stale client is obvious.
- Appends each load to `DevAgentDB.loadHistory` (capped at 20) in SavedVariables.
- Wraps `seterrorhandler` so Lua errors land in `DevAgentDB.errors` (capped at 100) before the normal handler prints them.
- Slash commands: `/devagent errors`, `/devagent clear`.

## DevMap

The feature addon. Files load in TOC order; `DevMap.lua` creates the `DevMap` namespace, then modules register into it.

| File | Contents |
|---|---|
| `DevMap.lua` | Namespace, module registry, load/error plumbing, `/devmap` commands |
| `map.lua` | Three buttons at the bottom of the quest log panel |
| `tracker.lua` | Sections in the "All Objectives" (objective tracker) UI |

### Quest log buttons (bottom-left of the panel)

| Button | Action |
|---|---|
| `clear tracking` | Removes every tracked quest (regular + world-quest watches) |
| `Track Current Zone` | Clears tracking, then watches quests whose UI map equals the zone you are standing in |
| `print ready for turn in` | Prints ready-to-hand-in quests in chat, grouped by zone |

### Objective tracker sections

| Section | Contents |
|---|---|
| `Ready For Turn In` | Ready-to-hand-in quests, one block per zone |
| `Quest Count` | `quests in log / max quests`, e.g. `24 / 25` |

Both register as tracker modules with `uiOrder` 100/101 and refresh on `QUEST_LOG_UPDATE`.

### DevMap slash commands

`/devmap errors`, `/devmap clear`, `/devmap modules`, `/devmap quests` (per-quest zone/belongs/watched/ready dump), `/devmap tracker` (force-register the tracker sections).

---

## agent.py

Run `python agent.py` in a terminal while developing.

- Watches every addon folder listed in `ADDON_NAMES` (`DevAgent`, `DevMap`) for `.lua`/`.toc` changes (including atomic-save `created`/`moved` events).
- On change, rewrites `local BUILD_VERSION = "..."` in `<Addon>.lua` with the git short SHA (`-dirty` when the tree is dirty) or a timestamp fallback, so the in-chat build banner proves which code is loaded.
- Mirrors changed files into the live install. When the live folder is a symlink/junction to the repo (the current setup) it logs that the edit is already live; otherwise it copies and logs each destination path.
- Logs every file it touches with a timestamp.
- Tails `WTF/Account/<account>/SavedVariables/DevAgent.lua` and prints new `[wow-error]` / `[wow-load]` entries to the terminal.

Configure `REPO_DIR`, `WOW_ROOT`, `WOW_FLAVOR`, `WOW_ACCOUNT_NAME` and `ADDON_NAMES` in the CONFIG block.

### Install layout

```
E:\dev\wowagent\            <- repo (DevAgent/, DevMap/, agent.py)
E:\Games\World of Warcraft\_forever_\Interface\AddOns\
    DevAgent  -> junction -> E:\dev\wowagent\DevAgent
    DevMap    -> junction -> E:\dev\wowagent\DevMap
```

The junctions mean live edits need no copy step; the watcher only stamps and logs. (Symlinks would work too, but require admin privileges, hence junctions.)

---

## Notes

- Both addons target the WoW: Forever client (build 1.60.1.x, interface `16001`), which is 11.x-derived — frame and API names were verified against the matching client source.
- Zone matching uses `C_Map.GetBestMapForUnit("player")` walked up to `Enum.UIMapType.Zone`, plus `GetQuestUiMapID(questID) == zoneMapID` and `C_QuestLog.GetQuestsOnMap(zoneMapID)` (the same combination Blizzard's own bounty-board filter uses).
- Lua errors in any module are captured into `DevMapDB.errors` and can be read with `/devmap errors`.
