// Scripts/e2e.sh の「in-app 経路が未検証のままではないか」ゲートを検証する。
//
// なぜ要るか: 既定スイートは iOS を xcuitest でしか回さないのに、利用者の既定エンジンは
// hybrid(in-app 優先)。2026-08-09 に in-app/xcuitest の両方を変えた回の E2E 254 本が
// 全部 engine=xcuitest で、in-app 側は1度も動かないまま緑になった。
// ゲート自体が壊れても誰も気付かないので、ここで両方向を固定する。

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readFileSync, mkdtempSync, writeFileSync, existsSync, readFileSync as read } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

const ROOT = resolve(import.meta.dirname, '../..')
const SCRIPT = join(ROOT, 'Scripts/e2e.sh')
const source = readFileSync(SCRIPT, 'utf8')

/** ゲートの2ブロック(判定・記録)だけを取り出し、変数を差し替えて実行する */
function runGate({ profile, failed, marker, digest }) {
  const dir = mkdtempSync(join(tmpdir(), 'inapp-gate-'))
  const markerPath = join(dir, 'marker')
  if (marker !== undefined) writeFileSync(markerPath, marker)
  // e2e.sh から「INAPP_MARKER= の行」〜「FAILED=0」の直前までと、末尾の記録ブロックを抜く
  const detect = source.slice(source.indexOf('INAPP_MARKER='), source.indexOf('\nFAILED=0'))
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
    `inapp_digest() { echo ${JSON.stringify(digest)}; }`,
    detect.replace(/^INAPP_MARKER=.*$/m, `INAPP_MARKER=${JSON.stringify(markerPath)}`)
      .replace(/^inapp_digest\(\).*$/m, ''),
    record,
  ].join('\n')
  const out = execFileSync('bash', ['-c', harness], { encoding: 'utf8' })
  return { out, markerPath, marker: existsSync(markerPath) ? read(markerPath, 'utf8').trim() : null }
}

test('印が無ければ「in-app 未検証」と警告する', () => {
  const { out } = runGate({ profile: 'ios-xcuitest', failed: 0, digest: 'abc' })
  assert.match(out, /in-app/)
  assert.match(out, /--ios-inapp/)
})

test('印が現在の digest と一致していれば黙る(常時発火しないこと)', () => {
  const { out } = runGate({ profile: 'ios-xcuitest', failed: 0, marker: 'abc\n', digest: 'abc' })
  assert.doesNotMatch(out, /in-app ブリッジの入力が/)
})

test('印が古ければ警告する', () => {
  const { out } = runGate({ profile: 'ios-xcuitest', failed: 0, marker: 'old\n', digest: 'abc' })
  assert.match(out, /in-app ブリッジの入力が/)
})

test('--ios-inapp が全部成功したら印を書く', () => {
  const { out, marker } = runGate({ profile: 'ios-inapp', failed: 0, digest: 'abc' })
  assert.equal(marker, 'abc')
  assert.match(out, /検証済みとして記録/)
})

test('--ios-inapp でも失敗があれば印を書かない(失敗を検証済みにしない)', () => {
  const { marker } = runGate({ profile: 'ios-inapp', failed: 1, digest: 'abc' })
  assert.equal(marker, null)
})

test('ゲートが呼ぶ api サブコマンドが実在する', () => {
  assert.match(source, /api bridge-sources --set inapp --digest/)
  const help = execFileSync('bash', ['-c',
    `cd ${JSON.stringify(ROOT)} && .build/debug/ftester api bridge-sources --help 2>&1 || true`],
    { encoding: 'utf8' })
  assert.match(help, /--set/)
  assert.match(help, /--digest/)
})
