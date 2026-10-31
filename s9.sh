#!/bin/sh
# s9.sh - 2026-10-31 자료실 게시기 A안 설치 (VPS 호스트, root)
# 1) /root/publish-site.sh 설치(지문 고정)  2) git 확인  3) GitHub 토큰 입력(가려짐) → /root/publisher/.env (600, 컨테이너 밖)
# 4) 자료실 저장소 받기 + 쓰기 권한 시험(실제로 올리지는 않음)
B=https://github.com/aigents-ai/card-templates/raw/s1/host
SP=34d00433cb3b75416a06cb3f4408f06d8a94c0f85d12fbddc909076e6a6f88ea
REPO=https://github.com/aigents-ai/aigents-ai.github.io.git
P=/root/publisher

echo "== 1 게시기 설치"
curl -sL "$B/publish-site.sh" -o /root/publish-site.sh.new || { echo "STOP: 받기 실패"; exit 1; }
echo "$SP  /root/publish-site.sh.new" | sha256sum -c --quiet || { echo "STOP: 지문 불일치 — 설치 안 함"; rm -f /root/publish-site.sh.new; exit 1; }
mv /root/publish-site.sh.new /root/publish-site.sh && chmod 700 /root/publish-site.sh
mkdir -p $P && chmod 700 $P

echo "== 2 git"
command -v git >/dev/null || { apt-get update -qq >/dev/null && apt-get install -y -qq git >/dev/null; }
command -v git >/dev/null && git --version || { echo "STOP: git 설치 실패"; exit 1; }

echo "== 3 토큰"
printf 'GitHub 토큰을 붙여 넣고 엔터 (화면에 안 보여요): '
stty -echo 2>/dev/null; read -r K; stty echo 2>/dev/null; echo
K=$(printf '%s' "$K" | tr -d ' \r\n\t')
case "$K" in github_pat_?*|ghp_?*) ;; *) echo "STOP: GitHub 토큰 모양이 아니에요(${#K}자) — 아무것도 저장 안 함"; exit 1;; esac
echo "토큰 ${#K}자, 끝 ...$(printf '%s' "$K" | tail -c 4)"
( umask 077; printf 'GH_SITE_TOKEN=%s\n' "$K" > $P/.env )
AUTH="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$K" | base64 -w0)"
K=; unset K

echo "== 4 저장소 받기 + 쓰기 권한 시험"
rm -rf $P/site
git -c credential.helper= -c "http.https://github.com/.extraheader=$AUTH" clone -q "$REPO" $P/site || { echo "STOP: 저장소를 받지 못했어요 — 토큰의 저장소 선택을 확인"; exit 1; }
BR=$(git -C $P/site symbolic-ref --short HEAD)
if git -C $P/site -c credential.helper= -c "http.https://github.com/.extraheader=$AUTH" push --dry-run -q origin "HEAD:$BR" 2>/dev/null; then
  echo "✅ 쓰기 권한 확인 (실제로 올린 것은 없음)"
else
  echo "❌ 쓰기 권한이 없어요 — 토큰 권한에서 Contents 를 Read and write 로"; exit 1
fi
echo "== done — 결재 뒤: bash /root/publish-site.sh 001"
