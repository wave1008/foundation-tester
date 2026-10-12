// Scripts/rn-deps.sh(RN の SUT のビルド前に node_modules・Pods をリポジトリの lock に揃える)を検証する。
// 守るのは「lock だけ新しい版になった機械で、古い依存のまま作り直さない」と「揃っているときは何もしない」。
// npm / pod は PATH の先頭に置いた偽物で差し替え、呼ばれたかどうかを記録する。

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, chmodSync, readdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

const ROOT = resolve(import.meta.dirname, '../..')

const lockOf = (packages) => JSON.stringify({ lockfileVersion: 3, packages: { '': { name: 'app' }, ...packages } })

function fixture({ lock, installed, podfileLock = 'PODS: a\n', manifestLock = podfileLock }) {
  const dir = mkdtempSync(join(tmpdir(), 'rn-deps-'))
  const app = join(dir, 'App')
  mkdirSync(join(app, 'ios/Pods'), { recursive: true })
  writeFileSync(join(app, 'package-lock.json'), lockOf(lock))
  if (installed !== undefined) {
    mkdirSync(join(app, 'node_modules'))
    writeFileSync(join(app, 'node_modules/.package-lock.json'), lockOf(installed))
  }
  writeFileSync(join(app, 'ios/Podfile.lock'), podfileLock)
  if (manifestLock !== null) writeFileSync(join(app, 'ios/Pods/Manifest.lock'), manifestLock)
  const bin = join(dir, 'bin')
  mkdirSync(bin)
  const calls = join(dir, 'calls')
  for (const tool of ['npm', 'pod']) {
    writeFileSync(join(bin, tool), `#!/bin/sh\necho "${tool} $* (cwd=$(basename "$PWD"))" >> ${JSON.stringify(calls)}\n`)
    chmodSync(join(bin, tool), 0o755)
  }
  return { app, bin, calls }
}

function sync(fx) {
  execFileSync('bash', ['-c', `set -euo pipefail; . ${JSON.stringify(join(ROOT, 'Scripts/rn-deps.sh'))}; rn_sync_node_modules; rn_sync_pods`], {
    cwd: fx.app, env: { ...process.env, PATH: `${fx.bin}:${process.env.PATH}` }, stdio: 'ignore',
  })
  return existsSync(fx.calls) ? readFileSync(fx.calls, 'utf8').trim().split('\n') : []
}

const RN86 = { 'node_modules/react-native': { version: '0.86.2' } }
const RN87 = { 'node_modules/react-native': { version: '0.87.1' } }

test('揃っているときは npm も pod も呼ばない', () => {
  assert.deepEqual(sync(fixture({ lock: RN86, installed: RN86 })), [])
})

test('lock だけ新しい版なら npm ci で入れ直す(npm install ではない = lock を書き換えない)', () => {
  assert.deepEqual(sync(fixture({ lock: RN87, installed: RN86 })), ['npm ci (cwd=App)'])
})

test('node_modules が無い・入れた記録が無いときも npm ci', () => {
  assert.deepEqual(sync(fixture({ lock: RN86 })), ['npm ci (cwd=App)'])
})

test('lock にあって入っていないパッケージがあれば npm ci', () => {
  const lock = { ...RN86, 'node_modules/left-pad': { version: '1.0.0' } }
  assert.deepEqual(sync(fixture({ lock, installed: RN86 })), ['npm ci (cwd=App)'])
})

test('optional のパッケージ(機種で入らないもの)が無くても入れ直さない', () => {
  const lock = { ...RN86, 'node_modules/fsevents': { version: '2.3.3', optional: true } }
  assert.deepEqual(sync(fixture({ lock, installed: RN86 })), [])
})

test('Pods が Podfile.lock と食い違えば ios で pod install --deployment(lock を書き換えない)', () => {
  assert.deepEqual(sync(fixture({ lock: RN86, installed: RN86, manifestLock: 'PODS: old\n' })), ['pod install --deployment (cwd=ios)'])
  assert.deepEqual(sync(fixture({ lock: RN86, installed: RN86, manifestLock: null })), ['pod install --deployment (cwd=ios)'])
})

test('RN のビルドスクリプトは全部、ビルドの前に依存を揃える(iOS は Pods も)', () => {
  let scripts = 0
  for (const sut of ['E2EAppRN', 'E2EXAppRN', 'E2EYAppRN']) {
    for (const name of readdirSync(join(ROOT, sut, 'scripts')).filter((n) => /^build-.*\.sh$/.test(n))) {
      scripts++
      const src = readFileSync(join(ROOT, sut, 'scripts', name), 'utf8')
      const build = src.search(/^xcodebuild |^\(cd android && \.\/gradlew/m)
      assert.ok(build > 0, `${sut}/scripts/${name} にビルドの行が見つからない`)
      const before = src.slice(0, build)
      assert.match(before, /^\. \.\.\/Scripts\/rn-deps\.sh$/m, `${sut}/scripts/${name} が rn-deps.sh を読んでいない`)
      assert.match(before, /^rn_sync_node_modules$/m, `${sut}/scripts/${name} がビルドの前に node_modules を揃えていない`)
      if (name.startsWith('build-ios')) {
        assert.match(before, /^rn_sync_pods$/m, `${sut}/scripts/${name} がビルドの前に Pods を揃えていない`)
      }
    }
  }
  assert.equal(scripts, 7)
})
