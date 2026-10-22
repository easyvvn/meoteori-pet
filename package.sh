#!/bin/zsh
# 다른 맥에 줄 설치 묶음 만들기 → dist/머털이_설치_v<버전>.zip
# CODEX=1 이면 Codex용 → dist/머털이_Codex_설치_v<버전>.zip (앱은 같고 설치 · 읽어보기만 다름)
# 받는 맥은 Xcode 도구 필요 없음: 압축 풀고 '설치.command' 실행
set -e
cd "${0:A:h}"
VER=$(grep -o 'CFBundleShortVersionString</key><string>[^<]*' build.sh | sed 's/.*<string>//')
STAGE=$(mktemp -d)/머털이
mkdir -p "$STAGE"
OUT="$STAGE/Meoteori.app" UNIVERSAL=1 ./build.sh >/dev/null
if [[ -n "$CODEX" ]]; then
  cp install_codex.sh "$STAGE/설치.command"; cp tools/읽어보기_codex.txt "$STAGE/읽어보기.txt"; ZIP="dist/머털이_Codex_설치_v$VER.zip"
else
  cp install.sh "$STAGE/설치.command"; cp tools/읽어보기.txt "$STAGE/읽어보기.txt"; ZIP="dist/머털이_설치_v$VER.zip"
fi
chmod +x "$STAGE/설치.command"
mkdir -p dist
rm -f "$ZIP"
ditto -c -k --keepParent "$STAGE" "$ZIP"
rm -rf "${STAGE:h}"
echo "$PWD/$ZIP"
