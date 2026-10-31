# dvd-auto-rip

Insert a DVD, walk away. A small set of Bash scripts that rip a disc with
[MakeMKV](https://www.makemkv.com/), compress it with
[HandBrake](https://handbrake.fr/) (H.265), file it in your media library with
Jellyfin/Plex-friendly names, eject the disc, and wait for the next one.

* **Movies**: the main feature goes to `Movies/<Title>/<Title>.mkv`.
* **TV shows**: every episode goes to `TV Shows/<Show>/Season 01/<Show> - S01E01.mkv`,
  numbered automatically across as many discs as the season takes.
* **Episodes stored as chapters** (kids' compilation discs and similar: one long title,
  many episodes): each chapter becomes its own numbered episode.
* Runs as a background service. No buttons, no GUI.

> Not affiliated with the "Automatic Ripping Machine" (ARM) project. This is a separate,
> much smaller tool.

Developed and used on a Debian-based Proxmox LXC container with MakeMKV 2.0.0 and
HandBrakeCLI (x265). It should work on any Linux machine with an optical drive.

## How it works

1. `dvd-watcher.sh` (a systemd service) notices a disc in the drive.
2. It runs `dvd-auto-rip.sh`, which reads the current mode (`dvd-mode`) and either rips a
   movie itself or hands over to the TV or chapters script.
3. MakeMKV rips the title(s); HandBrake encodes them; the encoded length is checked against
   the disc; only then does anything appear in your library.
4. The disc is ejected (also when the job fails, so a bad disc is never retried in a loop).

Safety: it never overwrites an existing file, and TV discs are all-or-nothing. If any
episode on a disc fails, nothing from that disc is published and the episode counter does
not move, so you can simply run the disc again.

## Requirements

* Linux with systemd (without systemd you can run `dvd-watcher.sh` yourself)
* `makemkvcon` (MakeMKV; see makemkv.com for Linux install and licensing)
* `HandBrakeCLI`
* `python3`, `flock` (util-linux), `ffprobe` (package `ffmpeg`, recommended: it verifies
  the encoded length)
* Enough scratch space: about 15 GB free. A raw DVD rip can be up to ~8 GB

## Install

```bash
git clone https://github.com/adrianayala1120-collab/dvd-auto-rip.git
cd dvd-auto-rip
sudo bash install.sh
```

This copies the scripts to `/usr/local/bin`, creates `/etc/dvd-auto-rip.conf`, creates the
`Movies` and `TV Shows` folders under `/media`, and installs and starts the
`dvd-auto-rip` service. To remove everything: `sudo bash uninstall.sh`.

## Usage

The default mode is **movies**: just insert a disc.

### TV shows

Tell it what you're loading, **once per season**:

```bash
dvd-mode tv "The Office (US)" 1          # show name, season number
```

Then insert discs one after another. Episodes are numbered in disc order and the counter
carries on from disc to disc by itself. Switch back with:

```bash
dvd-mode movie
```

`dvd-mode` on its own shows the current mode and the next episode number.

Use the official show name (with the year or country if needed) as Jellyfin and Plex match
on the folder name.

### Short episodes or unusual discs

By default a TV disc's titles between 15 and 70 minutes count as episodes (shorter titles
are extras, longer ones are "play all"). For shows with different episode lengths, give the
range in minutes:

```bash
dvd-mode tv "Bluey" 1 1 4 20             # show, season, first episode, min, max minutes
```

### Episodes stored as chapters

Some discs have one huge title with every episode as a chapter. Add `--chapters`:

```bash
dvd-mode tv "Bluey" 1 1 4 20 --chapters
```

Every chapter between 4 and 20 minutes becomes an episode (title cards and trailers are
skipped). Nothing needs to be looked up beforehand, because the chapter list is read from the disc.

### Multi-disc seasons

Same season, next disc: just swap discs. New season: run `dvd-mode` again with the new
season number. To fix a wrong counter, re-run it with the right first episode, e.g.
`dvd-mode tv "Bluey" 1 27 4 20 --chapters`.

## Configuration

Optional. Edit `/etc/dvd-auto-rip.conf` (every setting is shown commented out with its
default): media folder, drive, output folders, x265 preset and quality, keep or delete
the raw rips, and so on. Changes apply to the next disc.

Encoding defaults: H.265 (x265, preset `medium`, RF 22), automatic deinterlacing of
interlaced frames, **first audio track only** (AC3 passed through untouched), **no
subtitles**. Different audio or subtitle handling means editing the `HandBrakeCLI`
command in the scripts.

## Files

| Path | What it is |
| --- | --- |
| `bin/dvd-auto-rip.sh` | Movie ripper and entry point (hands over in TV mode) |
| `bin/dvd-auto-rip-tv.sh` | TV discs: one episode per disc title |
| `bin/dvd-auto-rip-chapters.sh` | TV discs: episodes stored as chapters |
| `bin/dvd-mode` | Switch between movie and TV mode |
| `bin/dvd-watcher.sh` | Watches the drive, starts jobs, ejects discs |
| `systemd/dvd-auto-rip.service` | Service definition |
| `dvd-auto-rip.conf.example` | Settings template |

Runtime data lives in `$MEDIA/_scratch/dvd-automation/`: `logs/` (one log per disc), `rips/`
and `work/` (temporary), and `mode` (what `dvd-mode` sets).

## Running inside a Proxmox LXC container

The container needs the drive passed through (and MakeMKV also needs the matching
`/dev/sg*` device). The following is a starting point for `/etc/pve/lxc/<id>.conf`; adjust
the device names to your system (`ls -l /dev/sr0 /dev/sg*` on the host):

```
lxc.cgroup2.devices.allow: b 11:* rwm
lxc.cgroup2.devices.allow: c 21:* rwm
lxc.mount.entry: /dev/sr0 dev/sr0 none bind,optional,create=file
lxc.mount.entry: /dev/sg0 dev/sg0 none bind,optional,create=file
```

Notes from real use:

* The `eject` command usually fails in a container (it needs udev), so the watcher ejects
  with a kernel call instead.
* `/usr/local/bin` is sometimes missing from `PATH` in minimal containers; the installer
  also links `dvd-mode` into `/usr/bin` for that reason.
* **Don't paste large scripts into a browser console**: it drops characters. Use
  `git clone`, `scp`, or `pct push`.
* Run `pct exec <id> -- /usr/local/bin/dvd-mode ...` (full path) from the host.

## Troubleshooting

* **Watch it work:** `journalctl -u dvd-auto-rip -f`, or read the newest file in
  `$MEDIA/_scratch/dvd-automation/logs/`. (The `[48K blob data]` lines in the journal are
  HandBrake's progress output and are harmless.)
* **"No episode-length titles found" on a TV disc:** the log lists every title as `EPISODE` or
  `skipped`. Either the episodes are shorter or longer than the filter (give a min and max
  to `dvd-mode`, as above), or all episodes are chapters of one long title (add `--chapters`).
* **`Read Error` from MakeMKV:** the drive couldn't read part of the disc. Clean it and
  retry; if the same title fails again the disc is probably damaged there.
* **`Destination already exists; refusing to overwrite`:** that disc was already ripped. For
  a TV disc it can also mean the episode counter is wrong. Check with `dvd-mode`.
* **Disc doesn't eject:** the container probably isn't allowed to control the drive; see the
  LXC notes. The watcher then waits for you to remove the disc instead of re-ripping it.
* **Not showing up in Jellyfin/Plex:** add `Movies` and `TV Shows` as libraries (content
  types Movies and Shows) and run a library scan.
* **A failed run leaves files in `rips/`.** They can be large; delete them when no job is running.

## Limitations

* Episode numbers follow the order on the disc. Compilation discs often don't match broadcast
  order, so titles may need renaming afterwards.
* Copy-protected or damaged discs may fail to rip.
* Only the first audio track is kept and subtitles are dropped (see Configuration).
* Discs with several unrelated long titles: the movie ripper takes the longest one.

## Legal

Make backups only of discs you own, and check what your country's law allows, as rules on
circumventing copy protection differ. MakeMKV and HandBrake have their own licenses.

## License

MIT, see [LICENSE](LICENSE).
