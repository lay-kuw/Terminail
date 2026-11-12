#!/bin/bash
# Terminail をビルドする
#   bash build.sh           ビルドだけ（build/Terminail.app）
#   bash build.sh install   ビルドして ~/Applications に入れて起動
#   bash build.sh dmg       ほかの Mac 用の dmg を作る（Apple Silicon 用）
set -euo pipefail
cd "$(dirname "$0")"

NAME="Terminail"
APP="build/$NAME.app"
MODE="${1:-}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() {   # compile <arch> <出力先>
  swiftc -O -swift-version 5 \
    -target "$1-apple-macos13.0" \
    Sources/*.swift \
    -framework AppKit -framework Carbon -framework QuartzCore -framework CoreText \
    -o "$2"
}

echo "✦ compiling..."
# Apple Silicon 専用（Intel 版は入れないぶん軽い）
compile arm64 "$APP/Contents/MacOS/Terminail"
strip -x "$APP/Contents/MacOS/Terminail"   # デバッグ用の情報を削って小さく

cp Info.plist "$APP/Contents/Info.plist"

# アイコン：Resources/AppIcon.png から .icns を作る
WORK="$(mktemp -d)"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$WORK"

# 強化ランタイム（--options runtime）付きで署名：ほかのプログラムがこのアプリにコードを差し込むのを防ぐ
# 失敗したら隠さずに止める（署名できていないアプリを入れないように）
if ! codesign --force --options runtime --sign - "$APP" 2>/dev/null; then
  echo "✗ 署名に失敗しました（codesign）" >&2
  exit 1
fi
echo "✦ できた: $APP ($(du -sh "$APP" | cut -f1))"

case "$MODE" in
  install)
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
    pkill -x Terminail || true
    sleep 0.5
    rm -rf "$DEST/$NAME.app"
    cp -R "$APP" "$DEST/"
    open "$DEST/$NAME.app"
    echo "✦ $DEST に入れて起動しました"
    ;;
  dmg)
    DMG="build/$NAME $VERSION.dmg"
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    # 開いたら、アプリを Applications（/Applications）にドラッグするだけ。
    # どの Mac にもある /Applications を指すので、作った Mac のユーザ名は dmg に入らない
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DMG"
    hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
    echo "✦ dmg: $DMG ($(du -sh "$DMG" | cut -f1))"
    ;;
esac
