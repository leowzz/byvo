#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SVG="$ROOT_DIR/assets/brand/byvo-icon.svg"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "rsvg-convert is required" >&2
  exit 1
fi

render_icon() {
  density="$1"
  size="$2"
  output="$ROOT_DIR/android/app/src/main/res/$density/ic_launcher.png"

  rsvg-convert -w "$size" -h "$size" "$SVG" -o "$output"
  echo "Generated $density/ic_launcher.png (${size}x${size})"
}

render_icon mipmap-mdpi 48
render_icon mipmap-hdpi 72
render_icon mipmap-xhdpi 96
render_icon mipmap-xxhdpi 144
render_icon mipmap-xxxhdpi 192
