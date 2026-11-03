#!/usr/bin/env bash
# Build Sonivo Threads 9:16 reel from a screen recording.
# Usage: ./build-reel.sh /path/to/sonivo-demo.mp4
set -euo pipefail

SRC="${1:?source mp4 required}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/exports"
STILLS="$OUT/stills"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$OUT" "$STILLS" "$ROOT/raw"

FONT_LAT="/usr/share/fonts/truetype/noto/NotoSansDisplay-Bold.ttf"
FONT_RU="/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf"
FONT_RU_REG="/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf"
# Prefer Syne variable (Latin wordmark) if present
if [[ -f /tmp/user-drive/fonts/syne.zip ]] && file /tmp/user-drive/fonts/syne.zip | grep -qi TrueType; then
  FONT_LAT=/tmp/user-drive/fonts/syne.zip
fi

W=1080
H=1920
PHONE_H=1500
PHONE_W=688

esc() { printf '%s' "$1" | sed "s/'/\\\\'/g; s/:/\\\\:/g"; }

cut_clip() {
  local start="$1" dur="$2" name="$3"
  ffmpeg -hide_banner -loglevel error -y -ss "$start" -i "$SRC" -t "$dur" \
    -vf "scale=${PHONE_W}:${PHONE_H}:force_original_aspect_ratio=decrease,pad=${PHONE_W}:${PHONE_H}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30" \
    -c:v libx264 -preset fast -crf 18 -an \
    "$WORK/${name}.mp4"
}

echo "== cutting clips =="
# Skip iOS Music folder (0–2.0s); open on Sonivo splash → Моя волна
cut_clip 2.05  2.8  c01_brand
cut_clip 6.0   6.0  c02_now
cut_clip 20.0  6.0  c03_lyrics
cut_clip 40.0  4.0  c04_wave
cut_clip 122.0 10.0 c05_eq
cut_clip 142.0 3.0  c06_end

make_card() {
  local name="$1" title="$2" sub="$3" dur="$4"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=0x0B0C0E:s=${W}x${H}:d=${dur}:r=30" \
    -vf "drawtext=fontfile=${FONT_LAT}:text='$(esc "$title")':fontcolor=white:fontsize=110:x=(w-text_w)/2:y=h*0.40,\
drawtext=fontfile=${FONT_RU_REG}:text='$(esc "$sub")':fontcolor=0xD4A574:fontsize=34:x=(w-text_w)/2:y=h*0.52" \
    -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p -an \
    "$WORK/${name}.mp4"
}

echo "== cards =="
make_card c00_title "SONIVO" "плеер · mashup · iOS" 2.0
make_card c99_end "SONIVO" "AutoMix Mashup · iOS" 2.2

frame_clip() {
  local in="$1" out="$2" caption="$3" cap2="${4:-}"
  local ox=$(( (W - PHONE_W) / 2 ))
  local oy=$(( (H - PHONE_H) / 2 + 20 ))
  local vf="\
color=c=0x0B0C0E:s=${W}x${H}:r=30[bg];\
[0:v]format=yuv420p,setsar=1[ph];\
[bg][ph]overlay=${ox}:${oy}:shortest=1,\
drawbox=x=${ox}:y=$((oy + PHONE_H + 4)):w=${PHONE_W}:h=18:color=black@0.35:t=fill,\
drawtext=fontfile=${FONT_LAT}:text='SONIVO':fontcolor=white:fontsize=40:x=44:y=48,\
drawtext=fontfile=${FONT_RU}:text='$(esc "$caption")':fontcolor=0xE8E6E1:fontsize=32:x=44:y=H-132"
  if [[ -n "$cap2" ]]; then
    vf+=",drawtext=fontfile=${FONT_RU_REG}:text='$(esc "$cap2")':fontcolor=0xD4A574:fontsize=24:x=44:y=H-88"
  fi
  ffmpeg -hide_banner -loglevel error -y -i "$WORK/${in}.mp4" \
    -filter_complex "$vf" \
    -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p -an \
    "$WORK/${out}.mp4"
}

echo "== framing =="
frame_clip c01_brand f01 "Моя волна" ""
frame_clip c02_now   f02 "Now Playing" "живые обложки · lossless"
frame_clip c03_lyrics f03 "Тексты" "караоке · синхрон"
frame_clip c04_wave  f04 "Моя волна" "лента · премьеры"
frame_clip c05_eq    f05 "10-band EQ" "Твой звук · в реальном времени"
frame_clip c06_end   f06 "Сведение" "волна по треку"

cat > "$WORK/list.txt" <<EOF
file '$WORK/c00_title.mp4'
file '$WORK/f01.mp4'
file '$WORK/f02.mp4'
file '$WORK/f03.mp4'
file '$WORK/f04.mp4'
file '$WORK/f05.mp4'
file '$WORK/f06.mp4'
file '$WORK/c99_end.mp4'
EOF

echo "== concat + audio =="
ffmpeg -hide_banner -loglevel error -y -ss 6 -i "$SRC" -t 30 -vn \
  -af "volume=0.5,afade=t=in:st=0:d=0.5,afade=t=out:st=28:d=1.5" \
  -c:a aac -b:a 160k "$WORK/bed.m4a"

ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i "$WORK/list.txt" -i "$WORK/bed.m4a" \
  -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p \
  -c:a aac -b:a 160k -shortest -movflags +faststart \
  "$OUT/sonivo-threads-9x16.mp4"

ffmpeg -hide_banner -loglevel error -y -i "$OUT/sonivo-threads-9x16.mp4" \
  -vf "scale=1080:1350:force_original_aspect_ratio=increase,crop=1080:1350" \
  -c:v libx264 -preset medium -crf 18 -c:a copy -movflags +faststart \
  "$OUT/sonivo-threads-4x5.mp4"

echo "== stills =="
ffmpeg -hide_banner -loglevel error -y -i "$OUT/sonivo-threads-9x16.mp4" \
  -vf "fps=1/5,scale=1080:1920" -q:v 2 "$STILLS/reel-%02d.jpg"

ffmpeg -hide_banner -loglevel error -y -ss 8 -i "$SRC" -frames:v 1 \
  -vf "scale=1080:1350:force_original_aspect_ratio=increase,crop=1080:1350" -q:v 2 "$STILLS/carousel-01-now.jpg"
ffmpeg -hide_banner -loglevel error -y -ss 23 -i "$SRC" -frames:v 1 \
  -vf "scale=1080:1350:force_original_aspect_ratio=increase,crop=1080:1350" -q:v 2 "$STILLS/carousel-02-lyrics.jpg"
ffmpeg -hide_banner -loglevel error -y -ss 125 -i "$SRC" -frames:v 1 \
  -vf "scale=1080:1350:force_original_aspect_ratio=increase,crop=1080:1350" -q:v 2 "$STILLS/carousel-03-eq.jpg"
ffmpeg -hide_banner -loglevel error -y -ss 2.5 -i "$SRC" -frames:v 1 \
  -vf "scale=1080:1350:force_original_aspect_ratio=increase,crop=1080:1350" -q:v 2 "$STILLS/carousel-04-splash.jpg"

ffprobe -hide_banner "$OUT/sonivo-threads-9x16.mp4" 2>&1 | head -18
ls -lh "$OUT"/*.mp4 "$STILLS"
echo "DONE → $OUT/sonivo-threads-9x16.mp4"
