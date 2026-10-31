#!/bin/bash
# dvd-auto-rip-tv.sh - rip every episode on a TV-show DVD.
# Called automatically by dvd-auto-rip.sh when the mode is "tv" (see: dvd-mode).
set -Eeuo pipefail

# Optional settings file (see dvd-auto-rip.conf.example)
CONF="${DVD_AUTO_RIP_CONF:-/etc/dvd-auto-rip.conf}"
if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1090
    source "$CONF"
fi

MEDIA="${MEDIA:-/media}"
DRIVE="${DRIVE:-/dev/sr0}"
SCRATCH="$MEDIA/_scratch/dvd-automation"
LOGDIR="$SCRATCH/logs"
RIPDIR="$SCRATCH/rips"
WORKDIR="$SCRATCH/work"
TVDIR="${TVDIR:-$MEDIA/TV Shows}"
MODE_FILE="$SCRATCH/mode"

EP_MIN_SECONDS="${EP_MIN_SECONDS:-900}"     # titles shorter than this are ignored (15 min)
EP_MAX_SECONDS="${EP_MAX_SECONDS:-4200}"    # titles longer than this are ignored (70 min, "play all")
HB_PRESET="${HB_PRESET:-medium}"
HB_RF="${HB_RF:-22}"
MIN_FREE_GB="${MIN_FREE_GB:-15}"
DURATION_TOLERANCE_PCT="${DURATION_TOLERANCE_PCT:-3}"
KEEP_ORIGINAL="${KEEP_ORIGINAL:-0}"         # 1 = keep raw MakeMKV rips

mkdir -p "$LOGDIR" "$RIPDIR" "$WORKDIR" /run/lock

exec 9>/run/lock/dvd-auto-rip.lock
if ! flock -n 9; then
    echo "Another DVD ripping job is already running."
    exit 1
fi

LOG="$LOGDIR/dvd-tv-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

echo "===== DVD TV job started: $(date) ====="

PARTIAL=""
SUCCESS=0
cleanup() {
    local rc=$?
    if [[ "$SUCCESS" -ne 1 ]]; then
        if [[ -n "$PARTIAL" ]]; then
            rm -f "$PARTIAL"
        fi
        echo "===== DVD TV job FAILED (exit code $rc): $(date) ====="
        echo "Log: $LOG"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

fail() { echo "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------- Load mode
MODE=""; SHOW=""; SEASON=""; NEXT_EPISODE=""
if [[ -f "$MODE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$MODE_FILE"
fi
if [[ "$MODE" != "tv" || -z "$SHOW" || ! "$SEASON" =~ ^[0-9]+$ || ! "$NEXT_EPISODE" =~ ^[0-9]+$ ]]; then
    fail "TV mode is not set up. Run: dvd-mode tv \"Show Name\" <season> [first-episode]"
fi
SEASON=$((10#$SEASON))
NEXT_EPISODE=$((10#$NEXT_EPISODE))

write_mode() {
    {
        echo "MODE=tv"
        printf 'SHOW=%q\n' "$SHOW"
        echo "SEASON=$SEASON"
        echo "NEXT_EPISODE=$1"
        grep -E '^EP_(MIN|MAX)_SECONDS=[0-9]+$' "$MODE_FILE" || true
    } > "$MODE_FILE.tmp"
    mv "$MODE_FILE.tmp" "$MODE_FILE"
}

# ---------------------------------------------------------------- Preflight
find_bin() {
    local name="$1" fallback="$2"
    if [[ -x "$fallback" ]]; then echo "$fallback"; else command -v "$name" || true; fi
}
MAKEMKV="$(find_bin makemkvcon /usr/bin/makemkvcon)"
HANDBRAKE="$(find_bin HandBrakeCLI /usr/local/bin/HandBrakeCLI)"
FFPROBE="$(command -v ffprobe || true)"

[[ -n "$MAKEMKV" ]] || fail "makemkvcon not found."
[[ -n "$HANDBRAKE" ]] || fail "HandBrakeCLI not found."
command -v python3 >/dev/null 2>&1 || fail "python3 is required."
[[ -b "$DRIVE" ]] || fail "DVD drive $DRIVE is not available."

FREE_GB="$(df -Pk "$SCRATCH" | awk 'NR==2 {print int($4/1048576)}')"
if (( FREE_GB < MIN_FREE_GB )); then
    fail "Only ${FREE_GB} GB free on scratch volume; need at least ${MIN_FREE_GB} GB."
fi

# ------------------------------------------------------------- Read the disc
# IMPORTANT: the same --minlength must be used for "info" and "mkv", because
# MakeMKV numbers titles after filtering by length.
echo "Reading DVD information..."
INFO="$WORKDIR/makemkv-info-tv.txt"
if ! "$MAKEMKV" --minlength="$EP_MIN_SECONDS" -r info "dev:$DRIVE" > "$INFO" 2>&1; then
    cat "$INFO"
    fail "MakeMKV could not read the disc."
fi

read -r -d '' PARSER <<'PY' || true
import re
import sys

path, lo, hi = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
titles = {}
with open(path, encoding="utf-8", errors="replace") as f:
    for line in f:
        m = re.match(r'^TINFO:(\d+),9,0,"(.*)"$', line.rstrip("\r\n"))
        if not m:
            continue
        try:
            secs = 0
            for part in m.group(2).split(":"):
                secs = secs * 60 + int(part)
        except ValueError:
            continue
        titles[int(m.group(1))] = secs

items = sorted(titles.items())
sel = [(t, s) for t, s in items if lo <= s <= hi]

# Drop a "play all" title: longer than every other title and about equal to their sum.
if len(sel) >= 4:
    total = sum(s for _, s in sel)
    keep = []
    for t, s in sel:
        biggest_other = max(x for u, x in sel if u != t)
        if s > biggest_other and abs(s - (total - s)) <= 0.03 * s:
            continue
        keep.append((t, s))
    sel = keep

chosen = {t for t, _ in sel}
print("Titles on disc:", file=sys.stderr)
for t, s in items:
    print(f"  title {t}: {s // 60}m{s % 60:02d}s  {'EPISODE' if t in chosen else 'skipped'}", file=sys.stderr)

if not sel:
    sys.exit("ERROR: no episode-length titles found on this disc.")
for t, s in sel:
    print(f"{t}\t{s}")
PY

if ! PARSED="$(python3 -c "$PARSER" "$INFO" "$EP_MIN_SECONDS" "$EP_MAX_SECONDS")"; then
    fail "Could not determine which titles are episodes."
fi
mapfile -t TITLES <<< "$PARSED"
COUNT="${#TITLES[@]}"

# ------------------------------------------------------------ Plan the names
SAFE_SHOW="$(printf '%s' "$SHOW" \
    | tr '/:' '  ' \
    | tr -cd '[:alnum:] ._()-' \
    | sed -E 's/[[:space:]]+/ /g; s/^[ .]+//; s/[ .]+$//')"
[[ -n "$SAFE_SHOW" ]] || fail "Show name '$SHOW' has no usable characters."

SEASON_NUM="$(printf '%02d' "$SEASON")"
SEASON_DIR="$TVDIR/$SAFE_SHOW/Season $SEASON_NUM"

ep_name() { printf '%s - S%sE%02d.mkv' "$SAFE_SHOW" "$SEASON_NUM" "$1"; }

echo "Show: $SAFE_SHOW  Season: $SEASON  Starting at episode: $NEXT_EPISODE"
echo "Found $COUNT episode(s):"
for ((i = 0; i < COUNT; i++)); do
    tid="${TITLES[i]%%$'\t'*}"
    name="$(ep_name $((NEXT_EPISODE + i)))"
    echo "  title $tid -> $name"
    if [[ -e "$SEASON_DIR/$name" ]]; then
        fail "$SEASON_DIR/$name already exists. Wrong episode counter? Check with: dvd-mode"
    fi
done

# -------------------------------------------------------------- Rip + encode
RIPJOB="$RIPDIR/tv-$(date +%Y%m%d-%H%M%S)"
OUTDIR="$RIPJOB/out"
mkdir -p "$OUTDIR"

for ((i = 0; i < COUNT; i++)); do
    IFS=$'\t' read -r TID TSECS <<< "${TITLES[i]}"
    EP=$((NEXT_EPISODE + i))
    NAME="$(ep_name "$EP")"
    RAW="$RIPJOB/raw-$TID"
    mkdir -p "$RAW"

    echo "--- $NAME (disc title $TID, ${TSECS}s) ---"
    if ! "$MAKEMKV" --minlength="$EP_MIN_SECONDS" mkv "dev:$DRIVE" "$TID" "$RAW"; then
        fail "MakeMKV failed on title $TID. Partial output is in: $RIPJOB"
    fi

    INPUT=""
    largest=0
    while IFS= read -r -d '' f; do
        size="$(stat -c %s "$f")"
        if (( size > largest )); then largest="$size"; INPUT="$f"; fi
    done < <(find "$RAW" -maxdepth 1 -type f -iname '*.mkv' -print0)
    [[ -n "$INPUT" && -s "$INPUT" ]] || fail "MakeMKV produced no file for title $TID."

    PARTIAL="$OUTDIR/$NAME.partial.mkv"
    rm -f "$PARTIAL"
    echo "Encoding $NAME with HandBrake..."
    if ! "$HANDBRAKE" \
            -i "$INPUT" -o "$PARTIAL" \
            -f av_mkv -e x265 --encoder-preset "$HB_PRESET" -q "$HB_RF" \
            --comb-detect --decomb \
            -a 1 -E copy:ac3 --audio-fallback ac3 \
            -s none --no-markers < /dev/null; then
        fail "HandBrake failed on $NAME. Raw rip kept at: $INPUT"
    fi
    [[ -s "$PARTIAL" ]] || fail "Encoded output for $NAME is missing or empty."

    if [[ -n "$FFPROBE" ]]; then
        DURATION="$("$FFPROBE" -v error -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 "$PARTIAL" 2>/dev/null || true)"
        [[ "$DURATION" =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail "ffprobe could not validate $NAME."
        echo "Encoded duration: ${DURATION}s (source title: ${TSECS}s)"
        if ! awk -v d="$DURATION" -v t="$TSECS" -v p="$DURATION_TOLERANCE_PCT" \
                'BEGIN { diff = (d > t) ? d - t : t - d; exit !(diff <= t * p / 100) }'; then
            fail "$NAME differs from the source by more than ${DURATION_TOLERANCE_PCT}%. Raw rip kept at: $INPUT"
        fi
    else
        echo "WARNING: ffprobe not found; only checked that the output is non-empty."
    fi

    mv "$PARTIAL" "$OUTDIR/$NAME"
    PARTIAL=""
    if [[ "$KEEP_ORIGINAL" != "1" ]]; then
        rm -rf "$RAW"
    fi
done

# ------------------------------------------------------------------ Publish
# Everything encoded fine, so only now do files appear in the library.
mkdir -p "$SEASON_DIR"
for ((i = 0; i < COUNT; i++)); do
    NAME="$(ep_name $((NEXT_EPISODE + i)))"
    [[ ! -e "$SEASON_DIR/$NAME" ]] || fail "$SEASON_DIR/$NAME appeared while encoding; not overwriting."
    mv -n "$OUTDIR/$NAME" "$SEASON_DIR/$NAME"
    echo "SUCCESS: $SEASON_DIR/$NAME"
done

NEXT=$((NEXT_EPISODE + COUNT))
write_mode "$NEXT"
SUCCESS=1

if [[ "$KEEP_ORIGINAL" != "1" ]]; then
    rm -rf "$RIPJOB"
fi
echo "Next disc will start at S${SEASON_NUM}E$(printf '%02d' "$NEXT")."
echo "(New season or a different show? Run: dvd-mode tv \"Show\" <season> [first-episode])"
echo "===== DVD TV job finished: $(date) ====="
