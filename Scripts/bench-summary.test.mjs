// bench-summary.mjs の指標変換を固定する。**実行は node --test Scripts/bench-summary.test.mjs**
// (拡張のテスト一式とは別。ここは依存もビルドも無い素の ESM)。
//
// 見ているのは「記録 → 指標」の対応だけ。claude もデバイスも要らないので、
// A/B の結論が変換の取り違えで狂っていないことは、いつでもここで確かめられる。

import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  metricsFromTranscript, median, aggregate, compare, formatTable, formatComparison,
} from './bench-summary.mjs'

const toolUse = (name) => ({
  type: 'assistant',
  message: { content: [{ type: 'tool_use', name, input: {} }] },
})
const toolResult = (isError) => ({
  type: 'user',
  message: { content: [{ type: 'tool_result', is_error: isError }] },
})
const result = (text, extra = {}) => ({
  type: 'result',
  subtype: 'success',
  duration_ms: 12000,
  num_turns: 7,
  usage: { output_tokens: 900 },
  result: text,
  ...extra,
})

test('ft_* の呼び出しだけを数え、他サーバの道具は無視する', () => {
  const m = metricsFromTranscript([
    toolUse('mcp__ftester__ft_snapshot'),
    toolUse('mcp__ftester__ft_tap'),
    toolUse('mcp__other__do_something'),
    toolUse('Read'),
    result('RESULT: 立川'),
  ], '立川')
  assert.equal(m.toolCalls, 2)
  assert.equal(m.byTool.ft_snapshot, 1)
  assert.equal(m.byTool.ft_tap, 1)
  assert.equal(m.byTool.do_something, undefined)
})

test('snapshots は ft_snapshot と ft_batch の合計(木を読み直した往復)', () => {
  const m = metricsFromTranscript([
    toolUse('mcp__ftester__ft_snapshot'),
    toolUse('mcp__ftester__ft_batch'),
    toolUse('mcp__ftester__ft_tap'),
    result('done'),
  ], null)
  assert.equal(m.snapshots, 2)
})

test('is_error の tool_result だけを誤りとして数える', () => {
  const m = metricsFromTranscript([
    toolResult(true), toolResult(false), toolResult(true), result('done'),
  ], null)
  assert.equal(m.errors, 2)
})

test('完了は最終テキストと expect の照合で決める(自己申告では決めない)', () => {
  const lines = [result('RESULT: 運賃は 480 円です')]
  assert.equal(metricsFromTranscript(lines, '480').completed, true)
  assert.equal(metricsFromTranscript(lines, '520').completed, false)
  // subtype が success でも、答えが違えば未完了
  assert.equal(metricsFromTranscript([result('分かりませんでした')], '480').completed, false)
})

test('expect が無ければ claude 自身の成否を使う', () => {
  assert.equal(metricsFromTranscript([result('x')], null).completed, true)
  assert.equal(
    metricsFromTranscript([result('x', { subtype: 'error_max_turns' })], null).completed, false)
})

test('壊れた行・未知の形で落ちない(記録は途中で切れることがある)', () => {
  const m = metricsFromTranscript(
    ['{壊れた', '', JSON.stringify(toolUse('mcp__ftester__ft_tap')), '{"type":"unknown"}'], null)
  assert.equal(m.toolCalls, 1)
  assert.equal(m.wallSeconds, null)
  assert.equal(m.completed, false)
})

test('median は偶数個で中央2つの平均・値が無ければ null', () => {
  assert.equal(median([3, 1, 2]), 2)
  assert.equal(median([4, 1, 2, 3]), 2.5)
  assert.equal(median([null, undefined]), null)
})

test('aggregate は variant × task で畳み、並びが決定的', () => {
  const runs = [
    { variant: 'b', task: 't1', metrics: { completed: true, toolCalls: 10, snapshots: 4, errors: 0, wallSeconds: 20 } },
    { variant: 'a', task: 't1', metrics: { completed: true, toolCalls: 8, snapshots: 3, errors: 0, wallSeconds: 18 } },
    { variant: 'a', task: 't1', metrics: { completed: false, toolCalls: 12, snapshots: 5, errors: 1, wallSeconds: 22 } },
  ]
  const rows = aggregate(runs)
  assert.deepEqual(rows.map((r) => `${r.variant}/${r.task}`), ['a/t1', 'b/t1'])
  assert.equal(rows[0].n, 2)
  assert.equal(rows[0].completed, 1)
  assert.equal(rows[0].toolCalls, 10)
})

test('未完了の run を含む組は比較しない(手数が少ないのは諦めたからかもしれない)', () => {
  const rows = [
    { variant: 'full', task: 't1', n: 2, completed: 2, toolCalls: 10, wallSeconds: 20 },
    { variant: 'off', task: 't1', n: 2, completed: 1, toolCalls: 6, wallSeconds: 15 },
    { variant: 'full', task: 't2', n: 1, completed: 1, toolCalls: 10, wallSeconds: 20 },
    { variant: 'off', task: 't2', n: 1, completed: 1, toolCalls: 14, wallSeconds: 26 },
  ]
  const deltas = compare(rows, 'full')
  const t1 = deltas.find((d) => d.task === 't1')
  const t2 = deltas.find((d) => d.task === 't2')
  assert.equal(t1.comparable, false)
  assert.equal(t1.toolCallsDelta, null)
  assert.equal(t2.comparable, true)
  assert.equal(t2.toolCallsDelta, 4)
  assert.equal(t2.wallSecondsDelta, 6)
})

test('基準 variant に無い task は比較へ出さない', () => {
  const rows = [
    { variant: 'full', task: 't1', n: 1, completed: 1, toolCalls: 10, wallSeconds: 1 },
    { variant: 'off', task: 't9', n: 1, completed: 1, toolCalls: 10, wallSeconds: 1 },
  ]
  assert.deepEqual(compare(rows, 'full'), [])
})

test('表と差分の見出しが出る(空の差分は何も出さない)', () => {
  const rows = aggregate([
    { variant: 'full', task: 't1', metrics: { completed: true, toolCalls: 10, snapshots: 4, errors: 0, wallSeconds: 20, outputTokens: 100 } },
  ])
  const table = formatTable(rows)
  assert.match(table, /variant/)
  assert.match(table, /^full\s+t1\s+1\s+1\/1/m)
  assert.equal(formatComparison([], 'full'), '')
  assert.match(formatComparison(compare([
    { variant: 'full', task: 't1', n: 1, completed: 1, toolCalls: 10, wallSeconds: 20 },
    { variant: 'off', task: 't1', n: 1, completed: 1, toolCalls: 13, wallSeconds: 20 },
  ], 'full'), 'full'), /tools \+3/)
})
