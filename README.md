# 머털이 (데스크톱 펫)

<img src="poses/pose_sit1.png" width="160" alt="머털이">

Claude Code나 Codex가 일하는 중인지, 확인이 필요한지, 끝났는지를
화면 위 강아지 머털이와 작은 카드로 알려 주는 macOS 앱입니다.

## 받기

[Releases](../../releases/latest)에서 쓰는 도구에 맞는 묶음을 받습니다.

- `meoteori-claude-v*.zip`: Claude Code용
- `meoteori-codex-v*.zip`: Codex용

둘 다 쓰면 두 묶음의 설치를 모두 돌리면 됩니다. 앱은 하나라 양쪽 신호를 같이 받습니다.

## 설치

1. 압축을 풉니다.
2. 터미널에 `zsh `를 치고(한 칸 띄움), 묶음 안의 `설치.command`를 끌어다 놓고 엔터.
   더블클릭은 '확인되지 않은 개발자' 경고로 막힐 수 있어서 이 방법이 확실합니다.
3. Codex용이면 추가로 두 단계가 더 있습니다.
   - 터미널에서 `codex`를 열고 `/hooks`에서 머털이 훅을 신뢰(trust)합니다.
   - Codex 앱을 쓰면 `Cmd+Q`로 완전히 끄고 다시 엽니다. 앱은 켜질 때만 훅 설정을 읽습니다.

자세한 내용은 묶음 안의 `읽어보기.txt`에 있습니다.

## 설치가 하는 일

- 앱을 `~/Applications/Meoteori.app`에 복사
- 훅 추가: Claude는 `~/.claude/settings.json`, Codex는 `~/.codex/hooks.json`
  - 고치기 전에 백업을 남기고, 기존 훅은 그대로 둡니다.
- 로그인할 때 자동으로 켜지게 등록 (`~/Library/LaunchAgents/kr.lizzy.meoteori.plist`)

## 되는 곳

- Claude Code: 터미널, 데스크톱 앱 Code 탭, IDE
- Codex: 터미널, Codex 앱
- ChatGPT · Claude 일반 대화창은 안 됩니다. 상태를 밖으로 알려 주지 않아서입니다.
- Codex 권한이 '읽기 전용'이면 반응하지 않습니다. Codex는 훅도 샌드박스 안에서 돌려서, 읽기 전용이면 신호 파일을 못 씁니다.

## 쓰는 법

- 머털이 클릭: 하트
- 카드 클릭: 그 세션의 앱 열기
- 끌어서 화면 아무 데나 놓기 (놓은 자리를 기억함)
- 메뉴 막대 발바닥 아이콘: 숨기기 · 산책 끄기 · 미리보기 · 종료

## 끄기 · 지우기

```bash
launchctl bootout gui/$(id -u)/kr.lizzy.meoteori && rm ~/Library/LaunchAgents/kr.lizzy.meoteori.plist
```

## 소스에서 빌드

Xcode 명령줄 도구(`swiftc`)가 필요합니다. 없으면 `xcode-select --install`.

```bash
./build.sh            # ~/Applications/Meoteori.app 빌드
./package.sh          # Claude용 설치 묶음 → dist/
CODEX=1 ./package.sh  # Codex용 설치 묶음 → dist/
```

- `Sources/main.swift`: 앱 전체 (AppKit)
- `poses/`: 포즈 그림 (`pose_<이름><1~4>.png`)

필요: macOS 13 이상. 애플 칩 · 인텔 둘 다 됩니다.
