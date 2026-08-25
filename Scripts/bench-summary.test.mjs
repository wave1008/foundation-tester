// bench-summary.mjs の指標変換を固定する。**実行は node --test Scripts/bench-summary.test.mjs**
// (拡張のテスト一式とは別。ここは依存もビルドも無い素の ESM)。
//
// 見ているのは「記録 → 指標」の対応だけ。claude もデバイスも要らないので、
// A/B の結論が変換の取り違えで狂っていないことは、いつでもここで確かめられる。

import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  metricsFromTranscript, median, aggregate, compare, formatTable, formatComparison, draftQuality, noteCost, foldNoteCost,
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

// --- セレクタの品質。**手数と独立の軸** ——
// 「書き手を助ける」注記(duplicateIDsNote 等)は、エージェントが常に ref で叩ける以上
// 手数には出ない。下書きのセレクタで測る。

const DRAFT = `Draft for com.example from 3 recorded interaction(s).
Steps in this draft:
  1. launch com.example
  2. tap "#ok"
  3. tap ".clickable&&送信"

@TestClass(app: "com.example", platform: "android")
class DraftedScenario {
    func S0010() {
        scenario {
            scene(1) {
                condition { launchApp() }.action {
                    tap("#ok")
                    tap(".clickable&&送信")
                    tap("#recycler_view >> .clickable[3]")
                    // TODO: no stable selector — tap at (12, 85) (step 5 of the exploration)
                    type("#field", "abc")
                }.expectation { }
            }
        }
    }
}`

test('下書きが無ければ null(その run はこの軸について何も言っていない)', () => {
  assert.equal(draftQuality('tap "#ok" done'), null)
  assert.equal(draftQuality(undefined), null)
})

test('索引セレクタと TODO を弱い側へ数える', () => {
  const q = draftQuality(DRAFT)
  assert.deepEqual(q, { stable: 3, indexed: 1, todo: 1 })
})

test('**冒頭の手順一覧は数えない**(同じ手を二重に数えてしまう)', () => {
  // 一覧の形は `2. tap "#ok"`(括弧が無い)。Swift の呼び出しだけを数えること
  const listingOnly = 'Steps in this draft:\n  1. tap "#ok"\n  2. tap "#ng"\n@TestClass(app: "x")\n'
  assert.deepEqual(draftQuality(listingOnly), { stable: 0, indexed: 0, todo: 0 })
})

test('metricsFromTranscript が tool_result から下書きを拾う(最後のものを採る)', () => {
  const draftResult = (text) => ({
    type: 'user',
    message: { content: [{ type: 'tool_result', content: [{ type: 'text', text }] }] },
  })
  const m = metricsFromTranscript([
    toolUse('mcp__ftester__ft_draft_scenario'),
    draftResult(DRAFT.replace('tap("#ok")', 'tap("#recycler_view >> .clickable[9]")')),
    toolUse('mcp__ftester__ft_draft_scenario'),
    draftResult(DRAFT),
    result('RESULT: ok'),
  ], null)
  assert.deepEqual(m.draft, { stable: 3, indexed: 1, todo: 1 }, '刈り込み後の下書きを採ること')
})

test('下書きを採らなかった run は品質の中央値に混ぜない', () => {
  const withDraft = { completed: true, toolCalls: 5, snapshots: 1, errors: 0, wallSeconds: 1, outputTokens: 1, draft: { stable: 4, indexed: 1, todo: 1 } }
  const without = { completed: true, toolCalls: 5, snapshots: 1, errors: 0, wallSeconds: 1, outputTokens: 1, draft: null }
  const [row] = aggregate([
    { variant: 'full', task: 't1', metrics: withDraft },
    { variant: 'full', task: 't1', metrics: without },
  ])
  assert.equal(row.drafted, 1)
  assert.equal(row.draftStable, 4)
  assert.equal(row.draftWeak, 2, '索引 + TODO を弱い側にまとめる')
})

test('弱いセレクタの差が比較に出る(手数が動かなくても)', () => {
  const rows = [
    { variant: 'full', task: 't1', n: 1, completed: 1, toolCalls: 10, wallSeconds: 1, drafted: 1, draftStable: 5, draftWeak: 0 },
    { variant: 'off', task: 't1', n: 1, completed: 1, toolCalls: 10, wallSeconds: 1, drafted: 1, draftStable: 2, draftWeak: 3 },
  ]
  const [d] = compare(rows, 'full')
  assert.equal(d.toolCallsDelta, 0, '手数は動かない = この注記は手数では測れない')
  assert.equal(d.draftWeakDelta, 3)
  assert.match(formatComparison([d], 'full'), /弱いセレクタ \+3/)
})

test('下書きを採っていない task では sel 列が "-"', () => {
  const rows = aggregate([
    { variant: 'full', task: 't1', metrics: { completed: true, toolCalls: 10, snapshots: 4, errors: 0, wallSeconds: 20, outputTokens: 100, draft: null } },
  ])
  assert.match(formatTable(rows), /-\s*$/m)
})

// --- 注記の実現コスト。カタログを縮めたいのに「実際に出ている量」で
// 削る候補を並べられなかったので足した。鍵との写像は持たない(二重管理はズレる)。

test('注記の行だけを拾う(木の行や本文は数えない)', () => {
  const text = [
    'note: these ids are shared by multiple elements',
    'screen: 1080x2424',
    '[1] button "OK" id=ok (0,0 10x10)',
    'caution: its label has changed from "A" to "B"',
    '⚠️ com.example is a system dialog drawn over the app',
    'tap [3] done.',
  ].join('\n')
  assert.deepEqual(noteCost(text).map((n) => n.signature.slice(0, 12)),
                   ['note: these ', 'caution: its', '⚠️ com.examp'])
})

test('同じ注記は署名で畳み、バイトの多い順に並ぶ', () => {
  const folded = foldNoteCost([
    { signature: 'note: A', bytes: 10 },
    { signature: 'note: B', bytes: 50 },
    { signature: 'note: A', bytes: 10 },
  ])
  assert.deepEqual(folded, [
    { signature: 'note: B', count: 1, bytes: 50 },
    { signature: 'note: A', count: 2, bytes: 20 },
  ])
})

test('metricsFromTranscript が注記のバイトを積む', () => {
  const noteResult = (text) => ({
    type: 'user',
    message: { content: [{ type: 'tool_result', content: [{ type: 'text', text }] }] },
  })
  const m = metricsFromTranscript([
    toolUse('mcp__ftester__ft_snapshot'),
    noteResult('note: abc\nscreen: 1x1\n[1] button "x"'),
    result('RESULT: ok'),
  ], null)
  assert.equal(m.noteBytes, Buffer.byteLength('note: abc', 'utf8'))
  assert.equal(m.notes.length, 1)
})

test('注記が1つも無い run は 0(欠測ではない)', () => {
  const m = metricsFromTranscript([toolUse('mcp__ftester__ft_tap'), result('RESULT: ok')], null)
  assert.equal(m.noteBytes, 0)
})
