#!/usr/bin/env bash
# /root/hrestart.sh v1 (2026-10-31) — 헤르메스 컨테이너 재시작(설정 반영용). 휴대폰 콘솔에서: bash /root/hrestart.sh
# 진행 중인 카드는 재시작으로 깨질 수 있어서 먼저 보여 주고 묻는다.
set -u
C="${HERMES_CONTAINER:-hermes-agent-bjmy-hermes-agent-1}"
docker exec -u hermes "$C" hermes kanban list 2>/dev/null | grep -i -E 'running|progress|claimed' | head -5
read -r -p "재시작할까요? 진행 중인 카드는 깨질 수 있어요 (y/N) " a
[ "$a" = y ] || { echo "취소 — 아무것도 바꾸지 않았어요"; exit 0; }
docker restart -t 20 "$C" >/dev/null 2>&1 || { echo "❌ 재시작 실패 — hPanel Docker 관리자에서 확인"; exit 1; }
for _ in $(seq 1 30); do docker exec "$C" true >/dev/null 2>&1 && break; sleep 2; done
if [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = "true" ]; then
  echo "■ 재시작 완료 — 1~2분 뒤 슬랙에서 비서실장에게 말을 걸어 확인하세요"; exit 0
fi
echo "❌ 컨테이너가 떠 있지 않아요 — hPanel Docker 관리자에서 확인"; exit 1
