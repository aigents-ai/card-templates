#!/bin/sh
# s10.sh - 2026-11-01 트레이딩 연구소 R0 설치 + 시험 1회 (VPS 호스트, root)
#  1) 파일 4개 받기·지문 확인  2) 컨테이너 파이썬·폴더  3) 가상환경 + 해시 고정 설치(TradingAgents 0.7.1, 처음 2~5분)
#  4) OpenRouter 새 키(가려짐) → trading-lab/.env (600)  5) 점검(돈 안 씀 · 봉인 폴더 밖 사본으로)
#  6) 실행기·설정·PDF 변환기 → /opt/data/scripts + 봉인(새 파일 확인 후 y)  7) 시험 1회(BTC-USD) 백그라운드 시작
# 다시 돌려도 된다: 설치된 것은 건너뛰고, 저장된 키는 그대로 쓸지 묻고, 성공 기록이 있는 날짜는 다시 돌리지 않는다.
# 봉인 폴더는 점검이 통과한 뒤에만 바꾸고, 봉인을 거절하면 시험은 시작하지 않는다.
# 진행 확인: sh s10.sh status
C="${HERMES_CONTAINER:-hermes-agent-bjmy-hermes-agent-1}"
B="${S10_BASE:-https://github.com/aigents-ai/card-templates/raw/s1/trading}"
L="${S10_LAB:-/opt/data/trading-lab}"
W="${S10_WORK:-/opt/data/work/trading-lab}"
S="${S10_SCRIPTS:-/opt/data/scripts}"
T="${S10_TMP:-/root/s10.tmp}"
SEAL="${S10_SEAL:-/root/seal.sh}"
ASK="${S10_ASKENV:-/opt/data/profiles/insta-ai/ask.env}"
H="docker exec -u hermes $C"
FILES="trading_r0.py trading_r0.json trading_r0_pdf.js"
trap 'stty echo 2>/dev/null' EXIT
trap 'stty echo 2>/dev/null; echo; echo "중단했어요 — 다시 하려면 sh s10.sh"; exit 130' INT TERM

# 실행기가 지금 도는지: 실행기가 쥐는 잠금 파일을 잠가 본다(컨테이너에 flock·pgrep 이 없어도 됨)
locked() {
  $H test -x "$L/venv/bin/python" || return 1
  docker exec -i -u hermes "$C" "$L/venv/bin/python" - "$L/run.lock" >/dev/null 2>&1 <<'PY'
import fcntl, sys
f = open(sys.argv[1], "a")
try:
    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(0)
sys.exit(1)
PY
}

# 우리 파일 세 개가 지금 내용 그대로 봉인됐는지: seal.sh 와 같은 방법(watch 의 함수)으로 본다
sealed_ok() {
  docker exec -i -u hermes "$C" python3 -B - "$S" >/dev/null 2>&1 <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import watch
sealed = {}
if watch.SEAL.exists():
    for line in watch.SEAL.read_text(encoding="utf-8").splitlines():
        if "  " in line:
            h, p = line.split("  ", 1)
            sealed[p] = h
now = watch.digest()
mine = [p for p in now if p.rsplit("/", 1)[-1] in ("trading_r0.py", "trading_r0.json", "trading_r0_pdf.js")]
sys.exit(0 if len(mine) == 3 and all(sealed.get(p) == now[p] for p in mine) else 1)
PY
}

if [ "${1:-}" = status ]; then
  if locked; then RUN=1; else RUN=0; fi
  docker exec -i -u hermes "$C" python3 - "$W" "$RUN" <<'PY'
import glob, json, os, sys
from datetime import datetime, timezone
w, running = sys.argv[1], sys.argv[2] == "1"
fs = glob.glob(os.path.join(w, "records", "*", "*.json")) + glob.glob(os.path.join(w, "tests", "records", "*", "*.json"))
fs.sort(key=os.path.getmtime)
if not fs:
    print("⏳ 도는 중 — 아직 기록 전" if running else "기록 없음 — 아직 시작 전이에요")
    raise SystemExit
d = json.load(open(fs[-1], encoding="utf-8"))
head = f"{'시험 ' if d.get('kind') == 'test' else ''}{d['ticker']} {d['trade_date']}"
if d["status"] == "running":
    age = int((datetime.now(timezone.utc) - datetime.fromisoformat(d["started_at"])).total_seconds() / 60)
    print(f"⏳ {head}: 도는 중 ({age}분째)" if running else f"⚠️ {head}: '도는 중'으로 남았는데 실행기는 멈춰 있어요 — 중간에 끊긴 것 같아요")
elif d["status"] == "ok":
    m, s = divmod(d.get("duration_s") or 0, 60)
    cost = "비용 모름" if d.get("cost_usd") is None else f"${d['cost_usd']:.2f}"
    print(f"✅ {head}: {d['rating']} · {cost} · {m}분 {s}초 · AI 호출 {d.get('llm_calls')}회 · 자료 호출 {d.get('tool_calls')}회")
    print(f"   보고서: {d.get('pdf') or d.get('report')}")
else:
    print(f"❌ {head}: 실패 — {d.get('error')}")
PY
  $H sh -c "grep -v -E '^(Cookie|Failed to get ticker)' $L/logs/test-run.out 2>/dev/null | tail -2"
  exit 0
fi

printf '트레이딩 연구소 R0를 설치하고 BTC 시험을 1회 돌려요(돈은 시험 1회분만 써요). 진행할까요? (y/N) '
read -r a
[ "$a" = y ] || { echo "취소 — 아무것도 바꾸지 않았어요"; exit 0; }

echo "== 1 받기·지문 확인"
mkdir -p "$T" && chmod 700 "$T"
get() {
  curl -sfL "$B/$1" -o "$T/$1" || { echo "STOP: $1 받기 실패"; exit 1; }
  echo "$2  $T/$1" | sha256sum -c --quiet || { echo "STOP: $1 지문 불일치 — 설치 안 함"; exit 1; }
}
get requirements-r0.txt b31d1c22af642801ea03cd7765e79224c2f3009333908d3582e03917431a7720
get trading_r0.py 2ecfac8fd5a83bb5bef30ccb4db46f0c1396c7f68aad3bb0d46f88f5e6cb6810
get trading_r0.json e7269eae930d013e1db45bbfcd152d16b091d9aaf5900b5e6094e2c2aa6b9877
get trading_r0_pdf.js 2c3c926a18e42b152ae49ec8a3414a5f66f26e058fa4ae957631b83e8b72e6d8
echo "파일 4개 확인"

echo "== 2 컨테이너 확인"
$H python3 -c 'import sys; v = sys.version_info; assert v >= (3, 11), v; print("파이썬", sys.version.split()[0])' || { echo "STOP: 컨테이너 파이썬이 3.11 보다 낮아요"; exit 1; }
$H node --version >/dev/null 2>&1 && echo "노드 있음 (PDF 변환용)" || echo "노드 없음 — PDF 없이 HTML 보고서만 남겨요"
$H sh -c "mkdir -p $L/logs $L/cache $L/results $L/staging $W && chmod 700 $L" || { echo "STOP: 폴더를 만들지 못했어요"; exit 1; }
if locked; then echo "STOP: 실행기가 지금 도는 중이에요 — 끝난 뒤 다시 (확인: sh s10.sh status)"; exit 1; fi

echo "== 3 가상환경 + 설치"
docker cp "$T/requirements-r0.txt" "$C:$L/requirements-r0.txt" && docker exec "$C" chmod 644 "$L/requirements-r0.txt" || { echo "STOP: 목록 복사 실패"; exit 1; }
LS=$(sha256sum "$T/requirements-r0.txt" | cut -c1-64)
docker exec -i -u hermes "$C" sh -s "$L" "$LS" <<'EOS'
L=$1; LS=$2
cd "$L" || exit 1
ready() { [ -x venv/bin/python ] && [ "$(cat .installed 2>/dev/null)" = "$LS" ] && venv/bin/python -c 'import sys, tradingagents; sys.exit(tradingagents.__version__ != "0.7.1")' 2>/dev/null; }
if ready; then echo "이미 설치됨 — 건너뜀"; exit 0; fi
# 휴대폰 콘솔이 끊겨도 컨테이너 안 설치는 계속 돈다 — 그사이 다시 돌려 설치가 겹치지 않게 막는다(30분 넘은 표시는 낡은 것)
if [ -d .installing ] && [ -z "$(find .installing -maxdepth 0 -mmin +30)" ]; then exit 3; fi
rm -rf .installing && mkdir .installing || exit 1
trap 'rmdir .installing 2>/dev/null' EXIT
echo "설치 중… 처음이면 2~5분 걸려요. 화면이 멈춘 것처럼 보여도 기다리세요."
rm -rf venv .installed
python3 -m venv venv 2>/dev/null || { rm -rf venv; command -v uv >/dev/null && uv venv -q venv; }
[ -x venv/bin/python ] || { echo "가상환경을 만들지 못했어요 (python3 -m venv)"; exit 1; }
if [ -x venv/bin/pip ]; then
  venv/bin/python -m pip install -q --no-cache-dir --disable-pip-version-check --require-hashes -r requirements-r0.txt || exit 1
else
  uv pip install -q --no-cache --python venv/bin/python --require-hashes -r requirements-r0.txt || exit 1
fi
venv/bin/python -c 'import sys, tradingagents; sys.exit(tradingagents.__version__ != "0.7.1")' || { echo "TradingAgents 0.7.1 확인 실패"; exit 1; }
{ venv/bin/python --version; venv/bin/python -m pip freeze 2>/dev/null || uv pip freeze --python venv/bin/python; } > install-record.txt 2>&1
echo "$LS" > .installed
echo "설치 완료: TradingAgents 0.7.1 (설치 목록: trading-lab/install-record.txt)"
EOS
rc=$?
if [ $rc -eq 3 ]; then echo "STOP: 다른 창에서 설치가 아직 도는 중이에요 — 몇 분 뒤 다시"; exit 1; fi
[ $rc -eq 0 ] || { echo "STOP: 설치 실패 — 위 마지막 몇 줄을 보내 주세요"; exit 1; }

echo "== 4 OpenRouter 키"
NEW=y
if $H test -s "$L/.env"; then
  printf '저장된 키가 있어요. 그대로 쓰려면 엔터, 새로 넣으려면 n: '
  read -r a
  [ "$a" = n ] || NEW=n
fi
if [ "$NEW" = y ]; then
  printf 'OpenRouter 새 키를 붙여 넣고 엔터 (화면에 안 보여요): '
  stty -echo 2>/dev/null; read -r K; stty echo 2>/dev/null; echo
  K=$(printf '%s' "$K" | tr -d ' \r\n\t')
  case "$K" in sk-or-v1-?*) ;; *) echo "STOP: OpenRouter 키 모양이 아니에요(${#K}자) — 저장 안 함"; exit 1;; esac
  echo "키 ${#K}자, 끝 ...$(printf '%s' "$K" | tail -c 4)"
  if printf '%s' "$K" | docker exec -i -u hermes "$C" sh -c "k=\$(cat); a=\$(sed -n 's/^OPENROUTER_API_KEY=//p' $ASK 2>/dev/null | head -1); [ -n \"\$a\" ] && [ \"\$k\" = \"\$a\" ]"; then
    K=; unset K
    echo "STOP: 카드뉴스용(ask.env) 키와 같아요 — 트레이딩용으로 새 키를 따로 만들어 넣으세요(한도·비용을 따로 재려고)"; exit 1
  fi
  printf 'OPENROUTER_API_KEY=%s\n' "$K" | docker exec -i -u hermes "$C" sh -c "umask 077; cat > $L/.env.new && chmod 600 $L/.env.new && mv $L/.env.new $L/.env" || { K=; echo "STOP: 키 저장 실패"; exit 1; }
  K=; unset K
  echo "저장: trading-lab/.env (600, 컨테이너 안 · 봉인·백업 대상 아님)"
fi

echo "== 5 점검 (돈 안 씀)"
for f in $FILES; do
  docker cp "$T/$f" "$C:$L/staging/$f" || { echo "STOP: $f 복사 실패"; exit 1; }
done
docker exec "$C" chmod 644 "$L/staging/trading_r0.py" "$L/staging/trading_r0.json" "$L/staging/trading_r0_pdf.js"
$H sh -c "cd $L && TRADING_CONFIG=$L/staging/trading_r0.json TRADING_PDF_JS=$L/staging/trading_r0_pdf.js venv/bin/python $L/staging/trading_r0.py --check" > "$T/check.out" 2>&1; rc=$?
grep -v -E '^(Cookie|Failed to get ticker)' "$T/check.out"
[ $rc -eq 0 ] || { echo "STOP: 점검 실패 — ❌ 줄을 고친 뒤 sh s10.sh 를 다시 (설치는 건너뛰어요 · 봉인 폴더는 그대로예요)"; exit 1; }

echo "== 6 실행기·설정·PDF 변환기 → scripts + 봉인"
for f in $FILES; do
  docker cp "$T/$f" "$C:$S/$f" || { echo "STOP: $f 복사 실패"; exit 1; }
done
docker exec "$C" chmod 644 "$S/trading_r0.py" "$S/trading_r0.json" "$S/trading_r0_pdf.js"
if sealed_ok; then
  echo "이미 지금 내용으로 봉인돼 있어요"
elif [ -f "$SEAL" ]; then
  echo "새 파일 trading_r0 세 개(그리고 아는 변경만)가 보이면 y"
  bash "$SEAL"
  sealed_ok || { echo "STOP: 봉인되지 않아 시험은 시작하지 않았어요 — 목록이 이상하면 화면을 보내 주시고, 괜찮으면 sh s10.sh 다시"; exit 1; }
else
  echo "STOP: 봉인 도구(/root/seal.sh)가 없어요 — s8 을 먼저 하세요"; exit 1
fi

echo "== 7 시험 1회 (BTC-USD)"
docker exec -d -u hermes "$C" sh -c "cd $L && { echo; echo \"== \$(date '+%F %T') 시험 시작\"; timeout 3600 venv/bin/python $S/trading_r0.py --tickers BTC-USD --tag test; } >> $L/logs/test-run.out 2>&1" || { echo "STOP: 시험을 시작하지 못했어요"; exit 1; }
sleep 20
if locked; then
  echo "시작했어요. 보통 5~20분 걸리고, 콘솔을 닫아도 계속 돌아요."
  echo "확인: sh s10.sh status"
  echo "끝나면 #01-지시에서 비서실장에게 결과를 #40-연구소에 올려 달라고 하세요."
else
  echo "실행기가 바로 끝났어요 — 마지막 줄:"
  $H sh -c "grep -v -E '^(Cookie|Failed to get ticker)' $L/logs/test-run.out | tail -3"
fi
