#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SVG="$ROOT_DIR/assets/brand/byvo-icon.svg"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "rsvg-convert is required" >&2
  exit 1
fi

check_icon() {
  density="$1"
  size="$2"
  target="$ROOT_DIR/android/app/src/main/res/$density/ic_launcher.png"
  tmp_png=$(mktemp "/tmp/byvo-icon-${density}-XXXXXX.png")

  rsvg-convert -w "$size" -h "$size" "$SVG" -o "$tmp_png"

  if ! cmp -s "$tmp_png" "$target"; then
    echo "Mismatch: $density/ic_launcher.png does not match rendered SVG (${size}x${size})" >&2
    rm -f "$tmp_png"
    exit 1
  fi

  rm -f "$tmp_png"
}

check_icon mipmap-mdpi 48
check_icon mipmap-hdpi 72
check_icon mipmap-xhdpi 96
check_icon mipmap-xxhdpi 144
check_icon mipmap-xxxhdpi 192

echo "Android launcher icons match the SVG source."
