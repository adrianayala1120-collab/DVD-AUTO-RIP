#!/bin/bash
# Installs dvd-auto-rip: scripts, config file and (if systemd is available) the
# background service that watches the drive. Run as root from the repo folder:
#   sudo bash install.sh
#
# Optional environment variables:
#   PREFIX=/usr/local   where the scripts go (into $PREFIX/bin)
#   NO_SERVICE=1        do not install/start the systemd service
#   NO_APT=1            do not try to apt-get install the optional "eject" tool
#   SKIP_DEP_CHECK=1    skip the check for MakeMKV/HandBrake/python3
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
BINDIR="$PREFIX/bin"
CONF="${DVD_AUTO_RIP_CONF:-/etc/dvd-auto-rip.conf}"
HERE="$(cd "$(dirname "$0")" && pwd)"

have() { command -v "$1" >/dev/null 2>&1; }

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root:  sudo bash install.sh"
    exit 1
fi

# ------------------------------------------------------------ dependencies
if [[ "${SKIP_DEP_CHECK:-0}" != "1" ]]; then
    missing=()
    if [[ ! -x /usr/bin/makemkvcon ]] && ! have makemkvcon; then missing+=("makemkvcon (MakeMKV)"); fi
    if [[ ! -x /usr/local/bin/HandBrakeCLI ]] && ! have HandBrakeCLI; then missing+=("HandBrakeCLI"); fi
    have python3 || missing+=("python3")
    have flock || missing+=("flock (package util-linux)")
    if (( ${#missing[@]} > 0 )); then
        echo "Missing required programs:"
        printf '  - %s\n' "${missing[@]}"
        echo "Install them first (see README.md), then run this installer again."
        exit 1
    fi
    have ffprobe || echo "NOTE: ffprobe (package ffmpeg) not found. Rips still work, but the check that"
    have ffprobe || echo "      the encoded length matches the disc will be skipped. Recommended: apt install ffmpeg"
fi

if ! have eject && [[ "${NO_APT:-0}" != "1" ]] && have apt-get; then
    apt-get install -y eject >/dev/null 2>&1 || true   # optional fallback only
fi

# ----------------------------------------------------------------- scripts
install -d "$BINDIR"
for f in dvd-auto-rip.sh dvd-auto-rip-tv.sh dvd-auto-rip-chapters.sh dvd-watcher.sh dvd-mode; do
    install -m 0755 "$HERE/bin/$f" "$BINDIR/$f"
done
# Some minimal containers do not have /usr/local/bin in PATH; make dvd-mode reachable anyway.
if [[ "$BINDIR" == "/usr/local/bin" && ! -e /usr/bin/dvd-mode ]]; then
    ln -s "$BINDIR/dvd-mode" /usr/bin/dvd-mode 2>/dev/null || true
fi

# ------------------------------------------------------------------ config
install -m 0644 "$HERE/dvd-auto-rip.conf.example" "$CONF.example"
if [[ ! -f "$CONF" ]]; then
    install -m 0644 "$HERE/dvd-auto-rip.conf.example" "$CONF"
    echo "Created $CONF (all settings commented out = defaults)."
else
    echo "Kept your existing $CONF."
fi

# shellcheck disable=SC1090
source "$CONF"
MEDIA="${MEDIA:-/media}"
mkdir -p "${MOVIEDIR:-$MEDIA/Movies}" "${TVDIR:-$MEDIA/TV Shows}" "$MEDIA/_scratch/dvd-automation"
if [[ ! -f "$MEDIA/_scratch/dvd-automation/mode" ]]; then
    echo "MODE=movie" > "$MEDIA/_scratch/dvd-automation/mode"
fi

# ----------------------------------------------------------------- service
if [[ "${NO_SERVICE:-0}" == "1" ]] || ! have systemctl || [[ ! -d /run/systemd/system ]]; then
    echo
    echo "Service not installed (no systemd, or NO_SERVICE=1)."
    echo "Start the watcher yourself with:  $BINDIR/dvd-watcher.sh"
else
    sed "s|@BINDIR@|$BINDIR|g" "$HERE/systemd/dvd-auto-rip.service" > /etc/systemd/system/dvd-auto-rip.service
    systemctl daemon-reload
    systemctl enable --now dvd-auto-rip.service
    echo "Service installed and started: dvd-auto-rip"
fi

cat <<MSG

Done.  Insert a disc and it will be ripped as a movie.

  Current mode:   dvd-mode
  TV show discs:  dvd-mode tv "Show Name" 1
  Back to movies: dvd-mode movie
  Watch it work:  journalctl -u dvd-auto-rip -f

MSG
