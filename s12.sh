#!/bin/sh
# s12.sh - 2026-11-01 자료실 게시기 v1.1 교체 (VPS 호스트, root)
#  게시기가 '게시함' 기록(원장의 published)을 결재 결정으로 읽어, 인스타를 먼저 올린 승인 묶음을 막던 문제를 고친다.
#  1) /root/publish-site.sh v1.1 받기·지문 확인·설치(토큰·저장소는 그대로)  2) 번호를 주면 바로 올린다: sh s12.sh 001
B="${S12_BASE:-https://github.com/aigents-ai/card-templates/raw/s1/host}"
SP=17eb391509ca2e60622aefe478d323ef99d0e8649229dbe5e1f1fa3f1e8d92a4
DST="${S12_DST:-/root/publish-site.sh}"

echo "== 1 게시기 v1.1 설치"
curl -sfL "$B/publish-site.sh" -o "$DST.new" || { echo "STOP: 받기 실패"; exit 1; }
echo "$SP  $DST.new" | sha256sum -c --quiet || { echo "STOP: 지문 불일치 — 5분 뒤 다시(깃허브 캐시)"; rm -f "$DST.new"; exit 1; }
if ! { mv "$DST.new" "$DST" && chmod 700 "$DST"; }; then echo "STOP: 설치 실패"; exit 1; fi
echo "설치: $DST (v1.1)"
if [ -n "${1:-}" ]; then
  echo "== 2 자료실 올리기 No.$1"
  exec bash "$DST" "$1"
fi
echo "다음: bash $DST 001"
