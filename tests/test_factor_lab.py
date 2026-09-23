"""factor_lab 的单测: 草稿一步步拼、校验、保存, 以及子进程试算/回测。

草稿和因子库放在 tmp_path(通过 QUANT_ASSISTANT_FACTOR_DIR), 价格用合成数据写进
临时 DuckDB, 不碰本机真实的 data/sp500.db 和 factors/。
"""
from __future__ import annotations

import numpy as np
import pandas as pd
import pytest
from liudb import init_schema, save_prices

import factor_lab as fl
from factor_lab import FactorLabError


@pytest.fixture(autouse=True)
def factor_dir(tmp_path, monkeypatch):
    d = tmp_path / "factors"
    monkeypatch.setenv(fl.FACTOR_DIR_ENV_VAR, str(d))
    return d


@pytest.fixture(scope="module")
def db_path(tmp_path_factory):
    """8 只标的、300 个交易日的合成行情(几何随机游走, 固定种子)。"""
    path = str(tmp_path_factory.mktemp("db") / "prices.db")
    init_schema(path=path)
    rng = np.random.default_rng(0)
    dates = pd.bdate_range("2023-01-02", periods=300)
    rows = []
    for i, t in enumerate(["AAA", "BBB", "CCC", "DDD", "EEE", "FFF", "GGG", "HHH"]):
        close = 100 * np.cumprod(1 + rng.normal(0.0003 * i, 0.02, len(dates)))
        for d, c in zip(dates, close, strict=True):
            rows.append({"date": d.strftime("%Y-%m-%d"), "ticker": t, "open": c, "high": c, "low": c,
                         "close": c, "adj_close": c, "volume": 1e6})
    save_prices(pd.DataFrame(rows), path=path)
    return path


def _build_gap_momentum(name="gap_mom"):
    """拼一个"跳过最近 skip 天的 window 天动量": price[t-skip]/price[t-skip-window] - 1。"""
    fl.draft_create(name, ["window", "skip"], "跳过最近几天的动量")
    fl.draft_add_step(name, "near", "shift", input={"ref": "price"}, by={"param": "skip"})
    fl.draft_add_step(name, "far", "shift", input={"ref": "near"}, by={"param": "window"})
    fl.draft_add_step(name, "ratio", "divide", a={"ref": "near"}, b={"ref": "far"})
    fl.draft_add_step(name, "result", "subtract", a={"ref": "ratio"}, b={"const": 1})
    return fl.draft_set_output(name, "result")


def test_draft_step_by_step_then_save(factor_dir):
    view = _build_gap_momentum()
    assert view["ready_to_save"] is True
    assert view["referable_ids"] == ["price", "near", "far", "ratio", "result"]

    listing = fl.list_factors()
    assert listing["drafts"] == ["gap_mom"]
    assert "gap_mom" not in {f["name"] for f in listing["factors"]}  # 草稿不进注册表

    saved = fl.draft_save("gap_mom")
    assert (factor_dir / "gap_mom.yaml").exists()
    assert saved["overwrote_existing"] is False
    listing = fl.list_factors()
    assert listing["drafts"] == []
    by_name = {f["name"]: f for f in listing["factors"]}
    assert by_name["gap_mom"]["source"] == "library"
    assert by_name["momentum"]["source"] == "builtin"
    assert fl.show_factor("gap_mom")["kind"] == "library"


def test_invalid_steps_rejected_and_not_written():
    fl.draft_create("bad", ["window"])
    cases = [
        ({"step_id": "x", "op": "shift", "input": {"ref": "price"}, "by": {"const": -3}}, "未来函数"),
        ({"step_id": "x", "op": "add", "a": {"ref": "nope"}, "b": {"const": 1}}, "不存在"),
        ({"step_id": "x", "op": "add", "a": {"ref": "price"}, "b": {"param": "undeclared"}}, "没在 params 里声明"),
        ({"step_id": "x", "op": "exec", "a": {"ref": "price"}, "b": {"const": 1}}, "不在白名单里"),
        ({"step_id": "x", "op": "add", "input": {"ref": "price"}, "by": {"const": 1}}, "只接受"),
        ({"step_id": "x", "op": "add", "a": {"ref": "price"}}, "缺 b"),
        ({"step_id": "price", "op": "add", "a": {"ref": "price"}, "b": {"const": 1}}, "重复"),
        ({"step_id": "X-1", "op": "add", "a": {"ref": "price"}, "b": {"const": 1}}, "不合法"),
    ]
    for kwargs, msg in cases:
        with pytest.raises(FactorLabError, match=msg):
            fl.draft_add_step("bad", **kwargs)
    assert fl.show_factor("bad")["spec"]["steps"] == []


def test_names_are_sanitized():
    for name in ["../evil", "Evil", "a/b", "", "x" * 41]:
        with pytest.raises(FactorLabError, match="不合法"):
            fl.draft_create(name)


def test_cannot_shadow_builtin():
    with pytest.raises(FactorLabError, match="内置因子"):
        fl.draft_create("momentum", ["window"])


def test_save_requires_output_and_remove_last_step_clears_it():
    fl.draft_create("half", [])
    fl.draft_add_step("half", "r", "multiply", a={"ref": "price"}, b={"const": 0.5})
    with pytest.raises(FactorLabError, match="缺 output"):
        fl.draft_save("half")
    fl.draft_set_output("half", "r")
    view = fl.draft_remove_last_step("half")
    assert view["removed"]["id"] == "r"
    assert "output" not in view["spec"]
    assert view["ready_to_save"] is False


def test_edit_saved_library_factor_overwrites(factor_dir):
    _build_gap_momentum("lib_f")
    fl.draft_save("lib_f")
    view = fl.draft_create("lib_f")  # 以已保存的版本为底稿
    assert len(view["spec"]["steps"]) == 4
    fl.draft_remove_last_step("lib_f")
    fl.draft_add_step("lib_f", "result", "subtract", a={"ref": "ratio"}, b={"const": 1.0})
    fl.draft_set_output("lib_f", "result")
    assert fl.draft_save("lib_f")["overwrote_existing"] is True


def test_preview_draft_in_subprocess(db_path):
    _build_gap_momentum()
    r = fl.preview("gap_mom", {"window": 20, "skip": 5}, None, "2023-01-01", "2024-12-31", db_path, horizon=10)
    assert r["universe"]["n_tickers"] == 8
    assert 0.8 < r["coverage"] < 1.0  # 前 25 天是 NaN
    assert r["distribution"]["inf_count"] == 0
    assert r["rank_ic"]["n_periods"] > 20
    assert len(r["latest_cross_section"]["top"]) == 5
    assert r["resource_limits"]["cpu_s"] == fl.WORKER_CPU_S


def test_preview_reports_runtime_errors(db_path):
    _build_gap_momentum()
    with pytest.raises(FactorLabError, match="未来函数"):
        fl.preview("gap_mom", {"window": 20, "skip": -1}, None, "2023-01-01", "2024-12-31", db_path)
    with pytest.raises(FactorLabError, match="需要参数"):
        fl.preview("gap_mom", {"window": 20}, None, "2023-01-01", "2024-12-31", db_path)


def test_backtest_uses_saved_library_factor(db_path):
    _build_gap_momentum()
    with pytest.raises(FactorLabError, match="先 factor_draft_save"):
        fl.backtest([{"name": "gap_mom"}], None, "2023-01-01", "2024-12-31", db_path)
    fl.draft_save("gap_mom")
    r = fl.backtest(
        [{"name": "gap_mom", "params": {"window": 20, "skip": 5}, "weight": 0.6},
         {"name": "reversal", "params": {"window": 5}, "weight": 0.4}],
        ["AAA", "BBB", "CCC", "DDD", "EEE", "FFF", "GGG", "HHH"],
        "2023-01-01", "2024-12-31", db_path, freq=10, n_quantiles=4, commission_bps=5,
    )
    assert set(r["quantile_forward_returns"]) == {"0", "1", "2", "3"}
    assert r["metrics"]["sharpe_ratio"] is not None
    assert r["nav_month_end"]


def test_backtest_input_limits(db_path):
    with pytest.raises(FactorLabError, match="最多"):
        fl.backtest([{"name": "momentum"}] * 6, None, "2023-01-01", "2024-12-31", db_path)
    with pytest.raises(FactorLabError, match="只能出现一次"):
        fl.backtest([{"name": "momentum"}, {"name": "momentum"}], None, "2023-01-01", "2024-12-31", db_path)
    with pytest.raises(FactorLabError, match="最多 100"):
        fl.preview("momentum", {"window": 5}, [f"T{i}" for i in range(101)], "2023-01-01", "2024-12-31", db_path)


def test_worker_timeout_is_enforced():
    with pytest.raises(FactorLabError, match="被终止"):
        fl.run_worker({"task": "preview"}, timeout_s=0.001)
