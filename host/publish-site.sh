#!/usr/bin/env bash
# /root/publish-site.sh v1 (2026-10-31) — 자료실 게시기 A안. 휴대폰 콘솔에서: bash /root/publish-site.sh 001
# 결재 원장(이벤트 파일)에서 '승인'이고, 묶음 폴더의 지문이 승인한 버전과 같을 때만 자료실에 올린다.
# GitHub 토큰은 컨테이너 밖 /root/publisher/.env 에만 있다(직원들은 닿지 않음).
# 올리기 전에 바뀌는 파일을 보여 주고 y를 받는다. 올리다 끊기면 재시도하지 않고 실제 반영 여부부터 확인한다.
set -u
N="${1:-}"
C="${HERMES_CONTAINER:-hermes-agent-bjmy-hermes-agent-1}"
P="${PUBLISHER_DIR:-/root/publisher}"
REPO_URL="${SITE_REPO_URL:-https://github.com/aigents-ai/aigents-ai.github.io.git}"
SITE="${SITE_BASE:-https://aigents-ai.github.io}"

[[ "$N" =~ ^[0-9]{3}$ ]] || { echo "사용: bash /root/publish-site.sh 001 (자료실 번호 세 자리)"; exit 2; }
[ -f "$P/LOCK" ] && { echo "■ 게시 잠금 중(비상정지) — 올리지 않아요. 해제: rm $P/LOCK"; exit 1; }
[ -f "$P/.env" ] || { echo "❌ 토큰 파일이 없어요 — 설치(s9.sh)부터"; exit 1; }
command -v git >/dev/null || { echo "❌ git 이 없어요 — 설치(s9.sh)를 다시 실행"; exit 1; }
TOKEN=$(sed -n 's/^GH_SITE_TOKEN=//p' "$P/.env")
[ -n "$TOKEN" ] || { echo "❌ 토큰 값이 비어 있어요 — 설치(s9.sh)를 다시 실행"; exit 1; }
AUTH="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$TOKEN" | base64 -w0)"
g() { git -c credential.helper= -c "http.https://github.com/.extraheader=$AUTH" "$@"; }

echo "== 1 승인 확인 (No.$N)"
INFO=$(docker exec -i -u hermes "$C" python3 -B - "$N" <<'PY'
import hashlib, json, pathlib, sys
n = sys.argv[1]
W = pathlib.Path("/opt/data/work")
hits = []
for cl in W.glob("brand/*/outbox/*/*/site/catalog-line.json"):
    try:
        e = json.loads(cl.read_text(encoding="utf-8"))
    except Exception:
        continue
    if isinstance(e, list):
        e = e[0] if e else {}
    if str(e.get("code", "")).zfill(3) == n:
        hits.append((cl.parent.parent, e))
if len(hits) != 1:
    print(json.dumps({"error": f"No.{n} 묶음을 {len(hits)}개 찾았어요(1개여야 해요)"}, ensure_ascii=False))
    sys.exit(0)
d, entry = hits[0]
# 지문 = digest-snapshot.py 의 version() 과 같은 방식
h = hashlib.sha256()
for f in sorted(x for x in d.rglob("*") if x.is_file() and x.name not in ("verdict.json", "check.json")):
    h.update(str(f.relative_to(d)).encode())
    h.update(f.read_bytes())
ver = h.hexdigest()[:8]
cur = {}
for f in sorted((W / "ops" / "approvals" / "decisions" / "events").glob("*.json")):
    try:
        ev = json.loads(f.read_text(encoding="utf-8"))
        cur[f"{ev['id']}@{ev['version']}"] = ev["decision"]
    except Exception:
        continue
print(json.dumps({"id": d.name, "dir": str(d), "version": ver, "decision": cur.get(f"{d.name}@{ver}"),
                  "url": str(entry.get("url", "")).strip("/"), "entry": entry}, ensure_ascii=False))
PY
)
field() { printf '%s' "$INFO" | python3 -c "import json,sys; d=json.load(sys.stdin); v=d.get('$1'); print('' if v is None else v)"; }
[ -n "$INFO" ] || { echo "❌ 컨테이너에서 묶음을 읽지 못했어요"; exit 1; }
ERR=$(field error); [ -z "$ERR" ] || { echo "❌ $ERR"; exit 1; }
ID=$(field id); D=$(field dir); VER=$(field version); DEC=$(field decision); URLDIR=$(field url)
echo "묶음 $ID @$VER · 원장 결정: ${DEC:-없음}"
[ "$DEC" = approved ] || { echo "■ 승인된 버전이 아니에요 — 올리지 않아요(승인 전이거나, 승인 뒤 파일이 바뀌어 지문이 달라졌어요)"; exit 1; }
[[ "$URLDIR" =~ ^[a-z0-9-]+$ ]] || { echo "❌ 페이지 폴더 이름이 이상해요: '$URLDIR'"; exit 1; }

echo "== 2 서버 바깥 기록 (덧붙이기만)"
mkdir -p "$P" && chmod 700 "$P"
printf '%s approved %s@%s No.%s %s\n' "$(date '+%F %T')" "$ID" "$VER" "$N" "$URLDIR" >> "$P/approved.log"
tail -1 "$P/approved.log"

echo "== 3 묶음 꺼내기"
rm -rf "$P/stage" && mkdir -p "$P/stage"
docker cp "$C:$D/site/$URLDIR" "$P/stage/$URLDIR" >/dev/null && docker cp "$C:$D/site/catalog-line.json" "$P/stage/catalog-line.json" >/dev/null \
  || { echo "❌ 페이지 폴더를 꺼내지 못했어요"; exit 1; }
[ -f "$P/stage/$URLDIR/index.html" ] || { echo "❌ index.html 이 없어요"; exit 1; }
echo "페이지 파일 $(find "$P/stage/$URLDIR" -type f | wc -l)개"

echo "== 4 자료실 저장소 맞추기"
if [ -d "$P/site/.git" ]; then
  g -C "$P/site" fetch -q origin || { echo "❌ 저장소를 받지 못했어요(토큰·네트워크)"; exit 1; }
  BR=$(git -C "$P/site" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##'); BR=${BR:-main}
  git -C "$P/site" checkout -q "$BR" && git -C "$P/site" reset -q --hard "origin/$BR" && git -C "$P/site" clean -qfd
else
  g clone -q "$REPO_URL" "$P/site" || { echo "❌ 저장소를 받지 못했어요(토큰·네트워크)"; exit 1; }
  BR=$(git -C "$P/site" symbolic-ref --short HEAD)
fi
git -C "$P/site" config user.name "aigents publisher"
git -C "$P/site" config user.email "publisher@users.noreply.github.com"

echo "== 5 페이지·목록 반영"
rm -rf "$P/site/$URLDIR" && cp -a "$P/stage/$URLDIR" "$P/site/$URLDIR"
python3 - "$P/site/assets/catalog.json" "$P/stage/catalog-line.json" <<'PY' || { echo "❌ 목록(catalog.json) 반영 실패"; exit 1; }
import json, sys
cat_path, line_path = sys.argv[1], sys.argv[2]
cat = json.load(open(cat_path, encoding="utf-8"))
new = json.load(open(line_path, encoding="utf-8"))
if isinstance(new, list):
    new = new[0]
cat = [e for e in cat if not e.get("sample") and e.get("id") != new.get("id") and str(e.get("code")) != str(new.get("code"))]
for e in cat:
    e["featured"] = False          # README: featured 는 하나만 — 가장 최근에 올린 안내
new.pop("sample", None)
new["featured"] = True
cat.insert(0, new)
with open(cat_path, "w", encoding="utf-8") as f:
    json.dump(cat, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(f"목록 {len(cat)}줄 (견본 줄 정리, 이번 안내를 맨 위·featured)")
PY
git -C "$P/site" add -A
CH=$(git -C "$P/site" status --short)
[ -n "$CH" ] || { echo "■ 바뀐 것이 없어요 — 이미 같은 내용이 올라가 있어요"; exit 0; }
echo "$CH" | head -15; [ "$(echo "$CH" | wc -l)" -gt 15 ] && echo "… 외 $(( $(echo "$CH" | wc -l) - 15 ))개"
read -r -p "자료실에 올릴까요? (y/N) " a
[ "$a" = y ] || { git -C "$P/site" reset -q --hard; echo "올리지 않았어요"; exit 0; }

echo "== 6 올리기"
git -C "$P/site" commit -q -m "자료실 No.$N $URLDIR — $ID@$VER"
L=$(git -C "$P/site" rev-parse HEAD)
if ! g -C "$P/site" push -q origin "HEAD:$BR"; then
  sleep 3
  R=$(g ls-remote "$REPO_URL" "refs/heads/$BR" | cut -f1)
  if [ "$R" = "$L" ]; then echo "✅ 응답만 끊겼고 실제로는 올라갔어요"
  else echo "❌ 올리지 못했어요 — 자동 재시도는 하지 않아요. 잠시 뒤 같은 명령을 다시 실행하세요"; exit 1; fi
fi
printf '%s published %s@%s No.%s %s %s\n' "$(date '+%F %T')" "$ID" "$VER" "$N" "$URLDIR" "${L:0:8}" >> "$P/published.log"
printf '{"id":"%s","version":"%s","code":"%s","url":"%s/%s/","commit":"%s","at":"%s"}\n' "$ID" "$VER" "$N" "$SITE" "$URLDIR" "$L" "$(date -Iseconds)" \
  | docker exec -i -u hermes "$C" sh -c "mkdir -p /opt/data/work/ops/approvals/site-published && cat > /opt/data/work/ops/approvals/site-published/$ID@$VER.json"
echo "✅ 올림: $SITE/$URLDIR/"

echo "== 7 공개 확인 (최대 2분)"
[ "${SITE_CHECK:-1}" = 1 ] || exit 0
for _ in $(seq 1 12); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$SITE/$URLDIR/")" = 200 ] && { echo "✅ 공개 확인: $SITE/$URLDIR/"; exit 0; }
  sleep 10
done
echo "■ 아직 반영 전이에요 — 1~2분 뒤 주소를 열어 보세요"
