"""往 sp500.db 里灌一批真实行情数据，供 query_prices 实际查到东西用。

只做这一件事：从 sources.get_prices（yfinance）拉 sources.map.first_50 里
已经定好的 50 支标的、最近 10 年的日线，清洗好之后用 liudb.save_prices
写进 QUANT_ASSISTANT_DB_PATH 指向的数据库。不做增量更新、不做重试调度——
这是个一次性种子脚本，跑坏了直接删掉 sp500.db 重跑就行，不用像线上 ETL
那样考虑幂等和断点续传。

用法：
    QUANT_ASSISTANT_DB_PATH=/path/to/sp500.db uv run python scripts/seed_prices.py
不传环境变量就用 liudb 的默认相对路径 sp500.db（不建议，容易忘了到底写去哪了）。
"""
from __future__ import annotations

import os
import sys
from datetime import date, timedelta

from loguru import logger

from liudb import init_schema, save_prices
from sources import get_prices
from sources.map.first_50 import tickers

YEARS = 10


def main() -> None:
    db_path = os.environ.get("QUANT_ASSISTANT_DB_PATH")
    if not db_path:
        logger.error("请设置 QUANT_ASSISTANT_DB_PATH，明确写去哪个数据库文件")
        sys.exit(1)

    end = date.today()
    start = end - timedelta(days=365 * YEARS)

    logger.info(f"目标数据库: {db_path}")
    logger.info(f"标的数量: {len(tickers)}")
    logger.info(f"日期范围: {start} ~ {end}")

    init_schema(path=db_path)

    # yfinance 一次性传所有 ticker 是它自己内部分批/多线程处理的，不用我们
    # 自己拆批次；单个 ticker 抓取失败只会在 get_prices 内部记 warning 并跳过，
    # 不会让整批失败。
    frame = get_prices(tickers, start=start.isoformat(), end=end.isoformat())

    if frame.empty:
        logger.error("get_prices 返回空结果，一行都没拿到，检查网络或 yfinance 是否可用")
        sys.exit(1)

    fetched_tickers = sorted(frame["ticker"].unique())
    missing = sorted(set(tickers) - set(fetched_tickers))
    if missing:
        logger.warning(f"这些标的没拿到数据，跳过了: {missing}")

    logger.info(f"拿到 {len(frame)} 行，覆盖 {len(fetched_tickers)} 支标的，开始写入…")
    save_prices(frame, path=db_path)
    logger.info("写入完成。")


if __name__ == "__main__":
    main()
