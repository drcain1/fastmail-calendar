# fastmail-calendar

CalDAV bridge for talking to a [Fastmail](https://www.fastmail.com) calendar
from the command line: **vdirsyncer** syncs your calendars to a local store,
**khal** gives you date-aware queries on top of it. Built for Hermes Agent —
the companion skill (`fastmail-calendar`) syncs on demand, answers "what's on
this week", checks conflicts, and creates events that push back to Fastmail.

Works on Linux/macOS out of the box; Windows (MSYS/git-bash) is supported via
an embedded one-time patch for a khal portability bug.

## What's in this repo

```
configs/vdirsyncer.config.template   vdirsyncer config (placeholders)
configs/khal.config.template         khal static tail (sqlite/locale/default)
scripts/setup.sh                     installer: tools + configs + patch + verify
scripts/sync-fastmail.sh             one-liner: vdirsyncer sync
patches/khal-windows.patch           the Windows khal fix, as a unified diff
skill/SKILL.md                       the Hermes Agent skill (per-account notes)
```

**No credentials in this repo.** The app password is injected at setup time
from `$FASTMAIL_PASSWORD` (or a hidden prompt) and lives only in the rendered
`~/.config/vdirsyncer/config` (chmod 600).

## Setup

1. **Fastmail app password** (one-time, in the web UI):
   Settings → Privacy & Security → *Connected apps & API tokens* →
   **New app password**, scope it to **Calendars (CalDAV)** only.
   Fastmail shows the password once.

2. **Run the installer** (idempotent, safe to re-run):

   ```bash
   FASTMAIL_USER=you@example.com FASTMAIL_PASSWORD=<that-password> \
     bash scripts/setup.sh
   ```

   It installs `vdirsyncer` + `khal` (via `uv tool` or `pipx`), renders both
   configs, applies the khal Windows patch where needed, discovers your
   calendars, syncs, and verifies with a `khal list` at the end.
   It picks the collection named "Calendar" as the default calendar
   (`personal`); rename/re-prioritize in `~/.config/khal/config` after.

## Day-to-day

```bash
vdirsyncer sync                  # pull latest (fast, incremental)
khal list 05-09-2026 20-09-2026  # events in a range  (DD-MM-YYYY!)
khal list --notstarted           # everything upcoming
khal search "dinner"             # full-text across all calendars
khal new "12 September 2026 19:00" "12 September 2026 21:00" "Dinner at x"
vdirsyncer sync                  # pushes the new event to Fastmail
```

Notes:

- khal parses dates with the configured `dateformat` (`%d-%m-%Y`) — use
  `DD-MM-YYYY`, not ISO, for range arguments.
- `khal new` is quiet on success (empty stdout, exit 0); verify with
  `khal list`, then sync — the second sync run must show zero "Copying"
  lines for the upload to be proven.
- `-a <calendar>` / `-d <calendar>` restrict or exclude calendars
  (section names from `~/.config/khal/config`).

## The khal Windows patch (why it exists)

khal ≤ 0.14 crashes on Windows in three stacked ways:

1. `os.O_DIRECTORY` doesn't exist on Windows → `AttributeError` when
   computing a vdir's etag.
2. `os.open(dir)` raises `PermissionError` on Windows → same function.
3. `os.fsync()` on a read-only handle raises `Bad file descriptor` →
   every `.ics` etag.

`scripts/setup.sh` patches `get_etag_from_file()` in the installed
`khal/khalendar/vdir.py` (detected across `uv tool` / `pipx` layouts) by
replacing the whole block — see `patches/khal-windows.patch` for the diff
of the working implementation. If you reinstall/upgrade khal and it
crashes again, re-run `scripts/setup.sh` (or `git apply patches/khal-windows.patch`
against the installed package).

Also: on the very first khal run, `khal.db` can be created as a
*directory* (sqlite then fails with `unable to open database file`).
Setup clears it; the same fix is `rm -rf ~/.cache/khal`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `401 Unauthorized` from Fastmail | App password revoked — regenerate (CalDAV scope) and re-run `setup.sh` |
| `vdirsyncer: Please run discover` | `yes \| vdirsyncer discover fastmail` (new calendars appeared) |
| khal `config error: color ... unacceptable` | Use the 16 named colors with *spaces* (`light blue`), or `#RRGGBB` |
| khal `Could not parse` on a date range | `DD-MM-YYYY` per `dateformat` |
| `khal.db` is a directory | `rm -rf ~/.cache/khal` and re-run |
| Sync warns "does not support Windows" | Harmless — sync works fine |
