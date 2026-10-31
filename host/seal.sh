#!/usr/bin/env bash
# /root/seal.sh v1 (2026-10-31) — 봉인 갱신. 휴대폰 콘솔에서: bash /root/seal.sh
# 봉인 이후 바뀐 봉인 대상 파일과, 오늘 새벽 백업본과 비교한 바뀐 줄을 먼저 보여 준다. y를 눌러야 봉인한다.
# (watch.py 를 그냥 실행하면 알림 파일을 옮겨 버려서, 비교는 watch 의 함수만 불러서 한다 · -B: 캐시 파일을 만들지 않음)
set -u
C="${HERMES_CONTAINER:-hermes-agent-bjmy-hermes-agent-1}"
# 파이썬 캐시(__pycache__)는 봉인 대상 폴더에 생긴 부산물이라 지운다(지운 것도 아래 목록에 보이고, 봉인하면 정리됨)
docker exec -u hermes "$C" sh -c 'rm -rf /opt/data/scripts/__pycache__'
docker exec -i -u hermes "$C" python3 -B - <<'PY'
import subprocess, sys
sys.path.insert(0, "/opt/data/scripts")
import watch
sealed = {}
if watch.SEAL.exists():
    for line in watch.SEAL.read_text(encoding="utf-8").splitlines():
        if "  " in line:
            h, p = line.split("  ", 1)
            sealed[p] = h
now = watch.digest()
changed = sorted(p for p in set(sealed) | set(now) if sealed.get(p) != now.get(p))
if not changed:
    print("바뀐 봉인 대상 파일 없음")
    sys.exit(0)
print(f"바뀐 봉인 대상 파일 {len(changed)}개")
for p in changed:
    tag = "새 파일" if p not in sealed else ("삭제됨" if p not in now else "바뀜")
    print(f"- {p} ({tag})")
    old, cur = watch.REPO / p, watch.DATA / p
    if old.is_file() and cur.is_file():
        r = subprocess.run(["diff", "-u", str(old), str(cur)], capture_output=True, text=True, errors="replace")
        ls = [l for l in r.stdout.splitlines() if l[:1] in "+-" and not l.startswith(("+++", "---"))]
        for l in ls[:10]:
            print("    " + l[:100])
        if len(ls) > 10:
            print(f"    … {len(ls) - 10}줄 더")
        if not ls:
            print("    (새벽 백업본과 같음 — 그 전에 바뀐 것)")
    elif cur.is_file() and not p.endswith(".pyc"):
        print("    (백업본이 없어 줄 비교는 못 함)")
PY
read -r -p "봉인할까요? (y/N) " a
[ "$a" = y ] || { echo "봉인 안 함"; exit 0; }
docker exec "$C" python3 /opt/data/scripts/watch.py --seal 2>&1 | tail -2
