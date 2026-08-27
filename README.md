# Backup Manager

*[Русская версия](README.ru.md)*

![Arch Linux](https://img.shields.io/badge/Arch_Linux-1793d1?style=flat-square&logo=archlinux&logoColor=white)
![BorgBackup](https://img.shields.io/badge/BorgBackup-1.4-5c4ee5?style=flat-square)
![Shell](https://img.shields.io/badge/Shell-4eaa25?style=flat-square&logo=gnubash&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)

Encrypted, deduplicated nightly backups for a single Linux machine — a small
wrapper around [BorgBackup](https://www.borgbackup.org/) that runs on systemd
timers, tells you the truth about its own state in your status bar, and proves
once a month that the backups actually restore.

![The menu](docs/screenshots/menu.png)

Most backup setups are never tested until the day they are needed. This one
tests itself: on the first of every month it picks 50 random files out of the
newest archive, extracts them, and compares them byte for byte against the
live system. If that fails, you find out on the first — not on the day the
disk dies.

## What's in it

- **Two tiers.** Tier 1 runs nightly and holds what you cannot re-download:
  `/etc`, dotfiles, keys, code, documents. Tier 2 joins in on the weekly full
  run and carries the bulky, survivable things — media libraries, chat history.
  A nightly run stays small because the big stuff is not in it.
- **Deduplication.** Borg splits files into chunks and stores each chunk once.
  On the machine this was written for, the nightly run went from 2.2 GB in
  1 min 45 s to **4.3 MB in 8 seconds** — the second snapshot only writes what
  actually changed.
- **Encryption.** `repokey-blake2`, AES-256. The passphrase lives in
  `/etc/backup-manager/passphrase`, mode `600 root:root`. The alternative — a
  plain archive with `/etc/shadow` inside it — is how it works by default in a
  lot of hand-rolled scripts.
- **A restore drill.** `bm drill` samples files from the newest archive,
  extracts them and compares them to what is on disk. Runs monthly, on a timer.
- **Status without root.** After each run `bm` writes `status.json` (mode 644,
  no secrets in it — names, sizes, dates). That is what the status-bar module
  and the menu read, so merely *looking* at the state never asks for a password.
- **A menu.** A rofi front-end over the whole thing, for when you would rather
  click than remember flags.

| | Before (a hand-written tar.zst script) | With Borg |
|---|---|---|
| nightly run | 2.2 GB, ~1 min 45 s | **4.3 MB, 8 s** |
| history kept | 1 point, yesterday overwritten | 7 daily + 4 weekly + 6 monthly |
| encryption | none, mode 644 with `/etc/shadow` inside | AES-256, `repokey-blake2` |
| scratch space | a full copy in `/var/tmp` | none, sources are read directly |

## Requirements

- A systemd-based Linux distribution. The installer knows `pacman`; on anything
  else install `borg`, `jq` and `openssl` yourself first and it will pick them up.
- `borg` 1.2 or newer, `jq`, `openssl`
- Optional: `rofi` (the menu), `kitty` (terminal actions in the menu),
  `libnotify` (desktop notifications), `fuse3` (`bm mount`)
- Root, for everything except `bm sources` and `bm --help`

## Installation

```bash
git clone https://github.com/Whyslab/backup-manager.git
cd backup-manager
sudo ./install.sh
```

The installer copies the code to `/opt/backup-manager`, generates
`config/settings.json` for the user who invoked `sudo`, symlinks `bm` and
`backup-manager` into `/usr/local/bin`, installs the systemd units and
logrotate rules, creates the borg repository, and offers to enable the timers.

**It will print a passphrase and a paper key. Write them down somewhere that is
not this computer.** Without them the repository cannot be read, even with
every byte of it intact. This is the one step of the installation that cannot
be undone later.

To see exactly what it would do, without doing any of it:

```bash
sudo ./install.sh --dry-run
```

To try it against a throwaway directory instead of your real system:

```bash
./install.sh --prefix /tmp/bm-test    # no root needed
```

### Before the first real backup

Check what is about to be included — this needs no root:

```bash
bm sources
```

`sources.json` ships with a reasonable default (configs, keys, `~/Projects`,
`~/Documents`, `~/Pictures` nightly; `~/Music` and `~/Videos` weekly). Adjust it
to your machine, then take the first snapshot:

```bash
sudo bm backup
```

## Usage

![The CLI](docs/screenshots/cli-help.png)

| Command | What it does |
|---|---|
| `bm status` | last snapshot, space used, when it was last checked |
| `bm backup` | tier 1 snapshot by hand |
| `bm backup --tier full` | full snapshot (tiers 1+2) |
| `bm backup --dry-run` | list what would be included, write nothing |
| `bm list` | list archives |
| `bm sources` | what is backed up, with sizes — **works without root** |
| `bm check` | integrity check |
| `bm check --deep` | the same, reading every byte back |
| `bm mount` | mount the repository at `/mnt/backup` |
| `bm umount` | unmount it |
| `bm restore <archive> [path…]` | extract to `/var/tmp`, leaving the system alone |
| `bm restore --to-system <archive>` | write over the live system (asks you to type `RESTORE`) |
| `bm drill` | run the restore drill now |
| `bm refresh-status` | rebuild `status.json` for the status bar |

### Getting a single file back

The safe path does not touch your system at all — mount the repository and copy
what you need out by hand:

```bash
sudo bm mount                 # pick an archive interactively, or name one
cp /mnt/backup/<archive>/home/<user>/notes.md ~/notes-recovered.md
sudo bm umount
```

`bm restore` without `--to-system` extracts into `/var/tmp/bm-restore-<date>` so
you can diff it against the live system before deciding anything.

### Schedule

| When | What | Unit |
|---|---|---|
| daily 03:20 | tier 1 snapshot | `bm-backup.timer` |
| Sunday 03:40 | full snapshot (tiers 1+2) | `bm-full.timer` |
| Monday 04:00 | integrity check | `bm-check.timer` |
| 1st of the month 04:30 | deep check + restore drill | `bm-drill.timer` |

Every timer is `Persistent=true`, so a run missed while the machine was off
happens after the next boot. All of them run at `Nice=19` with idle I/O
priority, so a backup never competes with what you are doing.

### The menu

`backup-manager` opens a rofi menu over the same commands — bind it to a key if
you want it (`SUPER + SHIFT + B` is what it was written for):

```bash
bind = SUPER SHIFT, B, exec, backup-manager   # Hyprland
```

![More actions](docs/screenshots/menu-more.png)
![Status](docs/screenshots/status.png)

Everything the status view shows is read from `status.json`, so it opens
instantly and never asks for a password.

## Configuration

Two files, both under `/opt/backup-manager/config/`:

**`sources.json`** — the single source of truth for what is backed up.

```json
{
  "path": "~/.config",
  "tier": 1,
  "exclude": ["**/cache2", "**/GPUCache"],
  "exclude_unless_full": ["some-huge-directory"]
}
```

- `tier: 1` — nightly. `tier: 2` — only in the weekly full run.
- `exclude` — always dropped.
- `exclude_unless_full` — dropped from the nightly run, kept in the full one.
- `never` (top level) — patterns dropped from everything.

> **The rule worth following:** include a directory whole and subtract the big
> things from it. Do not list wanted paths one by one. With a subtractive list a
> new directory is backed up by default; with an additive one it is silently
> missed, and you find out when you need it.

**`settings.json`** — retention, compression, where the repository lives:

```json
"retention": {
  "bm-t1":   { "keep_daily": 7, "keep_weekly": 4, "keep_monthly": 0 },
  "bm-full": { "keep_daily": 0, "keep_weekly": 4, "keep_monthly": 6 }
}
```

`targets` is a list, so a second destination has somewhere to go — see
Limitations.

### Status bar

`ui/hyprpanel_module.sh` prints one JSON object and always exits 0, which makes
it usable from any bar that can run a command (HyprPanel, Waybar, i3blocks):

```json
{ "alt": "ok", "state": "all good", "time": "27.08 03:26", "ago": "10h ago",
  "size": "1.5 GB", "count": "5", "next": "28.08 03:28" }
```

`alt` is one of `ok`, `warning`, `error`, `running`, `none` — use it to pick the
icon. It reports `warning` when the last snapshot is over 48 h old or integrity
has not been checked in three weeks, and `error` when a unit has failed.

## Limitations

Worth being honest about, because a backup you misunderstand is worse than none:

- **One disk.** By default the repository sits on the same disk as the
  originals. That covers "I deleted it", "I broke the config", "the update ate
  it" — it does **not** cover the disk dying. `targets` is a list precisely so a
  second destination can be added, but a second tier is not implemented here.
- **One machine.** No remote repositories, no `borg serve`, no cloud.
- **The passphrase is a single point of failure.** Lose it and the backups are
  gone, whatever their state on disk. The installer says so loudly; it is worth
  taking literally.
- **Arch-first.** Only the dependency install and `lib/packages.sh` (which
  records `pacman` / AUR package lists) are distribution-specific. Everything
  else is portable.
- **No pre/post hooks.** Databases are copied as files, so a database that is
  being written to at 03:20 may end up in an inconsistent state in the archive.

## Uninstall

```bash
sudo ./uninstall.sh              # remove the program, keep the backups
sudo ./uninstall.sh --purge      # also remove logs, state and the passphrase
```

The default deliberately leaves the borg repository and the passphrase alone —
removing a tool should not destroy the data it made. The uninstaller prints the
repository path and the two commands needed to read it without this project
installed at all:

```bash
export BORG_PASSCOMMAND='cat /etc/backup-manager/passphrase'
borg list /path/to/borg-repo
```

That is the point of building on Borg rather than a bespoke format: your
archives outlive this wrapper.

## Development

```bash
bash tests/run-tests.sh
```

57 checks: shell syntax, JSON validity, that the status module emits valid JSON
in every state (missing file, corrupt file, fresh, stale), that every menu entry
resolves and dispatches, that a sandbox install can be fully undone, that sizes
do not change with the system locale, and that nothing personal is shipped.
The suite never touches a real system and needs no root.

## License

MIT — see [LICENSE](LICENSE).
