#!/bin/zsh
# 빌드한 머털이 다시 띄우기 (자동 실행에 등록돼 있으면 launchd 로, 아니면 그냥 열기)
if launchctl print "gui/$(id -u)/kr.lizzy.meoteori" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/kr.lizzy.meoteori"
else
  pkill -x Meoteori; sleep 0.5; open "$HOME/Applications/Meoteori.app"
fi
