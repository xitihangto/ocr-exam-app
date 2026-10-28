#!/bin/bash
# 把 1024 母版打成 macOS 用的 AppIcon.icns。
#
#   bash tools/make_icns.sh docs/icon/icon-master.png Resources/AppIcon.icns
#
# 用系统自带的 sips + iconutil，不依赖 Pillow（工程里本来就没有第三方 Python 包）。
# 十档尺寸逐档出，@2x 也单独出 —— 让系统自己插值，16/32 那两档会糊。
set -euo pipefail

SRC="${1:-docs/icon/icon-master.png}"
DST="${2:-Resources/AppIcon.icns}"

if [ ! -f "$SRC" ]; then
  echo "❌ 找不到母版：$SRC"
  exit 1
fi

TMP="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$TMP"

for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
            "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
            "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
  px="${spec%%:*}"
  name="${spec##*:}"
  sips -z "$px" "$px" "$SRC" --out "$TMP/$name.png" >/dev/null
done

iconutil -c icns "$TMP" -o "$DST"
rm -rf "$(dirname "$TMP")"
echo "✓ $DST  $(du -h "$DST" | cut -f1)"
