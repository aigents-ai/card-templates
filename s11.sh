#!/bin/sh
# s11.sh v2 - 2026-11-01 트레이딩 연구소 R0 매일 자동 실행 (VPS 호스트, root)
#  1) 파일 3개 받기·지문 확인(실행기 v2.3 · 우편함 스크립트 · 하루 실행기)
#  2) FRED 키(거시 지표 · 무료 · 선택 — 가려진 입력, 저장 전에 FRED 에 확인) → trading-lab/.env 에 한 줄 추가
#  3) 점검(봉인 폴더 밖 사본으로)  4) scripts 에 넣고 봉인(y)  5) /root/r0-run.sh 설치
#  6) cron 등록(미국 주식 화~토 06:45 · BTC 매일 09:10, 한국 시각)
#  7) 첫 R0 실행: BTC 하루치를 지금 백그라운드로 — 끝나면 비서실장 근무표가 #40 에 올린다
# 다시 돌려도 된다: 저장된 FRED 키는 엔터로 그대로 쓰고, 봉인돼 있으면 건너뛰고, cron 은 같은 줄을 지우고 다시 넣는다.
C="${HERMES_CONTAINER:-hermes-agent-bjmy-hermes-agent-1}"
B="${S11_BASE:-https://github.com/aigents-ai/card-templates/raw/s1}"
L="${S11_LAB:-/opt/data/trading-lab}"
S="${S11_SCRIPTS:-/opt/data/scripts}"
T="${S11_TMP:-/root/s11.tmp}"
SEAL="${S11_SEAL:-/root/seal.sh}"
RUN="${S11_RUN:-/root/r0-run.sh}"
H="docker exec -u hermes $C"
trap 'stty echo 2>/dev/null' EXIT
trap 'stty echo 2>/dev/null; echo; echo "중단했어요 — 다시 하려면 sh s11.sh"; exit 130' INT TERM

drain() { [ -t 0 ] || return 0; stty -icanon min 0 time 0 2>/dev/null; dd bs=4096 count=64 >/dev/null 2>&1; stty icanon 2>/dev/null; }

# 이 파일들이 지금 내용 그대로 봉인됐는지(seal.sh 와 같은 방법)
sealed_ok() {
  docker exec -i -u hermes "$C" python3 -B - "$S" "$@" >/dev/null 2>&1 <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import watch
names = set(sys.argv[2:])
sealed = {}
if watch.SEAL.exists():
    for line in watch.SEAL.read_text(encoding="utf-8").splitlines():
        if "  " in line:
            h, p = line.split("  ", 1)
            sealed[p] = h
now = watch.digest()
mine = [p for p in now if p.rsplit("/", 1)[-1] in names]
sys.exit(0 if len(mine) == len(names) and all(sealed.get(p) == now[p] for p in mine) else 1)
PY
}

printf '트레이딩 R0를 매일 자동으로 돌리도록 등록하고, FRED 키를 넣고, BTC 첫 기록을 지금 1회 만들어요(구독 사용량을 조금 써요). 진행할까요? (y/N) '
read -r a
[ "$a" = y ] || { echo "취소 — 아무것도 바꾸지 않았어요"; exit 0; }

echo "== 1 받기·지문 확인"
mkdir -p "$T" && chmod 700 "$T"
get() {
  curl -sfL "$B/$1" -o "$T/${1##*/}" || { echo "STOP: $1 받기 실패"; exit 1; }
  echo "$2  $T/${1##*/}" | sha256sum -c --quiet || { echo "STOP: $1 지문 불일치 — 설치 안 함"; exit 1; }
}
get trading/trading_r0.py bfe7d386ff82f4a39ab6c5b8699997d33c0f8aad14d0cda4396fc13ee389e350
get trading/trading_r0_inbox.py a682f205a541f25387eaa66bdc50feff43ce0a12e388fa1452770b540d77024f
get host/r0-run.sh 66d4fb1acedadf615ba30abeeab0b4be017d14b67a3fce45100b57e8b51101c9
echo "파일 3개 확인"
$H test -x "$L/venv/bin/python" || { echo "STOP: 트레이딩 연구소가 설치돼 있지 않아요 — s10 을 먼저"; exit 1; }
for f in trading_r0.py trading_r0_inbox.py; do
  docker cp "$T/$f" "$C:$L/staging/$f" >/dev/null || { echo "STOP: $f 복사 실패"; exit 1; }
done
docker exec "$C" chmod 644 "$L/staging/trading_r0.py" "$L/staging/trading_r0_inbox.py"

echo "== 2 FRED 키 (거시 지표 · 무료 · 선택)"
HAVE=n
$H grep -q '^FRED_API_KEY=.' "$L/.env" 2>/dev/null && HAVE=y
# FRED 없이 넘어갈 때의 안내: 저장된 키가 있으면 그 키를 계속 쓴다
if [ $HAVE = y ]; then NOFRED="저장된 FRED 키를 그대로 써요"; else NOFRED="거시 지표 없이 돌아요(나중에 sh s11.sh 로 넣을 수 있어요)"; fi
ASK=y
if [ $HAVE = y ]; then
  drain
  printf '저장된 FRED 키가 있어요. 그대로 쓰려면 엔터, 새로 넣으려면 n: '
  read -r a
  [ "$a" = n ] || ASK=n
fi
n=0
while [ $ASK = y ]; do
  n=$((n + 1))
  drain  # 앞에서 더 눌린 엔터가 '건너뛰기'로 읽히지 않게
  printf 'FRED 키를 붙여 넣고 엔터 (화면에 안 보여요 · 건너뛰려면 그냥 엔터): '
  stty -echo 2>/dev/null; read -r K; stty echo 2>/dev/null; echo
  K=$(printf '%s' "$K" | tr -d ' \r\n\t')
  if [ -z "$K" ]; then echo "건너뜀 — $NOFRED"; break; fi
  # 키는 표준 입력으로만 넘긴다(명령줄·파일에 남지 않게). 확인 결과 줄에는 끝 4자만 나온다
  OUT=$(printf '%s\n' "$K" | docker exec -i -u hermes "$C" sh -c "cd $L && venv/bin/python $L/staging/trading_r0.py --fred-test" 2>&1); rc=$?
  printf '%s\n' "$OUT" | tail -1
  case $rc in
    0|4)
      if printf 'FRED_API_KEY=%s\n' "$K" | docker exec -i -u hermes "$C" sh -c "umask 077; { grep -v '^FRED_API_KEY=' $L/.env 2>/dev/null; cat; } > $L/.env.new && chmod 600 $L/.env.new && mv $L/.env.new $L/.env || { rm -f $L/.env.new; exit 1; }"; then
        [ $rc -eq 4 ] && echo "(FRED 에 닿지 않아 확인은 못 했지만 모양이 맞아서 저장했어요 — 실행 때 다시 시도해요)"
        echo "저장: trading-lab/.env 에 FRED 키 (600 · 예비 키 줄은 그대로)"
      else
        echo "⚠️ FRED 키를 저장하지 못했어요 — $NOFRED. 이 화면을 보내 주세요"
      fi
      break;;
    3|5) [ $n -lt 3 ] && echo "다시 붙여 넣어 주세요 — FRED 사이트 API Keys 화면에서 키만 복사";;
    *) echo "키 확인이 돌지 않았어요(코드 $rc) — $NOFRED"; break;;
  esac
  [ $n -lt 3 ] || { echo "세 번 다 안 됐어요 — $NOFRED"; break; }
done
K=; unset K

echo "== 3 점검 (봉인 폴더 밖 사본으로)"
$H sh -c "cd $L && TRADING_CONFIG=$S/trading_r0.json TRADING_PDF_JS=$S/trading_r0_pdf.js venv/bin/python $L/staging/trading_r0.py --check" > "$T/check.out" 2>&1; rc=$?
grep -v -E '^(Cookie|Failed to get ticker)' "$T/check.out"
[ $rc -eq 0 ] || { echo "STOP: 점검 실패 — ❌ 줄을 보내 주세요(봉인 폴더는 그대로예요)"; exit 1; }
OUT=$($H sh -c "d=\$(mktemp -d) && TRADING_WORK_DIR=\$d python3 $L/staging/trading_r0_inbox.py; r=\$?; rm -rf \$d; exit \$r"); rc=$?
{ [ $rc -eq 0 ] && [ -z "$OUT" ]; } || { echo "STOP: 우편함 스크립트 시험 실패 — $OUT"; exit 1; }
echo "우편함 스크립트: 빈 우편함이면 조용함(비서실장을 깨우지 않음) — 확인"

echo "== 4 scripts 에 넣고 봉인"
for f in trading_r0.py trading_r0_inbox.py; do
  docker cp "$T/$f" "$C:$S/$f" >/dev/null || { echo "STOP: $f 복사 실패"; exit 1; }
done
docker exec "$C" chmod 644 "$S/trading_r0.py" "$S/trading_r0_inbox.py"
if sealed_ok trading_r0.py trading_r0_inbox.py; then
  echo "이미 지금 내용으로 봉인돼 있어요"
elif [ -f "$SEAL" ]; then
  echo "trading_r0.py(바뀜)·trading_r0_inbox.py(새 파일)와 아는 변경만 보이면 y"
  drain
  bash "$SEAL"
  sealed_ok trading_r0.py trading_r0_inbox.py || { echo "STOP: 봉인되지 않아 등록은 하지 않았어요 — 목록이 이상하면 화면을 보내 주시고, 괜찮으면 sh s11.sh 다시"; exit 1; }
else
  echo "STOP: 봉인 도구(/root/seal.sh)가 없어요 — s8 을 먼저 하세요"; exit 1
fi

echo "== 5 하루 실행기 설치"
install -m 700 "$T/r0-run.sh" "$RUN" || { echo "STOP: $RUN 설치 실패"; exit 1; }
echo "설치: $RUN (호스트에서 AI 없이 돌고, 비상정지 중이면 건너뛰어요)"

echo "== 6 cron 등록"
case "$(date +%z)" in
  +0000) US="45 21 * * 1-5"; CR="10 0 * * *"; TZN="UTC";;
  +0900) US="45 6 * * 2-6"; CR="10 9 * * *"; TZN="한국";;
  *) echo "STOP: 서버 시간대가 예상과 달라요($(date +%z)) — 이 화면을 보내 주세요"; exit 1;;
esac
{ crontab -l 2>/dev/null | grep -v 'r0-run.sh'; echo "$US $RUN us  # trading-r0: 미국 주식, 한국 화~토 06:45"; echo "$CR $RUN crypto  # trading-r0: BTC, 한국 매일 09:10"; } | crontab - || { echo "STOP: cron 등록 실패"; exit 1; }
echo "서버 시간대: $TZN — 등록된 줄:"
crontab -l | grep 'r0-run.sh'
if pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1; then echo "cron 동작 중"; else echo "⚠️ cron 이 돌고 있지 않아요 — 이 화면을 보내 주세요"; fi

echo "== 7 첫 R0 실행: BTC 하루치 (지금, 백그라운드)"
nohup "$RUN" crypto >/dev/null 2>&1 &
sleep 5
tail -1 "${R0_LOG:-/root/r0-run.log}" 2>/dev/null
echo "보통 3~5분 걸려요. 확인: tail -3 /root/r0-run.log  또는  sh s10.sh status"
echo "끝나면 #01-지시에서 비서실장에게 근무표 trading-r0-report 등록을 부탁하세요(안내 메시지 참고)."
