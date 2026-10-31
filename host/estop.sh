#!/usr/bin/env bash
# /root/estop.sh v3.1 (2026-10-31: 컨테이너 이름 고정, hermes 명령은 -u hermes) — 휴대폰 hPanel 브라우저 터미널에서: bash /root/estop.sh   (바로 강제 정지: bash /root/estop.sh hard)
# 순서: ① 게시 잠금 → ② 새 실행 차단 → ③ 진행 중 작업 종료 → ④ 정지 상태 확인 → ⑤ 결과 보고
# 소프트 정지가 한 단계라도 실패하면 강제 정지(컨테이너 중지)로 넘어간다.
# 종료 코드: 0 정지 확인 · 2 강제 정지로 멈춤 · 1 정지 확인 실패(→ hPanel에서 VPS 중지)
set -u
C="${HERMES_CONTAINER:-hermes-agent-bjmy-hermes-agent-1}"         # docker ps 로 확인해 고정
CHECK_CMD="hermes status; hermes cron status"        # 리허설에서 정지 표시가 나오는 명령·문구를 확인해 고정
CHECK_WORD="paused"
LOCK="${ESTOP_LOCK:-/root/publisher/LOCK}"
POLICY="${ESTOP_POLICY_FILE:-/root/.estop-restart-policy}"
R="대표 비상정지 $(date '+%m-%d %H:%M')"
FAIL=""

ok()  { echo "✅ $1"; }
bad() { echo "❌ $1"; FAIL="$FAIL $1"; }
in_c()    { docker exec -u hermes "$C" "$@" >/dev/null 2>&1; }
paused()  { docker exec -u hermes "$C" sh -c "$CHECK_CMD" 2>/dev/null | grep -qi "$CHECK_WORD"; }
pause_c() { in_c hermes pause --reason "$R" || in_c hermes pause; }   # --reason 이 없는 버전 대비
up()      { for _ in $(seq 1 30); do in_c true && return 0; sleep 2; done; return 1; }

case "$C" in 여기에*) echo "❌ 컨테이너 이름을 먼저 고정하세요 (docker ps)"; exit 1;; esac

{ mkdir -p "$(dirname "$LOCK")" && touch "$LOCK" && [ -f "$LOCK" ]; } && ok "① 게시 잠금" || bad "①게시잠금"
if [ "${1:-}" != hard ]; then
  pause_c && ok "② 새 실행 차단 (pause)" || bad "②새실행차단"
  { docker restart -t 10 "$C" >/dev/null 2>&1 && up; } && ok "③ 진행 중 작업 종료 (재시작)" || bad "③작업종료"
  { pause_c && paused; } && ok "④ 정지 상태 확인" || bad "④정지확인"     # 재시작 뒤 pause 재적용 후 확인
  if [ -z "$FAIL" ]; then
    echo "■ 비상정지 완료 — 재개: bash /root/eresume.sh (게시 잠금은 따로 해제)"; exit 0
  fi
  echo "■ 소프트 정지 실패:$FAIL → 강제 정지로 전환"
fi

# 강제 정지: 재시작 정책을 기록해 두고 끈 뒤 컨테이너를 멈춘다 (Slack·대시보드 포함 전부 멈춤)
docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$C" > "$POLICY" 2>/dev/null
docker update --restart=no "$C" >/dev/null 2>&1
docker stop -t 20 "$C" >/dev/null 2>&1
if [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "false" ]; then
  echo "■ 강제 정지 완료 (컨테이너 중지) — 재개: bash /root/eresume.sh"; exit 2
fi
echo "■ 정지 확인 실패 — hPanel에서 VPS를 중지하세요"; exit 1
