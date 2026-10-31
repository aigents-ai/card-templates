#!/bin/sh
# s7.sh - 2026-10-31 기술팀장(프로필 tech) 만들기 (VPS 호스트, root). 컨테이너 재시작 없음 — 카드가 돌고 있어도 된다.
# 0) 확인·받기(지문 고정)  1) 프로필 생성(설명 포함)
# 2) AI팀장 프로필에서 모델 설정·플러그인 복사 + claude 경로·로그인 폴더 두 줄(오늘 AI팀장이 막혔던 원인)
# 3) 기본 SOUL(하지 않는 것·회사 공통 수칙)  4) 한 문장 답으로 확인  + /root/hrestart.sh(재시작 도우미) 설치
C=hermes-agent-bjmy-hermes-agent-1
B=https://github.com/aigents-ai/card-templates/raw/s1
SS=46d245d049ceeab8eca404ab0165d611a8e41adb992f8cccce1e1b328cb630c7
SH=44997f676b3197bd076664226cc6be584fb150fa835cc6c250f13b806bb49981
H="docker exec -u hermes $C"
DESC="헤르메스 서버 기술 담당. 컨테이너 안 설정·프로필·스킬·플러그인·패키지 설치와 점검, 고장 원인 찾기. 콘텐츠는 만들지 않는다."

echo "== 0 확인"
$H test -d /opt/data/profiles/tech && { echo "STOP: 프로필 tech 가 이미 있어요 — 아무것도 바꾸지 않았어요"; exit 1; }
$H test -f /opt/data/profiles/insta-ai/config.yaml || { echo "STOP: AI팀장 설정을 못 찾았어요"; exit 1; }
curl -sL "$B/staff/tech/SOUL.md" -o /tmp/tech-SOUL.md && curl -sL "$B/host/hrestart.sh" -o /root/hrestart.sh.new || { echo "STOP: 받기 실패"; exit 1; }
{ echo "$SS  /tmp/tech-SOUL.md" | sha256sum -c --quiet && echo "$SH  /root/hrestart.sh.new" | sha256sum -c --quiet; } || { echo "STOP: 지문 불일치 — 아무것도 바꾸지 않았어요"; rm -f /tmp/tech-SOUL.md /root/hrestart.sh.new; exit 1; }
mv /root/hrestart.sh.new /root/hrestart.sh && chmod 700 /root/hrestart.sh && echo "재시작 도우미 설치: bash /root/hrestart.sh"

echo "== 1 프로필 만들기"
$H timeout 120 hermes profile create tech --no-alias --description "$DESC" </dev/null 2>&1 | tail -3
$H test -d /opt/data/profiles/tech || { echo "STOP: 프로필이 안 만들어졌어요"; exit 1; }

echo "== 2 모델 설정·플러그인·claude 두 줄"
$H sh -c '
S=/opt/data/profiles/insta-ai; D=/opt/data/profiles/tech
[ -f $D/config.yaml ] && cp $D/config.yaml $D/config.yaml.orig
cp $S/config.yaml $D/config.yaml || { echo "STOP: 설정 복사 실패"; exit 1; }
mkdir -p $D/plugins && cp -a $S/plugins/. $D/plugins/ || { echo "STOP: 플러그인 복사 실패"; exit 1; }
touch $D/.env; [ -n "$(tail -c1 $D/.env)" ] && echo >> $D/.env
grep "^CLAUDE_SUBSCRIPTION_DIRECTSDK_" $S/.env | while IFS= read -r l; do k=${l%%=*}; grep -q "^$k=" $D/.env || echo "$l" >> $D/.env; done
chmod 600 $D/.env
echo "모델:$(grep -m1 -E "^[[:space:]]*default:" $D/config.yaml | cut -d: -f2-)"
echo "플러그인: $(ls $D/plugins | tr "\n" " ")"
grep "^CLAUDE_SUBSCRIPTION_DIRECTSDK_" $D/.env
' || exit 1

echo "== 3 기본 SOUL"
docker exec -i -u hermes $C sh -c 'cat > /opt/data/profiles/tech/SOUL.md' < /tmp/tech-SOUL.md && rm -f /tmp/tech-SOUL.md
$H head -1 /opt/data/profiles/tech/SOUL.md

echo "== 4 확인 — 한 문장 답(1분쯤)"
$H sh -c 'timeout 240 hermes -p tech chat --oneshot -q "한 문장으로 답해: 네 일은 뭐고, 하지 않는 일 두 가지는 뭐야?" 2>&1 | tail -4'
echo "== done"
