#!/usr/bin/env python3
"""trading_r0_inbox.py v1 (2026-11-01) — 트레이딩 R0 결과 우편함을 읽는 근무표 사전 스크립트(AI 없음).

호스트의 /root/r0-run.sh 가 실행마다 /opt/data/work/trading-lab/inbox/<시각>-<묶음>.json 을 남긴다.
이 스크립트는 새 우편이 없으면 아무것도 출력하지 않는다 — 근무표가 비서실장을 깨우지 않는다.
있으면 사람이 읽을 요약을 출력하고, 읽은 우편은 inbox/sent/ 로 옮긴다(같은 결과를 두 번 올리지 않게).
봉인 대상(/opt/data/scripts). 실행: python3 /opt/data/scripts/trading_r0_inbox.py
"""
import json
import os
import sys
from pathlib import Path

W = Path(os.environ.get("TRADING_WORK_DIR", "/opt/data/work/trading-lab"))
RC = {0: "정상", 1: "실패한 종목 있음", 2: "설정·점검 실패", 3: "이미 실행 중이라 건너뜀",
      4: "예비(유료)로 돈 종목 있음", 124: "시간 초과로 멈춤"}


def full(p):
    if not p:
        return None
    return p if p.startswith("/") else f"/opt/data/{p}"


def fmt(d: dict, name: str) -> str:
    rc = d.get("rc")
    head = f"[트레이딩 R0 · 묶음 {d.get('group', '?')} · {d.get('started_at') or d.get('started') or name} · 결과 코드 {rc}({RC.get(rc, '알 수 없음')})]"
    out = [head]
    for r in d.get("results") or []:
        late = " [늦게 채움]" if r.get("backfill") else ""
        brain = r.get("brain") or "-"
        if brain == "예비":
            brain += " $" + (f"{r['cost_usd']:.2f}" if r.get("cost_usd") is not None else "?")
        m, s = divmod(r.get("duration_s") or 0, 60)
        if r.get("status") == "ok":
            out.append(f"- {r['ticker']} {r['trade_date']}{late}: {r.get('rating')} · {brain} · {m}분 {s}초 · "
                       f"AI {r.get('llm_calls')}회·자료 {r.get('tool_calls')}회 · PDF {full(r.get('pdf')) or full(r.get('report'))}")
        else:
            out.append(f"- {r['ticker']} {r['trade_date']}{late}: 실패 · {brain} · {r.get('error')}")
        if r.get("needs_login"):
            out.append("  ! 구독 로그인이 끊김 — 대표가 콘솔에서 sh s10.sh 를 다시 돌려 로그인 단계에서 n")
    for n in d.get("notes") or []:
        out.append(f"- 참고: {n}")
    if not (d.get("results") or d.get("notes")):
        out.append("- 결과 없음(이미 기록이 있는 날이거나 휴장)")
    return "\n".join(out)


def main() -> int:
    inbox = W / "inbox"
    files = sorted(p for p in inbox.glob("*.json") if not p.name.endswith(".tmp"))
    if not files:
        return 0
    sent = inbox / "sent"
    sent.mkdir(parents=True, exist_ok=True)
    blocks = []
    for p in files:
        try:
            d = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            d = {"group": p.stem, "rc": None, "notes": [f"우편을 읽지 못함: {e}"]}
        blocks.append(fmt(d, p.stem))
        os.replace(p, sent / p.name)
    print("\n\n".join(blocks))
    return 0


if __name__ == "__main__":
    sys.exit(main())
