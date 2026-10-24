// 陽性対照スイート(Scripts/e2e-negative.sh)の2つの砦を固定する:
// ①同期 —— TestProjects/E2E-*/scenarios/_disabled/*.swift は全部 Scripts/negative-controls.json に載る
//   (controls か delegated)。載らない陽性対照は自動で回らないまま腐る
// ②判定 —— Scripts/negative_controls_judge.py の judge_scenario が「赤なら何でも ✅」になっていない
//   (場所・理由・クラッシュの記録まで見る。⚠️ 未検証を ✅ に畳まない)
// ③監視対象 —— watches が改名・削除に追随している(当たらない pattern は推奨を黙って止めうる)・
//   Scripts/verification_watch.py が未記録/変化を推奨に出す

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readFileSync, readdirSync, existsSync, mkdtempSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { tmpdir } from 'node:os'

const ROOT = resolve(import.meta.dirname, '../..')
const table = JSON.parse(readFileSync(join(ROOT, 'Scripts/negative-controls.json'), 'utf8'))

function disabledScenarios() {
  const out = []
  for (const project of readdirSync(join(ROOT, 'TestProjects'))) {
    if (!/^E2E-/.test(project)) continue
    const dir = join(ROOT, 'TestProjects', project, 'scenarios/_disabled')
    if (!existsSync(dir)) continue
    for (const file of readdirSync(dir)) if (file.endsWith('.swift')) out.push(`${project}/${file}`)
  }
  return out
}

test('_disabled の .swift は全部表に載っている(controls か delegated)', () => {
  const listed = new Set([...table.controls, ...table.delegated].map((c) => `${c.project}/${c.file}`))
  const found = disabledScenarios()
  assert.ok(found.length >= 10, `走査が _disabled に届いていない: ${found.length} 件`)
  const missing = found.filter((f) => !listed.has(f))
  assert.deepEqual(missing, [], '表に無い陽性対照(Scripts/negative-controls.json に足す)')
})

test('表の対照は実在するファイル・クラス・メソッドを指している', () => {
  for (const c of table.controls) {
    const path = join(ROOT, 'TestProjects', c.project, 'scenarios/_disabled', c.file)
    assert.ok(existsSync(path), `${c.project}/${c.file} が _disabled に無い`)
    const src = readFileSync(path, 'utf8')
    // \b は ASCII の語境界なので日本語のクラス名に効かない
    assert.match(src, new RegExp(`^class ${c.class}[\\s{]`, 'm'), `${c.file} にクラス ${c.class} が無い`)
    for (const sid of Object.keys(c.scenarios)) {
      assert.match(src, new RegExp(`func ${sid}\\(`), `${c.file} に ${sid} が無い`)
    }
    assert.ok(existsSync(join(ROOT, 'TestProjects', c.project, 'profiles/runs', `${c.profile}.json`)),
      `${c.project} にプロファイル ${c.profile} が無い`)
  }
  for (const d of table.delegated) {
    assert.ok(existsSync(join(ROOT, d.by)), `${d.by} が無い`)
  }
})

/** verification_watch.py を呼ぶ。ledger を渡すと本物の台帳(.fleetest/)の代わりにそこへ読み書きする */
function watch(args, ledger) {
  return execFileSync('python3', [join(ROOT, 'Scripts/verification_watch.py'), ...args], {
    encoding: 'utf8',
    env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1', ...(ledger ? { FT_VERIFICATION_WATCH_LEDGER: ledger } : {}) },
  })
}

test('監視対象: 全対照と heal-verify・fm-verify が watches を持ち、どの pattern も実在のファイルに当たる', () => {
  for (const key of ['common', 'heal-verify', 'fm-verify']) {
    assert.ok(Array.isArray(table.watches[key]) && table.watches[key].length > 0, `watches.${key} が無い`)
  }
  for (const c of table.controls) {
    assert.ok(Array.isArray(c.watches) && c.watches.length > 0, `${c.project}/${c.profile}/${c.file} に watches が無い`)
  }
  const units = watch(['units']).trim().split('\n')
  assert.equal(units.length, table.controls.length + 2)
  for (const u of units) {
    const missing = watch(['files', u]).split('\n').filter((l) => l.startsWith('MISSING'))
    assert.deepEqual(missing, [], `${u} の監視対象に当たらない pattern がある(改名・削除に追随する)`)
  }
})

test('監視対象: 未記録は never・記録すれば消え・digest が食い違えば changed', () => {
  const ledger = join(mkdtempSync(join(tmpdir(), 'verification-watch-')), 'ledger.json')
  const stale = () => Object.fromEntries(watch(['stale'], ledger).trim().split('\n').filter(Boolean).map((l) => l.split('\t')))
  assert.equal(stale()['heal-verify'], 'never')
  watch(['record', 'heal-verify'], ledger)
  assert.equal(stale()['heal-verify'], undefined, '記録した直後なのに推奨に残る')
  assert.equal(stale()['fm-verify'], 'never', '記録していない unit まで消えた')
  writeFileSync(ledger, JSON.stringify({ ...JSON.parse(readFileSync(ledger, 'utf8')), 'heal-verify': 'x' }))
  assert.equal(stale()['heal-verify'], 'changed')
})

/** judge_scenario(spec, result) を Python で呼ぶ。result が null = 結果が無い */
function judge(spec, result) {
  const code = [
    'import json, sys',
    `sys.path.insert(0, ${JSON.stringify(join(ROOT, 'Scripts'))})`,
    'from negative_controls_judge import judge_scenario',
    'spec, result = json.load(sys.stdin)',
    'print(json.dumps(judge_scenario(spec, result)))',
  ].join('\n')
  // import すると Scripts/__pycache__ を作業ツリーに書くので止める
  const out = execFileSync('python3', ['-c', code], {
    input: JSON.stringify([spec, result]), encoding: 'utf8',
    env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' },
  })
  const [verdict, reasons] = JSON.parse(out)
  return { verdict, reasons }
}

const redSpec = { expect: 'red', command: 'exist', failureKind: 'assertion', detailContains: ['text visibility check failed (offscreen)'] }
const failed = (step, extra = {}) => ({ passed: false, failedSteps: [step], timeline: [], ...extra })
const offscreen = { command: 'exist', failureKind: 'assertion', detail: 'text visibility check failed (offscreen): centre (201, 889)' }

test('期待どおりの場所・理由で落ちれば ✅', () => {
  assert.equal(judge(redSpec, failed(offscreen)).verdict, 'ok')
})

test('赤のはずが緑なら ❌', () => {
  assert.equal(judge(redSpec, { passed: true, timeline: [] }).verdict, 'fail')
})

test('別のコマンド・別の failureKind・別の文言で落ちたら ❌(赤なら何でも ✅ にしない)', () => {
  assert.equal(judge(redSpec, failed({ ...offscreen, command: 'tap' })).verdict, 'fail')
  assert.equal(judge(redSpec, failed({ ...offscreen, failureKind: 'not-found' })).verdict, 'fail')
  assert.equal(judge(redSpec, failed({ ...offscreen, detail: 'element not found: id=x' })).verdict, 'fail')
})

test('結果が無ければ ❌', () => {
  assert.equal(judge(redSpec, null).verdict, 'fail')
})

test('緑の対照が赤なら ❌・緑なら ✅', () => {
  assert.equal(judge({ expect: 'green' }, failed(offscreen)).verdict, 'fail')
  assert.equal(judge({ expect: 'green' }, { passed: true }).verdict, 'ok')
})

test('打ち切りの赤は timedOut と errorLogs の行で判定する(失敗ステップは持たない)', () => {
  const spec = { expect: 'red', timedOut: true, errorLogsContains: ['produced no output for'] }
  const killed = { passed: false, timedOut: true, failedSteps: [], timeline: [],
                   errorLogs: ['⏱ The scenario produced no output for 241.2s (allowed 240.0s = …) and was killed'] }
  assert.equal(judge(spec, killed).verdict, 'ok')
  // 全体の上限での打ち切り(別の理由)・打ち切られずに赤・行が無い は ❌
  assert.equal(judge(spec, { ...killed, errorLogs: ['⏱ The scenario exceeded 600s (default) and was killed'] }).verdict, 'fail')
  assert.equal(judge(spec, { ...killed, timedOut: false }).verdict, 'fail')
  assert.equal(judge(spec, { ...killed, errorLogs: [] }).verdict, 'fail')
})

test('注記の期待が満たされなければ ❌', () => {
  const spec = { expect: 'red', notesContains: ['system-alert-present'] }
  assert.equal(judge(spec, failed(offscreen)).verdict, 'fail')
  const withNote = failed(offscreen, { timeline: [{ notes: ['system-alert-present'] }] })
  assert.equal(judge(spec, withNote).verdict, 'ok')
})

test('appCrash の evidence が違う・無いなら ❌', () => {
  const spec = { expect: 'red', appCrash: 'fatalException' }
  assert.equal(judge(spec, failed(offscreen)).verdict, 'fail')
  assert.equal(judge(spec, failed(offscreen, { appCrash: { evidence: 'crashReport' } })).verdict, 'fail')
  assert.equal(judge(spec, failed(offscreen, { appCrash: { evidence: 'fatalException' } })).verdict, 'ok')
})

const fmSpec = {
  expect: 'red', command: 'exist', detailContains: ['text visibility check failed (on screen'],
  detailNotContains: ['judged by OCR alone'], fmCallsAtLeast: { occlusion: 2 }, requiresFM: true,
}

test('FM が判定を返さなかった回は ⚠️ 未検証(✅ に畳まない)', () => {
  const ocrOnly = failed({ command: 'exist', detail: 'text visibility check failed (on screen, judged by OCR alone because FM gave no verdict)' },
    { timeline: [{ notes: ['visibility-guard-skipped'] }] })
  assert.equal(judge(fmSpec, ocrOnly).verdict, 'unverified')
})

test('FM が判定を返した回は FM の呼び出し回数まで見る', () => {
  const byFM = (calls) => failed({ command: 'exist', detail: 'text visibility check failed (on screen): covered' },
    { fm: { byKind: { occlusion: { calls } } } })
  assert.equal(judge(fmSpec, byFM(2)).verdict, 'ok')
  assert.equal(judge(fmSpec, byFM(1)).verdict, 'fail')
})

test('既知の見逃しは ⚠️・記録されるようになったら ❌(表の更新を促す)', () => {
  const spec = { expect: 'red', appCrash: 'any', knownGap: 'Android のネイティブのクラッシュ' }
  assert.equal(judge(spec, failed(offscreen)).verdict, 'unverified')
  assert.equal(judge(spec, failed(offscreen, { appCrash: { evidence: 'fatalException' } })).verdict, 'fail')
  assert.equal(judge(spec, { passed: true }).verdict, 'fail')
})
