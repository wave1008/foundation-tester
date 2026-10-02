// 陽性対照スイート(Scripts/e2e-negative.sh)の2つの砦を固定する:
// ①同期 —— TestProjects/E2E-*/scenarios/_disabled/*.swift は全部 Scripts/negative-controls.json に載る
//   (controls か delegated)。載らない陽性対照は自動で回らないまま腐る
// ②判定 —— Scripts/negative_controls_judge.py の judge_scenario が「赤なら何でも ✅」になっていない
//   (場所・理由・クラッシュの記録まで見る。⚠️ 未検証を ✅ に畳まない)

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readFileSync, readdirSync, existsSync } from 'node:fs'
import { join, resolve } from 'node:path'

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

const redSpec = { expect: 'red', command: 'exist', failureKind: 'assertion', detailContains: ['false positive (offscreen)'] }
const failed = (step, extra = {}) => ({ passed: false, failedSteps: [step], timeline: [], ...extra })
const offscreen = { command: 'exist', failureKind: 'assertion', detail: 'false positive (offscreen): centre (201, 889)' }

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
  expect: 'red', command: 'exist', detailContains: ['false positive (occlusion'],
  detailNotContains: ['judged by OCR alone'], fmCallsAtLeast: { occlusion: 2 }, requiresFM: true,
}

test('FM が判定を返さなかった回は ⚠️ 未検証(✅ に畳まない)', () => {
  const ocrOnly = failed({ command: 'exist', detail: 'false positive (occlusion, judged by OCR alone because FM gave no verdict)' },
    { timeline: [{ notes: ['visibility-guard-skipped'] }] })
  assert.equal(judge(fmSpec, ocrOnly).verdict, 'unverified')
})

test('FM が判定を返した回は FM の呼び出し回数まで見る', () => {
  const byFM = (calls) => failed({ command: 'exist', detail: 'false positive (occlusion): covered' },
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
