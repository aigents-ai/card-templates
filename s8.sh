#!/bin/sh
# s8.sh - 2026-10-31 봉인 도구 설치 (VPS 호스트, root): /root/seal.sh
# 설치한 뒤 한 번 실행해 지금 상태를 보여 준다(바뀐 봉인 대상 파일·바뀐 줄 → y면 봉인).
B=https://github.com/aigents-ai/card-templates/raw/s1/host
S=dd312a4cf2abcb1b5f10c7bddb8e9c985a184e3c88d9afda6369dd9975af325f
curl -sL "$B/seal.sh" -o /root/seal.sh.new || { echo "STOP: 받기 실패"; exit 1; }
echo "$S  /root/seal.sh.new" | sha256sum -c --quiet || { echo "STOP: 지문 불일치 — 설치 안 함"; rm -f /root/seal.sh.new; exit 1; }
mv /root/seal.sh.new /root/seal.sh && chmod 700 /root/seal.sh && echo "설치: 앞으로 봉인은 bash /root/seal.sh"
echo "== 지금 상태"
bash /root/seal.sh
