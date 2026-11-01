#!/bin/sh
# /root/r0-run.sh v1 (2026-11-01) — 트레이딩 연구소 R0 하루 실행. 호스트 cron 이 부른다(AI 없음 · root).
# 사용: r0-run.sh us|crypto
#  1) 컨테이너가 멈췄거나 비상정지(hermes pause) 중이면 건너뜀
#  2) 실행기를 돌림(최대 90분) — 빠진 날도 종목마다 2개까지 채운다
#  3) 결과 요약을 비서실장 우편함(/opt/data/work/trading-lab/inbox)에 남김 → 근무표 trading-r0-report 가 #40 에 올림
# 기록: /root/r0-run.log (전체 출력)
set -u
PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"  # cron 의 짧은 PATH 에도 docker 가 잡히게
G="${1:-}"
case "$G" in us|crypto) ;; *) echo "사용: r0-run.sh us|crypto"; exit 2;; esac
C="${HERMES_CONTAINER:-hermes-agent-bjmy-hermes-agent-1}"
L="${R0_LAB:-/opt/data/trading-lab}"
W="${R0_WORK:-/opt/data/work/trading-lab}"
S="${R0_SCRIPTS:-/opt/data/scripts}"
LOG="${R0_LOG:-/root/r0-run.log}"
ts() { date '+%F %T %z'; }
note() { echo "$(ts) [$G] $*" >> "$LOG"; }

if [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" != true ]; then note "건너뜀: 컨테이너가 멈춰 있음"; exit 0; fi
if timeout 60 docker exec -u hermes "$C" sh -c 'hermes status; hermes cron status' 2>/dev/null | grep -qi paused; then
  note "건너뜀: 비상정지(일시정지) 중"; exit 0
fi

STAMP=$(date +%Y%m%d-%H%M%S)
SUM="$W/inbox/$STAMP-$G.json"
note "시작"
OUT=$(docker exec -u hermes "$C" sh -c "cd $L && timeout 5400 venv/bin/python $S/trading_r0.py --group $G --summary-file $SUM" 2>&1)
RC=$?
{ note "끝: 결과 코드 $RC"; printf '%s\n' "$OUT"; } >> "$LOG"

# 실행기가 요약을 남기지 못했으면(시간 초과·충돌) 대신 한 줄 남겨 보고가 빠지지 않게 한다
if ! docker exec -u hermes "$C" test -s "$SUM"; then
  printf '%s\n' "$OUT" | tail -5 | docker exec -i -u hermes "$C" python3 -c '
import json, os, sys
path, group, rc = sys.argv[1:4]
tail = [l.rstrip() for l in sys.stdin if l.strip()]
os.makedirs(os.path.dirname(path), exist_ok=True)
d = {"group": group, "rc": int(rc), "results": [], "notes": ["실행기가 요약을 남기지 못했어요(시간 초과·충돌) — 호스트 /root/r0-run.log 확인"] + tail[-3:]}
open(path + ".tmp", "w", encoding="utf-8").write(json.dumps(d, ensure_ascii=False, indent=1))
os.replace(path + ".tmp", path)
' "$SUM" "$G" "$RC" || note "우편함 기록 실패"
fi
exit 0
