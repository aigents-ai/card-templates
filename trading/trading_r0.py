#!/usr/bin/env python3
"""trading_r0.py v1 (2026-11-01) — 트레이딩 연구소 R0: 정해진 종목을 분석하고 결정을 기록한다.

거래 키 없음 · 주문 없음 · 연구용 기록이지 투자 조언이 아니다.
R0 통과 기준(계획서 8장): 정해진 종목의 분석·결정 기록이 30일 연속 끊기지 않는 것. 수익은 보지 않는다.

실행(컨테이너 안, hermes 사용자):
  /opt/data/trading-lab/venv/bin/python /opt/data/scripts/trading_r0.py --check          # 점검만(돈 안 씀)
  /opt/data/trading-lab/venv/bin/python /opt/data/scripts/trading_r0.py                  # 설정의 종목 전부
  ... --tickers BTC-USD --tag test                                                       # 시험 1회
  ... --date 2026-10-31   (기본: 방금 끝난 UTC 하루 = 하루 봉이 마감된 날)
  ... --force             (이미 성공 기록이 있는 날짜·종목도 다시)

설정: /opt/data/scripts/trading_r0.json (봉인 대상 — 모델·종목·분석가를 바꾸면 감시가 알아챈다)
키:   /opt/data/trading-lab/.env 의 OPENROUTER_API_KEY (권한 600, 백업·봉인 대상 아님)
결과: /opt/data/work/trading-lab/records/<날짜>/<종목>.json · records.jsonl
      /opt/data/work/trading-lab/reports/<날짜>/<종목>/complete_report.html (+ .pdf)
      TradingAgents 기억: /opt/data/work/trading-lab/memory/trading_memory.md
      시험(--tag test)은 같은 구조로 /opt/data/work/trading-lab/tests/ 아래에 따로 남는다
비용: OpenRouter 키 사용액을 실행 전후로 읽어 그 차이를 적는다(키 한도가 돈의 상한).
종료 코드: 0 전부 성공 · 1 실패한 종목 있음 · 2 설정·점검 실패 · 3 이미 실행 중
"""
import argparse
import fcntl
import json
import logging
import os
import subprocess
import sys
import time
import traceback
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

VERSION = "trading_r0 v1"
KST = ZoneInfo("Asia/Seoul")
LAB = Path(os.environ.get("TRADING_LAB_HOME", "/opt/data/trading-lab"))
WORK = Path(os.environ.get("TRADING_WORK_DIR", "/opt/data/work/trading-lab"))
CONFIG = Path(os.environ.get("TRADING_CONFIG", "/opt/data/scripts/trading_r0.json"))
PDF_JS = Path(os.environ.get("TRADING_PDF_JS", "/opt/data/scripts/trading_r0_pdf.js"))
OR_API = os.environ.get("OPENROUTER_API_BASE", "https://openrouter.ai/api/v1")
REQUIRED = ("tickers", "asset_type", "analysts", "quick_model", "deep_model")

log = logging.getLogger("trading_r0")


def now_kst() -> str:
    return datetime.now(KST).isoformat(timespec="seconds")


def rel(p: Path) -> str:
    """/opt/data 아래 경로는 보고에 짧게 쓴다."""
    s = str(p)
    return s[len("/opt/data/"):] if s.startswith("/opt/data/") else s


def load_config() -> dict:
    cfg = json.loads(CONFIG.read_text(encoding="utf-8"))
    missing = [k for k in REQUIRED if not cfg.get(k)]
    if missing:
        raise ValueError(f"설정에 빠진 값: {', '.join(missing)} ({CONFIG})")
    return cfg


def load_key() -> str:
    env = LAB / ".env"
    if not env.exists():
        raise ValueError(f"키 파일이 없어요: {env}")
    for line in env.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith("OPENROUTER_API_KEY="):
            key = line.split("=", 1)[1].strip().strip('"').strip("'")
            if key:
                return key
    raise ValueError(f"OPENROUTER_API_KEY 가 비어 있어요: {env}")


# ───────── OpenRouter: 모델 확인 · 키 사용액 ─────────
def _get(path: str, key: str | None = None, timeout: int = 30) -> dict:
    import requests
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    r = requests.get(f"{OR_API}{path}", headers=headers, timeout=timeout)
    r.raise_for_status()
    return r.json()


def key_info(key: str) -> dict:
    """키의 사용액(usage, 달러)·한도(limit)·남은 한도. 새 경로가 없으면 예전 경로."""
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
    시험이 30일 기록에 끼거나, 시험 결정이 R0 기억(교훈)에 들어가지 않게)."""
    return WORK if kind == "r0" else WORK / "tests"


# ───────── TradingAgents 설정 ─────────
def set_env_paths(kind: str):
    """TradingAgents 는 가져올 때 기본 설정을 만든다 — 경로·업데이트 확인은 그 전에 정한다."""
    os.environ.setdefault("TRADINGAGENTS_NO_UPDATE_CHECK", "1")
    os.environ["TRADINGAGENTS_RESULTS_DIR"] = str(LAB / "results")
    os.environ["TRADINGAGENTS_CACHE_DIR"] = str(LAB / "cache")
    os.environ["TRADINGAGENTS_MEMORY_LOG_PATH"] = str(out_base(kind) / "memory" / "trading_memory.md")


def ta_config(cfg: dict) -> dict:
    from tradingagents.default_config import build_default_config
    c = build_default_config()
    c.update({
        "llm_provider": cfg.get("provider", "openrouter"),
        "quick_think_llm": cfg["quick_model"],
        "deep_think_llm": cfg["deep_model"],
        "max_debate_rounds": int(cfg.get("max_debate_rounds", 1)),
        "max_risk_discuss_rounds": int(cfg.get("max_risk_discuss_rounds", 1)),
        "max_tool_rounds": int(cfg.get("max_tool_rounds", 10)),
        "output_language": cfg.get("output_language", "English"),
    })
    if cfg.get("llm_max_retries") is not None:
        c["llm_max_retries"] = int(cfg["llm_max_retries"])
    return c


def default_trade_date() -> str:
    """방금 끝난 UTC 하루. 코인 하루 봉은 UTC 0시(한국 9시)에 마감되고,
    TradingAgents 는 날짜 d 의 실행을 'd 마감 뒤'로 보고 d 다음 첫 마감에 들어간 것으로 채점한다.
    이 날짜는 '오늘'보다 앞이라 TradingAgents 가 과거 시점 규칙으로 돈다(그 시점 뒤 자료·날짜 없는 뉴스·
    지금의 예측시장 확률을 빼고 본다). R1 백테스트와 같은 규칙이라 기록끼리 비교할 수 있다 — 일부러 이렇게 둔다."""
    return (datetime.now(timezone.utc) - timedelta(days=1)).date().isoformat()


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


def run_one(cfg: dict, key: str, ticker: str, trade_date: str, kind: str, prices: dict) -> dict:
    from tradingagents.graph.trading_graph import TradingAgentsGraph

    rec = {
        "v": 1, "kind": kind, "runner": VERSION, "trade_date": trade_date, "ticker": ticker,
        "status": "running", "started_at": now_kst(), "finished_at": None, "duration_s": None,
        "rating": None, "cost_usd": None, "llm_calls": None, "tool_calls": None,
        "tokens_in": None, "tokens_out": None,
        "models": {"quick": cfg["quick_model"], "deep": cfg["deep_model"]},
        "prices_per_mtok": {t: prices.get(cfg[f"{t}_model"]) for t in ("quick", "deep")},
        "settings": None, "report": None, "pdf": None, "decision_excerpt": None, "error": None,
    }
    write_record(rec, final=False)  # 중간에 죽으면 'running' 으로 남아 끊긴 줄 안다
    t0 = time.monotonic()
    usage0 = key_usage(key)
    stats = make_stats()
    try:
        ta = TradingAgentsGraph(selected_analysts=list(cfg["analysts"]), config=ta_config(cfg), callbacks=[stats])
        # 생성자에 준 콜백은 AI 호출만 센다. 자료 호출(도구)은 그래프 실행 설정으로 넘겨야 잡힌다(CLI 와 같은 방법).
        graph_args = ta.propagator.get_graph_args
        ta.propagator.get_graph_args = lambda callbacks=None: graph_args(callbacks=[stats])
        rec["settings"] = ta.run_settings()
        final_state, rating = ta.propagate(ticker, trade_date, asset_type=cfg["asset_type"])
        out_dir = out_base(kind) / "reports" / trade_date / ticker
        ta.save_reports(final_state, ticker, save_path=out_dir, html=True)
        html = out_dir / "complete_report.html"
        rec["report"] = rel(html)
        pdf = make_pdf(html) if cfg.get("pdf", True) else None
        rec["pdf"] = rel(pdf) if pdf else None
        rec["rating"] = rating
        rec["decision_excerpt"] = str(final_state.get("final_trade_decision") or "")[:800]
        rec["status"] = "ok"
    except Exception as e:  # noqa: BLE001 — 한 종목이 실패해도 다음 종목은 돈다
        rec["status"] = "failed"
        rec["error"] = f"{type(e).__name__}: {str(e)[:500]}"
        log.error("run failed %s %s\n%s", ticker, trade_date, traceback.format_exc())
    finally:
        rec.update(stats.get())
        rec["duration_s"] = int(time.monotonic() - t0)
        rec["finished_at"] = now_kst()
        if usage0 is not None:
            settle = int(cfg.get("usage_settle_seconds", 20))
            usage1 = None
            for _ in range(3):  # 사용액 반영이 늦을 수 있어 몇 번 더 본다
                time.sleep(settle)
                usage1 = key_usage(key)
                if usage1 is not None and (usage1 > usage0 or not rec.get("llm_calls")):
                    break
            if usage1 is not None and (usage1 > usage0 or not rec.get("llm_calls")):
                rec["cost_usd"] = round(usage1 - usage0, 4)
            else:  # AI 를 불렀는데 사용액이 안 움직였으면 0 이 아니라 '모름'
                log.warning("key usage did not move after %s LLM calls; cost unknown", rec.get("llm_calls"))
        write_record(rec, final=True)
    return rec


def line(rec: dict) -> str:
    m, s = divmod(rec.get("duration_s") or 0, 60)
    cost = f"${rec['cost_usd']:.2f}" if rec.get("cost_usd") is not None else "비용 모름"
    calls = f"AI 호출 {rec.get('llm_calls')}회 · 자료 호출 {rec.get('tool_calls')}회"
    if rec["status"] == "ok":
        where = rec.get("pdf") or rec.get("report")
        return f"✅ {rec['ticker']} {rec['trade_date']}: {rec['rating']} · {cost} · {m}분 {s}초 · {calls} → {where}"
    return f"❌ {rec['ticker']} {rec['trade_date']}: 실패 · {cost} · {m}분 {s}초 · {calls} · {rec.get('error')}"


# ───────── 점검 ─────────
def check(cfg: dict) -> int:
    ok = True
    print(f"설정: {rel(CONFIG)} · 종목 {', '.join(cfg['tickers'])} · 분석가 {', '.join(cfg['analysts'])}")
    print(f"모델: 분석·토론 {cfg['quick_model']} / 최종 판단 {cfg['deep_model']}")
    try:
        key = load_key()
        print(f"키: 있음 (끝 ...{key[-4:]})")
    except ValueError as e:
        print(f"❌ {e}")
        return 2
    try:
        info = key_info(key)
        limit, used, left = info.get("limit"), info.get("usage"), info.get("limit_remaining")
        reset = info.get("limit_reset")

        def money(x):
            return "-" if x is None else f"${float(x):.2f}"
        eb = info.get("effective_budget") or None  # 조직·작업공간 예산(키 한도와 별개로 막는 층)
        if limit is not None:
            print(f"키 한도: {money(limit)}" + (f" ({reset} 초기화)" if reset else "")
                  + f" · 지금까지 사용 {money(used)} · 남은 한도 {money(left)}")
        elif eb:
            print(f"예산({eb.get('scope')}): {money(eb.get('limit_usd'))}"
                  + (f" ({eb.get('reset_interval')} 초기화)" if eb.get("reset_interval") else "")
                  + f" · 남은 예산 {money(eb.get('remaining_usd'))} · 키 사용 {money(used)}")
        else:
            print(f"키 한도: 없음 · 지금까지 사용 {money(used)}")
        if limit is None and not eb and cfg.get("require_key_limit", True):
            print("❌ 이 키에 한도가 없어요 — OpenRouter → Keys 에서 이 키의 Credit limit 을 정한 뒤 다시 하세요")
            ok = False
    except Exception as e:  # noqa: BLE001
        print(f"❌ 키 확인 실패: {e}")
        ok = False
    try:
        credits = _get("/credits", key).get("data") or {}
        if "total_credits" in credits:
            bal = float(credits.get("total_credits", 0)) - float(credits.get("total_usage", 0))
            print(f"계정 잔액: ${bal:.2f}" + ("  ⚠️ 잔액이 적어요 — 시험 전에 충전" if bal < 2 else ""))
    except Exception:  # noqa: BLE001 — 잔액 조회가 막힌 키도 있다
        print("계정 잔액: 조회 안 됨(건너뜀)")
    try:
        prices = model_prices({cfg["quick_model"], cfg["deep_model"]})
        for t in ("quick", "deep"):
            mid = cfg[f"{t}_model"]
            if mid in prices:
                pin, pout = prices[mid]
                print(f"모델 확인: {mid} — 백만 토큰당 입력 ${pin} · 출력 ${pout}")
            else:
                print(f"❌ OpenRouter 에 없는 모델: {mid}")
                ok = False
    except Exception as e:  # noqa: BLE001
        print(f"❌ 모델 목록 확인 실패: {e}")
        ok = False
    try:
        import yfinance as yf
        logging.getLogger("yfinance").setLevel(logging.CRITICAL)  # 쿠키·재시도 잡음은 숨기고 결과만 보인다
        h = yf.Ticker(cfg["tickers"][0]).history(period="5d")
        if h.empty:
            raise RuntimeError("받은 시세가 비어 있어요")
        print(f"시세 확인: {cfg['tickers'][0]} 최근 종가 {float(h['Close'].iloc[-1]):,.2f} ({h.index[-1].date()})")
    except Exception as e:  # noqa: BLE001
        print(f"⚠️ 시세(야후) 확인 실패: {str(e)[:200]} — 실행은 되지만 분석이 비어 보일 수 있어요")
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
    ap.add_argument("--check", action="store_true", help="점검만(돈 안 씀)")
    ap.add_argument("--tickers", help="쉼표로 구분, 기본은 설정의 종목")
    ap.add_argument("--date", help="YYYY-MM-DD, 기본은 방금 끝난 UTC 하루")
    ap.add_argument("--tag", default="r0", choices=("r0", "test"), help="기록의 종류: r0(30일 기록) · test(시험, 따로 보관)")
    ap.add_argument("--force", action="store_true", help="성공 기록이 있어도 다시")
    a = ap.parse_args()

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

    try:
        key = load_key()
    except ValueError as e:
        print(f"❌ {e}")
        return 2
    os.environ["OPENROUTER_API_KEY"] = key
    tickers = [t.strip() for t in (a.tickers.split(",") if a.tickers else cfg["tickers"]) if t.strip()]
    trade_date = a.date or default_trade_date()
    try:
        prices = model_prices({cfg["quick_model"], cfg["deep_model"]})
    except Exception as e:  # noqa: BLE001 — 가격은 기록용: 못 읽어도 실행
        log.warning("price lookup failed: %s", e)
        prices = {}

    failed = 0
    for t in tickers:
        p = record_path(trade_date, t, a.tag)
        if p.exists() and not a.force:
            try:
                if json.loads(p.read_text(encoding="utf-8")).get("status") == "ok":
                    print(f"⏭️ {t} {trade_date}: 이미 성공 기록이 있어 건너뜀 ({rel(p)})")
                    continue
            except (OSError, ValueError):
                pass
        rec = run_one(cfg, key, t, trade_date, a.tag, prices)
        print(line(rec), flush=True)
        failed += rec["status"] != "ok"
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
