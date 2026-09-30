// Scripts/e2ex.sh の「E2EX を最後に全部通したときからブリッジの入力が動いていないか」の印と警告を検証する。
// 仕組みは Scripts/e2e.sh と同じ(inappE2EGate.test.mjs)だが、2点が違うのでここで固定する:
// ①印は `.fleetest/<engine>-e2ex-verified`(E2E の印と混ぜない)
// ②警告は in-app の印にだけ出す(XCUITest は既知の赤 13 本で全部成功しない = 警告が鳴りっぱなしになる)

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

const ROOT = resolve(import.meta.dirname, '../..')
const source = readFileSync(join(ROOT, 'Scripts/e2ex.sh'), 'utf8')

/** 判定と記録の2ブロックだけを取り出し、変数を差し替えて実行する */
function runGate({ profile, failed, markers = {}, digest }) {
  const dir = mkdtempSync(join(tmpdir(), 'e2ex-gate-'))
  mkdirSync(join(dir, '.fleetest'), { recursive: true })
  for (const [name, body] of Object.entries(markers)) {
    writeFileSync(join(dir, '.fleetest', name), body)
  }
  const detectStart = source.indexOf('engine_digest()')
  const detect = source.slice(detectStart, source.indexOf('\n# ソースが成果物より新しいか', detectStart))
  const recordStart = source.indexOf('# **印を更新するのは全部成功したときだけ**')
  const record = source.slice(recordStart, source.indexOf('\nexit "$FAILED"', recordStart))
  assert.ok(detectStart >= 0 && recordStart >= 0, 'e2ex.sh からゲートの2ブロックを取り出せない')
  const harness = [
    'set -u',
    `ROOT=${JSON.stringify(dir)}`,
    'FLEETEST=/nonexistent',
    'RUN_IOS=1',
    `IOS_PROFILE=${JSON.stringify(profile)}`,
    `FAILED=${failed}`,
    detect.replace(/^engine_digest\(\).*$/m, `engine_digest() { echo ${JSON.stringify(digest)}; }`),
    record,
  ].join('\n')
  const out = execFileSync('bash', ['-c', harness], { encoding: 'utf8' })
  const readMarker = (name) => {
    const p = join(dir, '.fleetest', name)
    return existsSync(p) ? readFileSync(p, 'utf8').trim() : null
  }
  return { out, readMarker }
}

test('既定(in-app)の実行は xcuitest の印が無くても警告しない(既知の赤で鳴りっぱなしにしない)', () => {
  const { out } = runGate({ profile: 'ios-inapp', failed: 0, digest: 'abc' })
  assert.doesNotMatch(out, /⚠️/)
})

test('--ios-xcuitest の実行は E2EX の in-app の印が無ければ警告する', () => {
  const { out } = runGate({ profile: 'ios-xcuitest', failed: 0, digest: 'abc' })
  assert.match(out, /inapp ブリッジの入力が/)
  assert.match(out, /未検証のまま/)
})

test('--ios-xcuitest の実行は E2EX の in-app の印が一致していれば黙る', () => {
  const { out } = runGate({
    profile: 'ios-xcuitest', failed: 0, markers: { 'inapp-e2ex-verified': 'abc\n' }, digest: 'abc',
  })
  assert.doesNotMatch(out, /⚠️/)
})

test('E2E の印(-e2e-verified)は E2EX の印として数えない', () => {
  const { out } = runGate({
    profile: 'ios-xcuitest', failed: 0, markers: { 'inapp-e2e-verified': 'abc\n' }, digest: 'abc',
  })
  assert.match(out, /inapp ブリッジの入力が/)
})

test('全部成功したら回したエンジンの E2EX の印を書く', () => {
  const { out, readMarker } = runGate({ profile: 'ios-inapp', failed: 0, digest: 'abc' })
  assert.equal(readMarker('inapp-e2ex-verified'), 'abc')
  assert.equal(readMarker('inapp-e2e-verified'), null, 'E2E の印を書いてはいけない')
  assert.equal(readMarker('xcuitest-e2ex-verified'), null, '回していない側の印を書いてはいけない')
  assert.match(out, /検証済みとして記録/)
})

test('失敗があれば印を書かない', () => {
  const { readMarker } = runGate({ profile: 'ios-inapp', failed: 1, digest: 'abc' })
  assert.equal(readMarker('inapp-e2ex-verified'), null)
})
