#!/bin/bash
# dvd-auto-rip.sh - rip the main feature of a DVD with MakeMKV, encode with HandBrake.
#
# This is also the entry point for TV discs: when `dvd-mode tv ...` is active it
# hands over to dvd-auto-rip-tv.sh or dvd-auto-rip-chapters.sh.
set -Eeuo pipefail

# Optional settings file (see dvd-auto-rip.conf.example)
CONF="${DVD_AUTO_RIP_CONF:-/etc/dvd-auto-rip.conf}"
if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1090
    source "$CONF"
fi

MEDIA="${MEDIA:-/media}"
BIN_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# ----------------------------- TV mode hand-over ---------------------------
MODE_FILE="$MEDIA/_scratch/dvd-automation/mode"
if [[ -f "$MODE_FILE" ]] && grep -q '^MODE=tv$' "$MODE_FILE"; then
    if grep -q '^SPLIT_CHAPTERS=1$' "$MODE_FILE"; then
        exec "$BIN_DIR/dvd-auto-rip-chapters.sh" "$@"
    fi
    exec "$BIN_DIR/dvd-auto-rip-tv.sh" "$@"
fi

# ----------------------------- Configuration -----------------------------
# Every value can be overridden in /etc/dvd-auto-rip.conf.
DRIVE="${DRIVE:-/dev/sr0}"
SCRATCH="$MEDIA/_scratch/dvd-automation"
LOGDIR="$SCRATCH/logs"
RIPDIR="$SCRATCH/rips"
WORKDIR="$SCRATCH/work"
MOVIEDIR="${MOVIEDIR:-$MEDIA/Movies}"

MIN_TITLE_SECONDS="${MIN_TITLE_SECONDS:-3600}"        # main feature must be at least this long
HB_PRESET="${HB_PRESET:-medium}"                      # x265 encoder preset
HB_RF="${HB_RF:-22}"                                  # constant quality (lower = better/larger)
MIN_FREE_GB="${MIN_FREE_GB:-15}"                      # refuse to start with less free space
DURATION_TOLERANCE_PCT="${DURATION_TOLERANCE_PCT:-3}" # allowed output/source length difference
KEEP_ORIGINAL="${KEEP_ORIGINAL:-0}"                   # 1 = keep the raw MakeMKV rip

# MakeMKV numbers titles AFTER dropping the ones shorter than --minlength, so the
# "info" scan and the "mkv" rip must use the SAME value or the title numbers
# will not match.
MAKEMKV_MINLENGTH=120
# --------------------------------------------------------------------------

mkdir -p "$LOGDIR" "$RIPDIR" "$WORKDIR" "$MOVIEDIR" /run/lock

# Single-instance lock
exec 9>/run/lock/dvd-auto-rip.lock
if ! flock -n 9; then
    echo "Another DVD ripping job is already running."
    exit 1
fi

LOG="$LOGDIR/dvd-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

echo "===== DVD job started: $(date) ====="

# ----------------------------- Cleanup / traps ----------------------------
PARTIAL=""
SUCCESS=0

cleanup() {
    local rc=$?
    if [[ "$SUCCESS" -ne 1 ]]; then
        if [[ -n "$PARTIAL" ]]; then
            rm -f "$PARTIAL"
        fi
        echo "===== DVD job FAILED (exit code $rc): $(date) ====="
        echo "Log: $LOG"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ----------------------------- Preflight checks ---------------------------
find_bin() {
    local name="$1" fallback="$2"
    if [[ -x "$fallback" ]]; then
        echo "$fallback"
    else
        command -v "$name" || true
    fi
}

MAKEMKV="$(find_bin makemkvcon /usr/bin/makemkvcon)"
HANDBRAKE="$(find_bin HandBrakeCLI /usr/local/bin/HandBrakeCLI)"
FFPROBE="$(command -v ffprobe || true)"

for pair in "makemkvcon:$MAKEMKV" "HandBrakeCLI:$HANDBRAKE"; do
    if [[ -z "${pair#*:}" ]]; then
        echo "ERROR: Required executable not found: ${pair%%:*}"
        exit 1
    fi
done
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required."
    exit 1
fi

if [[ ! -b "$DRIVE" ]]; then
    echo "ERROR: DVD drive $DRIVE is not available."
    exit 1
fi

FREE_GB="$(df -Pk "$SCRATCH" | awk 'NR==2 {print int($4/1048576)}')"
if (( FREE_GB < MIN_FREE_GB )); then
    echo "ERROR: Only ${FREE_GB} GB free on scratch volume; need at least ${MIN_FREE_GB} GB."
    exit 1
fi

# ----------------------------- Read disc info -----------------------------
echo "Reading DVD information..."
INFO="$WORKDIR/makemkv-info.txt"
if ! "$MAKEMKV" --minlength="$MAKEMKV_MINLENGTH" -r info "dev:$DRIVE" > "$INFO" 2>&1; then
    cat "$INFO"
    echo "ERROR: MakeMKV could not read the disc."
    exit 1
fi

# Pick the disc name and the longest title of at least MIN_TITLE_SECONDS.
read -r -d '' PARSER <<'PY' || true
import re
import shlex
import string
import sys

path, min_seconds = sys.argv[1], int(sys.argv[2])
titles = {}
disc = ""
volume = ""

def unescape(value):
    return re.sub(r'\\(["\\])', r'\1', value)

with open(path, encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.rstrip("\r\n")

        m = re.match(r'^CINFO:(2|32),0,"(.*)"$', line)
        if m:
            if m.group(1) == "2" and not disc:
                disc = unescape(m.group(2))
            elif m.group(1) == "32" and not volume:
                volume = unescape(m.group(2))
            continue

        m = re.match(r'^TINFO:(\d+),(2|9),0,"(.*)"$', line)
        if m:
            tid, field, value = int(m.group(1)), int(m.group(2)), unescape(m.group(3))
            titles.setdefault(tid, {})["name" if field == 2 else "duration"] = value

def seconds(value):
    try:
        total = 0
        for part in value.split(":"):
            total = total * 60 + int(part)
        return total
    except (ValueError, AttributeError):
        return 0

candidates = [
    (seconds(t.get("duration", "")), tid, t)
    for tid, t in titles.items()
    if seconds(t.get("duration", "")) >= min_seconds
]
if not candidates:
    sys.exit(f"ERROR: No title at least {min_seconds // 60} minutes long was found.")

secs, tid, title = max(candidates, key=lambda c: (c[0], -c[1]))
disc = disc or volume or title.get("name", "") or "DVD Movie"

# Tidy shouty disc labels such as THE_MATRIX -> The Matrix
if "_" in disc or disc.isupper():
    disc = string.capwords(disc.replace("_", " ").lower())

def emit(key, value):
    print(f"{key}={shlex.quote(str(value))}")

emit("DISC_NAME", disc)
emit("TITLE_ID", tid)
emit("TITLE_DURATION", title.get("duration", "unknown"))
emit("TITLE_SECONDS", secs)
PY

if ! PARSED="$(python3 -c "$PARSER" "$INFO" "$MIN_TITLE_SECONDS")"; then
    echo "ERROR: Could not determine the title to rip (see message above)."
    exit 1
fi
eval "$PARSED"

# ----------------------------- Destination --------------------------------
SAFE_NAME="$(printf '%s' "$DISC_NAME" \
    | tr '/:' '  ' \
    | tr -cd '[:alnum:] ._()-' \
    | sed -E 's/[[:space:]]+/ /g; s/^[ .]+//; s/[ .]+$//')"

# Generic volume labels would collide between discs; make them unique.
if [[ -z "$SAFE_NAME" ]] || [[ "${SAFE_NAME^^}" =~ ^(DVD[ _]?VIDEO|DVDVOLUME|DVD[ _]?MOVIE|DISC[ _]?[0-9]*|VIDEO[ _]?TS|LOGICAL[ _]?VOLUME[ _]?ID)$ ]]; then
    SAFE_NAME="DVD Movie $(date +%Y-%m-%d_%H%M%S)"
    echo "WARNING: Disc label '$DISC_NAME' is generic; using '$SAFE_NAME'. Rename it afterwards."
fi

FINALDIR="$MOVIEDIR/$SAFE_NAME"
FINAL="$FINALDIR/$SAFE_NAME.mkv"

echo "Disc: $DISC_NAME"
echo "Selected title: $TITLE_ID ($TITLE_DURATION)"
echo "Destination: $FINAL"

if [[ -e "$FINAL" ]]; then
    echo "ERROR: Destination already exists; refusing to overwrite it: $FINAL"
    exit 1
fi

# ----------------------------- Rip ----------------------------------------
RIPJOB="$RIPDIR/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RIPJOB"

echo "Ripping selected title with MakeMKV..."
if ! "$MAKEMKV" --minlength="$MAKEMKV_MINLENGTH" mkv "dev:$DRIVE" "$TITLE_ID" "$RIPJOB"; then
    echo "ERROR: MakeMKV ripping failed. Any partial output is in: $RIPJOB"
    exit 1
fi

# Largest MKV in the rip folder
INPUT=""
largest=0
while IFS= read -r -d '' f; do
    size="$(stat -c %s "$f")"
    if (( size > largest )); then
        largest="$size"
        INPUT="$f"
    fi
done < <(find "$RIPJOB" -maxdepth 1 -type f -iname '*.mkv' -print0)

if [[ -z "$INPUT" || ! -s "$INPUT" ]]; then
    echo "ERROR: MakeMKV did not produce a non-empty MKV file."
    exit 1
fi

# ----------------------------- Encode -------------------------------------
# Encode inside the scratch area (not the library) so media servers never see
# half-finished files; the finished file is moved into place at the end.
PARTIAL="$RIPJOB/encode.partial.mkv"
rm -f "$PARTIAL"

echo "Encoding with HandBrake (H.265, $HB_PRESET, RF $HB_RF, AC3 passthrough, no subtitles)..."
# "< /dev/null" stops HandBrake from swallowing stdin.
if ! "$HANDBRAKE" \
        -i "$INPUT" \
        -o "$PARTIAL" \
        -f av_mkv \
        -e x265 \
        --encoder-preset "$HB_PRESET" \
        -q "$HB_RF" \
        --comb-detect \
        --decomb \
        -a 1 \
        -E copy:ac3 \
        --audio-fallback ac3 \
        -s none \
        --no-markers < /dev/null; then
    echo "ERROR: HandBrake encoding failed. The original rip is kept at: $INPUT"
    exit 1
fi

if [[ ! -s "$PARTIAL" ]]; then
    echo "ERROR: Encoded output is missing or empty. Original rip kept at: $INPUT"
    exit 1
fi

# ----------------------------- Validate -----------------------------------
if [[ -n "$FFPROBE" ]]; then
    DURATION="$("$FFPROBE" -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$PARTIAL" 2>/dev/null || true)"
    if [[ ! "$DURATION" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "ERROR: ffprobe could not validate the encoded file; original rip kept at: $INPUT"
        exit 1
    fi
    echo "Encoded duration: ${DURATION}s (source title: ${TITLE_SECONDS}s)"
    if ! awk -v d="$DURATION" -v t="$TITLE_SECONDS" -v p="$DURATION_TOLERANCE_PCT" \
            'BEGIN { diff = (d > t) ? d - t : t - d; exit !(diff <= t * p / 100) }'; then
        echo "ERROR: Encoded duration differs from the source by more than ${DURATION_TOLERANCE_PCT}%; original rip kept at: $INPUT"
        exit 1
    fi
else
    echo "WARNING: ffprobe not found; only checked that the output is non-empty."
fi

# ----------------------------- Publish ------------------------------------
mkdir -p "$FINALDIR"
if [[ -e "$FINAL" ]]; then
    echo "ERROR: Destination appeared while encoding; not overwriting: $FINAL"
    exit 1
fi
mv -n "$PARTIAL" "$FINAL"
if [[ -e "$PARTIAL" ]]; then
    echo "ERROR: Could not move the encoded file into place."
    exit 1
fi
PARTIAL=""
SUCCESS=1

echo "SUCCESS: $FINAL"
if [[ "$KEEP_ORIGINAL" == "1" ]]; then
    echo "Original MakeMKV rip retained at: $INPUT"
else
    rm -rf "$RIPJOB"
    echo "Original MakeMKV rip removed."
fi


echo "===== DVD job finished: $(date) ====="
