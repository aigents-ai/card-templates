#!/bin/sh
# s14.sh - 2026-11-06 서버 초기화 전 마지막 백업: 텍스트 + 그림 (VPS 호스트, root)
#  1) 텍스트 백업: 매일 04:00 근무표와 같은 backup.py 를 지금 한 번 더 돌린다 → GitHub 비공개 백업 저장소의 main
#  2) 그림 백업: 텍스트 백업이 빼는 work/ 의 그림·영상(png·jpg·mp4 등, 50MB 이하)을
#     같은 저장소의 새 가지 media-<날짜시각> 에 올린다. 목록 파일 MEDIA-README.md 를 함께 넣는다.
#     main·backup.py·work/ 는 하나도 바꾸지 않는다. 비밀값 이름(파일·폴더)과 cache 폴더(대표가 보낸 원본)는 넣지 않는다.
#  3) 두 백업 어디에도 들어가지 않은 work/ 파일·폴더는 이름과 크기만 보여 준다(전체 목록은 MEDIA-README.md).
#  다시 돌려도 된다: 텍스트는 같은 main 을 갱신하고, 그림은 새 가지를 하나 더 만든다.
set -u
C="${HERMES_CONTAINER:-hermes-agent-bjmy-hermes-agent-1}"
D="${S14_DATA:-/opt/data}"

[ "$(id -u)" = 0 ] || { echo "STOP: root 로 실행하세요"; exit 1; }
[ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" = true ] \
  || { echo "STOP: 컨테이너 $C 가 꺼져 있어요. 켜지 말고 이 화면을 Claude에게 보여 주세요"; exit 1; }
X() { docker exec -u hermes "$C" "$@"; }

echo "== 1 텍스트 백업 (main)"
T0=$(date +%s)
X python3 "$D/scripts/backup.py" || { echo "STOP: 텍스트 백업 실패 — 위 이유를 Claude에게 보여 주세요"; exit 1; }
OK=$(X python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$D/backup-repo/.git/backup-ok" 2>/dev/null)
case "$OK" in ''|*[!0-9]*) OK=0;; esac
[ "$OK" -ge "$T0" ] || { echo "STOP: 백업 성공 기록이 새로 생기지 않았어요 — 이 화면을 Claude에게 보여 주세요"; exit 1; }
LAST=$(X git -C "$D/backup-repo" log -1 --format='%ct %h %cd' --date=format:'%m-%d %H:%M')
set -- $LAST
if [ "${1:-0}" -ge "$T0" ]; then echo "완료: 새 기록 ${2:-?} (${3:-} ${4:-})"
else echo "완료: 바뀐 내용 없음 — main 은 이미 최신 (${2:-?}, ${3:-} ${4:-})"; fi

echo "== 2 그림 백업 (새 가지 — 몇 분 걸릴 수 있어요)"
docker exec -i -u hermes -e S14_DATA="$D" "$C" python3 - <<'PY' || { echo "STOP: 그림 백업 실패 — 위 이유를 Claude에게 보여 주세요"; exit 1; }
import datetime, fnmatch, os, pathlib, shutil, stat, subprocess, sys, tempfile

sys.stdout.reconfigure(errors="backslashreplace")
sys.stderr.reconfigure(errors="backslashreplace")
D = pathlib.Path(os.environ.get("S14_DATA") or "/opt/data")
WORK, REPO = D / "work", D / "backup-repo"
MEDIA = ["*.png", "*.jpg", "*.jpeg", "*.webp", "*.gif",
         "*.mp4", "*.mov", "*.webm", "*.mp3", "*.wav", "*.m4a"]
SECRET = [".env", ".env.*", "*.env", "auth.json", "*token*", "*secret*", "*credential*",
          "*.pem", "*.key", "*.p12", "id_rsa*", "*.kdbx", "cookies*", "hc_url"]    # backup.py 와 같은 목록
NEVER = {".git", "__pycache__", "node_modules", ".venv", "venv", "cache"}      # 어느 백업에도 넣지 않는 폴더
TEXT_SKIP = NEVER | {"archive"}                                               # backup.py 가 건너뛰는 폴더
TEXT_MEDIA = MEDIA[:10] + ["*.zip", "*.gz", "*.tar", "*.db", "*.sqlite*", "*.ttf", "*.otf", "*.woff*"]
LIBRARY = WORK / "brand" / "ai" / "library"
LIMIT, TEXT_MAX = 50_000_000, 2_000_000
PUSH_MAX = 1_500_000_000        # GitHub 는 한 번에 2GB 넘게 받지 않는다
MARGIN = 1_000_000_000          # 그림 사본을 저장소에 쓴 뒤에도 남길 디스크 여유


def hit(name, pats):
    return any(fnmatch.fnmatch(name, p) for p in pats)


def in_text_backup(p, size):
    """backup.py 의 wanted() 와 같은 판단(비밀값 이름은 따로 거른다)."""
    n = p.name.lower()
    keep_media = "templates" in p.parts or (LIBRARY in p.parents and hit(n, MEDIA[:5]))
    if hit(n, TEXT_MEDIA) and not keep_media:
        return False
    return size <= TEXT_MAX


def mb(n):
    return f"{n / 1_000_000:.1f}MB"


def show(rel):
    """화면·목록용 이름 — UTF-8 이 아닌 이름도 깨지지 않게."""
    return os.fsencode(rel).decode("utf-8", "backslashreplace")


def tree_size(d):
    total = 0
    for root, _, files in os.walk(d):
        for f in files:
            try:
                st = os.lstat(os.path.join(root, f))
            except OSError:
                continue
            if stat.S_ISREG(st.st_mode):
                total += st.st_size
    return total


if not (REPO / ".git").is_dir():
    sys.exit(f"⚠ 백업 저장소가 없어요: {REPO}")
if not WORK.is_dir():
    sys.exit(f"⚠ 작업 폴더가 없어요: {WORK}")

media, left = [], []            # left: (경로, 크기, 이유) — 어느 백업에도 안 들어가는 것


def unreadable(err):
    rel = os.path.relpath(err.filename, WORK) if err.filename else "?"
    left.append((rel, 0, "읽을 수 없는 폴더"))


for root, dirs, files in os.walk(WORK, onerror=unreadable):
    r = pathlib.Path(root)
    rel_dir = r.relative_to(WORK)
    keep = []
    for d in sorted(dirs):
        rel = (rel_dir / d).as_posix()
        if (r / d).is_symlink():
            left.append((rel, 0, "링크 폴더(원본은 다른 곳)"))
        elif d in NEVER:
            if d != "__pycache__":
                left.append((rel, tree_size(r / d), f"폴더째 뺌({d})"))
        else:
            keep.append(d)
    dirs[:] = keep
    text_skipped_dir = any(part in TEXT_SKIP for part in rel_dir.parts)
    secret_dir = any(hit(part.lower(), SECRET) for part in rel_dir.parts)
    for f in sorted(files):
        p = r / f
        rel = (rel_dir / f).as_posix()
        try:
            st = os.lstat(p)
        except OSError:
            left.append((rel, 0, "읽기 실패"))
            continue
        if stat.S_ISLNK(st.st_mode):
            left.append((rel, 0, "링크 파일(원본은 다른 곳)"))
            continue
        if not stat.S_ISREG(st.st_mode):
            continue
        size, n = st.st_size, f.lower()
        if hit(n, SECRET):
            left.append((rel, size, "비밀값 이름"))
        elif hit(n, MEDIA):
            if secret_dir:
                left.append((rel, size, "비밀값 이름 폴더 안"))
            elif size > LIMIT:
                left.append((rel, size, "50MB 넘음"))
            else:
                media.append((rel, p, size))
        elif text_skipped_dir or not in_text_backup(p, size):
            left.append((rel, size, "텍스트 백업 제외"))


def publish(tmp):
    """임시 색인으로 새 가지 하나를 만들어 올린다 — main·작업 트리·.git/index 는 건드리지 않는다."""
    env = dict(os.environ, GIT_INDEX_FILE=os.path.join(tmp, "index"), GIT_TERMINAL_PROMPT="0")

    def git(*args, inp=None):
        r = subprocess.run(["git", "-C", str(REPO), *args], input=inp, capture_output=True, env=env)
        if r.returncode != 0:
            err = (r.stderr or r.stdout).decode("utf-8", "replace").strip()
            sys.exit(f"⚠ git {args[0]} 실패: {err[:300]}")
        return r.stdout

    def hash_file(p):
        try:
            with open(p, "rb") as fh:
                r = subprocess.run(["git", "-C", str(REPO), "hash-object", "-w", "--no-filters", "--stdin"],
                                   stdin=fh, capture_output=True, env=env)
        except OSError:
            return None
        sha = r.stdout.decode("ascii", "replace").strip()
        return sha if r.returncode == 0 and len(sha) in (40, 64) else None

    def entry(sha, rel):
        return b"100644 " + sha.encode() + b"\t" + os.fsencode(rel) + b"\0"

    total = sum(s for _, _, s in media)
    if total > PUSH_MAX:
        sys.exit(f"⚠ 그림·영상이 {mb(total)}라 한 번에 못 올려요(GitHub 한도 2GB) — 이 화면을 Claude에게 보여 주세요")
    free = shutil.disk_usage(REPO).free
    if free < total + MARGIN:
        sys.exit(f"⚠ 디스크 여유가 부족해요(여유 {mb(free)}, 필요 {mb(total + MARGIN)}) — 이 화면을 Claude에게 보여 주세요")

    hashed = []
    for rel, p, size in media:
        sha = hash_file(p)
        if sha:
            hashed.append((rel, sha, size))
        else:
            left.append((rel, size, "읽기 실패"))
    if not hashed:
        print("올릴 수 있는 그림·영상이 없어요")
        return
    git("read-tree", "--empty")
    git("update-index", "-z", "--index-info", inp=b"".join(entry(sha, rel) for rel, sha, _ in hashed))
    tree = git("write-tree").decode().strip()
    names = set(git("ls-tree", "-r", "-z", "--name-only", tree).split(b"\0"))
    ok = [x for x in hashed if os.fsencode(x[0]) in names]
    left.extend((rel, size, "git 이 받지 않는 이름") for rel, _, size in hashed if os.fsencode(rel) not in names)
    if not ok:
        print("올릴 수 있는 그림·영상이 없어요")
        return

    now = datetime.datetime.now()
    branch = "media-" + now.strftime("%Y%m%d-%H%M%S")
    size_ok = sum(s for _, _, s in ok)
    lines = [f"# 그림 백업 {now:%Y-%m-%d %H:%M}",
             "",
             "서버 초기화 전, 텍스트 백업(main)이 빼는 work/ 의 그림·영상을 모은 가지. 경로는 work/ 기준.",
             f"파일 {len(ok)}개 · {mb(size_ok)}",
             ""] + [f"- {show(rel)} ({size:,} bytes)" for rel, _, size in ok]
    if left:
        lines += ["", "## 어느 백업에도 들어가지 않은 것 (이름·크기만)", ""]
        lines += [f"- {show(rel)} ({size:,} bytes) — {why}" for rel, size, why in left]
    readme = git("hash-object", "-w", "--no-filters", "--stdin",
                 inp=("\n".join(lines) + "\n").encode("utf-8")).decode().strip()
    git("update-index", "-z", "--index-info", inp=entry(readme, "MEDIA-README.md"))
    tree = git("write-tree").decode().strip()
    names = set(git("ls-tree", "-r", "-z", "--name-only", tree).split(b"\0")) - {b""}
    if len(names) != len(ok) + 1 or b"MEDIA-README.md" not in names:
        sys.exit("⚠ 올릴 목록을 만들지 못했어요(파일 수 불일치)")
    commit = git("commit-tree", tree, "-m", f"media backup {now:%Y-%m-%d %H:%M}").decode().strip()
    print(f"올리는 중: 그림·영상 {len(ok)}개 ({mb(size_ok)}) → 가지 {branch}", flush=True)
    git("push", "-q", "origin", f"{commit}:refs/heads/{branch}")
    remote = git("ls-remote", "origin", f"refs/heads/{branch}").decode().split()
    if not remote or remote[0] != commit:
        sys.exit("⚠ GitHub에서 새 가지를 확인하지 못했어요")
    print(f"완료: 가지 {branch} 확인")


if not media:
    print("올릴 그림·영상이 없어요")
else:
    tmp = tempfile.mkdtemp(prefix="s14-")
    try:
        publish(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

if left:
    kinds = {}
    for _, _, why in left:
        kinds[why] = kinds.get(why, 0) + 1
    print(f"어느 백업에도 안 들어간 work/ 파일·폴더 {len(left)}개: " + " · ".join(f"{k} {v}" for k, v in kinds.items()))
    for rel, size, why in left[:15]:
        print(f"  {show(rel)} ({mb(size)}) — {why}")
    if len(left) > 15:
        print(f"  … 외 {len(left) - 15}개 (전체 목록은 가지의 MEDIA-README.md)")
PY
echo "== done — 이 화면을 Claude에게 보여 주세요"
