"""quant-assistant 的 MCP server：把 liudb 的行情读取接口包成 query_prices 工具，
再加一组"一步步拼因子 + 试算 + 回测"的工具（逻辑在 factor_lab.py）。

供 DSH Agent 通过 stdio 调用。数据库路径尚未
最终确定（见 README「已完成的环境验证」一节），因此这里不写死默认路径，而是
从环境变量 QUANT_ASSISTANT_DB_PATH 读取；调用方（DSH profile / 本地调试）负责
设置它指向真实的 sp500.db。

allow/deny 工具白名单不在这个文件里实现——这里只负责"工具本身该做什么"，
"Agent 能不能调用它"是 DSH policy 层的事情，留给下一步。
"""
from __future__ import annotations

import os
from typing import Any

from liudb.reader.query import Query, loader
from mcp.server.fastmcp import FastMCP
from pydantic import ValidationError

import factor_lab

# 单次查询最多返回的行数，防止 Agent 传入过大的日期范围/标的列表时
# 把整张 prices 表都吐给模型。超过时按 [date, ticker] 升序截断，而不是报错，
# 这样 Agent 至少能拿到一部分数据、看到 truncated=True 后自己缩小范围重试。
MAX_ROWS = 2000

# query_prices 不传 columns 时返回的默认列，覆盖常见的 OHLCV 全集。
DEFAULT_COLUMNS = ("open", "high", "low", "close", "volume")

DB_PATH_ENV_VAR = "QUANT_ASSISTANT_DB_PATH"

mcp = FastMCP("quant-assistant")


def _resolve_db_path() -> str:
    """从环境变量取数据库路径；未设置时给出明确报错而不是猜一个默认值。

    数据库位置还没定下来（README 里明确写了留到第一片垂直切片再确定），
    与其硬编码一个大概率是错的相对路径，不如在调用时报错，把配置这件事
    逼到显式设置 QUANT_ASSISTANT_DB_PATH 上。
    """
    path = os.environ.get(DB_PATH_ENV_VAR)
    if not path:
        raise ValueError(
            f"未设置环境变量 {DB_PATH_ENV_VAR}，不知道去哪个 sp500.db 查询。"
            "启动 MCP server 前请先设置它指向 liudb 的数据库文件。"
        )
    return path


def query_prices_impl(
    tickers: list[str],
    start: str,
    end: str,
    columns: list[str] | None = None,
    db_path: str | None = None,
) -> dict:
    """query_prices 的核心逻辑，不依赖 FastMCP 的装饰器，方便单测直接调用。

    Args:
        tickers: 标的代码列表，如 ["AAPL", "KO"]。必填且不能为空——不支持
            "不限标的"的查询，避免 Agent 一次性拉取整张表。
        start: 起始日期（含），格式 "YYYY-MM-DD"。
        end: 结束日期（含），格式 "YYYY-MM-DD"。
        columns: 需要的列，取值范围见 liudb 的 registry（open/high/low/close/
            volume）。不传则返回 DEFAULT_COLUMNS 全部五列。close 已经是复权
            收盘价（liudb 的 registry 把 close 映射到物理列 adj_close）。
        db_path: 数据库文件路径。测试时直接传入临时文件；不传则从环境变量
            QUANT_ASSISTANT_DB_PATH 读取。

    Returns:
        dict:
        - rows: 每行一个 {date, ticker, <columns...>} 字典，date 是 ISO 字符串。
        - row_count: 实际返回的行数（截断之后）。
        - truncated: 是否因超过 MAX_ROWS 被截断。

    Raises:
        ValueError: tickers 为空、列名不在白名单、或数据库路径未配置。
            FastMCP 会把这里的 ValueError 转成工具调用错误返回给 Agent，
            不会让异常直接崩掉 server 进程。
    """
    if not tickers:
        raise ValueError("tickers 不能为空，query_prices 要求显式指定标的列表")

    resolved_path = db_path if db_path is not None else _resolve_db_path()
    request_columns = list(columns) if columns else list(DEFAULT_COLUMNS)

    try:
        request = Query(
            columns=request_columns, # type: ignore
            tickers=list(tickers),
            start=start,
            end=end,
        )
    except ValidationError as exc:
        raise ValueError(str(exc)) from exc

    frame = loader(request=request, path=resolved_path).reset_index()

    total_rows = len(frame)
    truncated = total_rows > MAX_ROWS
    if truncated:
        frame = frame.iloc[:MAX_ROWS]

    # DuckDB 的 date 列经 df() 转换后是 pandas Timestamp，转成 ISO 字符串方便
    # MCP 走 JSON 序列化；其余列都是 float/str，原样保留。
    frame["date"] = frame["date"].astype(str)

    return {
        "rows": frame.to_dict(orient="records"),
        "row_count": len(frame),
        "truncated": truncated,
    }


@mcp.tool()
def query_prices(
    tickers: list[str],
    start: str,
    end: str,
    columns: list[str] | None = None,
) -> dict:
    """查询本地 liudb 中的复权行情数据（open/high/low/close/volume）。

    Args:
        tickers: 标的代码列表，例如 ["AAPL", "KO"]。必填。
        start: 起始日期（含），格式 "YYYY-MM-DD"。
        end: 结束日期（含），格式 "YYYY-MM-DD"。
        columns: 需要的列（open/high/low/close/volume），不传则返回全部五列。
            close 是复权后的收盘价。

    Returns:
        dict，包含 rows（逐行记录）、row_count（返回行数）、
        truncated（是否因超过单次上限被截断）。
    """
    return query_prices_impl(tickers=tickers, start=start, end=end, columns=columns)


# ------------------------------------------------------------------ 拼因子工具
#
# 因子只能用 minibacktest 白名单里的 op 拼, 每个
# 操作数写成 {"const": 数字} / {"param": 参数名} / {"ref": "price" 或前面某步的 id}。
# 草稿每加一步就做一次完整静态校验; 试算和回测放在带资源上限的子进程里跑。

Operand = dict[str, str | int | float]


@mcp.tool()
def list_factors() -> dict:
    """列出已注册因子(builtin=minibacktest 自带, library=之前保存的)、未保存的草稿,
    以及拼因子能用的 op 和操作数写法。开始拼新因子前先看一眼, 避免重名。"""
    return factor_lab.list_factors()


@mcp.tool()
def show_factor(name: str) -> dict:
    """查看一个因子或草稿的完整定义(spec + YAML)。草稿还会给出下一步能引用的 id
    和是否已经可以保存。"""
    return factor_lab.show_factor(name)


@mcp.tool()
def factor_draft_create(name: str, params: list[str] | None = None, description: str = "") -> dict:
    """新建一个因子草稿。

    Args:
        name: 因子名, 小写蛇形(如 "mom_gap"), 不能跟内置因子重名。如果跟之前保存过的
            因子重名, 会以那个因子为底稿开始修改(params/description 参数被忽略), 保存时覆盖。
        params: 因子参数名列表, 如 ["window"]。窗口长度这类数字尽量做成参数, 不要写死,
            同一个因子才能换参数复用。
        description: 一句话说明这个因子想捕捉什么。
    """
    return factor_lab.draft_create(name, params, description)


@mcp.tool()
def factor_draft_add_step(
    name: str,
    step_id: str,
    op: str,
    a: Operand | None = None,
    b: Operand | None = None,
    input: Operand | None = None,
    by: Operand | None = None,
    window: Operand | None = None,
) -> dict:
    """给草稿追加一步计算, 追加前做完整校验, 不合法直接报错且不落盘。

    Args:
        name: 草稿名。
        step_id: 这一步的 id(小写蛇形), 后面的步骤用 {"ref": step_id} 引用它。
        op: add/subtract/multiply/divide(需要 a、b); shift(需要 input、by);
            rolling_mean/rolling_std/rolling_min/rolling_max(需要 input、window);
            cross_section_rank(只需要 input)。
            shift 把整张表往后挪 by 行(by 必须是非负整数; 负数会用到未来数据, 一律拒绝),
            input 必须是 {"ref": ...}。滚动窗口为 1~512 个交易日, 需完整窗口才产出值;
            cross_section_rank 在同一日期的有限值标的之间按升序计算百分位排名。
        a, b, input, by, window: 操作数, 三种写法之一: {"const": 数字}、
            {"param": 参数名}、{"ref": "price" 或前面某步的 id}。
            window 只接受 const 或 param。"price" 是复权收盘价宽表(行=日期, 列=标的)。

    Returns:
        草稿当前状态: spec、YAML、下一步能引用的 id、是否可以保存。
    """
    return factor_lab.draft_add_step(name, step_id, op, a=a, b=b, input=input, by=by, window=window)


@mcp.tool()
def factor_draft_remove_last_step(name: str) -> dict:
    """撤销草稿的最后一步(如果 output 指向它, output 也一并清掉)。"""
    return factor_lab.draft_remove_last_step(name)


@mcp.tool()
def factor_draft_set_output(name: str, step_id: str) -> dict:
    """指定草稿里哪一步是因子的最终值。设好之后才能试算和保存。"""
    return factor_lab.draft_set_output(name, step_id)


@mcp.tool()
def factor_draft_delete(name: str) -> dict:
    """删除一个草稿(只能删草稿, 不能删已保存的因子)。"""
    return factor_lab.draft_delete(name)


@mcp.tool()
def factor_draft_save(name: str) -> dict:
    """草稿通过完整校验后存进因子库, 之后 run_factor_backtest 才能按名字使用它。"""
    return factor_lab.draft_save(name)


@mcp.tool()
def preview_factor(
    name: str,
    start: str,
    end: str,
    params: dict[str, int | float] | None = None,
    tickers: list[str] | None = None,
    horizon: int = 21,
) -> dict:
    """在真实行情上试算一个因子(草稿或已保存的都行), 不跑回测。

    Args:
        name: 因子或草稿名。
        start, end: 日期范围, "YYYY-MM-DD"。
        params: 因子参数, 如 {"window": 126}。
        tickers: 标的列表, 不传表示本地数据库里的全部标的(最多 100 个)。
        horizon: 计算 Rank IC 用的前瞻天数(交易日), 默认 21。

    Returns:
        覆盖率、分布(含 inf 个数, 除以 0 会产生 inf)、最新截面的前后 5 名,
        以及每隔 horizon 天一个截面的 Rank IC 均值/标准差/ICIR/正值占比。
    """
    return factor_lab.preview(name, params, tickers, start, end, db_path=_resolve_db_path(), horizon=horizon)


@mcp.tool()
def preview_factor_step(
    name: str,
    step_id: str,
    start: str,
    end: str,
    params: dict[str, int | float] | None = None,
    tickers: list[str] | None = None,
    horizon: int = 21,
) -> dict:
    """试算因子或草稿的一个中间步骤, 无需先指定最终 output, 也不会修改草稿。

    返回该步骤的覆盖率、分布、最新截面和 Rank IC, 用来排查空值、无穷值或
    方向不对的问题。参数、日期和标的限制与 preview_factor 相同。
    """
    return factor_lab.preview(
        name, params, tickers, start, end, db_path=_resolve_db_path(), horizon=horizon, step_id=step_id
    )


@mcp.tool()
def run_factor_backtest(
    factors: list[dict[str, Any]],
    start: str,
    end: str,
    tickers: list[str] | None = None,
    freq: int = 21,
    n_quantiles: int = 5,
    commission_bps: float = 0.0,
    slippage_bps: float = 0.0,
) -> dict:
    """用已保存/内置的因子跑 minibacktest 截面多空回测(分位数多空、向量化)。

    Args:
        factors: [{"name": 因子名, "params": {...}, "weight": 权重}], 最多 5 个;
            各因子先截面 z-score 再按权重合成打分。草稿要先 factor_draft_save。
        start, end: 日期范围, "YYYY-MM-DD"。
        tickers: 标的列表, 不传表示本地数据库里的全部标的。
        freq: 调仓间隔(交易日), 默认 21(月度)。
        n_quantiles: 分组数, 做多最高组、做空最低组, 默认 5。
        commission_bps, slippage_bps: 单边佣金/滑点, 单位 bp。

    Returns:
        收益/风险/回撤/换手/成本指标、各分位组平均前瞻收益(检验单调性)、月末净值序列。
    """
    return factor_lab.backtest(
        factors, tickers, start, end, db_path=_resolve_db_path(), freq=freq, n_quantiles=n_quantiles,
        commission_bps=commission_bps, slippage_bps=slippage_bps,
    )


if __name__ == "__main__":
    mcp.run()
