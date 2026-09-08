#!/bin/bash
# Regenerate AppIcon.icns (stable, champagne) and AppIcon-Dev.icns (dev, amber) from the raw
# art (AppIcon-source.png). mockicon.swift keys the mark out of the source, composites it at
# 74% onto a clean charcoal squircle (transparent corners, no rim), and renders each size;
# iconutil packs the iconset. Re-run after changing the art or FRAC.
set -euo pipefail
cd "$(dirname "$0")"
SRC="AppIcon-source.png"
FRAC=0.74

build() {   # <markColor|orig> <out.icns>
  local mark="$1" out="$2" tmp set
  tmp="$(mktemp -d)"; set="$tmp/icon.iconset"; mkdir -p "$set"
  emit() { swift mockicon.swift "$SRC" "$set/$2" "$1" "$FRAC" "$mark" >/dev/null; }
  emit 16   icon_16x16.png
  emit 32   icon_16x16@2x.png;   cp "$set/icon_16x16@2x.png"   "$set/icon_32x32.png"
  emit 64   icon_32x32@2x.png
  emit 128  icon_128x128.png
  emit 256  icon_128x128@2x.png; cp "$set/icon_128x128@2x.png" "$set/icon_256x256.png"
  emit 512  icon_256x256@2x.png; cp "$set/icon_256x256@2x.png" "$set/icon_512x512.png"
  emit 1024 icon_512x512@2x.png
  iconutil -c icns "$set" -o "$out"
  rm -rf "$tmp"
  echo "built $out"
}

build orig   AppIcon.icns
build F5A623 AppIcon-Dev.icns
# The site's marks come off the same art: transparent corners, no rim, one per theme so the
# favicon can follow the browser's. The charcoal squircle reads on light chrome, the cream one
# on dark. og.png flattens the cream mark onto the site canvas, since a social card has no
# transparency to sit on.
SITE="../../site/img"
swift mockicon.swift "$SRC" "$SITE/mark.png"       512 "$FRAC" orig            >/dev/null
swift mockicon.swift "$SRC" "$SITE/mark-light.png" 512 "$FRAC" 181b1f eddfcd   >/dev/null
python3 - "$SITE" <<'PY'
import sys
from PIL import Image
site = sys.argv[1]
card = Image.new("RGB", (1200, 630), (13, 15, 19))
mark = Image.open(site + "/mark-light.png").convert("RGBA").resize((320, 320), Image.LANCZOS)
card.paste(mark, ((1200 - 320) // 2, (630 - 320) // 2), mark)
card.save(site + "/og.png")
PY
echo "built $SITE/mark.png, $SITE/mark-light.png, $SITE/og.png"
