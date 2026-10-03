#!/usr/bin/env bash
# Usage: scripts/import-to-bucket.sh DIR...
# Uploads photos/videos into <PREFIX>/originals with a JPEG poster in
# <PREFIX>/thumbnails, so Cloud Settings > Import from Bucket can pick them up.
# Stills -> HEIC (sips), videos kept as-is (already H.264/HEVC). Key = import_<name>.<ext>.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . .env.bucket; set +a
dest="s3://$BUCKET/$PREFIX"
tmp=$(mktemp -d)
trap 'mv "$tmp" "/tmp/import-to-bucket.$(date +%s)"' EXIT

existing=$(aws s3 ls "$dest/originals/" | awk '{print $4}')
n=0
for dir in "$@"; do
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    base=$(basename "$f"); stem="${base%.*}"; ext=$(echo "${base##*.}" | tr A-Z a-z)
    name="import_$stem"
    case "$ext" in
      mp4|mov|m4v)
        out="$f"; outext="$ext"
        ffmpeg -v error -y -ss 1 -i "$f" -frames:v 1 -vf "scale='min(512,iw)':-2" -q:v 4 "$tmp/$name.jpg" \
          || ffmpeg -v error -y -i "$f" -frames:v 1 -vf "scale='min(512,iw)':-2" -q:v 4 "$tmp/$name.jpg" ;;
      jpg|jpeg|png|heic|heif|tif|tiff)
        outext=heic; out="$tmp/$name.heic"
        sips -s format heic -s formatOptions 70 "$f" --out "$out" >/dev/null
        sips -s format jpeg -Z 512 "$f" --out "$tmp/$name.jpg" >/dev/null ;;
      *) echo "skip $base"; continue ;;
    esac
    if grep -qx "$name.$outext" <<<"$existing"; then echo "have $name.$outext"; continue; fi
    aws s3 cp --only-show-errors "$out" "$dest/originals/$name.$outext"
    aws s3 cp --only-show-errors "$tmp/$name.jpg" "$dest/thumbnails/$name.jpg"
    n=$((n+1)); echo "ok $name.$outext"
  done
done
echo "uploaded $n"
