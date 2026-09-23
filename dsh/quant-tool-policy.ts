/**
 * quant-acp 的工具白名单策略：默认拒绝一切模型可见工具，只放行显式登记的
 * 量化工具全名。挂在 DSH 的 `tools/pre-execute` waterfall 上，因此不管
 * 工具是哪个 bundle 注册的（dsh-base 的 bash/fs、我们自己的 quant MCP
 * server……），只要不在 ALLOWED_TOOLS 里，一律 deny。
 *
 * 这是运行时强制的白名单，不是提示词层面的"建议"：即使 profile 目前还
 * 挂着 dsh-base（bash、文件工具都还在工具目录里），Agent 实际调用它们时
 * 也会在这里被拦下来，返回模型可见的 deny 而不执行工具正文。
 *
 * 对照 LOCAL_QUANT_ASSISTANT_TECHNICAL_MANUAL.md 第 8 节的完整策略表：
 * 这里只登记了已经实现并测试过的工具：query_prices，以及"一步步拼因子"
 * 那一组（factor_lab.py：看因子、草稿增删步骤、试算、保存、回测）。手册里
 * list_universe/query_roe/refresh_* 等工具还没写，先不放进白名单——等对应的
 * MCP 工具真正实现、测试通过，再加一行。
 *
 * 拼因子工具能直接放行（不需要人工确认）的理由：它们只能写 factors/ 下的
 * YAML（草稿可删、已保存的因子不能删），计算只能用 minibacktest 的五种数值
 * op，试算/回测跑在带 CPU/内存/超时上限的子进程里——没有执行任意代码、
 * 读写任意文件或联网的路径。
 */
import type { Context } from '@deepseek-ai/cordis'
import type {} from '@deepseek-ai/dsh-tools'
import type { PreToolDecision, ToolExecution } from '@deepseek-ai/dsh-tools'

export const name = 'quant-tool-policy'

/** 已实现、已测试、允许 Agent 直接调用（无需人工批准）的工具全名。 */
export const ALLOWED_TOOLS: ReadonlySet<string> = new Set([
  'mcp__quant__query_prices',
  // 拼因子（factor_lab.py）
  'mcp__quant__list_factors',
  'mcp__quant__show_factor',
  'mcp__quant__factor_draft_create',
  'mcp__quant__factor_draft_add_step',
  'mcp__quant__factor_draft_remove_last_step',
  'mcp__quant__factor_draft_set_output',
  'mcp__quant__factor_draft_delete',
  'mcp__quant__factor_draft_save',
  'mcp__quant__preview_factor',
  'mcp__quant__run_factor_backtest',
])

/**
 * 根据工具全名给出 pre-execute 决定。拆成纯函数方便单测：不用起 DSH、
 * 不用连 MCP server、不用调模型，直接传字符串断言结果。
 */
export function decideToolAccess(toolName: string): PreToolDecision {
  if (ALLOWED_TOOLS.has(toolName)) {
    return { kind: 'allow' }
  }
  return {
    kind: 'deny',
    reason: `工具 "${toolName}" 不在 quant-acp 的白名单里，已被拒绝。`,
    info: { name: 'QuantToolPolicyDeniedError', code: 'QUANT_TOOL_NOT_ALLOWED' },
  }
}

export function apply(ctx: Context) {
  ctx.on('tools/pre-execute', async (exec: ToolExecution, next: () => Promise<PreToolDecision>) => {
    const decision = decideToolAccess(exec.name)
    if (decision.kind === 'allow') {
      return next()
    }
    return decision
  })
}
