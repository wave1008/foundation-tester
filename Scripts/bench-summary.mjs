#!/usr/bin/env node
// mcp-bench の記録(Claude Code の stream-json)を指標へ落とす。**純粋な変換だけ**を担う
// (デバイスにも claude にも触らない)ので bench-summary.test.mjs が全数を固定できる。
//
// 指標の選び方: 評価者を「フルコンテキストの私が読んで違和感があるか」から
// **「そのアプリを知らないエージェントがタスクを終えられたか・何手かかったか」**へ移すためのもの。
// 注記を1本足すか消すかは、この手数が動いたかどうかで決める —— 読んだ印象で決めると、
// 「もっと分かりやすく言えたはず」は無限に出るので目録は単調に増え続ける。
//
// 使い方: node Scripts/bench-summary.mjs <index.json> [--json <出力先>]
//   index.json = { "runs": [ { "variant", "task", "expect", "transcript" } ] }

import { readFileSync, writeFileSync } from 'node:fs'

/**
 * `ft_draft_scenario` が返した下書きから**セレクタの品質**を数える。
 *
 * **なぜ手数と別に要るか**: 注記には読者が2種類いる —— ⒜ いま作業しているエージェント
 * (タスクを終えるための情報)と ⒝ シナリオを書く人(壊れないセレクタを書くための情報)。
 * **⒝ は手数では原理的に測れない** —— エージェントは常に ref で叩けるので、
 * `duplicateIDsNote` / `ambiguousLabelsNote` / `unlabeledClickablesNote` を落としても
 * 手数は動かない(2026-08-13 に実測して ±0 だった)。出力バイトの主因はこの3本なので、
 * **bench はカタログの量の大半を判定できないままだった**。ここがその軸。
 *
 * 数えるのは下書きの本体(Swift のコード)だけ:
 * - `stable`  … 索引を含まないセレクタ(`#id` / `.type&&ラベル` / 素のラベル)
 * - `indexed` … `[n]` を含む = 同型の兄弟が増減すると壊れる
 * - `todo`    … 安定したセレクタが無く `// TODO: no stable selector` で残された手
 *
 * 冒頭の手順一覧(`2. tap "…"`)は**数えない**(同じ手を二重に数える)。
 * 判別は「Swift の呼び出し形か」= `("` と `")` を要求すること。
 * 下書きが1つも無ければ null(その run はこの軸について何も言っていない)。
 */
export function draftQuality(text) {
  if (typeof text !== 'string' || !text.includes('@TestClass')) return null
  const body = text.slice(text.indexOf('@TestClass'))
  const quality = { stable: 0, indexed: 0, todo: 0 }
  for (const match of body.matchAll(/\b(?:tap|type|scrollTo|swipe|press|doubleTap)\("([^"]*)"/g)) {
    if (/\[\d+\]/.test(match[1])) quality.indexed += 1
    else quality.stable += 1
  }
  quality.todo = [...body.matchAll(/\/\/ TODO: no stable selector/g)].length
  return quality
}

/**
 * 応答に載った**注記の実現コスト**を数える。
 *
 * **なぜ要るか**: `NoteCoverageTests` は固定コーパスに対する満額のバイト数を測るが、
 * **実際の run で何が何回出ているか**は誰も見ていない。カタログを縮めたいのに、
 * 削る候補を「実際に出ている量」で並べられなかった。ここはそれを出す ——
 * 手数が動かない注記でも、**出ている量は事実として比較できる**。
 *
 * 注記の鍵との対応は持たない(鍵→文言の写像を二重管理すると必ずズレる)。
 * **行頭の印**(`note:` / `caution:` / `⚠️`)で拾い、**先頭 48 文字を署名**にして畳む。
 * 同じ注記の短縮形(`once` の2回目以降)は別署名になるが、**それも含めて実現コスト**。
 */
export function noteCost(text) {
  if (typeof text !== 'string') return []
  const found = []
  for (const raw of text.split('\n')) {
    const line = raw.trim()
    if (!/^(note:|caution:|⚠️)/.test(line)) continue
    found.push({ signature: line.slice(0, 48), bytes: Buffer.byteLength(line, 'utf8') })
  }
  return found
}

/** (署名 → 回数・バイト)へ畳む。並びは**バイトの多い順**(削る候補が先に来る) */
export function foldNoteCost(entries) {
  const bySignature = new Map()
  for (const { signature, bytes } of entries) {
    const at = bySignature.get(signature) ?? { signature, count: 0, bytes: 0 }
    at.count += 1
    at.bytes += bytes
    bySignature.set(signature, at)
  }
  return [...bySignature.values()].sort((a, b) => b.bytes - a.bytes || a.signature.localeCompare(b.signature))
}

/**
 * 作成フロー(`kind: authoring`)の合否。**自己申告は見ない**。3つが揃ったときだけ完了:
 * - 最後の `ft_run_scenario` の応答が通った(`→ ✅ passed` があり `→ ❌ failed` が無い。
 *   この2行は isError を持たない旧版の応答にも同じ形で出るので、前後の比較に使える)
 * - その後にファイルを書き換えていない(通った後に書き換えたなら、最終ファイルは未検証)
 * - `mustContain` の文字列が最終ファイルに全部残っている(検証を削って緑にする抜け道を塞ぐ)
 */
export function authoringVerdict({ lastRunText, editedAfterLastRun, finalSource, mustContain }) {
  const ran = typeof lastRunText === 'string'
  const passed = ran && lastRunText.includes('→ ✅ passed') && !lastRunText.includes('→ ❌ failed')
  const missing = (mustContain ?? []).filter((needle) => !String(finalSource ?? '').includes(needle))
  return {
    completed: passed && !editedAfterLastRun && missing.length === 0,
    lastRunPassed: passed,
    editedAfterLastRun: Boolean(editedAfterLastRun),
    missing,
  }
}

/**
 * 起動イベントから「まっさらな読み手」だったかを判定する。3つとも空でなければ漏れている:
 * 自動メモリの置き場(memory_paths)・スキル・プラグイン。旧台本はクローンの内側で走らせていたので
 * 保守者のメモリを指し、fleetest のスキルも使える状態だった(2026-09-25)
 */
export function isolationFromInit(init) {
  const memory = init.memory_paths && Object.keys(init.memory_paths).length > 0
  const skills = Array.isArray(init.skills) && init.skills.length > 0
  const plugins = Array.isArray(init.plugins) && init.plugins.length > 0
  return !memory && !skills && !plugins
}

/** ファイルを書き換える道具(作成フローの判定と fileOps の数え分けに使う) */
const WRITING_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit'])

/**
 * 1回ぶんの記録から指標を採る。`lines` は stream-json の各行(文字列 or 解析済み)。
 * `authoring` を渡すと(`{ finalSource, mustContain }`)完了を authoringVerdict で決める
 */
export function metricsFromTranscript(lines, expect, authoring = null) {
  const events = lines
    .map((line) => (typeof line === 'string' ? safeParse(line) : line))
    .filter(Boolean)
  const byTool = {}
  let toolCalls = 0
  let errors = 0
  let wallSeconds = null
  let outputTokens = null
  let turns = null
  let finalText = ''
  let subtype = null
  let draft = null
  const notes = []
  // 作成フロー: tool_use の id → 名前(tool_result は id しか持たない)
  const toolNames = new Map()
  let fileOps = 0
  let lastRunText = null
  let editedAfterLastRun = false
  // まっさらな読み手だったか(起動イベントで判定。記録に起動イベントが無ければ null = 不明)
  let isolated = null
  for (const event of events) {
    if (event.type === 'system' && event.subtype === 'init') {
      isolated = isolationFromInit(event)
      continue
    }
    if (event.type === 'assistant') {
      for (const block of contentBlocks(event)) {
        if (block.type !== 'tool_use') continue
        const name = String(block.name ?? '')
        toolNames.set(block.id, name)
        // ファイル操作は ft_* と別に数える(作成フローのタスクでだけ許している)
        if (!name.startsWith('mcp__')) {
          fileOps += 1
          if (WRITING_TOOLS.has(name) && lastRunText !== null) editedAfterLastRun = true
          continue
        }
        // fleetest の ft_* だけを数える(他サーバの道具が混ざる構成でも指標がぶれない)
        if (!name.startsWith('mcp__fleetest__')) continue
        toolCalls += 1
        const short = name.slice('mcp__fleetest__'.length)
        byTool[short] = (byTool[short] ?? 0) + 1
      }
    } else if (event.type === 'user') {
      for (const block of contentBlocks(event)) {
        if (block.type !== 'tool_result') continue
        if (block.is_error === true) errors += 1
        // **下書きは最後のものを採る**(刈り込みで呼び直すのが正しい使い方なので、
        // 途中の下書きを混ぜると「直した後」の質が見えない)
        const text = resultText(block)
        if (toolNames.get(block.tool_use_id) === 'mcp__fleetest__ft_run_scenario') {
          lastRunText = text
          editedAfterLastRun = false
        }
        // 下書きは ft_draft_scenario の応答からだけ採る(作成フローで Read したシナリオ本文も
        // @TestClass を含むので、名前で絞らないと読んだファイルを「下書き」と数える)
        const from = toolNames.get(block.tool_use_id)
        const quality = from === undefined || from === 'mcp__fleetest__ft_draft_scenario'
          ? draftQuality(text) : null
        if (quality) draft = quality
        notes.push(...noteCost(text))
      }
    } else if (event.type === 'result') {
      subtype = event.subtype ?? null
      if (typeof event.duration_ms === 'number') wallSeconds = event.duration_ms / 1000
      if (typeof event.num_turns === 'number') turns = event.num_turns
      const usage = event.usage ?? {}
      if (typeof usage.output_tokens === 'number') outputTokens = usage.output_tokens
      if (typeof event.result === 'string') finalText = event.result
    }
  }
  // **完了は成果物で判定する**(「終わった」という自己申告ではなく、答えの中身を照合する)。
  // expect が無いタスクは claude 自身の成否だけを見る
  const verdict = authoring
    ? authoringVerdict({ lastRunText, editedAfterLastRun, finalSource: authoring.finalSource,
                         mustContain: authoring.mustContain })
    : null
  const completed = verdict
    ? verdict.completed
    : expect
      ? new RegExp(expect, 'i').test(finalText)
      : subtype === 'success'
  return {
    completed,
    verdict,
    isolated,
    fileOps,
    toolCalls,
    snapshots: (byTool.ft_snapshot ?? 0) + (byTool.ft_batch ?? 0),
    errors,
    turns,
    wallSeconds,
    outputTokens,
    byTool,
    finalText,
    draft,
    noteBytes: notes.reduce((sum, n) => sum + n.bytes, 0),
    notes,
  }
}

/** tool_result の中身を文字列にする(text ブロックの配列 / 素の文字列 の両方が来る) */
function resultText(block) {
  const content = block.content
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  return content.map((part) => (typeof part?.text === 'string' ? part.text : '')).join('\n')
}

function readText(path) {
  try {
    return readFileSync(path, 'utf8')
  } catch {
    return ''
  }
}

function safeParse(line) {
  try {
    return JSON.parse(line)
  } catch {
    return null
  }
}

function contentBlocks(event) {
  const content = event.message?.content
  return Array.isArray(content) ? content : []
}

export function median(values) {
  const present = values.filter((v) => typeof v === 'number' && Number.isFinite(v)).sort((a, b) => a - b)
  if (present.length === 0) return null
  const mid = Math.floor(present.length / 2)
  return present.length % 2 ? present[mid] : (present[mid - 1] + present[mid]) / 2
}

/** (variant, task) ごとに畳む。行の並びは variant → task の辞書順で決定的 */
export function aggregate(runs) {
  const groups = new Map()
  for (const run of runs) {
    const key = `${run.variant} ${run.task}`
    if (!groups.has(key)) groups.set(key, { variant: run.variant, task: run.task, runs: [] })
    groups.get(key).runs.push(run.metrics)
  }
  return [...groups.values()]
    .map((group) => ({
      variant: group.variant,
      task: group.task,
      n: group.runs.length,
      completed: group.runs.filter((m) => m.completed).length,
      toolCalls: median(group.runs.map((m) => m.toolCalls)),
      fileOps: median(group.runs.map((m) => m.fileOps)),
      snapshots: median(group.runs.map((m) => m.snapshots)),
      errors: median(group.runs.map((m) => m.errors)),
      wallSeconds: median(group.runs.map((m) => m.wallSeconds)),
      outputTokens: median(group.runs.map((m) => m.outputTokens)),
      // 下書きを1つも採らなかった run は**平均に混ぜない**(0 として数えると、
      // 下書きを頼まなかったタスクが「品質が悪い」ように見える)
      noteBytes: median(group.runs.map((m) => m.noteBytes)),
      drafted: group.runs.filter((m) => m.draft).length,
      draftStable: median(group.runs.filter((m) => m.draft).map((m) => m.draft.stable)),
      draftWeak: median(group.runs.filter((m) => m.draft)
        .map((m) => m.draft.indexed + m.draft.todo)),
    }))
    .sort((a, b) => a.variant.localeCompare(b.variant) || a.task.localeCompare(b.task))
}

/**
 * 基準の variant との差。**完了しなかった run を含む比較はしない**(手数が少ないのは
 * 早々に諦めたからかもしれない)ので、両方が全 run 完了した (task) だけを比べる
 */
export function compare(rows, baseVariant) {
  const base = new Map(rows.filter((r) => r.variant === baseVariant).map((r) => [r.task, r]))
  return rows
    .filter((r) => r.variant !== baseVariant && base.has(r.task))
    .map((r) => {
      const b = base.get(r.task)
      const comparable = r.completed === r.n && b.completed === b.n
      return {
        variant: r.variant,
        task: r.task,
        comparable,
        toolCallsDelta: comparable ? r.toolCalls - b.toolCalls : null,
        // **弱いセレクタが増えた = 落とした注記は書き手を助けていた**。手数と独立の軸なので
        // 両方が下書きを採った task でだけ意味を持つ
        draftWeakDelta: comparable && r.drafted && b.drafted && r.draftWeak != null
          && b.draftWeak != null ? r.draftWeak - b.draftWeak : null,
        wallSecondsDelta: comparable && r.wallSeconds != null && b.wallSeconds != null
          ? Number((r.wallSeconds - b.wallSeconds).toFixed(1))
          : null,
      }
    })
}

export function formatTable(rows) {
  // sel は「下書きの安定セレクタ数 / 弱いセレクタ数(索引 + TODO)」。下書きを採っていない
  // task では "-"(この軸について何も言っていない)
  // files は ft_* 以外(ファイルの読み書き)の回数。作成フローのタスクでだけ 0 でなくなる
  const header = ['variant', 'task', 'n', 'ok', 'tools', 'files', 'snaps', 'err', 'wall s', 'out tok',
                  'note B', 'sel ok/weak']
  const body = rows.map((r) => [
    r.variant,
    r.task,
    String(r.n),
    `${r.completed}/${r.n}`,
    fmt(r.toolCalls),
    fmt(r.fileOps),
    fmt(r.snapshots),
    fmt(r.errors),
    fmt(r.wallSeconds),
    fmt(r.outputTokens),
    fmt(r.noteBytes),
    r.drafted ? `${fmt(r.draftStable)}/${fmt(r.draftWeak)}` : '-',
  ])
  const widths = header.map((h, i) => Math.max(h.length, ...body.map((row) => row[i].length)))
  const line = (cells) => cells.map((c, i) => c.padEnd(widths[i])).join('  ').trimEnd()
  return [line(header), widths.map((w) => '-'.repeat(w)).join('  '), ...body.map(line)].join('\n')
}

function fmt(value) {
  if (value == null) return '-'
  return Number.isInteger(value) ? String(value) : value.toFixed(1)
}

export function formatComparison(deltas, baseVariant) {
  if (deltas.length === 0) return ''
  const lines = deltas.map((d) => {
    if (!d.comparable) {
      return `  ${d.variant}/${d.task}: 比較不能(どちらかで未完了の run がある)`
    }
    const sign = d.toolCallsDelta > 0 ? '+' : ''
    const wall = d.wallSecondsDelta == null ? '' : ` / wall ${d.wallSecondsDelta > 0 ? '+' : ''}${d.wallSecondsDelta}s`
    const weak = d.draftWeakDelta == null ? ''
      : ` / 弱いセレクタ ${d.draftWeakDelta > 0 ? '+' : ''}${d.draftWeakDelta}`
    return `  ${d.variant}/${d.task}: tools ${sign}${d.toolCallsDelta}${wall}${weak}`
  })
  return [`--- ${baseVariant} との差(+ = 手数が増えた = 落とした注記は効いていた) ---`, ...lines]
    .join('\n')
}

function main(argv) {
  const indexPath = argv[0]
  if (!indexPath) {
    console.error('usage: bench-summary.mjs <index.json> [--json <out>]')
    process.exit(2)
  }
  const index = JSON.parse(readFileSync(indexPath, 'utf8'))
  const runs = index.runs.map((run) => {
    const lines = readFileSync(run.transcript, 'utf8').split('\n').filter((l) => l.trim())
    const authoring = run.authoring
      ? { finalSource: run.authoring.final ? readText(run.authoring.final) : '',
          mustContain: run.authoring.mustContain }
      : null
    return { ...run, metrics: metricsFromTranscript(lines, run.expect, authoring) }
  })
  // **まっさらでなかった run は集計の意味が変わる**ので、表より先に名指しする
  for (const run of runs) {
    if (run.metrics.isolated === false) {
      console.log(`!! ${run.variant}/${run.task} ${run.transcript}: まっさらな読み手ではない`
        + '(メモリ・スキル・プラグインのどれかが見えている。台本の隔離を確かめる)')
    }
  }
  // 作成フローで落ちた run は理由を1行ずつ出す(表の ok だけでは直し損ねか検証の削りか分からない)
  for (const run of runs) {
    const v = run.metrics.verdict
    if (!v || v.completed) continue
    const why = !v.lastRunPassed ? '最後の ft_run_scenario が通っていない'
      : v.editedAfterLastRun ? '通った後にファイルを書き換えた'
        : `検証が消えた: ${v.missing.join(', ')}`
    console.log(`!! ${run.variant}/${run.task} ${run.transcript}: ${why}`)
  }
  const rows = aggregate(runs)
  console.log(formatTable(rows))
  const baseVariant = index.baseVariant ?? 'full'
  const deltas = compare(rows, baseVariant)
  const comparison = formatComparison(deltas, baseVariant)
  if (comparison) console.log('\n' + comparison)
  // **削る候補をバイトの多い順に出す**。手数が動かない注記でも、出ている量は事実
  const folded = foldNoteCost(runs.flatMap((run) => run.metrics.notes))
  if (folded.length) {
    console.log('\n--- 実際に出た注記(全 run 合計・バイトの多い順・上位10)---')
    for (const row of folded.slice(0, 10)) {
      console.log(`  ${String(row.bytes).padStart(6)} B  ×${String(row.count).padStart(3)}  ${row.signature}`)
    }
    const total = folded.reduce((sum, r) => sum + r.bytes, 0)
    console.log(`  合計 ${total} B / ${folded.length} 種`)
  }

  const jsonFlag = argv.indexOf('--json')
  if (jsonFlag >= 0 && argv[jsonFlag + 1]) {
    writeFileSync(argv[jsonFlag + 1], JSON.stringify({ rows, deltas, runs }, null, 2))
  }
}

// import されたときは実行しない(テストが純粋関数だけを呼ぶ)
if (process.argv[1] && process.argv[1].endsWith('bench-summary.mjs')) main(process.argv.slice(2))
