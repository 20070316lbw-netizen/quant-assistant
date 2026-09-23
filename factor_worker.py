"""factor_lab 的计算子进程: stdin 读一个 JSON 任务, stdout 写一个 JSON 结果。

启动后第一件事(在 import pandas/duckdb 之前)给自己设资源上限:
- RLIMIT_CPU: CPU 秒数, 超了内核直接发 SIGXCPU 终止;
- RLIMIT_AS: 地址空间上限(Linux 上有效; macOS 内核不强制这一项, 设置失败
  就记下来如实报告, 那边靠父进程的墙钟超时 + factor_lab 的输入规模上限兜底)。

只做两件事: preview(试算一个因子 spec, 给分布和 IC) 和 backtest(按名字
跑 minibacktest 的 Backtester)。不接受任何代码/表达式, 因子只能是
minibacktest.validate_spec 认可的 YAML 计算图。
"""
from __future__ import annotations

import json
import sys


def _apply_limits(limits: dict) -> dict:
    import resource

    status = {}
    cpu = int(limits.get("cpu_s", 60))
    try:
        resource.setrlimit(resource.RLIMIT_CPU, (cpu, cpu + 5))
        status["cpu_s"] = cpu
    except (ValueError, OSError):
        status["cpu_s"] = None
    mem = int(limits.get("memory_mb", 2048)) * 1024 * 1024
    try:
        resource.setrlimit(resource.RLIMIT_AS, (mem, mem))
        status["memory_mb"] = limits.get("memory_mb", 2048)
    except (ValueError, OSError):
        status["memory_mb"] = None  # macOS: 不支持, 如实报告
    return status


def _load_close(tickers, start, end, db_path):
    import liudb

    query = liudb.Query(columns=["close"], tickers=tickers, start=start, end=end)
    long = liudb.loader(request=query, path=db_path)
    if long.empty:
        raise ValueError(f"{start} ~ {end} 区间内没有查到价格数据(tickers={tickers or '全部'})")
    wide = long["close"].unstack("ticker").sort_index()
    return wide


def _num(x, digits=6):
    import math

    if x is None:
        return None
    x = float(x)
    return None if math.isnan(x) or math.isinf(x) else round(x, digits)


def _preview(task: dict) -> dict:
    import numpy as np
    from minibacktest.factors import compile_spec
    from minibacktest.rebalance import rebalance_dates

    price = _load_close(task["tickers"], task["start"], task["end"], task["db_path"])
    if price.shape[1] > 100:
        raise ValueError("标的数超过 100")
    fn = compile_spec(task["spec"], factor_name=task["factor_name"])
    values = fn(price, **task["params"])

    n_inf = int(np.isinf(values).sum())
    clean = values.replace([np.inf, -np.inf], np.nan)
    wide = clean.unstack("ticker").reindex(index=price.index, columns=price.columns)
    total = wide.size
    valid = clean.dropna()

    q = valid.quantile([0.05, 0.5, 0.95]) if len(valid) else None
    distribution = {
        "count": len(valid),
        "mean": _num(valid.mean()) if len(valid) else None,
        "std": _num(valid.std()) if len(valid) else None,
        "min": _num(valid.min()) if len(valid) else None,
        "p5": _num(q.loc[0.05]) if q is not None else None,
        "median": _num(q.loc[0.5]) if q is not None else None,
        "p95": _num(q.loc[0.95]) if q is not None else None,
        "max": _num(valid.max()) if len(valid) else None,
        "inf_count": n_inf,
    }

    latest = None
    rows_with_data = wide.dropna(how="all")
    if len(rows_with_data):
        last_date = rows_with_data.index[-1]
        cross = rows_with_data.iloc[-1].dropna().sort_values(ascending=False)
        latest = {
            "date": str(last_date.date()),
            "n": len(cross),
            "top": [{"ticker": t, "value": _num(v)} for t, v in cross.head(5).items()],
            "bottom": [{"ticker": t, "value": _num(v)} for t, v in cross.tail(5).items()],
        }

    # Rank IC: 每隔 horizon 个交易日取一个截面, 因子值 vs 之后 horizon 天的收益。
    # 对齐方式跟 engine 一致: t 日收盘算出的因子决定 t+1 起的持仓, 所以前瞻
    # 收益从 t 日收盘算到 t+h 日收盘。
    h = task["horizon"]
    fwd = price.shift(-h) / price - 1.0
    ics = []
    for d in rebalance_dates(price.index, h):
        f, r = wide.loc[d], fwd.loc[d]
        ok = f.notna() & r.notna()
        if ok.sum() >= 5:
            ic = f[ok].rank().corr(r[ok].rank())
            if not np.isnan(ic):
                ics.append(ic)
    ic_arr = np.array(ics)
    ic = {
        "horizon": h,
        "n_periods": len(ics),
        "mean": _num(ic_arr.mean()) if len(ics) else None,
        "std": _num(ic_arr.std(ddof=1)) if len(ics) > 1 else None,
        "icir": _num(ic_arr.mean() / ic_arr.std(ddof=1)) if len(ics) > 1 and ic_arr.std(ddof=1) > 0 else None,
        "positive_ratio": _num((ic_arr > 0).mean(), 4) if len(ics) else None,
    }

    return {
        "factor": task["factor_name"],
        "params": task["params"],
        "universe": {"n_tickers": price.shape[1], "start": str(price.index[0].date()),
                     "end": str(price.index[-1].date()), "n_days": price.shape[0]},
        "coverage": _num(len(valid) / total, 4) if total else 0.0,
        "distribution": distribution,
        "latest_cross_section": latest,
        "rank_ic": ic,
    }


def _backtest(task: dict) -> dict:
    import pandas as pd
    from minibacktest.backtester import Backtester
    from minibacktest.evaluation.quantile import quantile_forward_returns

    tickers = task["tickers"]
    if tickers is None:
        tickers = sorted(_load_close(None, task["start"], task["end"], task["db_path"]).columns)
    if len(tickers) > 100:
        raise ValueError("标的数超过 100")

    bt = Backtester(
        tickers=tickers,
        start=task["start"],
        end=task["end"],
        factor_specs=[(f["name"], f["params"]) for f in task["factors"]],
        factor_weights={f["name"]: f["weight"] for f in task["factors"]},
        freq=task["freq"],
        n_quantiles=task["n_quantiles"],
        db_path=task["db_path"],
        commission_bps=task["commission_bps"],
        slippage_bps=task["slippage_bps"],
    )
    r = bt.run(refresh_data=False)

    metrics = {}
    for key in (
        "return_pct", "buy_and_hold_return_pct", "return_ann_pct", "volatility_ann_pct", "cagr_pct",
        "sharpe_ratio", "sortino_ratio", "calmar_ratio", "alpha_pct", "beta",
        "max_drawdown_pct", "avg_drawdown_pct", "exposure_time_pct",
        "equity_final", "turnover_ann_pct", "total_cost_pct",
    ):
        metrics[key] = _num(getattr(r, key), 4)
    metrics["max_drawdown_days"] = r.max_drawdown_duration.days if pd.notna(r.max_drawdown_duration) else None

    qret = quantile_forward_returns(bt.score, bt.price, freq=task["freq"], n_quantiles=task["n_quantiles"])
    nav = r.equity_curve["nav"].resample("ME").last().dropna()

    return {
        "factors": task["factors"],
        "universe": {"n_tickers": len(tickers), "start": str(r.start.date()), "end": str(r.end.date())},
        "settings": {k: task[k] for k in ("freq", "n_quantiles", "commission_bps", "slippage_bps")},
        "metrics": metrics,
        "quantile_forward_returns": {str(int(k)): _num(v) for k, v in qret.items()},
        "nav_month_end": [{"date": str(d.date()), "nav": _num(v, 2)} for d, v in nav.items()],
    }


def main() -> None:
    task = json.loads(sys.stdin.read())
    limits = _apply_limits(task.get("limits", {}))
    try:
        if task["task"] == "preview":
            result = _preview(task)
        elif task["task"] == "backtest":
            result = _backtest(task)
        else:
            raise ValueError(f"未知任务 {task['task']!r}")
        result["resource_limits"] = limits
    except MemoryError:
        result = {"error": "计算超出内存上限, 缩小标的数/日期范围后重试"}
    except (ValueError, KeyError, TypeError) as exc:
        # FactorSpecError 是 ValueError 的子类; liudb 的 Query 校验错误也是。
        result = {"error": f"{type(exc).__name__}: {exc}"}
    sys.stdout.write(json.dumps(result, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
