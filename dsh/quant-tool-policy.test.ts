import { describe, expect, it } from 'vitest'
import { ALLOWED_TOOLS, decideToolAccess } from './quant-tool-policy.ts'

describe('decideToolAccess', () => {
  it('allows the implemented quant tools', () => {
    const decision = decideToolAccess('mcp__quant__query_prices')
    expect(decision).toEqual({ kind: 'allow' })
  })

  it('allows the factor-lab tools (draft step by step, preview, save, backtest)', () => {
    for (const toolName of [
      'mcp__quant__list_factors',
      'mcp__quant__factor_draft_create',
      'mcp__quant__factor_draft_add_step',
      'mcp__quant__factor_draft_set_output',
      'mcp__quant__factor_draft_save',
      'mcp__quant__preview_factor',
      'mcp__quant__run_factor_backtest',
    ]) {
      expect(decideToolAccess(toolName)).toEqual({ kind: 'allow' })
    }
  })

  it('matches exact names only: same tool name from another MCP server is denied', () => {
    expect(decideToolAccess('mcp__other__run_factor_backtest').kind).toBe('deny')
    expect(decideToolAccess('run_factor_backtest').kind).toBe('deny')
    expect(decideToolAccess('mcp__quant__factor_delete').kind).toBe('deny')
  })

  it('denies dsh-base bash, even though it stays registered while we sit on the acp template', () => {
    const decision = decideToolAccess('bash')
    expect(decision.kind).toBe('deny')
  })

  it('denies dsh-base generic file tools', () => {
    for (const toolName of ['read_file', 'write_file', 'edit_file']) {
      expect(decideToolAccess(toolName).kind).toBe('deny')
    }
  })

  it('denies quant tools from the manual that are not implemented yet', () => {
    // 手册第 8.2 节列了这些，但对应的 MCP 工具还没写——白名单里不该有它们，
    // 免得白名单"看起来"允许了实际上会 404 的工具。
    for (const toolName of [
      'mcp__quant__list_universe',
      'mcp__quant__query_roe',
      'mcp__quant__refresh_prices',
      'mcp__report__render_quant_report',
    ]) {
      expect(decideToolAccess(toolName).kind).toBe('deny')
    }
  })

  it('denies a tool from a different, unrelated MCP server', () => {
    expect(decideToolAccess('mcp__github__create_issue').kind).toBe('deny')
  })

  it('denies an empty or malformed tool name instead of throwing', () => {
    expect(() => decideToolAccess('')).not.toThrow()
    expect(decideToolAccess('').kind).toBe('deny')
  })

  it('deny reason names the exact rejected tool and carries a structured code', () => {
    const decision = decideToolAccess('bash')
    if (decision.kind !== 'deny') throw new Error('expected deny')
    expect(decision.reason).toContain('bash')
    expect(decision.info?.code).toBe('QUANT_TOOL_NOT_ALLOWED')
  })

  it('ALLOWED_TOOLS currently contains exactly the implemented tool set', () => {
    expect([...ALLOWED_TOOLS].sort()).toEqual(
      [
        'mcp__quant__query_prices',
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
      ].sort(),
    )
  })
})
