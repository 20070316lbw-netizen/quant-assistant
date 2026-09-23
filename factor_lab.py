"""让 Agent 一步步拼因子: 草稿管理 + 受限子进程试算/回测。

设计照 ../minibacktest README「未来打算：让 Agent 拼装因子」一节:

- Agent 不写 YAML 文本, 也不写代码, 而是一步步调工具——"新建草稿"、"加一步
  shift/divide/..."、"指定输出"、"保存"。每一步落地成草稿 YAML 里的一个 step,
  加的那一刻就用 minibacktest 的 validate_spec(partial=True)做完整静态校验,
  写错了当场报错, 不会拖到最后才发现。
- 词表就是 minibacktest 的 ALLOWED_OPS(add/subtract/multiply/divide/shift),
  没有 eval/import/文件/网络原语, 所以"沙箱"要防的只是资源失控: 试算和回测
  放进子进程(factor_worker.py), 子进程先给自己设 CPU/内存上限再干活, 父进程
  再套一层墙钟超时。另外输入规模本身有上限(标的数、步数), 每一步只是一张
  T×N 的表, 内存占用在构造上就是有界的——macOS 不强制 RLIMIT_AS, 这层
  "规模上限"才是那里真正起作用的内存保护。
- 保存下来的因子放在 QUANT_ASSISTANT_FACTOR_DIR(默认本仓库的 factors/),
  通过 MINIBACKTEST_EXTRA_FACTOR_DIRS 挂进 minibacktest 的注册表, 跟内置的
  momentum/reversal 一样能被 Backtester 按名字取到; 不能和内置因子同名。
  草稿放在它的 drafts/ 子目录, 注册表只扫顶层 *.yaml, 草稿不会被当成正式因子。

这个模块只管"工具该做什么"; Agent 能不能调用由 dsh/quant-tool-policy.ts 决定。
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml
from minibacktest.factors import (
    ALLOWED_OPS,
    EXTRA_DIRS_ENV_VAR,
    OP_FIELDS,
    FactorSpecError,
    load_specs,
    validate_spec,
)

FACTOR_DIR_ENV_VAR = "QUANT_ASSISTANT_FACTOR_DIR"
DEFAULT_FACTOR_DIR = Path(__file__).resolve().parent / "factors"
WORKER_PATH = Path(__file__).resolve().parent / "factor_worker.py"

# 因子名和 step id 都会进文件名 / YAML, 只允许小写蛇形, 顺带杜绝路径穿越。
_NAME_RE = re.compile(r"^[a-z][a-z0-9_]{0,39}$")

MAX_STEPS = 40          # 一个因子最多几步
MAX_PARAMS = 8
MAX_TICKERS = 100       # 试算/回测一次最多多少标的
MAX_FACTORS_PER_BACKTEST = 5
DESCRIPTION_MAX_LEN = 500

# 子进程资源上限。墙钟超时由父进程强制; CPU/内存由子进程启动时 setrlimit。
WORKER_TIMEOUT_S = 60
WORKER_CPU_S = 60
WORKER_MEMORY_MB = 2048


class FactorLabError(ValueError):
    """给 Agent 看的业务错误(名字不合法、草稿不存在、子进程超时等)。
    FastMCP 会把 ValueError 转成工具调用错误返回, 不会崩掉 server。"""


# ---------------------------------------------------------------- 路径与存取


def factor_dir() -> Path:
    raw = os.environ.get(FACTOR_DIR_ENV_VAR)
    return Path(raw).expanduser() if raw else DEFAULT_FACTOR_DIR


def _drafts_dir() -> Path:
    return factor_dir() / "drafts"


def _check_name(name: str, what: str = "因子名") -> str:
    if not isinstance(name, str) or not _NAME_RE.match(name):
        raise FactorLabError(f"{what} {name!r} 不合法: 只能用小写字母开头的 a-z/0-9/下划线, 最长 40 个字符")
    return name


def _draft_path(name: str) -> Path:
    return _drafts_dir() / f"{_check_name(name)}.yaml"


def _registry_env() -> dict[str, str]:
    """子进程和本进程查询注册表时用的环境变量: 把因子库目录挂进 minibacktest。"""
    env = dict(os.environ)
    extra = [str(factor_dir())]
    if env.get(EXTRA_DIRS_ENV_VAR):
        extra.append(env[EXTRA_DIRS_ENV_VAR])
    env[EXTRA_DIRS_ENV_VAR] = os.pathsep.join(extra)
    return env


def _registered_specs() -> dict[str, tuple[Path, dict[str, Any]]]:
    """内置 + 因子库里的全部已注册因子(不含草稿)。"""
    try:
        return load_specs(extra_dirs=[factor_dir()])
    except FactorSpecError as exc:
        raise FactorLabError(f"因子注册表加载失败: {exc}") from exc


def _is_library_path(path: Path) -> bool:
    return path.resolve().parent == factor_dir().resolve()


def _read_draft(name: str) -> dict[str, Any]:
    path = _draft_path(name)
    if not path.exists():
        raise FactorLabError(f"没有叫 {name!r} 的草稿, 先用 factor_draft_create 新建")
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def _write_yaml(path: Path, spec: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = yaml.safe_dump(spec, allow_unicode=True, sort_keys=False)
    tmp = path.with_suffix(".yaml.tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)  # 原子替换, 不会留下写了一半的 YAML


def _draft_view(spec: dict[str, Any]) -> dict[str, Any]:
    """返回给 Agent 的草稿状态: 完整 spec + 下一步能引用什么 + 是否可以保存。"""
    steps = spec.get("steps") or []
    try:
        validate_spec(spec, factor_name=spec["name"])
        ready, problem = True, None
    except FactorSpecError as exc:
        ready, problem = False, str(exc)
    return {
        "spec": spec,
        "yaml": yaml.safe_dump(spec, allow_unicode=True, sort_keys=False),
        "referable_ids": ["price", *[s["id"] for s in steps]],
        "declared_params": spec.get("params") or [],
        "ready_to_save": ready,
        "not_ready_reason": problem,
    }


def _validate_draft(spec: dict[str, Any]) -> None:
    try:
        validate_spec(spec, factor_name=spec["name"], partial=True)
    except FactorSpecError as exc:
        raise FactorLabError(str(exc)) from exc


# ---------------------------------------------------------------- 查看


def list_factors() -> dict[str, Any]:
    """已注册因子(内置/因子库)、草稿, 以及可用的 op 词表。"""
    factors = []
    for name, (path, spec) in sorted(_registered_specs().items()):
        factors.append(
            {
                "name": name,
                "source": "library" if _is_library_path(path) else "builtin",
                "params": spec.get("params") or [],
                "description": spec.get("description", ""),
                "n_steps": len(spec.get("steps") or []),
            }
        )
    drafts = sorted(p.stem for p in _drafts_dir().glob("*.yaml")) if _drafts_dir().is_dir() else []
    return {
        "factors": factors,
        "drafts": drafts,
        "ops": {op: list(OP_FIELDS[op]) for op in sorted(ALLOWED_OPS)},
        "operand_forms": ['{"const": 数字}', '{"param": 参数名}', '{"ref": "price" 或前面某步的 id}'],
    }


def show_factor(name: str) -> dict[str, Any]:
    """查看一个已注册因子或草稿的完整定义。草稿优先(同名时说明正在改它)。"""
    _check_name(name)
    if _draft_path(name).exists():
        return {"kind": "draft", **_draft_view(_read_draft(name))}
    specs = _registered_specs()
    if name not in specs:
        raise FactorLabError(f"没有叫 {name!r} 的因子或草稿, 已注册的有 {sorted(specs)}")
    path, spec = specs[name]
    return {
        "kind": "library" if _is_library_path(path) else "builtin",
        "spec": spec,
        "yaml": yaml.safe_dump(spec, allow_unicode=True, sort_keys=False),
    }


# ---------------------------------------------------------------- 草稿: 一步步拼


def draft_create(name: str, params: list[str] | None = None, description: str = "") -> dict[str, Any]:
    _check_name(name)
    params = list(params or [])
    if len(params) > MAX_PARAMS:
        raise FactorLabError(f"参数最多 {MAX_PARAMS} 个")
    for p in params:
        _check_name(p, "参数名")
    if _draft_path(name).exists():
        raise FactorLabError(f"草稿 {name!r} 已经存在; 继续往里加步骤, 或先 factor_draft_delete")
    specs = _registered_specs()
    if name in specs and not _is_library_path(specs[name][0]):
        raise FactorLabError(f"{name!r} 是内置因子的名字, 换一个")
    spec: dict[str, Any] = {"name": name, "description": str(description)[:DESCRIPTION_MAX_LEN], "params": params,
                            "steps": []}
    if name in specs:
        # 因子库里已有同名因子: 以它为底稿修改, 保存时覆盖。
        spec = {**specs[name][1], "name": name}
    _validate_draft(spec)
    _write_yaml(_draft_path(name), spec)
    return _draft_view(spec)


def draft_add_step(
    name: str,
    step_id: str,
    op: str,
    a: dict[str, Any] | None = None,
    b: dict[str, Any] | None = None,
    input: dict[str, Any] | None = None,
    by: dict[str, Any] | None = None,
) -> dict[str, Any]:
    spec = _read_draft(name)
    _check_name(step_id, "step id")
    if op not in ALLOWED_OPS:
        raise FactorLabError(f"op {op!r} 不在白名单里, 只认 {sorted(ALLOWED_OPS)}")
    steps = list(spec.get("steps") or [])
    if len(steps) >= MAX_STEPS:
        raise FactorLabError(f"一个因子最多 {MAX_STEPS} 步")
    given = {"a": a, "b": b, "input": input, "by": by}
    fields = OP_FIELDS[op]
    wrong = [k for k, v in given.items() if v is not None and k not in fields]
    if wrong:
        raise FactorLabError(f"{op} 只接受 {list(fields)}, 不要传 {wrong}")
    step: dict[str, Any] = {"id": step_id, "op": op}
    for f in fields:
        if given[f] is None:
            raise FactorLabError(f"{op} 需要 {list(fields)}, 缺 {f}")
        step[f] = given[f]
    candidate = {**spec, "steps": [*steps, step]}
    _validate_draft(candidate)
    _write_yaml(_draft_path(name), candidate)
    return _draft_view(candidate)


def draft_remove_last_step(name: str) -> dict[str, Any]:
    spec = _read_draft(name)
    steps = list(spec.get("steps") or [])
    if not steps:
        raise FactorLabError(f"草稿 {name!r} 还没有任何步骤")
    removed = steps.pop()
    spec = {**spec, "steps": steps}
    if spec.get("output") == removed["id"]:
        spec.pop("output")
    _write_yaml(_draft_path(name), spec)
    return {"removed": removed, **_draft_view(spec)}


def draft_set_output(name: str, step_id: str) -> dict[str, Any]:
    spec = {**_read_draft(name), "output": step_id}
    _validate_draft(spec)
    _write_yaml(_draft_path(name), spec)
    return _draft_view(spec)


def draft_delete(name: str) -> dict[str, Any]:
    path = _draft_path(name)
    if not path.exists():
        raise FactorLabError(f"没有叫 {name!r} 的草稿")
    path.unlink()
    return {"deleted": name}


def draft_save(name: str) -> dict[str, Any]:
    """草稿通过完整校验后存进因子库, 之后能被 run_factor_backtest 按名字使用。"""
    spec = _read_draft(name)
    try:
        validate_spec(spec, factor_name=name)
    except FactorSpecError as exc:
        raise FactorLabError(f"还不能保存: {exc}") from exc
    specs = _registered_specs()
    if name in specs and not _is_library_path(specs[name][0]):
        raise FactorLabError(f"{name!r} 是内置因子的名字, 不能覆盖")
    target = factor_dir() / f"{name}.yaml"
    overwritten = target.exists()
    _write_yaml(target, spec)
    _draft_path(name).unlink()
    return {"saved": name, "path": str(target), "overwrote_existing": overwritten}


# ---------------------------------------------------------------- 受限子进程


def _resolve_spec(name: str) -> dict[str, Any]:
    """试算用的 spec: 草稿优先, 其次已注册因子。"""
    _check_name(name)
    if _draft_path(name).exists():
        spec = _read_draft(name)
        try:
            validate_spec(spec, factor_name=name)
        except FactorSpecError as exc:
            raise FactorLabError(f"草稿还不完整, 不能试算: {exc}") from exc
        return spec
    specs = _registered_specs()
    if name not in specs:
        raise FactorLabError(f"没有叫 {name!r} 的因子或草稿")
    return specs[name][1]


def _check_tickers(tickers: list[str] | None) -> list[str] | None:
    if tickers is None:
        return None
    if not tickers:
        raise FactorLabError("tickers 不能是空列表; 不传表示用数据库里的全部标的")
    if len(tickers) > MAX_TICKERS:
        raise FactorLabError(f"一次最多 {MAX_TICKERS} 个标的")
    return [str(t).upper() for t in tickers]


def run_worker(task: dict[str, Any], *, timeout_s: float = WORKER_TIMEOUT_S) -> dict[str, Any]:
    """在子进程里跑 factor_worker.py: stdin 进一个 JSON 任务, stdout 出一个 JSON 结果。

    子进程启动第一件事就是给自己 setrlimit(CPU 秒数 + 地址空间), 父进程这边
    再用 subprocess.run(timeout=...) 兜底墙钟时间——因子算飞了只会让这一次工具
    调用报错, 不会卡住或吃光 MCP server 所在的进程。
    """
    payload = {**task, "limits": {"cpu_s": WORKER_CPU_S, "memory_mb": WORKER_MEMORY_MB}}
    try:
        proc = subprocess.run(
            [sys.executable, str(WORKER_PATH)],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            timeout=timeout_s,
            env=_registry_env(),
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise FactorLabError(f"计算超过 {timeout_s:g} 秒被终止; 缩小标的数/日期范围后重试") from exc

    out = proc.stdout.strip().splitlines()
    result = None
    if out:
        try:
            result = json.loads(out[-1])
        except json.JSONDecodeError:
            result = None
    if result is None:
        tail = "\n".join(proc.stderr.strip().splitlines()[-5:])
        raise FactorLabError(f"计算子进程异常退出(exit={proc.returncode}): {tail or '无输出'}")
    if "error" in result:
        raise FactorLabError(result["error"])
    return result


def preview(
    name: str,
    params: dict[str, Any] | None,
    tickers: list[str] | None,
    start: str,
    end: str,
    db_path: str,
    horizon: int = 21,
) -> dict[str, Any]:
    if not 1 <= int(horizon) <= 252:
        raise FactorLabError("horizon 取 1~252 个交易日")
    return run_worker(
        {
            "task": "preview",
            "factor_name": name,
            "spec": _resolve_spec(name),
            "params": params or {},
            "tickers": _check_tickers(tickers),
            "start": start,
            "end": end,
            "db_path": db_path,
            "horizon": int(horizon),
        }
    )


def backtest(
    factors: list[dict[str, Any]],
    tickers: list[str] | None,
    start: str,
    end: str,
    db_path: str,
    freq: int = 21,
    n_quantiles: int = 5,
    commission_bps: float = 0.0,
    slippage_bps: float = 0.0,
) -> dict[str, Any]:
    if not factors:
        raise FactorLabError("factors 不能为空")
    if len(factors) > MAX_FACTORS_PER_BACKTEST:
        raise FactorLabError(f"一次回测最多 {MAX_FACTORS_PER_BACKTEST} 个因子")
    specs = _registered_specs()
    drafts = {p.stem for p in _drafts_dir().glob("*.yaml")} if _drafts_dir().is_dir() else set()
    cleaned = []
    for f in factors:
        name = _check_name(f.get("name", ""))
        if name not in specs:
            hint = "; 它还是草稿, 先 factor_draft_save" if name in drafts else ""
            raise FactorLabError(f"因子 {name!r} 没有注册{hint}")
        cleaned.append({"name": name, "params": dict(f.get("params") or {}), "weight": float(f.get("weight", 1.0))})
    if len({c["name"] for c in cleaned}) != len(cleaned):
        raise FactorLabError("同一个因子在一次回测里只能出现一次")
    if not 1 <= int(freq) <= 252 or not 2 <= int(n_quantiles) <= 10:
        raise FactorLabError("freq 取 1~252, n_quantiles 取 2~10")
    if not (0 <= commission_bps <= 100 and 0 <= slippage_bps <= 100):
        raise FactorLabError("commission_bps / slippage_bps 取 0~100")
    return run_worker(
        {
            "task": "backtest",
            "factors": cleaned,
            "tickers": _check_tickers(tickers),
            "start": start,
            "end": end,
            "db_path": db_path,
            "freq": int(freq),
            "n_quantiles": int(n_quantiles),
            "commission_bps": float(commission_bps),
            "slippage_bps": float(slippage_bps),
        },
        timeout_s=WORKER_TIMEOUT_S * 2,
    )
