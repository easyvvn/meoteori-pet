#!/bin/zsh
# 머털이 설치 · Codex용 (맥마다 한 번). 여러 번 돌려도 안전하다.
# 1) 앱 빌드(묶음이면 복사) → ~/Applications/Meoteori.app
# 2) Codex 훅 추가 → ~/.codex/hooks.json (이미 있으면 건너뜀, 고치기 전 백업)
# 3) 로그인할 때 자동 실행 → ~/Library/LaunchAgents/kr.lizzy.meoteori.plist
# 필요 없음(묶음). 소스에서 빌드할 때만 Xcode 명령줄 도구(swiftc), 없으면 `xcode-select --install`
set -e
cd "${0:A:h}"
APP="$HOME/Applications/Meoteori.app"

# 묶음(zip)으로 받았으면 옆에 든 앱을 그대로 쓰고, 소스 폴더면 빌드한다
if [[ -d "./Meoteori.app" ]]; then
  echo "1/3 앱 복사"
  # 받은 앱엔 '인터넷에서 받음' 표시가 붙어 있다. 표시가 남은 채로 한 번이라도 켜지면
  # macOS 경고가 뜨고 휴지통으로 갈 수 있어서, 먼저 자동 실행을 내리고 표시를 지운 뒤 복사한다
  launchctl bootout "gui/$(id -u)/kr.lizzy.meoteori" 2>/dev/null || true
  pkill -x Meoteori 2>/dev/null || true
  xattr -dr com.apple.quarantine "./Meoteori.app" 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$APP"
  cp -R "./Meoteori.app" "$APP"
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
else
  echo "1/3 앱 빌드"
  ./build.sh >/dev/null
fi
echo "    $APP"

echo "2/3 Codex 훅"
mkdir -p "$HOME/.codex" "$HOME/.meoteori/inbox"
# python3 은 새 맥에서 Xcode 도구 설치 창을 띄우므로, macOS 기본 JavaScript(osascript)로 JSON 을 고친다
osascript -l JavaScript - "$HOME/.codex/hooks.json" <<'JS'
ObjC.import('Foundation')
function run(argv) {
  const p = argv[0], fm = $.NSFileManager.defaultManager
  const exists = fm.fileExistsAtPath(p)
  const d = exists ? JSON.parse(ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(p, $.NSUTF8StringEncoding, null))) : {}
  // Codex 훅은 Codex 샌드박스 안에서 돌아 홈 폴더엔 못 쓴다. 샌드박스가 열어 두는 $TMPDIR 에 쓴다
  const cmd = 'd="${TMPDIR:-/tmp}/meoteori-inbox"; mkdir -p "$d" && cat > "$d/codex-$(date +%s)-$$-$RANDOM.json" 2>/dev/null; exit 0'
  const hooks = d.hooks || (d.hooks = {}), added = []
  // Codex 훅 이름은 Claude와 같다. 알림(Notification) 대신 멈춤(Interrupt)이 있다
  for (const [ev, matcher] of [["UserPromptSubmit"], ["PreToolUse"], ["PostToolUse"], ["PermissionRequest"],
                               ["Stop"], ["SessionEnd"], ["Interrupt"]]) {
    let groups = hooks[ev] || (hooks[ev] = [])
    if (groups.some(g => (g.hooks || []).some(h => h.command === cmd))) continue
    // 예전 머털이 훅(v0.7 첫 묶음, 홈 폴더에 쓰던 것)은 빼고 새로 넣는다
    groups.forEach(g => { g.hooks = (g.hooks || []).filter(h => !(h.command || "").includes("meoteori")) })
    groups = hooks[ev] = groups.filter(g => g.hooks.length)
    const g = matcher ? { matcher, hooks: [] } : { hooks: [] }
    g.hooks.push({ type: "command", command: cmd, timeout: 3 })
    groups.push(g); added.push(ev)
  }
  if (!added.length) return "    이미 있음"
  if (exists) {
    const stamp = new Date().toISOString().replace(/[-:]/g, "").replace("T", "-").slice(0, 15)
    fm.copyItemAtPathToPathError(p, p + ".bak-meoteori-" + stamp, null)
  }
  $(JSON.stringify(d, null, 2)).writeToFileAtomicallyEncodingError(p, true, $.NSUTF8StringEncoding, null)
  return "    추가: " + added.join(", ") + (exists ? " (백업 남김)" : "")
}
JS

echo "3/3 로그인할 때 자동 실행"
PLIST="$HOME/Library/LaunchAgents/kr.lizzy.meoteori.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>kr.lizzy.meoteori</string>
<key>ProgramArguments</key><array><string>$APP/Contents/MacOS/Meoteori</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
PL
# 이미 떠 있는 머털이는 내리고 launchd 로 다시 띄운다 (두 마리 방지)
launchctl bootout "gui/$(id -u)/kr.lizzy.meoteori" 2>/dev/null || true
pkill -x Meoteori 2>/dev/null || true
sleep 0.5
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "    $PLIST"

echo "끝. 마지막으로 Codex에서 훅을 한 번 믿어 주세요:"
echo "    터미널에서 codex 를 열고 /hooks 를 입력해 머털이 훅(meoteori-inbox)을 신뢰(trust)"
echo "    Codex 앱을 쓰면 Cmd+Q 로 완전히 끄고 다시 열기 (앱은 켜질 때만 훅 설정을 읽음)"
echo "    그다음 새로 여는 Codex 채팅부터 머털이가 반응해요."
echo "끄기: 메뉴 막대 발바닥 → 종료 (다음 로그인 때 다시 켜짐)"
echo "자동 실행 해제: launchctl bootout gui/\$(id -u)/kr.lizzy.meoteori && rm \"$PLIST\""
