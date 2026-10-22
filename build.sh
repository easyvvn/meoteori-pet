#!/bin/zsh
# 머털이.app 빌드 → ~/Applications/Meoteori.app
# OUT=경로 로 다른 곳에, UNIVERSAL=1 이면 애플 칩 + 인텔 둘 다 도는 앱 (묶음용, package.sh 가 씀)
set -e
cd "${0:A:h}"
APP="${OUT:-$HOME/Applications/Meoteori.app}"
POSES="${1:-poses}"  # pose_<이름>.png 가 든 폴더 (lie·sit·walk1~4·sleep·work·wait·happy …)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ -n "$UNIVERSAL" ]]; then
  T=$(mktemp -d)
  for arch in arm64 x86_64; do
    swiftc -O -target $arch-apple-macos13 -o "$T/$arch" Sources/main.swift -framework AppKit -framework QuartzCore
  done
  lipo -create "$T/arm64" "$T/x86_64" -output "$APP/Contents/MacOS/Meoteori"
  rm -rf "$T"
else
  swiftc -O -o "$APP/Contents/MacOS/Meoteori" Sources/main.swift -framework AppKit -framework QuartzCore
fi
rm -f "$APP/Contents/Resources/"*.png(N)
cp "$POSES"/pose_*.png "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>머털이</string>
<key>CFBundleIdentifier</key><string>kr.lizzy.meoteori</string>
<key>CFBundleExecutable</key><string>Meoteori</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.7.1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force -s - "$APP" >/dev/null 2>&1 || true
echo "$APP"
