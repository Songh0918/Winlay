#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$ROOT/dist}"
APP="$OUTPUT/Winlay.app"
DMG="$OUTPUT/Winlay.dmg"
ZIP="$OUTPUT/Winlay-macos-universal.zip"
CHECKSUM="$OUTPUT/SHA256SUMS"

if [[ -e "$APP" || -e "$DMG" || -e "$ZIP" || -e "$CHECKSUM" ]]; then
  echo "$OUTPUT 中已有构建产物，请先移走旧文件，或指定其他输出目录。" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/winlay-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STAGED_APP="$WORK/Winlay.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

for ARCH in x86_64 arm64; do
  echo "正在编译 ${ARCH}…"
  xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macosx15.0" \
    -module-cache-path "$WORK/module-cache-$ARCH" \
    -o "$WORK/Winlay-$ARCH" \
    "$ROOT/Winlay/WinlayApp.swift" "$ROOT"/Winlay/Core/*.swift \
    "$ROOT"/Winlay/Services/*.swift "$ROOT"/Winlay/Views/*.swift
done
xcrun lipo -create "$WORK/Winlay-x86_64" "$WORK/Winlay-arm64" -output "$STAGED_APP/Contents/MacOS/Winlay"
xcrun lipo "$STAGED_APP/Contents/MacOS/Winlay" -verify_arch x86_64 arm64

cp "$ROOT/Winlay/Info.plist" "$STAGED_APP/Contents/Info.plist"
PLIST=/usr/libexec/PlistBuddy
"$PLIST" -c 'Set :CFBundleIdentifier com.songh.winlay' "$STAGED_APP/Contents/Info.plist"
"$PLIST" -c 'Set :CFBundleExecutable Winlay' "$STAGED_APP/Contents/Info.plist"
"$PLIST" -c 'Set :LSMinimumSystemVersion 15.0' "$STAGED_APP/Contents/Info.plist"
"$PLIST" -c 'Add :CFBundleIconFile string AppIcon' "$STAGED_APP/Contents/Info.plist"

ICONS="$ROOT/Winlay/Assets.xcassets/AppIcon.appiconset"
python3 - "$ICONS" "$STAGED_APP/Contents/Resources/AppIcon.icns" <<'PY'
import pathlib
import struct
import sys

icons = pathlib.Path(sys.argv[1])
chunks = []
for kind, size in ((b'icp4', 16), (b'icp5', 32), (b'icp6', 64),
                   (b'ic07', 128), (b'ic08', 256), (b'ic09', 512), (b'ic10', 1024)):
    data = (icons / f'icon-{size}.png').read_bytes()
    chunks.append(kind + struct.pack('>I', len(data) + 8) + data)
content = b''.join(chunks)
pathlib.Path(sys.argv[2]).write_bytes(b'icns' + struct.pack('>I', len(content) + 8) + content)
PY
codesign --force --sign - "$STAGED_APP"
codesign --verify --strict "$STAGED_APP"

mkdir -p "$OUTPUT"
ditto "$STAGED_APP" "$APP"
ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP" "$ZIP"
(cd "$OUTPUT" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$CHECKSUM")")
mkdir "$WORK/dmg"
ditto "$STAGED_APP" "$WORK/dmg/Winlay.app"
ln -s /Applications "$WORK/dmg/Applications"
echo "构建完成：$APP"
echo "通用安装包：$ZIP"
if [[ "${WINLAY_SKIP_DMG:-0}" == "1" ]]; then
  exit 0
fi
if ! hdiutil create -volname Winlay -srcfolder "$WORK/dmg" -format UDZO "$DMG"; then
  echo "DMG 创建失败；已生成的 .app 和 ZIP 仍可使用。" >&2
else
  echo "磁盘映像：$DMG"
fi
