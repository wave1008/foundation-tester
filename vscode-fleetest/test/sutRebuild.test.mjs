// Scripts/sut-rebuild.sh(e2e.sh / e2ex.sh / e2ey.sh / e2e-devices.sh が source する SUT の作り直し判定)を検証する。
// 守るのは「外部 SDK だけ上げたら作り直す」—— mtime だけの判定では、古い SDK で作ったアプリのまま黙って回る。
// flutter / xcodebuild は PATH の先頭に置いた偽物で差し替える(版を返すだけ)。

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, chmodSync, utimesSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

const ROOT = resolve(import.meta.dirname, '../..')
const SCRIPTS = ['Scripts/e2e.sh', 'Scripts/e2ex.sh', 'Scripts/e2ey.sh', 'Scripts/e2e-devices.sh']

function fixture({ flutterSut = true, artifactName = 'android/app.apk' } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'sut-rebuild-'))
  const app = join(dir, 'App')
  mkdirSync(join(app, 'lib'), { recursive: true })
  mkdirSync(join(app, 'dist/android'), { recursive: true })
  mkdirSync(join(app, 'dist/ios-simulator'), { recursive: true })
  if (flutterSut) writeFileSync(join(app, 'pubspec.yaml'), 'name: app\n')
  writeFileSync(join(app, 'lib/main.dart'), '')
  const artifact = join(app, 'dist', artifactName)
  if (artifactName.endsWith('.app')) mkdirSync(artifact)
  else writeFileSync(artifact, '')
  // ソースを成果物より古くしておく(①mtime の軸が立たない状態から始める)
  const old = new Date(Date.now() - 3600_000)
  utimesSync(join(app, 'lib/main.dart'), old, old)
  const bin = join(dir, 'bin')
  mkdirSync(bin)
  return { dir, app, artifact, bin }
}

/** 偽の flutter。out = --version --machine の標準出力そのもの(null = コマンドが失敗する) */
function setFlutter(bin, out) {
  const p = join(bin, 'flutter')
  writeFileSync(p, out === null ? '#!/bin/sh\nexit 1\n' : `#!/bin/sh\ncat <<'JSON'\n${out}\nJSON\n`)
  chmodSync(p, 0o755)
}
/** 偽の xcodebuild。build = -version のビルド番号 */
function setXcode(bin, build) {
  const p = join(bin, 'xcodebuild')
  writeFileSync(p, `#!/bin/sh\nprintf 'Xcode 99.0\\nBuild version ${build}\\n'\n`)
  chmodSync(p, 0o755)
}
const version = (fw, engine = 'e1') => JSON.stringify({ frameworkVersion: '9.9.9', frameworkRevision: fw, engineRevision: engine })

/** needs_rebuild の真偽を返す。record = true なら判定の前に record_sdk を打つ */
function run(fx, { force = 0, record = false } = {}) {
  const script = [
    'set -euo pipefail',
    `FORCE_REBUILD=${force}`,
    `. ${JSON.stringify(join(ROOT, 'Scripts/sut-rebuild.sh'))}`,
    record ? `record_sdk ${JSON.stringify(fx.artifact)}` : ':',
    `if needs_rebuild ${JSON.stringify(fx.artifact)} ${JSON.stringify(join(fx.app, 'lib'))}; then echo yes; else echo no; fi`,
  ].join('\n')
  return execFileSync('bash', ['-c', script], {
    encoding: 'utf8', env: { ...process.env, PATH: `${fx.bin}:${process.env.PATH}` }, stdio: ['ignore', 'pipe', 'ignore'],
  }).trim()
}

test('控えの無い Flutter の成果物は作り直す(この判定を入れる前に作ったアプリ)', () => {
  const fx = fixture()
  setFlutter(fx.bin, version('aaa'))
  assert.equal(run(fx), 'yes')
})

test('ビルド後に控えを書けば、同じ SDK・ソース無変更では作り直さない', () => {
  const fx = fixture()
  setFlutter(fx.bin, version('aaa'))
  assert.equal(run(fx, { record: true }), 'no')
  assert.equal(readFileSync(`${fx.artifact}.sdk`, 'utf8').trim(), 'flutter aaa e1')
})

test('SDK だけ上げたら作り直す(framework / engine のどちらが違っても)', () => {
  const fx = fixture()
  setFlutter(fx.bin, version('aaa'))
  run(fx, { record: true })
  setFlutter(fx.bin, version('bbb'))
  assert.equal(run(fx), 'yes')
  setFlutter(fx.bin, version('aaa', 'e2'))
  assert.equal(run(fx), 'yes')
})

test('ツールの作り直しの案内行が JSON の前に混ざっても版を読める', () => {
  const fx = fixture()
  setFlutter(fx.bin, `Building flutter tool...\n${version('aaa')}`)
  assert.equal(run(fx, { record: true }), 'no')
  assert.equal(readFileSync(`${fx.artifact}.sdk`, 'utf8').trim(), 'flutter aaa e1')
})

test('版を読めないときは mtime だけで判定し、控えも書かない', () => {
  const fx = fixture()
  setFlutter(fx.bin, null)
  assert.equal(run(fx, { record: true }), 'no')
  assert.equal(existsSync(`${fx.artifact}.sdk`), false)
})

test('Flutter 以外の SUT は SDK の版を見ない(控えも書かない)', () => {
  const fx = fixture({ flutterSut: false })
  setFlutter(fx.bin, version('aaa'))
  assert.equal(run(fx, { record: true }), 'no')
  assert.equal(existsSync(`${fx.artifact}.sdk`), false)
})

test('iOS の成果物は Xcode のビルド番号も控え、Xcode だけ上げても作り直す(Flutter 以外の SUT も)', () => {
  const fx = fixture({ flutterSut: false, artifactName: 'ios-simulator/App.app' })
  setXcode(fx.bin, '27A100')
  assert.equal(run(fx, { record: true }), 'no')
  assert.equal(readFileSync(`${fx.artifact}.sdk`, 'utf8').trim(), 'xcode 27A100')
  setXcode(fx.bin, '27A200')
  assert.equal(run(fx), 'yes')
})

test('Flutter の iOS の成果物は Flutter と Xcode の両方を控える', () => {
  const fx = fixture({ artifactName: 'ios-simulator/App.app' })
  setFlutter(fx.bin, version('aaa'))
  setXcode(fx.bin, '27A100')
  assert.equal(run(fx, { record: true }), 'no')
  assert.equal(readFileSync(`${fx.artifact}.sdk`, 'utf8').trim(), 'flutter aaa e1\nxcode 27A100')
  setFlutter(fx.bin, version('bbb'))
  assert.equal(run(fx), 'yes')
})

test('ソースが成果物より新しければ作り直す・--rebuild は常に作り直す', () => {
  const fx = fixture()
  setFlutter(fx.bin, version('aaa'))
  run(fx, { record: true })
  assert.equal(run(fx, { force: 1 }), 'yes')
  const future = new Date(Date.now() + 3600_000)
  utimesSync(join(fx.app, 'lib/main.dart'), future, future)
  assert.equal(run(fx), 'yes')
})

test('4本のスクリプトは判定を自前で持たず sut-rebuild.sh を読む', () => {
  for (const s of SCRIPTS) {
    const src = readFileSync(join(ROOT, s), 'utf8')
    assert.match(src, /\. "\$ROOT\/Scripts\/sut-rebuild\.sh"/, `${s} が sut-rebuild.sh を読んでいない`)
    assert.doesNotMatch(src, /^needs_rebuild\(\)/m, `${s} が needs_rebuild を自前で定義している`)
  }
})

test('SUT のビルドの直後には必ず record_sdk がある(書き忘れた iOS の成果物は毎回作り直しになる)', () => {
  let builds = 0
  for (const s of SCRIPTS) {
    const lines = readFileSync(join(ROOT, s), 'utf8').split('\n')
    lines.forEach((line, i) => {
      if (!/scripts\/build-[a-z-]+\.sh"(; then)?\s*$/.test(line)) return
      builds++
      assert.match(lines[i + 1] ?? '', /^\s*record_sdk /, `${s}:${i + 2} にビルド直後の record_sdk が無い`)
    })
  }
  // 走査が空振りしていないこと(e2e.sh 10 + e2e-devices.sh 8 + e2ex.sh 2 + e2ey.sh 2)
  assert.equal(builds, 22)
})
