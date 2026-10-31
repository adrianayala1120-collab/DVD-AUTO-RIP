#!/bin/bash
# dvd-watcher.sh - watches the optical drive and runs dvd-auto-rip.sh every time a
# disc is inserted. Ejects the disc afterwards (success or failure) so the same disc
# is never processed twice. Runs as a systemd service (see systemd/dvd-auto-rip.service).

CONF="${DVD_AUTO_RIP_CONF:-/etc/dvd-auto-rip.conf}"
if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1090
    source "$CONF"
fi

DRIVE="${DRIVE:-/dev/sr0}"
BIN_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
RIP="${RIP:-$BIN_DIR/dvd-auto-rip.sh}"

log() { echo "[$(date '+%F %T')] $*"; }

# True when a readable disc is in the drive.
has_disc() {
    timeout 30 dd if="$DRIVE" of=/dev/null bs=2048 count=1 status=none 2>/dev/null
}

# Eject with the kernel ioctl. The "eject" command needs udev, which is usually
# missing inside LXC containers; this works without it.
eject_disc() {
    python3 - "$DRIVE" <<'PY' 2>/dev/null
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NONBLOCK)
try:
    fcntl.ioctl(fd, 0x5329, 0)   # CDROM_LOCKDOOR: unlock (ignore if not permitted)
except OSError:
    pass
fcntl.ioctl(fd, 0x5309)          # CDROMEJECT
PY
}

log "Watching $DRIVE for discs..."
while true; do
    if [[ -b "$DRIVE" ]] && has_disc; then
        log "Disc detected; letting the drive settle..."
        sleep 15
        if has_disc; then
            log "Starting rip job"
            if "$RIP"; then
                log "Job finished OK"
            else
                log "Job FAILED (see the newest log in the scratch logs folder)"
            fi

            log "Ejecting disc"
            if eject_disc || eject "$DRIVE" 2>/dev/null; then
                sleep 5
            else
                log "Could not eject; remove the disc by hand. Waiting for it to be removed..."
                while has_disc; do sleep 10; done
            fi
            log "Ready for the next disc"
        fi
    fi
    sleep 5
done
