#!/usr/bin/env bash
#
# live-handoff installer
#
#   bash install.sh              install, or update an existing install (safe to re-run)
#   bash install.sh --uninstall  remove the skill and its three hooks
#   bash install.sh --help       show the options
#
# What it does:
#   1. Copies skills/live-handoff/ into <claude dir>/skills/live-handoff/.
#   2. Merges three hooks into <claude dir>/settings.json:
#        PostToolUse (Edit|Write|MultiEdit) -> sync_state.py post_edit
#        SessionStart                       -> sync_state.py session_start
#        PreCompact                         -> sync_state.py pre_compact
#      Every other setting and hook in that file keeps its value and its
#      place, and a timestamped backup is written before the file changes.
#
# <claude dir> is $CLAUDE_CONFIG_DIR when that is set, otherwise ~/.claude.
#
# The hooks need Python 3.8 or newer. The installer looks for one that really
# runs: on Windows the first "python" on PATH is often the Microsoft Store
# placeholder. To choose the interpreter yourself:
#   LIVE_HANDOFF_PYTHON=/path/to/python bash install.sh

set -euo pipefail

SKILL_NAME="live-handoff"
SKILL_FILES=("SKILL.md" "scripts/sync_state.py")

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
live-handoff installer

  bash install.sh              install, or update an existing install (safe to re-run)
  bash install.sh --uninstall  remove the skill and its three hooks
  bash install.sh --help       show this text

Environment:
  CLAUDE_CONFIG_DIR     Claude Code's config folder, when it is not ~/.claude
  LIVE_HANDOFF_PYTHON   the Python 3.8+ interpreter the hooks should use
EOF
}

MODE="install"
for arg in "$@"; do
  case "$arg" in
    --uninstall) MODE="uninstall" ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "unknown option: $arg (see: bash install.sh --help)" ;;
  esac
done

case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) ON_WINDOWS=1 ;;
  *)                    ON_WINDOWS=0 ;;
esac

# A path in the form a Windows program understands (C:/...). Git Bash usually
# rewrites /c/... arguments by itself, but not when MSYS_NO_PATHCONV is set or
# the path holds an apostrophe or a bracket, so it is done here.
native() {
  if [ "$ON_WINDOWS" = 1 ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s\n' "$1"
  fi
}

# --- Where things are --------------------------------------------------------

SELF="${BASH_SOURCE[0]:-}"
[ -n "$SELF" ] && [ -f "$SELF" ] || die "run install.sh from a copy of the repository (git clone it first)"
SRC_DIR="$(CDPATH= cd -- "$(dirname -- "$SELF")" && pwd)"
SKILL_SRC="$SRC_DIR/skills/$SKILL_NAME"

if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  CLAUDE_DIR="$CLAUDE_CONFIG_DIR"
elif [ "$ON_WINDOWS" = 1 ] && [ -n "${USERPROFILE:-}" ]; then
  # Claude Code keeps its files in the Windows profile folder, and $HOME can
  # point somewhere else in Git Bash.
  CLAUDE_DIR="$USERPROFILE/.claude"
else
  CLAUDE_DIR="$HOME/.claude"
fi
if [ "$ON_WINDOWS" = 1 ] && command -v cygpath >/dev/null 2>&1; then
  CLAUDE_DIR="$(cygpath -u "$CLAUDE_DIR")"
fi
case "$CLAUDE_DIR" in
  /*|[A-Za-z]:*) ;;
  *)             CLAUDE_DIR="$PWD/$CLAUDE_DIR" ;;
esac
CLAUDE_DIR="${CLAUDE_DIR%/}"
DEST="$CLAUDE_DIR/skills/$SKILL_NAME"
SETTINGS="$CLAUDE_DIR/settings.json"

# --- A Python that really runs -----------------------------------------------

PY=()
# -I: ignore the current folder and PYTHON* variables, so a file named json.py
#     next to the user cannot be picked up. -X utf8: paths with letters outside
#     ASCII survive the trip between Python and bash on Windows.
PYFLAGS=(-I -X utf8)

py_ok() {
  [ "$("$@" "${PYFLAGS[@]}" -c 'import sys; print("live-handoff-ok" if sys.version_info >= (3, 8) else "too-old")' 2>/dev/null | tr -d '\r')" = "live-handoff-ok" ]
}

find_python() {
  local candidate
  if [ -n "${LIVE_HANDOFF_PYTHON:-}" ]; then
    if py_ok "$LIVE_HANDOFF_PYTHON"; then
      PY=("$LIVE_HANDOFF_PYTHON")
      return 0
    fi
    die "LIVE_HANDOFF_PYTHON=$LIVE_HANDOFF_PYTHON is not a working Python 3.8 or newer"
  fi
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && py_ok "$candidate"; then
      PY=("$candidate")
      return 0
    fi
  done
  if command -v py >/dev/null 2>&1; then
    if py_ok py -3; then PY=(py -3); return 0; fi
    if py_ok py; then PY=(py); return 0; fi
  fi
  # The first match on PATH can be a placeholder that does not run. Try the rest.
  while IFS= read -r candidate; do
    if [ -n "$candidate" ] && py_ok "$candidate"; then
      PY=("$candidate")
      return 0
    fi
  done < <(type -ap python3 python 2>/dev/null || true)
  return 1
}

# What the hook commands call. On Windows command names are unreliable, so
# the hooks get the full path of the interpreter that passed the check.
# Elsewhere they get the command name, except behind a version manager's shim
# (pyenv, asdf, mise), which picks a version per folder and fails where that
# version is not installed.
hook_python() {
  local exact base found
  exact="$("${PY[@]}" "${PYFLAGS[@]}" -c 'import pathlib, sys; print(pathlib.Path(sys.executable).as_posix())' | tr -d '\r')"
  base="$("${PY[@]}" "${PYFLAGS[@]}" -c 'import pathlib, sys; print(pathlib.Path(getattr(sys, "_base_executable", "") or sys.executable).as_posix())' | tr -d '\r')"
  if [ -n "${LIVE_HANDOFF_PYTHON:-}" ]; then
    case "$LIVE_HANDOFF_PYTHON" in
      */*|*\\*) printf '%s\n' "$exact" ;;
      *)        if [ "$ON_WINDOWS" = 1 ]; then printf '%s\n' "$exact"; else printf '%s\n' "$LIVE_HANDOFF_PYTHON"; fi ;;
    esac
    return 0
  fi
  # Only the name python3 is safe to write as a name. "python" can be Python 2
  # in another environment, and Python 2 exits with code 2 on the -I option.
  if [ "$ON_WINDOWS" = 1 ] || [ "${#PY[@]}" -gt 1 ] || [ "${PY[0]}" != "python3" ]; then
    printf '%s\n' "$base"
    return 0
  fi
  found="$(command -v "${PY[0]}" 2>/dev/null || true)"
  case "$found" in
    */shims/*) printf '%s\n' "$base" ;;
    *)         printf '%s\n' "${PY[0]}" ;;
  esac
}

HAVE_PY=0
PY_VERSION=""
HOOK_PY=""
if find_python; then
  HAVE_PY=1
  PY_VERSION="$("${PY[@]}" "${PYFLAGS[@]}" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' | tr -d '\r')"
  HOOK_PY="$(hook_python)"
  [ -n "$PY_VERSION" ] && [ -n "$HOOK_PY" ] || die "the Python that was found did not answer; set LIVE_HANDOFF_PYTHON to one that works"
fi

# --- settings.json -----------------------------------------------------------
#
# Arguments: mode (check, install or uninstall), settings file, installed
# script, interpreter for the hook commands, the bash running this installer.

edit_settings() {
  "${PY[@]}" "${PYFLAGS[@]}" - "$1" "$(native "$SETTINGS")" "$(native "$DEST/scripts/sync_state.py")" "$HOOK_PY" "$(native "${BASH:-bash}")" <<'PYCODE'
import copy
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

mode, settings_path, script_path, hook_python, bash_path = sys.argv[1:6]

MARK = "live-handoff/scripts/sync_state.py"
EVENTS = (
    ("PostToolUse", "Edit|Write|MultiEdit", "post_edit"),
    ("SessionStart", None, "session_start"),
    ("PreCompact", None, "pre_compact"),
)
SUBCOMMANDS = "|".join(sub for _event, _matcher, sub in EVENTS)
TIMEOUT_SECONDS = 15
UNSAFE = re.compile(r'[$`"\\\r\n]')
OURS = re.compile(r"(?:^|[\s\"'/=])" + re.escape(MARK) + r"[\"']?\s+(%s)\b" % SUBCOMMANDS)
# A command that is nothing but our call: optional guard, interpreter,
# optional -I, the script, the mode, optional "|| true".
EXACT = re.compile(
    r'^\s*(?:\[ ! -f "[^"]+" \] \|\| )?'
    r'(?:"[^"]+"|[^\s"]+)(?: -3)?(?: -I)?\s+'
    r'(?:"[^"]*' + re.escape(MARK) + r'"|[^\s"]*' + re.escape(MARK) + r")\s+"
    r"(?:%s)(?:\s*\|\|\s*true)?\s*$" % SUBCOMMANDS
)
PLAIN_MATCHER = re.compile(r"^[A-Za-z0-9_|]+$")


def say(text):
    """Print a line. A broken stdout must not change what the run reports."""
    try:
        print(text)
        sys.stdout.flush()
    except Exception:
        pass


def fail(message):
    try:
        sys.stderr.write("install.sh: %s\n" % message)
        sys.stderr.flush()
    except Exception:
        pass
    os._exit(1)


script = os.path.abspath(script_path).replace("\\", "/")
for label, value in (("skill folder", script), ("Python path", hook_python)):
    if UNSAFE.search(value):
        fail("the %s (%s) contains a character that cannot be written into a hook command" % (label, value))


def command_for(sub):
    """The hook command. A missing script is a silent no-op, never an error:
    Python exits with code 2 when it cannot open its script, and exit code 2
    from a PreCompact hook blocks compaction. -I keeps a project's own Python
    files and PYTHON* variables out of the hook."""
    python = hook_python if re.match(r"^[A-Za-z0-9_.+-]+$", hook_python) else '"%s"' % hook_python
    return '[ ! -f "%s" ] || %s -I "%s" %s' % (script, python, script, sub)


def ours_kind(hook, sub=None):
    """How a hook entry relates to our script (with the given mode): None when
    it does not run it, "exact" when it is nothing but our call, "embedded"
    when our call is part of a longer command the user wrote."""
    if not isinstance(hook, dict):
        return None
    command = hook.get("command")
    args = hook.get("args")
    parts = [command] + (args if isinstance(args, list) else [])
    text = " ".join(part for part in parts if isinstance(part, str)).replace("\\", "/")
    found = OURS.search(text)
    if not found or (sub is not None and found.group(1) != sub):
        return None
    if isinstance(args, list):
        rest = [arg.replace("\\", "/") for arg in args if isinstance(arg, str)]
        if rest and rest[0] == "-I":
            rest = rest[1:]
        exact = len(rest) == 2 and rest[0].endswith(MARK) and rest[1] == found.group(1)
    else:
        exact = isinstance(command, str) and EXACT.match(command.replace("\\", "/")) is not None
    return "exact" if exact else "embedded"


def matcher_names(matcher):
    """What a matcher covers: None for everything, a set of tool names, or
    "pattern" for anything this program cannot be sure about (a regular
    expression, a list, a name with other characters)."""
    if matcher is None:
        return None
    if not isinstance(matcher, str):
        return "pattern"
    if matcher.strip() in ("", "*"):
        return None
    if not PLAIN_MATCHER.match(matcher):
        return "pattern"
    return {name for name in matcher.split("|") if name}


def reject_constant(name):
    raise ValueError("%s is not valid JSON" % name)


def load(path):
    """(bytes, text, data) of the settings file; (None, None, {}) when there is none."""
    if not os.path.lexists(path):
        return None, None, {}
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError as exc:
        fail("%s could not be read (%s). Nothing was changed." % (path, exc))
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        fail("%s is not UTF-8 text (%s). Nothing was changed." % (path, exc))
    if not text.strip():
        return raw, text, {}
    try:
        data = json.loads(text, parse_constant=reject_constant)
    except ValueError as exc:
        fail("%s is not valid JSON (%s). Nothing was changed. Fix the file and run install.sh again." % (path, exc))
    if not isinstance(data, dict):
        fail("%s does not hold a JSON object. Nothing was changed." % path)
    return raw, text, data


def render(original_text, data):
    """The new file as bytes, with the old file's indentation, line endings
    and final newline."""
    indent = "  "
    newline = "\n"
    ending = True
    if original_text is not None and original_text.strip():
        found = re.search(r'\n([ \t]+)"', original_text)
        if found:
            indent = found.group(1)
        if "\r\n" in original_text:
            newline = "\r\n"
        ending = original_text.endswith("\n")
    try:
        text = json.dumps(data, indent=indent, ensure_ascii=False, allow_nan=False)
    except ValueError as exc:
        fail("%s holds a value that cannot be written back as JSON (%s). Nothing was changed." % (settings_path, exc))
    if newline != "\n":
        text = text.replace("\n", newline)
    if ending:
        text += newline
    try:
        return text.encode("utf-8")
    except UnicodeEncodeError:
        # A lone surrogate escape: keep such strings as \u escapes.
        text = json.dumps(data, indent=indent, ensure_ascii=True, allow_nan=False)
        if newline != "\n":
            text = text.replace("\n", newline)
        return (text + (newline if ending else "")).encode("ascii")


EMBEDDED = []  # (event, command) of entries where our call sits inside a longer command


def install(data):
    hooks = data.get("hooks")
    if hooks is None:
        hooks = data["hooks"] = {}
    if not isinstance(hooks, dict):
        fail('"hooks" in %s is not an object. Nothing was changed.' % settings_path)
    for event, matcher, sub in EVENTS:
        groups = hooks.get(event)
        if groups is None:
            groups = []
        if not isinstance(groups, list):
            fail('"hooks.%s" in %s is not a list. Nothing was changed.' % (event, settings_path))
        command = command_for(sub)
        placed = False
        covers_all = False
        covered = set()
        new_groups = []
        for group in groups:
            entries = group.get("hooks") if isinstance(group, dict) else None
            if not isinstance(entries, list):
                new_groups.append(group)
                continue
            names = matcher_names(group.get("matcher"))
            kept = []
            kept_here = False
            for entry in entries:
                kind = ours_kind(entry, sub)
                if kind is None:
                    kept.append(entry)
                    continue
                if kind == "embedded":
                    # Our call inside a longer command the user wrote: theirs
                    # to keep. It counts as installed, so no second copy is
                    # added next to it.
                    kept.append(entry)
                    EMBEDDED.append((event, str(entry.get("command"))))
                else:
                    # A copy of our hook that adds nothing (the same tools are
                    # already served) is dropped. A copy the user put under a
                    # matcher of its own is kept.
                    adds_nothing = kept_here or covers_all or (isinstance(names, set) and placed and names <= covered)
                    if adds_nothing:
                        continue
                    # Refresh the command, keep the user's matcher and timeout.
                    entry = dict(entry)
                    entry["type"] = "command"
                    entry["command"] = command
                    entry.pop("args", None)
                    kept.append(entry)
                kept_here = True
                placed = True
                if names is None:
                    covers_all = True
                elif isinstance(names, set):
                    covered |= names
            if entries and not kept:
                continue
            if kept != entries:
                group = dict(group)
                group["hooks"] = kept
            new_groups.append(group)
        if not placed:
            group = {}
            if matcher:
                group["matcher"] = matcher
            group["hooks"] = [{"type": "command", "command": command, "timeout": TIMEOUT_SECONDS}]
            new_groups.append(group)
        hooks[event] = new_groups


def uninstall(data):
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return
    removed = False
    for event in list(hooks):
        groups = hooks[event]
        if not isinstance(groups, list):
            continue
        new_groups = []
        touched = False
        for group in groups:
            entries = group.get("hooks") if isinstance(group, dict) else None
            if not isinstance(entries, list):
                new_groups.append(group)
                continue
            kept = []
            for entry in entries:
                kind = ours_kind(entry)
                if kind == "exact":
                    continue
                if kind == "embedded":
                    EMBEDDED.append((event, str(entry.get("command"))))
                kept.append(entry)
            if len(kept) != len(entries):
                touched = True
                if not kept:
                    continue
                group = dict(group)
                group["hooks"] = kept
            new_groups.append(group)
        if touched:
            removed = True
            if new_groups:
                hooks[event] = new_groups
            else:
                del hooks[event]
    if removed and not hooks:
        del data["hooks"]


def self_test():
    """Run the exact PostToolUse command the way Claude Code will, through
    bash, before anything is written to settings.json."""
    command = command_for("post_edit")
    work = tempfile.mkdtemp(prefix="live-handoff-selftest-")
    try:
        project = os.path.join(work, "project")
        os.makedirs(project)
        payload = {
            "hook_event_name": "PostToolUse",
            "tool_name": "Write",
            "tool_input": {"file_path": os.path.join(project, "example.txt")},
        }
        env = dict(os.environ)
        env.pop("LIVE_HANDOFF_DISABLE", None)
        env["CLAUDE_PROJECT_DIR"] = project
        problem = None
        try:
            proc = subprocess.run(
                [bash_path, "-c", command],
                input=json.dumps(payload).encode("utf-8"),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=project,
                env=env,
                timeout=60,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            problem = "the hook command could not be run for a self-test (%s). settings.json was not changed." % exc
        if problem is None:
            out = proc.stdout.decode("utf-8", "replace").strip()
            try:
                reply = json.loads(out)["hookSpecificOutput"]
                good = reply["hookEventName"] == "PostToolUse" and bool(reply["additionalContext"])
            except Exception:
                good = False
            if proc.returncode != 0 or not good:
                problem = (
                    "self-test failed, so settings.json was not changed.\n"
                    "  command:   %s\n  exit code: %s\n  stdout:    %s\n  stderr:    %s"
                    % (command, proc.returncode, out[:300], proc.stderr.decode("utf-8", "replace").strip()[:300])
                )
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if problem:
        fail(problem)


def free_name(path):
    """path, or path with -2, -3 ... added, whichever does not exist yet."""
    if not os.path.lexists(path):
        return path
    number = 2
    while os.path.lexists("%s-%d" % (path, number)):
        number += 1
    return "%s-%d" % (path, number)


def write(path, original_bytes, new_bytes):
    """Replace settings.json in one step, after a backup, and read it back."""
    target = os.path.realpath(path)  # write through a symlinked settings file
    folder = os.path.dirname(target)
    had_file = original_bytes is not None
    backup = None
    backup_done = False
    partial = None
    replaced = False
    try:
        os.makedirs(folder, exist_ok=True)
        if had_file:
            with open(target, "rb") as now:
                if now.read() != original_bytes:
                    fail("%s changed while the installer was running. Nothing was changed. Run install.sh again." % path)
            stamp = time.strftime("%Y%m%d-%H%M%S")
            backup = free_name("%s.live-handoff-%s.bak" % (target, stamp))
            shutil.copy2(target, backup)
            backup_done = True
        if had_file and os.stat(target).st_nlink > 1:
            # A hard link (a dotfiles setup): replacing the file would cut it
            # loose from its other name, so write into it instead.
            replaced = True
            with open(target, "r+b") as out:
                out.write(new_bytes)
                out.truncate()
                out.flush()
                os.fsync(out.fileno())
        else:
            handle, partial = tempfile.mkstemp(prefix=".settings-", suffix=".tmp", dir=folder)
            with os.fdopen(handle, "wb") as out:
                out.write(new_bytes)
                out.flush()
                os.fsync(out.fileno())
            if had_file and os.name != "nt":
                try:
                    shutil.copymode(target, partial)
                except OSError:
                    pass
            for attempt in range(5):
                try:
                    os.replace(partial, target)
                    replaced = True
                    break
                except PermissionError:
                    if attempt == 4:
                        raise
                    time.sleep(0.2)
        with open(target, "rb") as check:
            if check.read() != new_bytes:
                raise OSError("the file read back differently from what was written")
    except OSError as exc:
        if partial and not replaced:
            try:
                os.chmod(partial, 0o600)
                os.unlink(partial)
            except OSError:
                pass
        if replaced:
            # The new file is in place but does not read back. Put the old one
            # back, but only from a backup that was completed.
            if backup_done:
                try:
                    with open(backup, "rb") as saved, open(target, "r+b" if os.path.exists(target) else "wb") as out:
                        out.write(saved.read())
                        out.truncate()
                    fail("%s could not be verified after writing (%s). The previous file was restored from %s." % (path, exc, backup))
                except OSError:
                    fail("%s could not be verified after writing (%s) and could not be restored. Your previous file is %s." % (path, exc, backup))
            fail("%s could not be verified after writing (%s)." % (path, exc))
        if backup:
            try:
                os.unlink(backup)
            except OSError:
                pass
        fail("%s could not be written (%s). Nothing was changed." % (path, exc))
    return backup


if mode not in ("check", "install", "uninstall"):
    fail("unknown mode: %s" % mode)

if mode == "install":
    # Before the settings file is read, so the read, the merge and the write
    # happen back to back.
    self_test()
    say("self-test: the PostToolUse hook command ran and returned a reminder")

original_bytes, original_text, data = load(settings_path)
before = copy.deepcopy(data)

if mode == "uninstall":
    uninstall(data)
else:
    install(data)

new_bytes = render(original_text, data)

if mode == "check":
    # Preflight, before any file is copied: the settings file can be read,
    # merged, written back as JSON, and is not read-only.
    target = os.path.realpath(settings_path)
    if original_bytes is not None and not os.access(target, os.W_OK):
        fail("%s is read-only. Nothing was changed." % settings_path)
    os._exit(0)

if data == before:
    if mode == "install":
        say("settings:  the three hooks are already in place, nothing to change")
    else:
        say("settings:  no live-handoff hooks found, nothing to change")
else:
    backup = write(settings_path, original_bytes, new_bytes)
    if mode == "install":
        say("settings:  hooks merged for %s" % ", ".join(event for event, _matcher, _sub in EVENTS))
    else:
        say("settings:  live-handoff hooks removed")
    if backup:
        say("backup:    %s" % backup.replace("\\", "/"))

for event, command in EMBEDDED:
    if mode == "install":
        say("note:      a %s entry runs live-handoff inside a longer command of yours; it was left as it is:" % event)
    else:
        say("note:      a %s entry runs live-handoff inside a longer command of yours and was NOT removed." % event)
        say("           It will fail once the skill files are gone: take the live-handoff part out of it by hand:")
    say("           %s" % command[:300])

# The settings file is final here. Leave without the interpreter's own exit
# work, so a broken stdout cannot turn a finished run into a reported failure.
os._exit(0)
PYCODE
}

# --- Install / uninstall -----------------------------------------------------

same_folder() { [ -d "$DEST" ] && [ "$SKILL_SRC" -ef "$DEST" ]; }

remove_skill_files() {
  local rel
  for rel in "${SKILL_FILES[@]}"; do
    rm -f "$DEST/$rel"
  done
  rm -rf "$DEST/scripts/__pycache__"
  rmdir "$DEST/scripts" 2>/dev/null || true
  rmdir "$DEST" 2>/dev/null || true
}

has_our_hooks() { grep -Eq "(^|[^A-Za-z0-9_-])$SKILL_NAME/scripts/sync_state\.py" "$SETTINGS" 2>/dev/null; }

# One installer at a time: two at once could undo each other's work.
LOCK=""
take_lock() {
  LOCK="$CLAUDE_DIR/.live-handoff-install.lock"
  if ! mkdir "$LOCK" 2>/dev/null; then
    LOCK=""
    die "another install.sh seems to be running (found $CLAUDE_DIR/.live-handoff-install.lock). If none is, remove that folder and run this again."
  fi
}
trap 'if [ -n "$LOCK" ]; then rmdir "$LOCK" 2>/dev/null || true; fi' EXIT

if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  REMOVE_HINT="CLAUDE_CONFIG_DIR=\"$CLAUDE_CONFIG_DIR\" bash \"$SRC_DIR/install.sh\" --uninstall"
else
  REMOVE_HINT="bash \"$SRC_DIR/install.sh\" --uninstall"
fi

if [ "$MODE" = "install" ]; then
  [ "$HAVE_PY" = 1 ] || die "no working Python 3.8 or newer was found. Install Python 3, or point LIVE_HANDOFF_PYTHON at one, and run install.sh again."
  for rel in "${SKILL_FILES[@]}"; do
    [ -f "$SKILL_SRC/$rel" ] || die "missing $SKILL_SRC/$rel: run install.sh from a full copy of the repository"
  done
  if [ -L "$DEST" ] && ! same_folder; then
    die "$DEST is a link to another folder. Remove the link, or run install.sh from the copy it points to."
  fi
  edit_settings check
  mkdir -p "$CLAUDE_DIR"
  take_lock
  FRESH=1
  [ -e "$DEST" ] && FRESH=0
  SKILLS_FRESH=1
  [ -e "$CLAUDE_DIR/skills" ] && SKILLS_FRESH=0
  if same_folder; then
    say "skill:     $DEST is this repository's own folder, nothing to copy"
  else
    for rel in "${SKILL_FILES[@]}"; do
      mkdir -p "$DEST/$(dirname "$rel")"
      cp -f "$SKILL_SRC/$rel" "$DEST/$rel"
    done
    chmod +x "$DEST/scripts/sync_state.py"
    say "skill:     copied to $DEST"
  fi
  say "python:    $HOOK_PY ($PY_VERSION)"
  if ! edit_settings install; then
    if has_our_hooks; then
      # The settings step reported an error after the hooks were written (or
      # they were there before). Taking the skill files away now would leave
      # hooks with nothing behind them.
      die "the settings step did not finish cleanly, but the live-handoff hooks are in $SETTINGS, so the skill files were left in place. Run install.sh again to check."
    fi
    if same_folder; then
      die "installation failed. The hooks were not written to settings.json."
    fi
    if [ "$FRESH" = 1 ]; then
      remove_skill_files
      if [ "$SKILLS_FRESH" = 1 ]; then rmdir "$CLAUDE_DIR/skills" 2>/dev/null || true; fi
      die "installation failed. The skill files copied in this run were removed again."
    fi
    die "installation failed. The skill files in $DEST were updated; the hooks in settings.json were not."
  fi
  say ""
  say "live-handoff is installed."
  say "  Sessions that are already open load the hooks by themselves; if /hooks"
  say "  does not list them in such a session, restart Claude Code. TODO.md is"
  say "  printed at the next session start, /clear or compaction."
  say "  To remove it: $REMOVE_HINT"
else
  if [ -d "$CLAUDE_DIR" ]; then take_lock; fi
  if [ "$HAVE_PY" = 1 ]; then
    edit_settings uninstall
  else
    say "settings:  no working Python was found, so settings.json was not edited."
    if has_our_hooks; then
      say "           The live-handoff entries in $SETTINGS stay. They do nothing"
      say "           once the skill files are gone. Delete them by hand, or run this"
      say "           again when Python is back."
    fi
  fi
  if [ -L "$DEST" ]; then
    say "skill:     $DEST is a link to another folder and was left as it is. Remove the link yourself."
  elif same_folder; then
    say "skill:     $DEST is this repository's own folder, left in place"
  elif [ -d "$DEST" ]; then
    remove_skill_files
    if [ -e "$DEST" ]; then
      say "skill:     removed the live-handoff files; other files are still in $DEST, so the folder was kept"
    else
      say "skill:     removed $DEST"
    fi
  else
    say "skill:     $DEST was not there"
  fi
  say ""
  say "live-handoff is uninstalled. TODO.md and .handoff/ in your projects were not touched."
fi
