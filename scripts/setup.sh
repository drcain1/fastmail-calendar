#!/usr/bin/env bash
# setup.sh — install and configure vdirsyncer + khal against Fastmail CalDAV.
#
# Usage:
#   FASTMAIL_USER=you@example.com FASTMAIL_PASSWORD=<caldav-app-password> \
#     bash scripts/setup.sh
#
# If either env var is missing you will be prompted (password with hidden
# input). Nothing in this repo contains credentials: rendered configs land
# in your home directory only, chmod 600.
#
# Steps:
#   1. Install vdirsyncer + khal (uv tool, else pipx, else already present).
#   2. Render vdirsyncer config from configs/vdirsyncer.config.template.
#   3. Discover collections + first sync.
#   4. Apply the khal Windows patch where applicable (auto-skipped elsewhere).
#   5. Render khal.config: one [[section]] per discovered calendar + static
#      tail from configs/khal.config.template.
#   6. Verify with a khal list.
#
# Idempotent — safe to re-run. On Windows (MSYS/git-bash) also works.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XDG="${XDG_CONFIG_HOME:-$HOME/.config}"
# native Windows tools choke on MSYS backslash paths inside quoted config
# strings (configobj unescapes \U etc.) — normalize to forward slashes.
NORM() { printf '%s' "$1" | tr '\\' '/'; }
VDIRCONFIG="$(NORM "$XDG/vdirsyncer/config")"
KHALCONFIG="$(NORM "$XDG/khal/config")"
STATUS_PATH="$(NORM "$HOME")/.vdirsyncer/status"
LOCAL_STORE="$(NORM "$HOME")/.calendars/fm"
SQLITE_DB="$(NORM "$HOME")/.cache/khal/khal.db"

# --- 0. inputs ----------------------------------------------------------------
FASTMAIL_USER="${FASTMAIL_USER:-}"
FASTMAIL_PASSWORD="${FASTMAIL_PASSWORD:-}"
if [[ -z "$FASTMAIL_USER" ]]; then
  read -rp "Fastmail email address: " FASTMAIL_USER
fi
if [[ -z "$FASTMAIL_PASSWORD" ]]; then
  read -rsp "CalDAV app password (Settings > Privacy & Security > app passwords, scope: Calendars only): " FASTMAIL_PASSWORD
  echo
fi
[[ -n "$FASTMAIL_USER" && -n "$FASTMAIL_PASSWORD" ]] || {
  echo "error: need FASTMAIL_USER and FASTMAIL_PASSWORD" >&2; exit 1; }

# --- 1. install tools ---------------------------------------------------------
if command -v vdirsyncer >/dev/null && command -v khal >/dev/null; then
  echo "tools already installed"
elif command -v uv >/dev/null; then
  echo "installing vdirsyncer + khal via uv tool ..."
  uv tool install vdirsyncer
  uv tool install khal
elif command -v pipx >/dev/null; then
  echo "installing vdirsyncer + khal via pipx ..."
  pipx install vdirsyncer
  pipx install khal
else
  echo "error: need 'uv' or 'pipx' on PATH (or vdirsyncer+khal preinstalled)" >&2
  exit 1
fi

# --- 2. render vdirsyncer config -----------------------------------------------
mkdir -p "$(dirname "$VDIRCONFIG")"
if [[ -f "$VDIRCONFIG" ]] && grep -q "caldav.fastmail.com" "$VDIRCONFIG"; then
  echo "existing vdirsyncer config found — updating credentials in place"
  python - "$VDIRCONFIG" "$FASTMAIL_USER" "$FASTMAIL_PASSWORD" <<'PY'
import re, sys
path, user, pw = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
text = re.sub(r'(?m)^username = .*$', 'username = "%s"' % user, text)
text = re.sub(r'(?m)^password = .*$', 'password = "%s"' % pw, text)
open(path, "w").write(text)
PY
else
  sed -e "s|__STATUS_PATH__|$STATUS_PATH|g" \
      -e "s|__FASTMAIL_USER__|$FASTMAIL_USER|g" \
      -e "s|__FASTMAIL_PASSWORD__|$FASTMAIL_PASSWORD|g" \
      -e "s|__LOCAL_STORE__|$LOCAL_STORE|g" \
      "$REPO_ROOT/configs/vdirsyncer.config.template" > "$VDIRCONFIG"
  echo "wrote $VDIRCONFIG"
fi
chmod 600 "$VDIRCONFIG"

# --- 3. discover + first sync ---------------------------------------------------
echo "discovering collections (first run creates local stores) ..."
DISCOVER_OUT="$(yes | vdirsyncer discover fastmail 2>&1 || true)"
echo "syncing ..."
vdirsyncer sync >/dev/null
echo "sync OK"

# --- 4. khal Windows patch -------------------------------------------------------
apply_khal_patch() {
  python - <<'PY'
import glob, os, sys

home = os.path.expanduser("~")
patterns = [
    os.path.join(home, "AppData/Roaming/uv/tools/khal/Lib/site-packages/khal/khalendar/vdir.py"),
    os.path.join(home, ".local/share/uv/tools/khal/lib/*/site-packages/khal/khalendar/vdir.py"),
    os.path.join(home, ".local/pipx/venvs/khal/lib/python*/site-packages/khal/khalendar/vdir.py"),
    os.path.join(home, ".local/share/virtualenvs/khal-*/lib/python*/site-packages/khal/khalendar/vdir.py"),
]
target = None
for pat in patterns:
    hits = sorted(glob.glob(pat))
    if hits:
        target = hits[0]
        break
if target is None:
    print("warning: could not locate installed khal vdir.py; skipped Windows patch (fine on Linux/macOS)")
    sys.exit(0)

old = '''    close_f = False
    if hasattr(f, "read"):
        f.flush()
        f = f.fileno()
    elif isinstance(f, str):
        flags = 0
        if os.path.isdir(f):
            flags = os.O_DIRECTORY
        f = os.open(f, flags)
        close_f = True

    # assure that all internal buffers associated with this file are
    # written to disk
    try:
        os.fsync(f)
        stat = os.fstat(f)
    finally:
        if close_f:
            os.close(f)'''
new = '''    close_f = False
    stat = None
    if hasattr(f, "read"):
        f.flush()
        f = f.fileno()
    elif isinstance(f, str) and os.path.isdir(f):
        # Windows: os.open(dir) raises PermissionError, so stat the dir directly.
        stat = os.stat(f)
    elif isinstance(f, str):
        try:
            # Some Windows setups reject fsync on read-only handles.
            f = os.open(f, os.O_RDWR)
        except OSError:
            f = os.open(f, 0)
        close_f = True

    if stat is None:
        # assure that all internal buffers associated with this file are
        # written to disk
        try:
            os.fsync(f)
            stat = os.fstat(f)
        finally:
            if close_f:
                os.close(f)'''

src = open(target).read()
if "stat = os.stat(f)" in src:
    print(f"khal Windows patch already present: {target}")
elif old in src:
    open(target, "w").write(src.replace(old, new))
    print(f"patched khal: {target}")
else:
    print(f"warning: stock code block not found in {target}; patch may already differ — skipped")
PY
}
if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]] || command -v cygpath >/dev/null; then
  apply_khal_patch
fi

# --- 5. render khal config --------------------------------------------------------
mkdir -p "$(dirname "$KHALCONFIG")" "$(dirname "$SQLITE_DB")"
# known first-run glitch: khal can create khal.db as a DIRECTORY
[[ -d "$SQLITE_DB" ]] && rm -rf "$SQLITE_DB"

COLORS=("light blue" "light green" "light red" "light magenta" "light cyan" "light gray" "yellow" "brown")

# collect discovered collections first so we can pick a sensible default:
# prefer a collection literally named "Calendar", else the first one;
# skip the "Contacts" virtual collection (VCARDs, not events).
COL_UUIDS=()
COL_NAMES=()
in_remote=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  case "$line" in
    "fastmail_remote:"*) in_remote=1; continue ;;
    "fastmail_local:"*)  in_remote=0; continue ;;
  esac
  [[ $in_remote -eq 1 ]] || continue
  uuid="$(printf '%s' "$line" | sed -nE 's/.*"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})".*/\1/p')"
  [[ -n "$uuid" ]] || continue
  name="$(printf '%s' "$line" | sed -nE 's/.*\("(.*)"\)/\1/p')"
  [[ -n "$name" ]] || name="calendar"
  [[ "${name,,}" == "contacts" ]] && continue
  COL_UUIDS+=("$uuid")
  COL_NAMES+=("$name")
done <<< "$DISCOVER_OUT"

DEFAULT_IDX=0
for i in "${!COL_NAMES[@]}"; do
  [[ "${COL_NAMES[$i],,}" == "calendar" ]] && { DEFAULT_IDX=$i; break; }
done

{
  echo "[calendars]"
  echo
  for i in "${!COL_UUIDS[@]}"; do
    safe="$(printf '%s' "${COL_NAMES[$i]}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_' | sed 's/_*$//')"
    [[ -n "$safe" ]] || safe="cal_$i"
    color="${COLORS[$((i % ${#COLORS[@]}))]}"
    if [[ $i -eq $DEFAULT_IDX ]]; then
      section="personal"; priority=10
    else
      section="cal_${safe}"; priority=9
    fi
    echo "[[${section}]]"
    echo "path = ${LOCAL_STORE}/${COL_UUIDS[$i]}/"
    echo "color = ${color}"
    echo "priority = ${priority}"
    echo
  done
  if [[ ${#COL_UUIDS[@]} -eq 0 ]]; then
    echo "warning: no calendars discovered — add [[...]] sections by hand" >&2
  fi
  # static tail (sqlite/locale/default), with db path filled in
  sed -e "s|__SQLITE_DB__|$SQLITE_DB|g" "$REPO_ROOT/configs/khal.config.template"
} > "$KHALCONFIG"
chmod 600 "$KHALCONFIG"
echo "wrote $KHALCONFIG (default calendar: ${COL_NAMES[$DEFAULT_IDX]:-n/a})"

# --- 6. verify ---------------------------------------------------------------------
echo
echo "verifying khal ..."
if khal list 2>&1 | head -5; then
  echo
  echo "setup complete. Try:  khal list 05-09-2026 30-09-2026"
else
  echo "khal verification failed — check $KHALCONFIG" >&2
  exit 1
fi
