---
name: fastmail-calendar
description: Use when asked about the user's schedule or calendar events.
---

# fastmail-calendar

Hermes Agent skill — the operational notes for this repo's Fastmail CalDAV
setup. The live copy for this machine is at
`~AppData/Local/hermes/skills/productivity/fastmail-calendar/SKILL.md`.

> **Per-account/per-machine:** the calendar UUID table and absolute paths
> below describe *one* installation (a single Fastmail account, Windows
> host). Other accounts: re-run `scripts/setup.sh` — it prints the
> calendar mapping and regenerates `~/.config/khal/config` from discovery.
> The app password itself is **not** in this file.

---


Sync then query. Two commands:

```bash
vdirsyncer sync          # pull latest from Fastmail (incremental, fast)
khal list 05-09-2026 20-09-2026
```

khal date parsing uses the configured dateformat (`%d-%m-%Y`) — use `DD-MM-YYYY`, not ISO.

## Key commands
- `khal list [start [end]]` — events in range; `-a <cal>` restrict to one calendar, `-d` exclude, `--notstarted` upcoming only
- `khal search <text>` — full-text across all calendars
- `khal new "09 September 2026 14:30" "09 September 2026 16:30" "Title" :: "description"` — add event with description; full datetime strings are the reliable form (short forms like `09:00 12-09` parse oddly). Default calendar fm_personal; use `-a` to target another.
- After creating: `khal list` the day to verify EXACTLY ONE new event, then `vdirsyncer sync` pushes to Fastmail. `khal new`'s stdout is useless (empty even on success) — judge by exit code + khal list.

## Adding an event from a tweet/X post
1. Tweet content often arrives empty or dateless. Fetch it: `curl -s https://api.fxtwitter.com/<user>/status/<id>` — JSON with `tweet.text`, `tweet.created_at`, `tweet.media.photos[]` (orig URLs).
2. The EVENT DATE is usually only in the poster image → `vision_analyze` the photo URL, asking specifically for the printed date/time/timezone.
3. Cross-check the date against context (announcement date, "N days left" follow-up posts) before committing.
4. Timezone: no TZ printed + Japanese event ⇒ JST. User is in CEST — convert (JST−9h) and state the assumption in the reply. Store the event in local time (khal uses the machine's zone) and put both TZs in the description.
5. No end time printed ⇒ pick a sane block (e.g. 2h for a DJ set) and say so.
6. Check the day with `khal list` for conflicts first; after pushing, run `vdirsyncer sync` twice — the 2nd run must show zero "Copying/Creating" lines to prove the event actually uploaded.

## Duplicate prevention (learned the hard way)
- A `khal new` piped into `grep -v` that finds nothing exits 1 with empty output — the event WAS created. Never assume failure from empty stdout; verify with `khal list`.
- If a duplicate slipped in: identify the ics files (`grep -l "SUMMARY:<title>"` in the calendar dir), keep the one with DESCRIPTION, `rm` the other, `vdirsyncer sync`.

## Repo (canonical setup)
`https://github.com/drcain1/fastmail-calendar` — credential-free config templates, `scripts/setup.sh` (idempotent installer incl. the Windows khal patch + verification), `patches/khal-windows.patch`, README. Re-run setup.sh on a new machine, or after a khal upgrade wipes the patch.

## Layout (do NOT reconfigure from scratch)
- vdirsyncer config: `~/.config/vdirsyncer/config` — CalDAV at `https://caldav.fastmail.com/`, CalDAV-scoped app password stored there (see the account's address in that config)
- Local store: `~/.calendars/fm/<uuid>/` (one dir per calendar)
- khal config: `~/.config/khal/config`, sqlite cache at `~/.cache/khal/khal.db`
- Helper: `bash <repo>/scripts/sync-fastmail.sh` (just runs vdirsyncer sync)

## Calendar name → UUID

Per-account reference for *this* machine's live install. The khal section
name (column 1) is what you pass to `khal list -a <name>`. On a different
account or after re-running `setup.sh`, the UUIDs and display names change —
re-derive the mapping from `vdirsyncer discover` output (each collection is
printed as `"<uuid>" ("<Display Name>")`).

| khal name | calendar | UUID |
|---|---|---|
| fm_personal | Calendar | 81956116-caa7-4dc4-b9be-bb0289ebf7c8 |
| fm_second | (personal) | 22ff0da7-b3d0-4bbc-bd40-5ca00efee4c2 |
| fm_holidays | Holidays (readonly) | 7cd0998b-b813-4b1b-82b2-5f640b051825 |
| fm_travel | Travel | 0dcc99bf-47d9-45b5-9ff3-28a4e50b10db |
| fm_prior_trip | Past trip (2025) | 10e9095b-1d6e-4479-b25c-af4734b7d9ef |
| fm_shared | (shared) | 0d4ed2b8-eb1a-478b-875b-ab6caa15931d |

## Windows pitfalls (khal 0.14, installed via `uv tool install khal`)
1. khal needs patching for Windows in `AppData/Roaming/uv/tools/khal/Lib/site-packages/khal/khalendar/vdir.py`, function `get_etag_from_file`: `os.O_DIRECTORY` and `os.open(dir)` don't exist/fail on Windows, and `os.fsync` on read-only handles raises EBADF. Working version: for str paths that are dirs, `stat = os.stat(f)` directly; for regular files open with `os.O_RDWR` (fall back to `0`), then fsync/fstat. If khal crashes with `O_DIRECTORY` / `PermissionError` on a .ics dir / `Bad file descriptor` on fsync, re-apply this patch (an upgrade wipes it).
2. On first-ever run khal may create `khal.db` as a directory; if sqlite says `unable to open database file`, `rm -rf ~/.cache/khal` and re-run.
3. vdirsyncer warns "currently does not support Windows" — that warning is harmless; sync works fine.
4. `yes | vdirsyncer discover fastmail` is how local collections get created (interactive prompt otherwise). Not needed again unless new calendars appear on Fastmail.

## If auth breaks
- 401 from Fastmail → app password revoked/expired: user regenerates at Fastmail web UI → Settings → Privacy & Security → Connected apps & API tokens (CalDAV scope), update password in vdirsyncer config.
