"""query_prices 的单测：直接调用 query_prices_impl, 不经过 FastMCP/stdio。"""
from __future__ import annotations

import pandas as pd
import pytest
from liudb import init_schema, save_prices

from mcp_server import query_prices_impl


@pytest.fixture
def db_path(tmp_path):
    """临时数据库，写入两只标的、跨越两天的行情，其中一行 close != adj_close
    用来确认 query_prices 返回的是复权价而不是原始收盘价。"""
    path = str(tmp_path / "test_sp500.db")
    init_schema(path=path)

    df = pd.DataFrame(
        [
            {
                "date": "2024-01-02",
                "ticker": "AAPL",
                "open": 180.0,
                "high": 185.0,
                "low": 179.0,
                "close": 182.0,
                "adj_close": 181.5,
                "volume": 5_000_000.0,
            },
            {
                "date": "2024-01-03",
                "ticker": "AAPL",
                "open": 182.0,
                "high": 186.0,
                "low": 181.0,
                "close": 184.0,
                "adj_close": 183.5,
                "volume": 6_000_000.0,
            },
            {
                "date": "2024-01-02",
                "ticker": "MSFT",
                "open": 370.0,
                "high": 375.0,
                "low": 368.0,
                "close": 372.0,
                "adj_close": 372.0,
                "volume": 3_000_000.0,
            },
        ]
    )
    save_prices(df, path=path)
    return path


def test_query_prices_returns_adjusted_close(db_path):
    result = query_prices_impl(
        tickers=["AAPL"],
        start="2024-01-01",
        end="2024-01-31",
        db_path=db_path,
    )

    assert result["row_count"] == 2
    assert result["truncated"] is False
    first_row = result["rows"][0]
    assert first_row["date"] == "2024-01-02"
    assert first_row["ticker"] == "AAPL"
    assert first_row["close"] == 181.5  # 复权价，不是未复权的 182.0


def test_query_prices_filters_by_ticker_and_columns(db_path):
    result = query_prices_impl(
        tickers=["MSFT"],
        start="2024-01-02",
        end="2024-01-02",
        columns=["close", "volume"],
        db_path=db_path,
    )

    assert result["row_count"] == 1
    row = result["rows"][0]
    assert set(row) == {"date", "ticker", "close", "volume"}
    assert row["ticker"] == "MSFT"


def test_query_prices_rejects_empty_tickers(db_path):
    with pytest.raises(ValueError, match="tickers"):
        query_prices_impl(tickers=[], start="2024-01-01", end="2024-01-31", db_path=db_path)


def test_query_prices_rejects_invalid_column(db_path):
    with pytest.raises(ValueError):
        query_prices_impl(
            tickers=["AAPL"],
            start="2024-01-01",
            end="2024-01-31",
            columns=["adj_close"],  # 只能用逻辑列名 close，不能直接要 adj_close
            db_path=db_path,
        )


def test_query_prices_requires_explicit_db_path_or_env(monkeypatch, db_path):
    monkeypatch.delenv("QUANT_ASSISTANT_DB_PATH", raising=False)
    with pytest.raises(ValueError, match="QUANT_ASSISTANT_DB_PATH"):
        query_prices_impl(tickers=["AAPL"], start="2024-01-01", end="2024-01-31")


def test_query_prices_truncates_when_over_max_rows(db_path, monkeypatch):
    import mcp_server

    monkeypatch.setattr(mcp_server, "MAX_ROWS", 1)
    result = mcp_server.query_prices_impl(
        tickers=["AAPL"],
        start="2024-01-01",
        end="2024-01-31",
        db_path=db_path,
    )

    assert result["row_count"] == 1
    assert result["truncated"] is True
