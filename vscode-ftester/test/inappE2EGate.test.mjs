// Scripts/e2e.sh の「回さなかった側のエンジンが未検証のままではないか」ゲートを検証する。
//
// なぜ要るか: 1回の実行が見るのは iOS の2エンジンのうち片方だけ。2026-08-09 に in-app/xcuitest の
// 両方を変えた回の E2E 254 本が全部 engine=xcuitest で、in-app 側は1度も動かないまま緑になった。
// ゲート自体が壊れても誰も気付かないので、ここで両方向を固定する。
// 2026-08-11 に既定が in-app へ反転し、印もエンジンごと(.ftester/<engine>-e2e-verified)になった。

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync, existsSync, readFileSync as read } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

const ROOT = resolve(import.meta.dirname, '../..')
const SCRIPT = join(ROOT, 'Scripts/e2e.sh')
const source = readFileSync(SCRIPT, 'utf8')

/** ゲートの2ブロック(判定・記録)だけを取り出し、変数を差し替えて実行する。
 * marker は「エンジン名 → 中身」。engine_marker が組み立てるパス($ROOT/.ftester/<engine>-e2e-verified)
 * に置くので、テスト側でパスの組み立て規則を二重に持たない。 */
function runGate({ profile, failed, markers = {}, digest }) {
  const dir = mkdtempSync(join(tmpdir(), 'engine-gate-'))
  mkdirSync(join(dir, '.ftester'), { recursive: true })
  for (const [engine, body] of Object.entries(markers)) {
    writeFileSync(join(dir, '.ftester', `${engine}-e2e-verified`), body)
  }
  // e2e.sh から「engine_digest= の行」〜「FAILED=0」の直前までと、末尾の記録ブロックを抜く
  const detect = source.slice(source.indexOf('engine_digest()'), source.indexOf('\nFAILED=0'))
  const recordStart = source.indexOf('# **通した状態を覚えるのは全部成功したときだけ**')
  const record = source.slice(recordStart, source.indexOf('\nexit "$FAILED"'))
  const harness = [
    'set -u',
    `ROOT=${JSON.stringify(dir)}`,
    'FTESTER=/nonexistent',
    `RUN_IOS=1`,
    `IOS_PROFILE=${JSON.stringify(profile)}`,
    `FAILED=${failed}`,
    // api 呼び出しは固定値に差し替える(このテストはゲートの分岐を見るもので、
    // digest の中身は BridgeContractTests の担当)
    detect.replace(/^engine_digest\(\).*$/m, `engine_digest() { echo ${JSON.stringify(digest)}; }`),
    record,
  ].join('\n')
  const out = execFileSync('bash', ['-c', harness], { encoding: 'utf8' })
  const readMarker = (engine) => {
    const p = join(dir, '.ftester', `${engine}-e2e-verified`)
    return existsSync(p) ? read(p, 'utf8').trim() : null
  }
  return { out, readMarker }
}

test('既定(in-app)の実行は xcuitest の印が無ければ警告する', () => {
  const { out } = runGate({ profile: 'ios-inapp', failed: 0, digest: 'abc' })
  assert.match(out, /xcuitest/)
  assert.match(out, /--ios-xcuitest/)
})

test('--ios-xcuitest の実行は in-app の印が無ければ警告する(向きが逆でも同じ)', () => {
  const { out } = runGate({ profile: 'ios-xcuitest', failed: 0, digest: 'abc' })
  assert.match(out, /inapp/)
  assert.match(out, /--ios-inapp/)
})

test('印が現在の digest と一致していれば黙る(常時発火しないこと)', () => {
  const { out } = runGate({ profile: 'ios-inapp', failed: 0, markers: { xcuitest: 'abc\n' }, digest: 'abc' })
  assert.doesNotMatch(out, /ブリッジの入力が/)
})

test('印が古ければ警告する', () => {
  const { out } = runGate({ profile: 'ios-inapp', failed: 0, markers: { xcuitest: 'old\n' }, digest: 'abc' })
  assert.match(out, /ブリッジの入力が/)
})

test('全部成功したら「回した側」の印を書く(既定 = in-app)', () => {
  const { out, readMarker } = runGate({ profile: 'ios-inapp', failed: 0, digest: 'abc' })
  assert.equal(readMarker('inapp'), 'abc')
  assert.equal(readMarker('xcuitest'), null, '回していない側の印を書いてはいけない')
  assert.match(out, /検証済みとして記録/)
})

test('--ios-xcuitest が全部成功したら xcuitest の印を書く', () => {
  const { readMarker } = runGate({ profile: 'ios-xcuitest', failed: 0, digest: 'abc' })
  assert.equal(readMarker('xcuitest'), 'abc')
  assert.equal(readMarker('inapp'), null)
})

test('失敗があれば印を書かない(失敗を検証済みにしない)', () => {
  const { readMarker } = runGate({ profile: 'ios-inapp', failed: 1, digest: 'abc' })
  assert.equal(readMarker('inapp'), null)
})

test('ゲートが呼ぶ api サブコマンドが実在する', () => {
  assert.match(source, /api bridge-sources --set "\$1" --digest/)
  const help = execFileSync('bash', ['-c',
    `cd ${JSON.stringify(ROOT)} && .build/debug/ftester api bridge-sources --help 2>&1 || true`],
    { encoding: 'utf8' })
  assert.match(help, /--set/)
  assert.match(help, /--digest/)
  // --set が受ける値(この2つを渡す)が help に出ていること
  assert.match(help, /inapp/)
  assert.match(help, /xcuitest/)
})
