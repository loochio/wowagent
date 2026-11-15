#!/usr/bin/env python3
"""
DevAgent/DevMap sync/watch script for live-developed WoW addons.

What it does:
  1. Watches each addon folder in REPO_DIR for .lua / .toc changes.
  2. On change: stamps a fresh BUILD_VERSION into <Addon>.lua (git SHA if
     available, else a timestamp), then mirrors the changed files into the
     live "_forever_" AddOns folder. When the live folder is a junction to
     the repo, the edit is already live and it says so instead of copying.
  3. Logs every file it touches and where it went.
  4. Watches DevAgent's SavedVariables file (written by WoW on logout or UI
     reload) and prints new DevAgentDB.errors / DevAgentDB.loadHistory entries,
     so you get feedback without tabbing into the game.

Setup:
  1. pip install watchdog
  2. Edit the CONFIG block below.
  3. Run: python agent.py
"""

import os
import re
import shutil
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Optional

from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer

# ----------------------------- CONFIG --------------------------------------

# Repo folder that holds one sub-folder per addon.
REPO_DIR = Path(r"E:\dev\wowagent")

# Root of your WoW install (the folder containing "_retail_", "_forever_", ...).
WOW_ROOT = Path(r"E:\Games\World of Warcraft")

# Install flavor you develop against. Forever installs into "_forever_".
WOW_FLAVOR = "_forever_"

# Addon folder names under REPO_DIR that get mirrored into the live AddOns dir.
ADDON_NAMES = ["DevAgent", "DevMap"]

# Your WoW account folder name under WTF\Account\<THIS>. It's the folder
# name shown in your WTF\Account directory, not your Battle.net email.
WOW_ACCOUNT_NAME = "50168625#1"

WATCH_SUFFIXES = (".lua", ".toc")
DEBOUNCE_SECONDS = 0.5

# ----------------------------------------------------------------------------

LIVE_ADDONS_DIR = WOW_ROOT / WOW_FLAVOR / "Interface" / "AddOns"

SAVEDVARS_PATH = (
    WOW_ROOT / WOW_FLAVOR / "WTF" / "Account" / WOW_ACCOUNT_NAME
    / "SavedVariables" / "DevAgent.lua"
)

DEVMAP_SAVEDVARS_PATH = (
    WOW_ROOT / WOW_FLAVOR / "WTF" / "Account" / WOW_ACCOUNT_NAME
    / "SavedVariables" / "DevMap.lua"
)

VERSION_RE = re.compile(r'(local BUILD_VERSION = ")[^"]*(")')


# ----------------------------- logging -------------------------------------

def log(message: str) -> None:
    print(f"[agent {datetime.now():%H:%M:%S}] {message}", flush=True)


def warn(message: str) -> None:
    print(f"[agent {datetime.now():%H:%M:%S}] WARNING: {message}", flush=True)


# ----------------------------- paths ---------------------------------------

def source_dir(addon: str) -> Path:
    return REPO_DIR / addon


def live_addon_dir(addon: str) -> Path:
    return LIVE_ADDONS_DIR / addon


def is_live_linked(addon: str) -> bool:
    """True when the live AddOns folder is a symlink/junction to the repo."""
    src, dst = source_dir(addon), live_addon_dir(addon)
    try:
        return dst.exists() and os.path.samefile(src, dst)
    except OSError:
        return False


# ----------------------------- build stamp ---------------------------------

def get_build_tag() -> str:
    """git short SHA if this is a git repo, else a timestamp."""
    try:
        sha = subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=REPO_DIR, stderr=subprocess.DEVNULL, text=True,
        ).strip()
        dirty = subprocess.call(
            ["git", "diff", "--quiet"], cwd=REPO_DIR,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ) != 0
        return f"dev-{sha}{'-dirty' if dirty else ''}"
    except Exception:
        return "dev-" + datetime.now().strftime("%Y%m%d-%H%M%S")


def stamp_version(addon: str) -> Optional[str]:
    """Rewrite BUILD_VERSION in <addon>.lua. Returns the tag only if we wrote."""
    lua_file = source_dir(addon) / f"{addon}.lua"
    if not lua_file.exists():
        warn(f"{lua_file} not found, skipping build stamp")
        return None
    tag = get_build_tag()
    text = lua_file.read_text(encoding="utf-8")
    new_text, n = VERSION_RE.subn(rf'\g<1>{tag}\g<2>', text)
    if n == 0:
        return None  # this addon has no BUILD_VERSION line
    if new_text == text:
        return None  # already stamped
    lua_file.write_text(new_text, encoding="utf-8")
    return tag


# ----------------------------- syncing -------------------------------------

def sync_files(addon: str, paths) -> None:
    dst_dir = live_addon_dir(addon)
    if is_live_linked(addon):
        for path in paths:
            log(f"{addon}: {path.name} is live via junction -> {dst_dir}")
        return
    dst_dir.mkdir(parents=True, exist_ok=True)
    for path in paths:
        target = dst_dir / path.name
        shutil.copy2(path, target)
        log(f"{addon}: copied {path.name} -> {target}")


def sync_all(addon: str) -> None:
    src, dst = source_dir(addon), live_addon_dir(addon)
    if is_live_linked(addon):
        log(f"{addon}: live via junction -> {dst} (no copy needed)")
        return
    dst.mkdir(parents=True, exist_ok=True)
    for path in sorted(src.glob("*")):
        if path.is_file() and path.suffix.lower() in WATCH_SUFFIXES:
            shutil.copy2(path, dst / path.name)
            log(f"{addon}: copied {path.name} -> {dst / path.name}")


# ----------------------------- file watcher --------------------------------

class SourceChangeHandler(FileSystemEventHandler):
    def __init__(self, addon: str):
        self.addon = addon
        self._lock = threading.Lock()
        self._pending = {}
        self._timer = None
        self._suppress_until = {}

    def on_any_event(self, event) -> None:
        if event.is_directory:
            return
        if event.event_type not in ("created", "modified", "moved"):
            return
        path = Path(event.dest_path if event.event_type == "moved" else event.src_path)
        if path.suffix.lower() not in WATCH_SUFFIXES:
            return

        with self._lock:
            # Ignore the write we just did when stamping BUILD_VERSION.
            until = self._suppress_until.get(path)
            if until is not None:
                if time.monotonic() < until:
                    return
                self._suppress_until.pop(path, None)

            self._pending[path] = True
            if self._timer is not None:
                self._timer.cancel()
            self._timer = threading.Timer(DEBOUNCE_SECONDS, self._flush)
            self._timer.daemon = True
            self._timer.start()

    def _suppress(self, path: Path, seconds: float = 1.0) -> None:
        with self._lock:
            self._suppress_until[path] = time.monotonic() + seconds

    def _flush(self) -> None:
        with self._lock:
            paths = sorted(self._pending)
            self._pending.clear()
            self._timer = None
        if not paths:
            return

        for path in paths:
            log(f"{self.addon}: changed {path}")

        lua_file = source_dir(self.addon) / f"{self.addon}.lua"
        if lua_file in paths:
            # Mark the path before we write, so the write's own event can't
            # queue a second, empty update.
            self._suppress(lua_file)
            tag = stamp_version(self.addon)
            if tag:
                log(f"{self.addon}: stamped BUILD_VERSION -> {tag}")

        sync_files(self.addon, paths)
        log(f"{self.addon}: /reload in-game to pick it up")


# ------------------------- SavedVariables tail -----------------------------

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
    def __init__(self, path: Path, addon: str):
        self.path = path
        self.addon = addon
        self.seen_errors = 0
        self.seen_loads = 0
        self._prime()

    def _read(self):
        if not self.path.exists():
            return "", ""
        text = self.path.read_text(encoding="utf-8", errors="replace")
        return _extract_block(text, "errors"), _extract_block(text, "loadHistory")

    def _prime(self):
        # On first run, don't dump the whole backlog — just record counts.
        errors_block, loads_block = self._read()
        self.seen_errors = len(_ERROR_ENTRY_RE.findall(errors_block))
        self.seen_loads = len(_LOAD_ENTRY_RE.findall(loads_block))

    def on_modified(self, event):
        if event.is_directory or Path(event.src_path) != self.path:
            return
        # SavedVariables can be mid-write when the event fires; brief settle.
        time.sleep(0.3)
        errors_block, loads_block = self._read()
        errors = _ERROR_ENTRY_RE.findall(errors_block)
        loads = _LOAD_ENTRY_RE.findall(loads_block)

        for t, msg in errors[self.seen_errors:]:
            msg = msg.replace('\\"', '"').replace("\\n", "\n")
            print(f"[wow-error/{self.addon}] {t}  {msg}", flush=True)
        for t, ver in loads[self.seen_loads:]:
            print(f"[wow-load/{self.addon}]  {t}  build={ver}", flush=True)

        self.seen_errors = len(errors)
        self.seen_loads = len(loads)


def main():
    missing = [name for name in ADDON_NAMES if not source_dir(name).exists()]
    if missing:
        sys.exit(f"addon folder(s) not found: {', '.join(str(source_dir(n)) for n in missing)}")
    if WOW_ACCOUNT_NAME == "YOURACCOUNT":
        log("NOTE: set WOW_ACCOUNT_NAME in the CONFIG block before "
            "SavedVariables tailing will work.")

    for name in ADDON_NAMES:
        sync_all(name)

    observer = Observer()
    for name in ADDON_NAMES:
        observer.schedule(SourceChangeHandler(name), str(source_dir(name)), recursive=False)

    for path, addon in ((SAVEDVARS_PATH, "DevAgent"), (DEVMAP_SAVEDVARS_PATH, "DevMap")):
        if path.parent.exists():
            observer.schedule(SavedVarsHandler(path, addon), str(path.parent), recursive=False)
        else:
            log(f"NOTE: {path.parent} doesn't exist yet — "
                "it's created after the addon loads once in-game.")

    observer.start()
    log("watching for changes. Ctrl+C to stop.")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()


if __name__ == "__main__":
    main()
