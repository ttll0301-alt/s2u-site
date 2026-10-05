#!/bin/bash
# Usage: scripts/prep-media.sh <slug> <file> [file...]
# Photos (.jpg/.jpeg/.png/.heic) -> resized JPEG  fyf-<slug>[-N].jpg  (long edge 1600px)
# Videos (.mp4/.mov)             -> copied as fyf-<slug>.mp4 + poster fyf-<slug>.jpg (Quick Look frame)
# No ffmpeg on this Mac, so videos are NOT re-encoded: tell the user if one is > 8 MB.
set -e
cd "$(dirname "$0")/.."
slug="$1"; shift
[ -n "$slug" ] && [ $# -gt 0 ] || { sed -n '2,5p' "$0"; exit 1; }
n=0
for f in "$@"; do
  ext=$(echo "${f##*.}" | tr 'A-Z' 'a-z')
  case "$ext" in
    jpg|jpeg|png|heic)
      n=$((n+1)); out="fyf-$slug.jpg"; [ $# -gt 1 ] && out="fyf-$slug-$n.jpg"
      sips -s format jpeg -s formatOptions 78 -Z 1600 "$f" --out "$out" >/dev/null
      echo "photo -> $out ($(du -k "$out" | cut -f1) KB)";;
    mp4|mov)
      cp "$f" "fyf-$slug.mp4"
      tmp=$(mktemp -d); qlmanage -t -s 1200 -o "$tmp" "fyf-$slug.mp4" >/dev/null 2>&1 || true
      if [ -f "$tmp/fyf-$slug.mp4.png" ]; then
        sips -s format jpeg -s formatOptions 78 "$tmp/fyf-$slug.mp4.png" --out "fyf-$slug.jpg" >/dev/null
        echo "video -> fyf-$slug.mp4 ($(du -k "fyf-$slug.mp4" | cut -f1) KB) + poster fyf-$slug.jpg"
      else
        echo "video -> fyf-$slug.mp4 (poster generation failed; supply a jpg)"
      fi
      rm -rf "$tmp";;
    *) echo "skip $f (unsupported)";;
  esac
done
python3 scripts/check-site.py || true
