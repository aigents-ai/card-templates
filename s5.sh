#!/bin/sh
# s5.sh - 2026-10-31 seal after the 비서실장 edits rubric.md / check_card.py examples (strategy v0.6+)
# Shows the changed lines first, then seals only if you type y.
C=hermes-agent-bjmy-hermes-agent-1
echo "== rubric.md"
docker exec $C grep -n -E '과장|역대급|무조건|상투' /opt/data/work/training/insta-ai/judge/rubric.md | cut -c1-160
echo "== check_card.py"
docker exec $C grep -n -E '과장|역대급|무조건|상투' /opt/data/scripts/check_card.py | cut -c1-160
echo "== syntax"
docker exec -u hermes $C python3 -m py_compile /opt/data/scripts/check_card.py && echo "check_card.py OK"
printf 'Seal now? (y/N) '
read -r a
[ "$a" = y ] || { echo "not sealed"; exit 0; }
docker exec $C python3 /opt/data/scripts/watch.py --seal 2>&1 | tail -2
echo "== done"
