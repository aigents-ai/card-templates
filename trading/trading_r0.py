#!/usr/bin/env python3
"""trading_r0.py v2 (2026-11-01) — 트레이딩 연구소 R0: 정해진 종목을 분석하고 결정을 기록한다.

거래 키 없음 · 주문 없음 · 연구용 기록이지 투자 조언이 아니다.
R0 통과 기준(계획서 8장): 정해진 종목의 분석·결정 기록이 끊기지 않는 것(코인은 30일, 미국 주식은 거래일 30일).
수익은 보지 않는다.

두뇌: 주(primary)는 ChatGPT 구독(Sign in with ChatGPT), 구독 한도·로그인 문제로 막히면 그 종목만
예비(fallback, OpenRouter 키 · 키 한도가 돈의 상한)로 다시 돈다.

실행(컨테이너 안, hermes 사용자):
  venv/bin/python /opt/data/scripts/trading_r0.py --check            # 점검만(돈·구독 사용량 안 씀)
  venv/bin/python /opt/data/scripts/trading_r0.py --group us         # 미국 주식 묶음(장 마감 뒤)
  venv/bin/python /opt/data/scripts/trading_r0.py --group crypto     # 코인 묶음
  ... --tickers NVDA --tag test                                      # 시험 1회
  ... --date 2026-10-30 · --force · --no-fallback
  ... --login | --whoami | --logout                                  # ChatGPT 구독 로그인 관리

설정: /opt/data/scripts/trading_r0.json (봉인 대상 — 모델·종목·분석가를 바꾸면 감시가 알아챈다)
키·로그인: /opt/data/trading-lab/.env (예비 OPENROUTER_API_KEY, 600)
          /opt/data/trading-lab/home/.tradingagents/chatgpt-auth.json (구독 로그인, 600)
결과: /opt/data/work/trading-lab/records/<날짜>/<종목>.json · records.jsonl
      /opt/data/work/trading-lab/reports/<날짜>/<종목>/complete_report.html (+ .pdf)
      TradingAgents 기억: /opt/data/work/trading-lab/memory/trading_memory.md
      시험(--tag test)은 같은 구조로 /opt/data/work/trading-lab/tests/ 아래에 따로 남는다
날짜: 코인은 방금 끝난 UTC 하루, 미국 주식은 마감(16:30 뉴욕)이 지난 마지막 거래일. 휴장일이면 건너뛴다.
종료 코드: 0 전부 성공(휴장 건너뜀 포함) · 1 실패한 종목 있음 · 2 설정·점검 실패 · 3 이미 실행 중
"""
import argparse
import fcntl
import json
import logging
import os
import re
import subprocess
import sys
import time
import traceback
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

VERSION = "trading_r0 v2"
KST = ZoneInfo("Asia/Seoul")
NY = ZoneInfo("America/New_York")
LAB = Path(os.environ.get("TRADING_LAB_HOME", "/opt/data/trading-lab"))
WORK = Path(os.environ.get("TRADING_WORK_DIR", "/opt/data/work/trading-lab"))
CONFIG = Path(os.environ.get("TRADING_CONFIG", "/opt/data/scripts/trading_r0.json"))
PDF_JS = Path(os.environ.get("TRADING_PDF_JS", "/opt/data/scripts/trading_r0_pdf.js"))
OR_API = os.environ.get("OPENROUTER_API_BASE", "https://openrouter.ai/api/v1")
# TradingAgents 는 로그인·캐시를 ~/.tradingagents·~/.cache 에 둔다 — 가져오기 전에 집을 연구소 폴더 안으로 정한다
os.environ["HOME"] = str(LAB / "home")
# 구독 한도·로그인·연결 문제처럼 '두뇌 쪽' 실패일 때만 예비로 넘어간다(자료 문제로 예비 돈을 쓰지 않게)
PROVIDER_ERR = re.compile(r"429|usage.?limit|rate.?limit|quota|insufficient|unauthori|forbidden|authenticat|permission|"
                          r"\b40[13]\b|sign.?in|chatgpt|credential|connection|proxy|unreachable|timed? ?out|timeout|"
                          r"overloaded|\b5\d\d\b", re.I)

log = logging.getLogger("trading_r0")
log.addHandler(logging.NullHandler())  # 점검 화면에는 경고 잡음을 내지 않는다(실행 때는 기록 파일로 간다)


def now_kst() -> str:
    return datetime.now(KST).isoformat(timespec="seconds")


def rel(p: Path) -> str:
    """/opt/data 아래 경로는 보고에 짧게 쓴다."""
    s = str(p)
    return s[len("/opt/data/"):] if s.startswith("/opt/data/") else s


def mask_email(e: str | None) -> str:
    if not e or "@" not in e:
        return e or "-"
    name, dom = e.split("@", 1)
    return f"{name[:2]}***@{dom}"


# ───────── 설정 ─────────
def load_config() -> dict:
    cfg = json.loads(CONFIG.read_text(encoding="utf-8"))
    errs = []
    for tier in ("primary",) + (("fallback",) if cfg.get("fallback") else ()):
        t = cfg.get(tier) or {}
        errs += [f"{tier}.{k}" for k in ("provider", "quick_model", "deep_model") if not t.get(k)]
    groups = cfg.get("groups") or {}
    if not groups:
        errs.append("groups")
    for name, g in groups.items():
        errs += [f"groups.{name}.{k}" for k in ("tickers", "asset_type", "analysts", "calendar") if not g.get(k)]
        if g.get("calendar") not in ("us", "utc"):
            errs.append(f"groups.{name}.calendar(us|utc)")
    if errs:
        raise ValueError(f"설정에 빠지거나 틀린 값: {', '.join(errs)} ({CONFIG})")
    return cfg


def group_of(cfg: dict, ticker: str) -> tuple[str, dict]:
    for name, g in cfg["groups"].items():
        if ticker in g["tickers"]:
            return name, g
    raise ValueError(f"설정의 어느 묶음에도 없는 종목: {ticker}")


def load_key() -> str | None:
    """예비(OpenRouter) 키. 없으면 None — 예비 없이 구독만으로 돈다."""
    env = LAB / ".env"
    try:
        lines = env.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    for line in lines:
        line = line.strip()
        if line.startswith("OPENROUTER_API_KEY="):
            key = line.split("=", 1)[1].strip().strip('"').strip("'")
            return key or None
    return None


# ───────── OpenRouter(예비): 모델 확인 · 키 사용액 ─────────
def _get(path: str, key: str | None = None, timeout: int = 30) -> dict:
    import requests
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    r = requests.get(f"{OR_API}{path}", headers=headers, timeout=timeout)
    r.raise_for_status()
    return r.json()


def key_info(key: str) -> dict:
    last = None
    for path in ("/key", "/auth/key"):
        try:
            return _get(path, key).get("data") or {}
        except Exception as e:  # noqa: BLE001 — 다음 경로를 시도
            last = e
    raise RuntimeError(f"키 정보를 읽지 못했어요: {last}")


def key_usage(key: str) -> float | None:
    try:
        u = key_info(key).get("usage")
        return float(u) if u is not None else None
    except Exception as e:  # noqa: BLE001
        log.warning("key usage read failed: %s", e)
        return None


def model_prices(model_ids) -> dict:
    """{모델: (입력 $/백만, 출력 $/백만)} — 목록에 없는 모델은 빠진다."""
    data = _get("/models").get("data") or []
    out = {}
    for m in data:
        if m.get("id") in model_ids:
            p = m.get("pricing") or {}
            try:
                out[m["id"]] = (round(float(p.get("prompt", 0)) * 1e6, 4), round(float(p.get("completion", 0)) * 1e6, 4))
            except (TypeError, ValueError):
                out[m["id"]] = (None, None)
    return out


# ───────── ChatGPT 구독 로그인 ─────────
def login() -> int:
    """Sign in with ChatGPT. 주소를 출력하고, 브라우저가 넘어간 주소를 run/login.in(이름 붙은 파이프)으로 받는다.
    s10.sh 가 이 출력을 읽어 주소를 보여 주고, 붙여 넣은 주소를 가려진 입력으로 받아 파이프에 써 준다."""
    from tradingagents.llm_clients import chatgpt_auth
    run = LAB / "run"
    run.mkdir(parents=True, exist_ok=True)
    fifo = run / "login.in"
    fifo.unlink(missing_ok=True)
    os.mkfifo(fifo, 0o600)
    pid = run / "login.pid"  # s10.sh 가 다시 돌 때 앞서 연 로그인을 닫을 수 있게
    pid.write_text(str(os.getpid()))

    def read_line() -> str:
        with open(fifo, encoding="utf-8") as f:  # 붙여 넣은 주소가 올 때까지 기다린다
            return f.readline()

    try:
        email = chatgpt_auth.sign_in(say=lambda m: print(m, flush=True), read_line=read_line, timeout=1800)
        print(f"LOGIN-OK {mask_email(email)}", flush=True)
        return 0
    except chatgpt_auth.ChatGPTAuthError as e:
        print(f"LOGIN-ERR {e}", flush=True)
        return 1
    except OSError as e:  # 1455 번 포트가 이미 쓰이는 중 — 앞서 연 로그인 창이 아직 기다리는 중
        print(f"LOGIN-ERR 앞서 연 로그인이 아직 기다리는 중이에요(30분 뒤 저절로 닫혀요): {e}", flush=True)
        return 1
    except Exception as e:  # noqa: BLE001
        print(f"LOGIN-ERR {type(e).__name__}: {str(e)[:300]}", flush=True)
        return 1
    finally:
        fifo.unlink(missing_ok=True)
        pid.unlink(missing_ok=True)


def whoami() -> int:
    from tradingagents.llm_clients import chatgpt_auth
    who = chatgpt_auth.signed_in_as()
    print(mask_email(who) if who else "-")
    return 0 if who else 1


def logout() -> int:
    from tradingagents.llm_clients import chatgpt_auth
    out = chatgpt_auth.sign_out()
    print({"revoked": "로그아웃: OpenAI 에서 권한을 거뒀어요", "forgotten": "로그아웃: 서버에서 지웠어요(OpenAI 연결 실패 — ChatGPT 설정에서도 Disconnect)",
           None: "로그인된 계정이 없어요"}[out])
    return 0


# ───────── 통계(AI 호출·자료 호출·토큰) ─────────
def make_stats():
    import threading

    from langchain_core.callbacks import BaseCallbackHandler

    class Stats(BaseCallbackHandler):
        def __init__(self):
            super().__init__()
            self._lock = threading.Lock()
            self.llm_calls = self.tool_calls = self.tokens_in = self.tokens_out = 0

        def on_chat_model_start(self, serialized, messages, **kw):
            with self._lock:
                self.llm_calls += 1

        def on_llm_start(self, serialized, prompts, **kw):
            with self._lock:
                self.llm_calls += 1

        def on_llm_end(self, response, **kw):
            try:
                msg = response.generations[0][0].message
                um = getattr(msg, "usage_metadata", None) or {}
            except (AttributeError, IndexError, TypeError):
                return
            with self._lock:
                self.tokens_in += int(um.get("input_tokens", 0) or 0)
                self.tokens_out += int(um.get("output_tokens", 0) or 0)

        def on_tool_start(self, serialized, input_str, **kw):
            with self._lock:
                self.tool_calls += 1

        def get(self):
            with self._lock:
                return {"llm_calls": self.llm_calls, "tool_calls": self.tool_calls,
                        "tokens_in": self.tokens_in, "tokens_out": self.tokens_out}

    return Stats()


# ───────── 결과 위치: R0 기록과 시험 기록은 섞지 않는다 ─────────
def out_base(kind: str) -> Path:
    """r0 → work/trading-lab/ · test → work/trading-lab/tests/ (기록·보고서·기억을 따로 둔다:
    시험이 R0 기록에 끼거나, 시험 결정이 R0 기억(교훈)에 들어가지 않게)."""
    return WORK if kind == "r0" else WORK / "tests"


# ───────── TradingAgents 설정 ─────────
def set_env_paths(kind: str):
    """TradingAgents 는 가져올 때 기본 설정을 만든다 — 경로·업데이트 확인은 그 전에 정한다."""
    os.environ.setdefault("TRADINGAGENTS_NO_UPDATE_CHECK", "1")
    os.environ["TRADINGAGENTS_RESULTS_DIR"] = str(LAB / "results")
    os.environ["TRADINGAGENTS_CACHE_DIR"] = str(LAB / "cache")
    os.environ["TRADINGAGENTS_MEMORY_LOG_PATH"] = str(out_base(kind) / "memory" / "trading_memory.md")


def ta_config(cfg: dict, tier: dict) -> dict:
    from tradingagents.default_config import build_default_config
    c = build_default_config()
    c.update({
        "llm_provider": tier["provider"],
        "quick_think_llm": tier["quick_model"],
        "deep_think_llm": tier["deep_model"],
        "max_debate_rounds": int(cfg.get("max_debate_rounds", 1)),
        "max_risk_discuss_rounds": int(cfg.get("max_risk_discuss_rounds", 1)),
        "max_tool_rounds": int(cfg.get("max_tool_rounds", 10)),
        "output_language": cfg.get("output_language", "English"),
    })
    if cfg.get("llm_max_retries") is not None:
        c["llm_max_retries"] = int(cfg["llm_max_retries"])
    return c


def trade_date_for(calendar: str, ticker: str) -> tuple[str | None, str]:
    """(분석 날짜, 설명). 날짜가 None 이면 그날은 건너뛴다(휴장).

    utc: 방금 끝난 UTC 하루 — 코인 하루 봉은 UTC 0시(한국 9시)에 마감된다.
    us : 뉴욕 16:30 이 지난 마지막 평일, 그날 하루 봉이 실제로 있는지 야후에서 확인(휴장일 거르기).
    TradingAgents 는 날짜 d 의 실행을 'd 마감 뒤'로 보고 d 다음 첫 마감에 들어간 것으로 채점한다.
    이 날짜는 '오늘'보다 앞이라 과거 시점 규칙으로 돈다(그 뒤 자료·날짜 없는 뉴스를 빼고 본다) —
    R1 백테스트와 같은 규칙이라 기록끼리 비교할 수 있게, 일부러 이렇게 둔다."""
    if calendar == "utc":
        return (datetime.now(timezone.utc) - timedelta(days=1)).date().isoformat(), "UTC 하루"
    ny = datetime.now(NY)
    d = ny.date()
    if ny.weekday() >= 5 or (ny.hour, ny.minute) < (16, 30):
        d -= timedelta(days=1)
    while d.weekday() >= 5:
        d -= timedelta(days=1)
    try:
        import yfinance as yf
        logging.getLogger("yfinance").setLevel(logging.CRITICAL)
        h = yf.Ticker(ticker).history(start=(d - timedelta(days=7)).isoformat(), end=(d + timedelta(days=1)).isoformat())
        days = {ix.date() for ix in h.index}
        if days and d not in days:
            return None, f"{d} 휴장(마지막 거래일 {max(days)})"
    except Exception as e:  # noqa: BLE001 — 확인을 못 하면 그 날짜로 돌린다(자료가 없으면 실행이 알려 준다)
        log.warning("trading-day check failed for %s: %s", ticker, e)
    return d.isoformat(), "미국 거래일"


# ───────── 기록 ─────────
def record_path(trade_date: str, ticker: str, kind: str) -> Path:
    return out_base(kind) / "records" / trade_date / f"{ticker}.json"


def write_record(rec: dict, final: bool):
    p = record_path(rec["trade_date"], rec["ticker"], rec["kind"])
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(rec, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, p)
    if final:
        with open(out_base(rec["kind"]) / "records.jsonl", "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def make_pdf(html: Path) -> Path | None:
    pdf = html.with_suffix(".pdf")
    try:
        r = subprocess.run(["node", str(PDF_JS), str(html), str(pdf)], capture_output=True, text=True, timeout=180)
        if r.returncode == 0 and pdf.exists() and pdf.stat().st_size > 0:
            return pdf
        log.warning("pdf failed rc=%s %s", r.returncode, (r.stderr or r.stdout)[-300:])
    except Exception as e:  # noqa: BLE001 — PDF 는 덤: 실패해도 기록은 남긴다
        log.warning("pdf failed: %s", e)
    return None


def attempt(cfg: dict, tier: dict, group: dict, ticker: str, trade_date: str, kind: str) -> tuple[dict, dict]:
    """한 두뇌(구독 또는 예비)로 한 종목을 돌린다. (결과, 통계) — 실패하면 예외에 통계를 붙여 던진다."""
    from tradingagents.graph.trading_graph import TradingAgentsGraph

    stats = make_stats()
    try:
        ta = TradingAgentsGraph(selected_analysts=list(group["analysts"]), config=ta_config(cfg, tier), callbacks=[stats])
        # 생성자에 준 콜백은 AI 호출만 센다. 자료 호출(도구)은 그래프 실행 설정으로 넘겨야 잡힌다(CLI 와 같은 방법).
        graph_args = ta.propagator.get_graph_args
        ta.propagator.get_graph_args = lambda callbacks=None: graph_args(callbacks=[stats])
        settings = ta.run_settings()
        final_state, rating = ta.propagate(ticker, trade_date, asset_type=group["asset_type"])
        out_dir = out_base(kind) / "reports" / trade_date / ticker
        ta.save_reports(final_state, ticker, save_path=out_dir, html=True)
        html = out_dir / "complete_report.html"
        pdf = make_pdf(html) if cfg.get("pdf", True) else None
        return {"settings": settings, "rating": rating, "report": rel(html), "pdf": rel(pdf) if pdf else None,
                "decision_excerpt": str(final_state.get("final_trade_decision") or "")[:800]}, stats.get()
    except Exception as e:
        try:
            e.stats = stats.get()  # type: ignore[attr-defined]
        except Exception:  # noqa: BLE001 — 속성을 못 붙이는 예외도 있다
            pass
        raise


def run_one(cfg: dict, key: str | None, ticker: str, trade_date: str, kind: str, prices: dict,
            use_fallback: bool) -> dict:
    gname, group = group_of(cfg, ticker)
    tiers = [("구독", cfg["primary"])]
    if use_fallback and cfg.get("fallback") and key:
        tiers.append(("예비", cfg["fallback"]))
    rec = {
        "v": 2, "kind": kind, "runner": VERSION, "trade_date": trade_date, "ticker": ticker, "group": gname,
        "status": "running", "started_at": now_kst(), "finished_at": None, "duration_s": None,
        "brain": None, "provider": None, "rating": None, "cost_usd": None,
        "llm_calls": None, "tool_calls": None, "tokens_in": None, "tokens_out": None,
        "models": None, "prices_per_mtok": None, "attempts": [],
        "settings": None, "report": None, "pdf": None, "decision_excerpt": None, "error": None,
    }
    write_record(rec, final=False)  # 중간에 죽으면 'running' 으로 남아 끊긴 줄 안다
    t0 = time.monotonic()
    for i, (label, tier) in enumerate(tiers):
        paid = tier["provider"] != "chatgpt"
        usage0 = key_usage(key) if (paid and key) else None
        if paid and key:
            os.environ["OPENROUTER_API_KEY"] = key
        a = {"brain": label, "provider": tier["provider"], "models": {"quick": tier["quick_model"], "deep": tier["deep_model"]},
             "started_at": now_kst(), "status": None, "error": None, "cost_usd": None}
        try:
            out, st = attempt(cfg, tier, group, ticker, trade_date, kind)
            a.update(status="ok", **st)
            rec.update(out)
            rec.update(st)
            rec.update(status="ok", brain=label, provider=tier["provider"], models=a["models"], error=None,
                       prices_per_mtok={t: prices.get(tier[f"{t}_model"]) for t in ("quick", "deep")} if paid else None)
        except Exception as e:  # noqa: BLE001 — 실패는 기록으로 남기고, 두뇌 쪽 실패면 예비로 넘어간다
            err = f"{type(e).__name__}: {str(e)[:500]}"
            log.error("attempt %s failed %s %s\n%s", label, ticker, trade_date, traceback.format_exc())
            a.update(status="failed", error=err, **getattr(e, "stats", {}))
            rec.update(status="failed", error=err, brain=label, provider=tier["provider"], models=a["models"])
            rec.update(getattr(e, "stats", {}))
        finally:
            if usage0 is not None:
                a["cost_usd"] = settle_cost(cfg, key, usage0, a.get("llm_calls"))
                if rec["brain"] == label:
                    rec["cost_usd"] = a["cost_usd"]
            rec["attempts"].append(a)
        if rec["status"] == "ok":
            break
        more = i + 1 < len(tiers)
        if more and not PROVIDER_ERR.search(rec["error"] or ""):
            log.info("not a provider error — no fallback: %s", rec["error"])
            break
    rec["duration_s"] = int(time.monotonic() - t0)
    rec["finished_at"] = now_kst()
    write_record(rec, final=True)
    return rec


def settle_cost(cfg: dict, key: str, usage0: float, llm_calls) -> float | None:
    """키 사용액은 늦게 반영될 수 있어 몇 번 더 본다. AI 를 불렀는데 안 움직이면 0 이 아니라 '모름'."""
    settle = int(cfg.get("usage_settle_seconds", 20))
    usage1 = None
    for _ in range(3):
        time.sleep(settle)
        usage1 = key_usage(key)
        if usage1 is not None and (usage1 > usage0 or not llm_calls):
            return round(usage1 - usage0, 4)
    log.warning("key usage did not move after %s LLM calls; cost unknown", llm_calls)
    return None


def line(rec: dict) -> str:
    m, s = divmod(rec.get("duration_s") or 0, 60)
    if rec.get("brain") == "구독":
        cost = "구독"
    else:
        cost = f"예비 ${rec['cost_usd']:.2f}" if rec.get("cost_usd") is not None else "예비 · 비용 모름"
    calls = f"AI 호출 {rec.get('llm_calls')}회 · 자료 호출 {rec.get('tool_calls')}회"
    tried = " (구독 실패 → 예비)" if len(rec.get("attempts") or []) > 1 else ""
    if rec["status"] == "ok":
        where = rec.get("pdf") or rec.get("report")
        return f"✅ {rec['ticker']} {rec['trade_date']}: {rec['rating']} · {cost}{tried} · {m}분 {s}초 · {calls} → {where}"
    return f"❌ {rec['ticker']} {rec['trade_date']}: 실패 · {cost}{tried} · {m}분 {s}초 · {calls} · {rec.get('error')}"


# ───────── 점검 ─────────
def check(cfg: dict) -> int:
    ok = True

    def money(x):
        return "-" if x is None else f"${float(x):.2f}"

    for name, g in cfg["groups"].items():
        when = "미국 장 마감 뒤" if g["calendar"] == "us" else "매일(UTC 하루)"
        print(f"묶음 {name}: {', '.join(g['tickers'])} · {when} · 분석가 {', '.join(g['analysts'])}")
    p, f = cfg["primary"], cfg.get("fallback")
    print(f"주 두뇌({p['provider']}): 분석·토론 {p['quick_model']} / 최종 판단 {p['deep_model']}")
    if p["provider"] == "chatgpt":
        try:
            from tradingagents.llm_clients import chatgpt_auth
            who = chatgpt_auth.signed_in_as()
            if not who:
                print("❌ ChatGPT 구독 로그인이 없어요 — sh s10.sh 의 로그인 단계를 다시")
                ok = False
            else:
                print(f"ChatGPT 로그인: {mask_email(who)}")
                offered = {slug for _, slug in chatgpt_auth.list_models()}
                for mid in (p["quick_model"], p["deep_model"]):
                    if mid in offered:
                        print(f"구독 모델 확인: {mid}")
                    else:
                        print(f"❌ 구독에서 쓸 수 없는 모델: {mid} (쓸 수 있는 것: {', '.join(sorted(offered)[:12])})")
                        ok = False
        except Exception as e:  # noqa: BLE001
            print(f"❌ 구독 확인 실패: {str(e)[:300]}")
            ok = False
    if f:
        print(f"예비 두뇌({f['provider']}): 분석·토론 {f['quick_model']} / 최종 판단 {f['deep_model']}")
        key = load_key()
        if not key:
            print("❌ 예비 키가 없어요 — sh s10.sh 의 예비 키 단계를 다시")
            ok = False
        else:
            print(f"예비 키: 있음 (끝 ...{key[-4:]})")
            try:
                info = key_info(key)
                limit, used, left, reset = info.get("limit"), info.get("usage"), info.get("limit_remaining"), info.get("limit_reset")
                eb = info.get("effective_budget") or None  # 조직·작업공간 예산(키 한도와 별개로 막는 층)
                if limit is not None:
                    print(f"예비 키 한도: {money(limit)}" + (f" ({reset} 초기화)" if reset else "")
                          + f" · 지금까지 사용 {money(used)} · 남은 한도 {money(left)}")
                elif eb:
                    print(f"예비 예산({eb.get('scope')}): {money(eb.get('limit_usd'))}"
                          + (f" ({eb.get('reset_interval')} 초기화)" if eb.get("reset_interval") else "")
                          + f" · 남은 예산 {money(eb.get('remaining_usd'))} · 키 사용 {money(used)}")
                else:
                    print(f"예비 키 한도: 없음 · 지금까지 사용 {money(used)}")
                if limit is None and not eb and cfg.get("require_key_limit", True):
                    print("❌ 예비 키에 한도가 없어요 — OpenRouter → Keys 에서 이 키의 Credit limit 을 정한 뒤 다시")
                    ok = False
            except Exception as e:  # noqa: BLE001
                print(f"❌ 예비 키 확인 실패: {e}")
                ok = False
            try:
                credits = _get("/credits", key).get("data") or {}
                if "total_credits" in credits:
                    bal = float(credits.get("total_credits", 0)) - float(credits.get("total_usage", 0))
                    print(f"OpenRouter 잔액: ${bal:.2f}" + ("  ⚠️ 잔액이 적어요" if bal < 2 else ""))
            except Exception:  # noqa: BLE001 — 잔액 조회가 막힌 키도 있다
                print("OpenRouter 잔액: 조회 안 됨(건너뜀)")
            try:
                prices = model_prices({f["quick_model"], f["deep_model"]})
                for t in ("quick", "deep"):
                    mid = f[f"{t}_model"]
                    if mid in prices:
                        print(f"예비 모델 확인: {mid} — 백만 토큰당 입력 ${prices[mid][0]} · 출력 ${prices[mid][1]}")
                    else:
                        print(f"❌ OpenRouter 에 없는 모델: {mid}")
                        ok = False
            except Exception as e:  # noqa: BLE001
                print(f"❌ 예비 모델 목록 확인 실패: {e}")
                ok = False
    for name, g in cfg["groups"].items():
        t = g["tickers"][0]
        try:
            d, why = trade_date_for(g["calendar"], t)
            import yfinance as yf
            logging.getLogger("yfinance").setLevel(logging.CRITICAL)
            h = yf.Ticker(t).history(period="5d")
            if h.empty:
                raise RuntimeError("받은 시세가 비어 있어요")
            print(f"시세 확인: {t} 최근 종가 {float(h['Close'].iloc[-1]):,.2f} ({h.index[-1].date()}) · 다음 분석 날짜 {d or '-'} ({why})")
        except Exception as e:  # noqa: BLE001
            print(f"⚠️ 시세(야후) 확인 실패 {t}: {str(e)[:200]} — 실행은 되지만 분석이 비어 보일 수 있어요")
    try:
        r = subprocess.run(["node", str(PDF_JS), "--check"], capture_output=True, text=True, timeout=60)
        print(("PDF 변환: " + r.stdout.strip()) if r.returncode == 0 else f"⚠️ PDF 변환 안 됨(HTML 만 남김): {(r.stderr or r.stdout).strip()[:200]}")
    except Exception as e:  # noqa: BLE001
        print(f"⚠️ PDF 변환 확인 실패(HTML 만 남김): {e}")
    try:
        import tradingagents
        print(f"TradingAgents {tradingagents.__version__} · 파이썬 {sys.version.split()[0]}")
    except Exception as e:  # noqa: BLE001
        print(f"❌ TradingAgents 를 불러오지 못했어요: {e}")
        ok = False
    print("✅ 점검 통과" if ok else "❌ 점검 실패 — 위 ❌ 줄을 고친 뒤 다시")
    return 0 if ok else 2


def main() -> int:
    ap = argparse.ArgumentParser(description="트레이딩 연구소 R0 실행기")
    ap.add_argument("--check", action="store_true", help="점검만(돈·구독 사용량 안 씀)")
    ap.add_argument("--login", action="store_true", help="ChatGPT 구독 로그인(s10.sh 가 부른다)")
    ap.add_argument("--whoami", action="store_true", help="로그인된 ChatGPT 계정")
    ap.add_argument("--logout", action="store_true", help="ChatGPT 구독 로그아웃(권한 거두기)")
    ap.add_argument("--group", help="묶음 이름(us · crypto), 기본은 전부")
    ap.add_argument("--tickers", help="쉼표로 구분 — 설정의 묶음에 있는 종목만")
    ap.add_argument("--date", help="YYYY-MM-DD — 기본은 묶음마다 정한 날짜(코인: 방금 끝난 UTC 하루, 미국: 마지막 거래일)")
    ap.add_argument("--tag", default="r0", choices=("r0", "test"), help="기록의 종류: r0(이어지는 기록) · test(시험, 따로 보관)")
    ap.add_argument("--force", action="store_true", help="성공 기록이 있어도 다시")
    ap.add_argument("--no-fallback", action="store_true", help="구독이 막혀도 예비로 넘어가지 않음")
    a = ap.parse_args()

    (LAB / "home").mkdir(parents=True, exist_ok=True)
    if a.login or a.whoami or a.logout:
        set_env_paths("r0")
        return login() if a.login else whoami() if a.whoami else logout()
    try:
        cfg = load_config()
    except Exception as e:  # noqa: BLE001
        print(f"❌ 설정을 읽지 못했어요: {e}")
        return 2
    set_env_paths(a.tag)
    if a.check:
        return check(cfg)

    base = out_base(a.tag)
    for d in (LAB / "logs", base / "records", base / "reports", base / "memory"):
        d.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(KST).strftime("%Y%m%d-%H%M%S")
    logging.basicConfig(filename=str(LAB / "logs" / f"{stamp}.log"), level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    lock = open(LAB / "run.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("❌ 이미 실행 중이에요 — 끝난 뒤 다시")
        return 3

    if a.tickers:
        tickers = [t.strip() for t in a.tickers.split(",") if t.strip()]
    else:
        names = [a.group] if a.group else list(cfg["groups"])
        tickers = [t for n in names for t in cfg["groups"][n]["tickers"]]
    try:
        for t in tickers:
            group_of(cfg, t)
    except ValueError as e:
        print(f"❌ {e}")
        return 2
    key = load_key()
    prices = {}
    if key and cfg.get("fallback"):
        try:
            prices = model_prices({cfg["fallback"]["quick_model"], cfg["fallback"]["deep_model"]})
        except Exception as e:  # noqa: BLE001 — 가격은 기록용: 못 읽어도 실행
            log.warning("price lookup failed: %s", e)

    failed = 0
    for t in tickers:
        _, g = group_of(cfg, t)
        if a.date:
            trade_date = a.date
        else:
            trade_date, why = trade_date_for(g["calendar"], t)
            if trade_date is None:
                print(f"⏭️ {t}: {why} — 건너뜀", flush=True)
                continue
        p = record_path(trade_date, t, a.tag)
        if p.exists() and not a.force:
            try:
                if json.loads(p.read_text(encoding="utf-8")).get("status") == "ok":
                    print(f"⏭️ {t} {trade_date}: 이미 성공 기록이 있어 건너뜀 ({rel(p)})", flush=True)
                    continue
            except (OSError, ValueError):
                pass
        rec = run_one(cfg, key, t, trade_date, a.tag, prices, use_fallback=not a.no_fallback)
        print(line(rec), flush=True)
        failed += rec["status"] != "ok"
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
