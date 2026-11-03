#!/bin/sh
# s13.sh - 2026-11-03 Tailscale 연결 + 대시보드 준비 점검 (VPS 호스트, root)
#  1) Tailscale 설치: 공식 apt 저장소(서명 확인). 저장소 줄은 이 스크립트가 직접 쓴다.
#  2) 이 서버를 대표의 Tailscale 계정에 연결: 화면에 나온 로그인 주소를 휴대폰 브라우저로 연다(비밀값 입력 없음).
#     서버 DNS는 그대로 둔다(--accept-dns=false). 출구 노드·경로 공유·Tailscale SSH는 켜지 않는다.
#  3) 대시보드 준비 점검: 읽기만 한다. 컨테이너·Hermes 설정은 하나도 바꾸지 않는다.
#     결과를 Claude에게 보여 주면 대시보드를 켜는 다음 설치기(s14)를 만든다.
set -u
C="${HERMES_CONTAINER:-hermes-agent-bjmy-hermes-agent-1}"
HN="${TS_HOSTNAME:-aigents-vps}"
K=/usr/share/keyrings/tailscale-archive-keyring.gpg
L=/etc/apt/sources.list.d/tailscale.list

[ "$(id -u)" = 0 ] || { echo "STOP: root 로 실행하세요"; exit 1; }

echo "== 1 Tailscale 설치"
if command -v tailscale >/dev/null 2>&1; then
  echo "이미 설치됨: $(tailscale version 2>/dev/null | head -1)"
else
  [ -r /etc/os-release ] || { echo "STOP: OS 정보를 못 읽었어요"; exit 1; }
  . /etc/os-release
  case "${ID:-}" in ubuntu|debian) ;; *) echo "STOP: 이 설치기가 모르는 OS예요(${ID:-?})"; exit 1;; esac
  CN="${VERSION_CODENAME:-}"
  case "$CN" in ''|*[!a-z]*) echo "STOP: OS 코드네임이 이상해요('$CN')"; exit 1;; esac
  curl -fsSL --max-time 60 "https://pkgs.tailscale.com/stable/$ID/$CN.noarmor.gpg" -o "$K.new" \
    || { rm -f "$K.new"; echo "STOP: Tailscale 서명 키를 못 받았어요(네트워크 또는 지원하지 않는 OS 버전 $ID $CN)"; exit 1; }
  [ -s "$K.new" ] || { rm -f "$K.new"; echo "STOP: 받은 서명 키가 비어 있어요"; exit 1; }
  mv "$K.new" "$K" && chmod 644 "$K"
  echo "deb [signed-by=$K] https://pkgs.tailscale.com/stable/$ID $CN main" > "$L"
  # Tailscale 저장소만 새로 읽는다(다른 저장소 문제로 멈추지 않게)
  if ! apt-get update -qq -o Dir::Etc::sourcelist=sources.list.d/tailscale.list -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 >/tmp/s13-apt.log 2>&1; then
    tail -3 /tmp/s13-apt.log; rm -f "$L" "$K"
    echo "STOP: Tailscale 저장소를 읽지 못했어요(서명 확인 실패일 수 있어요). 넣었던 저장소 줄은 지웠어요"; exit 1
  fi
  # NEEDRESTART_SUSPEND: 설치 뒤 다른 서비스(ssh·containerd 등)가 자동 재시작되지 않게
  if ! DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get install -y -qq tailscale </dev/null >>/tmp/s13-apt.log 2>&1; then
    tail -3 /tmp/s13-apt.log; echo "STOP: 설치 실패"; exit 1
  fi
  command -v tailscale >/dev/null 2>&1 || { echo "STOP: 설치했는데 tailscale 명령이 없어요"; exit 1; }
  echo "설치: $(tailscale version 2>/dev/null | head -1)"
fi
systemctl enable --now tailscaled >/dev/null 2>&1
if ! systemctl is-active --quiet tailscaled; then
  journalctl -u tailscaled -n 5 --no-pager 2>/dev/null | cut -c1-120
  echo "STOP: tailscaled 가 켜지지 않았어요 — 이 화면을 Claude에게 보여 주세요"; exit 1
fi

echo "== 2 이 서버를 Tailscale 계정에 연결"
# status 는 연결(Running·Starting)일 때만 0 — ip -4 는 끊긴 뒤에도 옛 주소를 보여 줘서 따로 본다
IP4=$(tailscale status >/dev/null 2>&1 && tailscale ip -4 2>/dev/null | head -1)
if [ -n "$IP4" ]; then
  echo "이미 연결됨"
else
  echo "곧 'https://login.tailscale.com/a/...' 주소가 나와요."
  echo "휴대폰 브라우저 주소창에 그 주소를 그대로 쳐서 열고,"
  echo "Tailscale 앱에 가입한 그 계정으로 로그인한 뒤 Connect 를 누르세요."
  echo "(최대 15분 기다려요. 끊기면 sh s13.sh 를 다시 실행하면 돼요)"
  tailscale up --hostname="$HN" --accept-dns=false --timeout=15m \
    || { echo "STOP: 연결이 끝나지 않았어요 — sh s13.sh 를 다시 실행하세요"; exit 1; }
  IP4=$(tailscale status >/dev/null 2>&1 && tailscale ip -4 2>/dev/null | head -1)
  [ -n "$IP4" ] || { echo "STOP: 연결은 됐다는데 주소가 없어요 — sh s13.sh 를 다시 실행하세요"; exit 1; }
fi
NAME=$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Self",{}).get("DNSName","").rstrip("."))' 2>/dev/null)
echo "서버 Tailscale 주소: $IP4 ${NAME:+($NAME)}"

echo "== 3 대시보드 준비 점검 (읽기만)"
docker inspect "$C" >/dev/null 2>&1 || { echo "STOP: 컨테이너 $C 를 못 찾았어요"; exit 1; }
echo "- Hermes: $(docker exec -u hermes "$C" timeout 20 hermes --version 2>&1 | head -1)"
if docker exec -u hermes "$C" sh -c 'timeout 20 hermes dashboard --help >/dev/null 2>&1'; then
  echo "- dashboard 명령: 있음"
  docker exec -u hermes "$C" sh -c 'timeout 20 hermes dashboard --help 2>&1' | grep -E -- '--(host|port|no-open)' | head -6 | cut -c1-90
else
  echo "- dashboard 명령: 없음(이 버전에는 없어요)"
fi
echo "- 컨테이너 환경의 대시보드 변수: $(docker exec "$C" sh -c 'env | grep -o "^HERMES_DASHBOARD[A-Z_]*" | sort | tr "\n" " "')"
echo "- 대시보드 서비스 폴더: $(docker exec "$C" sh -c 'for d in /etc/s6-overlay/s6-rc.d /etc/services.d /run/service /etc/s6; do ls -d "$d"/*dash* 2>/dev/null; done | tr "\n" " "')"
echo "- 9119 포트(컨테이너 안): $(docker exec "$C" python3 -c 'import socket; s=socket.socket(); s.settimeout(1); print("열려 있음" if s.connect_ex(("127.0.0.1",9119))==0 else "닫혀 있음")' 2>&1)"
echo "- 인증 설정 코드: $(docker exec "$C" sh -c 'timeout 60 grep -rl --include=*.py --exclude-dir=node_modules --exclude-dir=tools --exclude-dir=.git -e HERMES_DASHBOARD_BASIC_AUTH -e trusted_proxies /opt/hermes 2>/dev/null | head -3 | tr "\n" " "')"
echo "- 컨테이너 네트워크: $(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} {{end}}' "$C")"
echo "- 열린 포트: $(docker port "$C" 2>/dev/null | tr "\n" " ")"
echo "- compose 폴더: $(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$C" 2>/dev/null)"
echo "- 호스트 OS: $(. /etc/os-release; echo "${PRETTY_NAME:-?}") · socat: $(command -v socat >/dev/null 2>&1 && echo 있음 || echo 없음)"
echo "== done — 이 화면을 Claude에게 보여 주세요"
