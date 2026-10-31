#!/bin/bash
# Removes the scripts and the service. Your ripped media, the scratch folder and
# /etc/dvd-auto-rip.conf are left alone.
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
BINDIR="$PREFIX/bin"

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root:  sudo bash uninstall.sh"
    exit 1
fi

if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl disable --now dvd-auto-rip.service 2>/dev/null || true
    rm -f /etc/systemd/system/dvd-auto-rip.service
    systemctl daemon-reload
fi

for f in dvd-auto-rip.sh dvd-auto-rip-tv.sh dvd-auto-rip-chapters.sh dvd-watcher.sh dvd-mode; do
    rm -f "$BINDIR/$f"
done
if [[ -L /usr/bin/dvd-mode ]]; then rm -f /usr/bin/dvd-mode; fi

echo "Removed. Left in place: your media, the scratch folder and /etc/dvd-auto-rip.conf."
