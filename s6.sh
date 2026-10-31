#!/bin/sh
# s6.sh - 2026-10-31 비상정지 v3.1 설치·시험 (VPS 호스트, root)
# 시험 중 컨테이너가 한 번 재시작된다 → 진행 중인 카드가 없을 때 실행한다.
# 1) /root/estop.sh · /root/eresume.sh 설치 (지문 고정)  2) 정지 표시 문구 확인(pause → 확인 → resume)
# 3) 비상정지 시험(소프트) → 재개  4) 실패 경로 시험(틀린 이름 → ❌ + 종료 코드 1)
C=hermes-agent-bjmy-hermes-agent-1
B=https://github.com/aigents-ai/card-templates/raw/s1/host
SE=7baccc75384995fc212abf5dd47873ea7b59f2883506deca6fe9fbe34b87d711
SR=5557bd17896086faad1620447798bb92be702f0c3ef3f2869d5f4f8f8acfa92a
H="docker exec -u hermes $C"

echo "== 0 진행 중인 카드"
$H hermes kanban list 2>/dev/null | grep -i -E 'running|progress|claimed' | head -5
printf '진행 중인 카드가 없으면 y (y/N) '
read -r a
[ "$a" = y ] || { echo "중단 — 아무것도 바꾸지 않았어요"; exit 0; }

echo "== 1 설치"
curl -sL "$B/estop.sh" -o /root/estop.sh.new && curl -sL "$B/eresume.sh" -o /root/eresume.sh.new || { echo "STOP: 받기 실패"; exit 1; }
{ echo "$SE  /root/estop.sh.new" | sha256sum -c --quiet && echo "$SR  /root/eresume.sh.new" | sha256sum -c --quiet; } || { echo "STOP: 지문 불일치 — 설치 안 함"; rm -f /root/estop.sh.new /root/eresume.sh.new; exit 1; }
mv /root/estop.sh.new /root/estop.sh && mv /root/eresume.sh.new /root/eresume.sh && chmod 700 /root/estop.sh /root/eresume.sh
ls -l /root/estop.sh /root/eresume.sh | cut -c1-80

echo "== 2 정지 표시 확인"
$H hermes pause --reason s6-probe >/dev/null 2>&1 || $H hermes pause >/dev/null 2>&1 || { echo "STOP: hermes pause 실패"; exit 1; }
out=$($H sh -c 'hermes status; hermes cron status' 2>&1)
echo "$out" | grep -i -E 'paus|정지' | head -3 | cut -c1-90
$H hermes resume >/dev/null 2>&1 || { echo "STOP: hermes resume 실패 — bash /root/eresume.sh 를 치세요"; exit 1; }
echo "$out" | grep -qi paused || { echo "STOP: 멈춘 상태에서 'paused' 문구가 안 보여요 — 이 화면을 보내 주세요"; exit 1; }
$H sh -c 'hermes status; hermes cron status' 2>&1 | grep -qi paused && { echo "STOP: 재개한 뒤에도 'paused'가 보여요(문구가 애매함) — 이 화면을 보내 주세요"; exit 1; }
echo "✅ 정지 표시 확인, 재개 정상"

echo "== 3 비상정지 시험 (소프트, 컨테이너 재시작 포함 1~2분)"
bash /root/estop.sh; echo "estop 종료 코드 $? (0이 정상)"
echo "== 4 재개"
bash /root/eresume.sh; echo "eresume 종료 코드 $? (0이 정상)"

echo "== 5 실패 경로 (❌ 표시 + 종료 코드 1이 정상)"
HERMES_CONTAINER=no-such-container ESTOP_POLICY_FILE=/tmp/s6-policy ESTOP_LOCK=/tmp/s6-lock bash /root/estop.sh; echo "종료 코드 $?"
rm -f /tmp/s6-policy /tmp/s6-lock /root/publisher/LOCK
echo "== done (시험으로 만든 게시 잠금 파일은 지웠어요)"
