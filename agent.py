#!/usr/bin/env python3
"""
DevAgent sync/watch script for a live-developed WoW addon.

What it does:
  1. Watches your source folder for .lua / .toc changes.
  2. On change: stamps a fresh BUILD_VERSION into DevAgent.lua (git SHA if
     available, else a timestamp), and — if you are NOT using a symlink —
     copies the files into the live AddOns folder.
  3. Prints a reminder to /reload in-game.
  4. Watches the addon's SavedVariables file (only written by WoW on
     logout/UI-reload) and, when it changes, prints any new entries in
     DevAgentDB.errors and DevAgentDB.loadHistory so you get instant
     feedback in this terminal without tabbing into the game.

Setup:
  1. pip install watchdog
  2. Edit the CONFIG block below.
  3. Run: python agent.py
"""

import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer

# ----------------------------- CONFIG --------------------------------------

# Folder containing DevAgent.toc / DevAgent.lua that you actually edit.
SOURCE_DIR = Path(r"E:\dev\wowagent\DevAgent")

# Live AddOns folder for the addon. If you symlinked SOURCE_DIR directly into
# AddOns, set USE_SYMLINK = True and this path is ignored for syncing (only
# used to help you set the symlink up once, see README note below).
ADDON_DIR = Path(
    r"E:\Games\World of Warcraft\_classic_beta_\Interface\AddOns\DevAgent"
)
USE_SYMLINK = True

# Your WoW account folder name under WTF\Account\<THIS>. It's the folder
# name shown in your WTF\Account directory, not your Battle.net email.
WOW_ACCOUNT_NAME = "50168625#2"

# Root of your WoW install (the folder containing "_retail_").
WOW_ROOT = Path(r"E:\Games\World of Warcraft")

SAVEDVARS_PATH = (
    WOW_ROOT / "_classic_beta_" / "WTF" / "Account" / WOW_ACCOUNT_NAME
    / "SavedVariables" / "DevAgent.lua"
)

DEBOUNCE_SECONDS = 0.5

# ----------------------------------------------------------------------------

LUA_FILE = SOURCE_DIR / "DevAgent.lua"
VERSION_RE = re.compile(r'(local BUILD_VERSION = ")[^"]*(")')


def get_build_tag() -> str:
    """git short SHA if this is a git repo, else a timestamp."""
    try:
        sha = subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=SOURCE_DIR, stderr=subprocess.DEVNULL, text=True,
        ).strip()
        dirty = subprocess.call(
            ["git", "diff", "--quiet"], cwd=SOURCE_DIR,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ) != 0
        return f"dev-{sha}{'-dirty' if dirty else ''}"
    except Exception:
        return "dev-" + datetime.now().strftime("%Y%m%d-%H%M%S")


def stamp_version() -> str:
    if not LUA_FILE.exists():
        print(f"[agent] WARNING: {LUA_FILE} not found, skipping stamp.")
        return ""
    tag = get_build_tag()
    text = LUA_FILE.read_text(encoding="utf-8")
    new_text, n = VERSION_RE.subn(rf'\g<1>{tag}\g<2>', text)
    if n == 0:
        print("[agent] WARNING: BUILD_VERSION line not found in DevAgent.lua")
    elif new_text != text:
        LUA_FILE.write_text(new_text, encoding="utf-8")
    return tag


def sync_to_addon_dir():
    if USE_SYMLINK:
        return  # nothing to copy, the folder IS the live folder
    import shutil
    ADDON_DIR.mkdir(parents=True, exist_ok=True)
    for f in SOURCE_DIR.glob("*"):
        if f.is_file():
            shutil.copy2(f, ADDON_DIR / f.name)


class SourceChangeHandler(FileSystemEventHandler):
    def __init__(self):
        self._last = 0.0

    def on_modified(self, event):
        if event.is_directory:
            return
        if not event.src_path.endswith((".lua", ".toc")):
            return
        now = time.time()
        if now - self._last < DEBOUNCE_SECONDS:
            return
        self._last = now
        tag = stamp_version()
        sync_to_addon_dir()
        print(f"[agent] synced, build {tag} -> /reload in-game to pick it up")


# ------------------------- SavedVariables tail -------------------------

_ERROR_ENTRY_RE = re.compile(
    r'\["time"\]\s*=\s*"([^"]*)".*?\["message"\]\s*=\s*"((?:[^"\\]|\\.)*)"',
    re.DOTALL,
)
_LOAD_ENTRY_RE = re.compile(
    r'\["time"\]\s*=\s*"([^"]*)".*?\["version"\]\s*=\s*"([^"]*)"',
    re.DOTALL,
)


def _extract_block(text: str, key: str) -> str:
    """Grab the Lua table body for DevAgentDB.<key> = { ... }."""
    m = re.search(rf'\["{key}"\]\s*=\s*\{{', text)
    if not m:
        return ""
    start = m.end()
    depth = 1
    i = start
    while i < len(text) and depth > 0:
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
        i += 1
    return text[start:i - 1]


class SavedVarsHandler(FileSystemEventHandler):
    def __init__(self):
        self.seen_errors = 0
        self.seen_loads = 0
        self._prime()

    def _read(self):
        if not SAVEDVARS_PATH.exists():
            return "", ""
        text = SAVEDVARS_PATH.read_text(encoding="utf-8", errors="replace")
        return _extract_block(text, "errors"), _extract_block(text, "loadHistory")

    def _prime(self):
        # On first run, don't dump the whole backlog — just record counts.
        errors_block, loads_block = self._read()
        self.seen_errors = len(_ERROR_ENTRY_RE.findall(errors_block))
        self.seen_loads = len(_LOAD_ENTRY_RE.findall(loads_block))

    def on_modified(self, event):
        if event.is_directory or Path(event.src_path) != SAVEDVARS_PATH:
            return
        # SavedVariables can be mid-write when the event fires; brief settle.
        time.sleep(0.3)
        errors_block, loads_block = self._read()
        errors = _ERROR_ENTRY_RE.findall(errors_block)
        loads = _LOAD_ENTRY_RE.findall(loads_block)

        for t, msg in errors[self.seen_errors:]:
            msg = msg.replace('\\"', '"').replace("\\n", "\n")
            print(f"[wow-error] {t}  {msg}")
        for t, ver in loads[self.seen_loads:]:
            print(f"[wow-load]  {t}  build={ver}")

        self.seen_errors = len(errors)
        self.seen_loads = len(loads)


def main():
    if not SOURCE_DIR.exists():
        sys.exit(f"SOURCE_DIR does not exist: {SOURCE_DIR}")
    if WOW_ACCOUNT_NAME == "YOURACCOUNT":
        print("[agent] NOTE: set WOW_ACCOUNT_NAME in the CONFIG block before "
              "SavedVariables tailing will work.")

    observer = Observer()
    observer.schedule(SourceChangeHandler(), str(SOURCE_DIR), recursive=False)

    if SAVEDVARS_PATH.parent.exists():
        observer.schedule(SavedVarsHandler(), str(SAVEDVARS_PATH.parent), recursive=False)
    else:
        print(f"[agent] NOTE: {SAVEDVARS_PATH.parent} doesn't exist yet — "
              "it's created after the addon loads once in-game.")

    observer.start()
    print("[agent] watching for changes. Ctrl+C to stop.")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()


if __name__ == "__main__":
    main()