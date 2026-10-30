#!/bin/sh
# s3.sh - 2026-10-30 setup step 3 (run on the VPS host as root)
# 0) read the OpenRouter key (hidden; nothing changes if it is missing)
# 1) templates v0.1.1 (models.json gpt -> openai/gpt-6-luna, sha256 pinned) + selftest + seal
# 2) write insta-ai/ask.env (hermes, 600)  3) ask.py test on the example prompt (2 short API calls)
C=hermes-agent-bjmy-hermes-agent-1
Z=https://github.com/aigents-ai/card-templates/raw/design-v0.1.1/templates.zip

printf 'Paste the OpenRouter key (hidden), then Enter: '
stty -echo 2>/dev/null; read -r K; stty echo 2>/dev/null; echo
K=$(printf '%s' "$K" | tr -d ' \r\n\t')
case "$K" in sk-or-v1-?*) ;; *) echo "STOP: no key read (${#K} chars) - nothing changed"; exit 1;; esac
echo "key: ${#K} chars, ends ...$(printf '%s' "$K" | tail -c 4)"

echo "== 1 templates v0.1.1"
docker exec $C python3 -c "import io,hashlib,shutil,urllib.request,zipfile;b=urllib.request.urlopen('$Z').read();h=hashlib.sha256(b).hexdigest();print(h[:12]);assert h.startswith('e80bc0fdaab8'),'HASH MISMATCH';shutil.rmtree('/opt/data/work/brand/ai/templates',ignore_errors=True);zipfile.ZipFile(io.BytesIO(b)).extractall('/opt/data/work/brand/ai');print('installed')" || { echo "STOP: install failed - key not saved"; exit 1; }
docker exec -u hermes $C node /opt/data/work/brand/ai/templates/render.js --selftest | head -1
docker exec $C python3 /opt/data/scripts/watch.py --seal 2>&1 | tail -2

echo "== 2 ask.env"
printf 'OPENROUTER_API_KEY=%s\n' "$K" | docker exec -i -u hermes $C sh -c 'umask 077; f=/opt/data/profiles/insta-ai/ask.env; cat > $f; chmod 600 $f; ls -l $f'
K=; unset K

echo "== 3 ask test"
docker exec -u hermes $C sh -c 'rm -rf /tmp/asktest; mkdir -p /tmp/asktest && cp /opt/data/work/brand/ai/templates/example/prompt.txt /tmp/asktest/ && python3 /opt/data/work/brand/ai/templates/ask.py /tmp/asktest'
echo "== done"
