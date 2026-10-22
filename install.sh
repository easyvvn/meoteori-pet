#!/bin/zsh
# 머털이 설치 (맥마다 한 번). 여러 번 돌려도 안전하다.
# 1) 앱 빌드(묶음이면 복사) → ~/Applications/Meoteori.app
# 2) Claude Code 훅 추가 → ~/.claude/settings.json (이미 있으면 건너뜀, 고치기 전 백업)
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

echo "2/3 Claude Code 훅"
mkdir -p "$HOME/.claude" "$HOME/.meoteori/inbox"
# python3 은 새 맥에서 Xcode 도구 설치 창을 띄우므로, macOS 기본 JavaScript(osascript)로 JSON 을 고친다
osascript -l JavaScript - "$HOME/.claude/settings.json" <<'JS'
ObjC.import('Foundation')
function run(argv) {
  const p = argv[0], fm = $.NSFileManager.defaultManager
  const exists = fm.fileExistsAtPath(p)
  const d = exists ? JSON.parse(ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(p, $.NSUTF8StringEncoding, null))) : {}
  const cmd = 'mkdir -p "$HOME/.meoteori/inbox" && cat > "$HOME/.meoteori/inbox/$(date +%s)-$$-$RANDOM.json" 2>/dev/null; exit 0'
  const hooks = d.hooks || (d.hooks = {}), added = []
  for (const [ev, matcher] of [["UserPromptSubmit"], ["PreToolUse", "*"], ["PostToolUse", "*"], ["PostToolUseFailure", "*"],
                               ["PermissionRequest", "*"], ["Notification"], ["Stop"], ["SessionEnd"]]) {
    const groups = hooks[ev] || (hooks[ev] = [])
    if (groups.some(g => (g.hooks || []).some(h => (h.command || "").includes(".meoteori/inbox")))) continue
    const g = matcher ? { matcher, hooks: [] } : { hooks: [] }
    g.hooks.push({ type: "command", command: cmd, timeout: 5 })
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

echo "끝. 새로 여는 Claude Code 세션부터 머털이가 반응해요."
echo "끄기: 메뉴 막대 발바닥 → 종료 (다음 로그인 때 다시 켜짐)"
echo "자동 실행 해제: launchctl bootout gui/\$(id -u)/kr.lizzy.meoteori && rm \"$PLIST\""
