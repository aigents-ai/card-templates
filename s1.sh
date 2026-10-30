#!/bin/sh
# s1.sh - 2026-10-30 setup step 1 (run on the VPS host as root)
# 1) claude CLI check  2) templates v0.1 install (sha256 pinned)  3) renderer selftest  4) show backup.py library change
# Read-only except step 2. No seal here.
C=hermes-agent-bjmy-hermes-agent-1
N=/opt/hermes/tools/node-26.12.1-linux-x64
P=$N/lib/node_modules/@anthropic-ai

echo "== 1 claude"
docker exec -u hermes $C sh -c "uname -m; ls -l $N/bin/claude; od -An -c -N4 \"\$(readlink -f $N/bin/claude)\"; grep -m1 '\"version\"' $P/claude-code/package.json; ls $P $P/claude-code/node_modules/@anthropic-ai 2>&1; echo which:; which -a claude; echo gw:; tr '\\000' '\\n' < /proc/\$(pgrep -f 'gateway' | head -1)/environ 2>/dev/null | grep -E '^PATH=|CLAUDE'"

echo "== 2 install"
docker exec $C python3 -c "import io,hashlib,shutil,urllib.request,zipfile;b=urllib.request.urlopen('https://github.com/aigents-ai/card-templates/raw/main/templates.zip').read();h=hashlib.sha256(b).hexdigest();print(h[:12]);assert h.startswith('c79b973c088a'),'HASH MISMATCH';shutil.rmtree('/opt/data/work/brand/ai/templates',ignore_errors=True);zipfile.ZipFile(io.BytesIO(b)).extractall('/opt/data/work/brand/ai');print('installed')" || { echo "STOP: install failed"; exit 1; }

echo "== 3 selftest"
docker exec -u hermes $C node /opt/data/work/brand/ai/templates/render.js --selftest

echo "== 4 backup.py"
docker exec $C grep -n -i -B2 -A4 library /opt/data/scripts/backup.py

echo "== done"
