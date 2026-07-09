#!/usr/bin/env bash
# make-demo-gif.sh — turn a screen recording into a tight, optimized promo GIF.
#
# Recording is native: hit Cmd-Shift-5, pick "Record Selected Portion", frame a
# small region around your text field, record `я сказал ghbdtn` → tap Option →
# `я сказал привет`, stop. Then feed the .mov here.
#
# Usage:
#   scripts/make-demo-gif.sh INPUT.mov [OUTPUT.gif]
#   FPS=15 WIDTH=900 START=0.5 DURATION=4 scripts/make-demo-gif.sh in.mov demo.gif
#
# Env knobs (all optional):
#   FPS=15        frames/sec (12–18 is the sweet spot for UI demos)
#   WIDTH=900     output width in px, height auto (keeps aspect)
#   START=        trim: start seconds (e.g. 0.5 to drop the fumble before typing)
#   DURATION=     trim: length in seconds from START
set -euo pipefail

in=${1:?usage: make-demo-gif.sh INPUT.mov [OUTPUT.gif]}
out=${2:-${in%.*}.gif}
fps=${FPS:-15}
width=${WIDTH:-900}
start=${START:-}
duration=${DURATION:-}

[[ -f $in ]] || { echo "no such file: $in" >&2; exit 1; }

# Build the trim args shared by both paths.
trim=()
[[ -n $start ]]    && trim+=(-ss "$start")
[[ -n $duration ]] && trim+=(-t "$duration")

if command -v gifski >/dev/null 2>&1 && command -v ffmpeg >/dev/null 2>&1; then
  # Best quality: ffmpeg extracts frames, gifski builds a per-frame-palette GIF.
  echo "→ gifski path (fps=$fps width=$width)"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  ffmpeg -hide_banner -loglevel error "${trim[@]}" -i "$in" \
    -vf "fps=$fps,scale=$width:-1:flags=lanczos" "$tmp/f%05d.png"
  gifski --fps "$fps" --width "$width" -o "$out" "$tmp"/f*.png
elif command -v ffmpeg >/dev/null 2>&1; then
  # Fallback: ffmpeg two-pass palette. Good, slightly worse gradients than gifski.
  echo "→ ffmpeg palette path (fps=$fps width=$width)"
  pal=$(mktemp -t relayout-pal).png
  trap 'rm -f "$pal"' EXIT
  vf="fps=$fps,scale=$width:-1:flags=lanczos"
  ffmpeg -hide_banner -loglevel error "${trim[@]}" -i "$in" \
    -vf "$vf,palettegen=stats_mode=diff" -y "$pal"
  ffmpeg -hide_banner -loglevel error "${trim[@]}" -i "$in" -i "$pal" \
    -lavfi "$vf[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3" -y "$out"
else
  echo "need ffmpeg (and ideally gifski) — brew install gifski ffmpeg" >&2
  exit 1
fi

bytes=$(stat -f%z "$out")
printf '✓ %s  (%s, %d KB)\n' "$out" "${width}px @ ${fps}fps" "$((bytes/1024))"
[[ $bytes -gt 5242880 ]] && echo "⚠ >5 MB — drop FPS/WIDTH or trim tighter (GitHub/PH prefer <5 MB)"
