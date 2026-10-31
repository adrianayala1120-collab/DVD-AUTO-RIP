#!/bin/bash
# dvd-auto-rip-chapters.sh - for TV discs that keep every episode inside ONE long title:
# each chapter that is episode-length becomes its own numbered episode.
# Used automatically when the mode file has SPLIT_CHAPTERS=1 (dvd-mode tv ... --chapters).
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

EP_MIN_SECONDS="${EP_MIN_SECONDS:-180}"     # chapters shorter than this are not episodes
EP_MAX_SECONDS="${EP_MAX_SECONDS:-3600}"    # chapters longer than this are not episodes
TITLE_MIN_SECONDS=600                       # the long title must be at least this long
HB_PRESET="${HB_PRESET:-medium}"
HB_RF="${HB_RF:-22}"
MIN_FREE_GB="${MIN_FREE_GB:-15}"
DURATION_TOLERANCE_PCT="${DURATION_TOLERANCE_PCT:-4}"
KEEP_ORIGINAL="${KEEP_ORIGINAL:-0}"

mkdir -p "$LOGDIR" "$RIPDIR" "$WORKDIR" /run/lock

exec 9>/run/lock/dvd-auto-rip.lock
if ! flock -n 9; then
    echo "Another DVD ripping job is already running."
    exit 1
fi

LOG="$LOGDIR/dvd-chapters-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
echo "===== DVD CHAPTER job started: $(date) ====="

PARTIAL=""
SUCCESS=0
cleanup() {
    local rc=$?
    if [[ "$SUCCESS" -ne 1 ]]; then
        if [[ -n "$PARTIAL" ]]; then rm -f "$PARTIAL"; fi
        echo "===== DVD CHAPTER job FAILED (exit code $rc): $(date) ====="
        echo "Log: $LOG"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
fail() { echo "ERROR: $*"; exit 1; }

MODE=""; SHOW=""; SEASON=""; NEXT_EPISODE=""
if [[ -f "$MODE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$MODE_FILE"
fi
if [[ "$MODE" != "tv" || -z "$SHOW" || ! "$SEASON" =~ ^[0-9]+$ || ! "$NEXT_EPISODE" =~ ^[0-9]+$ ]]; then
    fail "TV mode is not set up. Run: dvd-mode tv \"Show Name\" <season> [first-episode] --chapters"
fi
SEASON=$((10#$SEASON))
NEXT_EPISODE=$((10#$NEXT_EPISODE))

write_mode() {
    {
        echo "MODE=tv"
        printf 'SHOW=%q\n' "$SHOW"
        echo "SEASON=$SEASON"
        echo "NEXT_EPISODE=$1"
        grep -E '^(EP_(MIN|MAX)_SECONDS|SPLIT_CHAPTERS)=[0-9]+$' "$MODE_FILE" || true
    } > "$MODE_FILE.tmp"
    mv "$MODE_FILE.tmp" "$MODE_FILE"
}

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

# ------------------------------------------------- Find the long title and rip it
# The same --minlength must be used for "info" and "mkv" (MakeMKV numbers titles after filtering).
echo "Reading DVD information..."
INFO="$WORKDIR/makemkv-info-chapters.txt"
if ! "$MAKEMKV" --minlength="$TITLE_MIN_SECONDS" -r info "dev:$DRIVE" > "$INFO" 2>&1; then
    cat "$INFO"
    fail "MakeMKV could not read the disc."
fi

read -r -d '' PICK_TITLE <<'PY' || true
import re
import sys

titles = {}
with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
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

if not titles:
    sys.exit("ERROR: no title long enough was found on this disc.")
best = max(titles, key=lambda t: titles[t])
for t, s in sorted(titles.items()):
    print(f"  title {t}: {s // 60}m{s % 60:02d}s  {'USING' if t == best else 'ignored'}", file=sys.stderr)
print(f"{best}\t{titles[best]}")
PY

if ! PICKED="$(python3 -c "$PICK_TITLE" "$INFO")"; then
    fail "Could not pick a title."
fi
IFS=$'\t' read -r TID TSECS <<< "$PICKED"

RIPJOB="$RIPDIR/chapters-$(date +%Y%m%d-%H%M%S)"
RAW="$RIPJOB/raw"
OUTDIR="$RIPJOB/out"
mkdir -p "$RAW" "$OUTDIR"

echo "Ripping title $TID (${TSECS}s) with MakeMKV..."
if ! "$MAKEMKV" --minlength="$TITLE_MIN_SECONDS" mkv "dev:$DRIVE" "$TID" "$RAW"; then
    fail "MakeMKV failed. Partial output is in: $RIPJOB"
fi

INPUT=""
largest=0
while IFS= read -r -d '' f; do
    size="$(stat -c %s "$f")"
    if (( size > largest )); then largest="$size"; INPUT="$f"; fi
done < <(find "$RAW" -maxdepth 1 -type f -iname '*.mkv' -print0)
[[ -n "$INPUT" && -s "$INPUT" ]] || fail "MakeMKV produced no file."

# ------------------------------------------------------- Work out the episodes
SCAN="$WORKDIR/hb-scan-chapters.txt"
"$HANDBRAKE" -i "$INPUT" -t 1 --scan < /dev/null > "$SCAN" 2>&1 || true

read -r -d '' PICK_CHAPTERS <<'PY' || true
import re
import sys

path, lo, hi = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
in_chapters = False
chapters = []
with open(path, encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.rstrip("\r\n")
        if re.match(r'^\s*\+ chapters:\s*$', line):
            in_chapters = True
            continue
        if not in_chapters:
            continue
        m = re.match(r'^\s*\+ (\d+): duration (\d+):(\d+):(\d+)\s*$', line)
        if m:
            secs = int(m.group(2)) * 3600 + int(m.group(3)) * 60 + int(m.group(4))
            chapters.append((int(m.group(1)), secs))
        elif re.match(r'^\s*\+ ', line):
            break

if not chapters:
    sys.exit("ERROR: no chapters found in the ripped file.")
sel = [(c, s) for c, s in chapters if lo <= s <= hi]
chosen = {c for c, _ in sel}
print("Chapters in the title:", file=sys.stderr)
for c, s in chapters:
    print(f"  chapter {c}: {s // 60}m{s % 60:02d}s  {'EPISODE' if c in chosen else 'skipped'}", file=sys.stderr)
if not sel:
    sys.exit("ERROR: no chapter is episode-length (check the min/max minutes given to dvd-mode).")
for c, s in sel:
    print(f"{c}\t{s}")
PY

if ! PARSED="$(python3 -c "$PICK_CHAPTERS" "$SCAN" "$EP_MIN_SECONDS" "$EP_MAX_SECONDS")"; then
    fail "Could not work out the episodes. Raw rip kept at: $INPUT"
fi
mapfile -t CHAPS <<< "$PARSED"
COUNT="${#CHAPS[@]}"

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
    ch="${CHAPS[i]%%$'\t'*}"
    name="$(ep_name $((NEXT_EPISODE + i)))"
    echo "  chapter $ch -> $name"
    if [[ -e "$SEASON_DIR/$name" ]]; then
        fail "$SEASON_DIR/$name already exists. Wrong episode counter? Check with: dvd-mode"
    fi
done

# ------------------------------------------------------------------- Encode
for ((i = 0; i < COUNT; i++)); do
    IFS=$'\t' read -r CH CSECS <<< "${CHAPS[i]}"
    NAME="$(ep_name $((NEXT_EPISODE + i)))"
    PARTIAL="$OUTDIR/$NAME.partial.mkv"
    rm -f "$PARTIAL"
    echo "--- $NAME (chapter $CH, ${CSECS}s) ---"
    if ! "$HANDBRAKE" \
            -i "$INPUT" -t 1 -c "$CH" -o "$PARTIAL" \
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
        echo "Encoded duration: ${DURATION}s (chapter length: ${CSECS}s)"
        if ! awk -v d="$DURATION" -v t="$CSECS" -v p="$DURATION_TOLERANCE_PCT" \
                'BEGIN { diff = (d > t) ? d - t : t - d; exit !(diff <= t * p / 100 + 2) }'; then
            fail "$NAME differs from the chapter length by more than ${DURATION_TOLERANCE_PCT}%. Raw rip kept at: $INPUT"
        fi
    else
        echo "WARNING: ffprobe not found; only checked that the output is non-empty."
    fi
    mv "$PARTIAL" "$OUTDIR/$NAME"
    PARTIAL=""
done

# ------------------------------------------------------------------ Publish
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

if [[ "$KEEP_ORIGINAL" != "1" ]]; then rm -rf "$RIPJOB"; fi
echo "Next disc will start at S${SEASON_NUM}E$(printf '%02d' "$NEXT")."
echo "===== DVD CHAPTER job finished: $(date) ====="
