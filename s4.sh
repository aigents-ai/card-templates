#!/bin/sh
# s4.sh - 2026-10-30 setup step 4 (run on the VPS host as root)
# AI팀장 worker reaches claude now but gets 401 "Not logged in": it does not run with HOME=/opt/data,
# so it cannot see the login in /opt/data/.claude. Point it there with CLAUDE_SUBSCRIPTION_DIRECTSDK_CONFIG_DIR.
# 1) login files exist (sizes only)  2) test: foreign HOME + CLAUDE_CONFIG_DIR -> must answer "ok"  3) only then add the .env line
C=hermes-agent-bjmy-hermes-agent-1

echo "== 1 login files"
docker exec -u hermes $C sh -c 'ls -l /opt/data/.claude/.credentials.json /opt/data/.claude.json 2>&1 | cut -c1-90'

echo "== 2 test (other HOME, shared login dir)"
r=$(docker exec -u hermes -e HOME=/tmp/h4 -e CLAUDE_CONFIG_DIR=/opt/data/.claude $C sh -c 'mkdir -p /tmp/h4; cd /tmp/h4; timeout 120 /opt/data/.local/bin/claude -p "Reply with exactly: ok" 2>&1 | tail -3')
echo "$r"
case "$r" in *[Oo][Kk]*) ;; *) echo "STOP: test did not answer ok - .env not changed"; exit 1;; esac

echo "== 3 insta-ai .env"
docker exec -u hermes $C sh -c '
E=/opt/data/profiles/insta-ai/.env
[ -n "$(tail -c1 $E)" ] && echo >> $E
grep -q "^CLAUDE_SUBSCRIPTION_DIRECTSDK_CONFIG_DIR=" $E || { echo "CLAUDE_SUBSCRIPTION_DIRECTSDK_CONFIG_DIR=/opt/data/.claude" >> $E; echo added; }
grep "^CLAUDE_SUBSCRIPTION_DIRECTSDK_" $E'
echo "== done"
