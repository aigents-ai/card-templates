#!/bin/sh
# s2.sh - 2026-10-30 setup step 2 (run on the VPS host as root)
# 1) point insta-ai at the working claude CLI  2) backup.py --check  3) seal
# The image copy /opt/hermes/tools/node-*/bin/claude is an npm stub (postinstall never ran) -> Exec format error.
# Working CLI: /opt/data/.local/bin/claude (native install). Fix lives in the profile .env (survives image updates).
C=hermes-agent-bjmy-hermes-agent-1

echo "== 1 claude for insta-ai"
docker exec -u hermes $C sh -c '
E=/opt/data/profiles/insta-ai/.env; D=/opt/data/.env
echo "default:"; grep "^CLAUDE_SUBSCRIPTION_DIRECTSDK_" $D
[ -n "$(tail -c1 $E)" ] && echo >> $E
grep "^CLAUDE_SUBSCRIPTION_DIRECTSDK_" $D | while IFS= read -r l; do k=${l%%=*}; grep -q "^$k=" $E || { echo "$l" >> $E; echo "copied $k"; }; done
grep -q "^CLAUDE_SUBSCRIPTION_DIRECTSDK_COMMAND=" $E || { echo "CLAUDE_SUBSCRIPTION_DIRECTSDK_COMMAND=/opt/data/.local/bin/claude" >> $E; echo "added COMMAND"; }
echo "insta-ai:"; grep "^CLAUDE_SUBSCRIPTION_DIRECTSDK_" $E
/opt/data/.local/bin/claude --version'

echo "== 2 backup check"
out=$(docker exec -u hermes $C python3 /opt/data/scripts/backup.py --check 2>&1); rc=$?
echo "$out" | tail -12
[ $rc -eq 0 ] || { echo "STOP: backup check failed (rc=$rc), not sealed"; exit 1; }

echo "== 3 seal"
docker exec $C python3 /opt/data/scripts/watch.py --seal 2>&1 | tail -8

echo "== done"
