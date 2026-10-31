#!/usr/bin/env bash
# /root/eresume.sh v3.1 (2026-10-31: 컨테이너 이름 고정, hermes 명령은 -u hermes) — 재개. 게시 잠금(LOCK)은 일부러 그대로 둔다(따로 해제: rm /root/publisher/LOCK)
set -u
C="${HERMES_CONTAINER:-hermes-agent-bjmy-hermes-agent-1}"
CHECK_CMD="hermes status; hermes cron status"; CHECK_WORD="paused"
POLICY="${ESTOP_POLICY_FILE:-/root/.estop-restart-policy}"
in_c() { docker exec -u hermes "$C" "$@" >/dev/null 2>&1; }
up()   { for _ in $(seq 1 30); do in_c true && return 0; sleep 2; done; return 1; }

case "$C" in 여기에*) echo "❌ 컨테이너 이름을 먼저 고정하세요 (docker ps)"; exit 1;; esac

if [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" != "true" ]; then   # 강제 정지 뒤라면
  P=$(cat "$POLICY" 2>/dev/null); P=${P:-unless-stopped}
  docker update --restart="$P" "$C" >/dev/null 2>&1
  { docker start "$C" >/dev/null 2>&1 && up; } || { echo "❌ 컨테이너 시작 실패 — hPanel Docker 관리자에서 확인"; exit 1; }
  echo "✅ 컨테이너 다시 시작 (재시작 정책: $P)"
fi
in_c hermes resume || { echo "❌ hermes resume 실패"; exit 1; }
if docker exec -u hermes "$C" sh -c "$CHECK_CMD" 2>/dev/null | grep -qi "$CHECK_WORD"; then
  echo "❌ 정지 표시가 아직 남아 있음 — hermes status 확인"; exit 1
fi
echo "■ 재개 완료 — 멈춘 동안 밀린 근무표는 한 번씩 돈다. 게시 잠금 해제는 따로: rm /root/publisher/LOCK"
