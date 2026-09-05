// 階層をまたぐ終了保証の統合テスト。部品単位のテスト(ParentDeathWatchTests / ShellTimeoutTests)は
// 「起こした側 → fleetest → シナリオ実行バイナリ」の連鎖が**実バイナリの配線**で切れずに終わることを
// 確かめていない(Codex 指摘 2026-09-06)。ここは3層を実バイナリで組む:
//
//   起こした側(/bin/sh = 拡張の役。`FT_PARENT_PID=$$` を渡す)
//     → `fleetest api run --dry-run --debug --pause-on-start`(ScenarioHost が孫を起こす)
//       → `fleetest-scenarios-E2E-CMP`(最初のステップの手前で停止し続ける = 長生きする孫)
//
// デバイスにも swift build にも触れない(`--skip-build`。swift test の最中に入れ子で swift build を
// 撃つと SPM のビルドロックで詰まる)。両バイナリは同じパッケージの product なので swift test が建てる。
//
// 終わり方は2つ(CLAUDE.md「終了猶予の方針は1つ」の両側):
//   ① 親の異常終了 —— 起こした側を SIGKILL。子は ParentDeathWatch(kqueue)で自らに SIGTERM、
//      孫は子の死を同じ機構で見て消える
//   ② 正常キャンセル —— 子へ SIGTERM(拡張のキャンセルと同じ)。孫は子の死で消える
// どちらも「時限の SIGKILL 無しで」両層が消えることを見る(残れば `exitTimeout` で赤)。

import XCTest
import FTCore

final class CrossLayerTerminationTests: XCTestCase {

    /// E2E-CMP に実在するシナリオ(dry-run なのでアプリも端末も要らない)
    private static let scenarioID = "ID無し画面を方向セレクタで操作できること.S0010"
    /// 孫が `paused` を出すまでの上限(fleetest 起動 + list + runner 起動。実測 2 秒前後。
    /// 並列テストの負荷で伸びるので余裕を持つ)
    private static let readyTimeout: TimeInterval = 60
    /// 親の死・SIGTERM から両層が消えるまでの上限。実測 0.05 秒(kqueue の NOTE_EXIT は即時)。
    /// ここを超えて生きていたら「後始末が刺さった」のではなく配線が切れている
    private static let exitTimeout: TimeInterval = 10

    private struct Chain {
        let spawner: Process
        let spawnerStdin: Pipe
        let childPID: pid_t
        let grandchildPID: pid_t
        let stderrURL: URL
        let tempDir: URL
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - ① 親の異常終了

    func testKillingTheSpawnerTakesDownFleetestAndItsScenarioRunner() throws {
        let chain = try launchChain()
        defer { tearDown(chain) }

        kill(chain.spawner.processIdentifier, SIGKILL)
        chain.spawner.waitUntilExit()

        try assertBothLayersExit(chain, within: Self.exitTimeout)
        let stderr = (try? String(contentsOf: chain.stderrURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(
            stderr.contains("parent process \(chain.spawner.processIdentifier) exited"),
            "子は ParentDeathWatch の発話を残して終わるはず。stderr:\n\(stderr)")
    }

    // MARK: - ② 正常キャンセル

    func testSigtermToFleetestTakesDownTheScenarioRunnerToo() throws {
        let chain = try launchChain()
        defer { tearDown(chain) }

        kill(chain.childPID, SIGTERM)

        try assertBothLayersExit(chain, within: Self.exitTimeout)
        XCTAssertTrue(ProcessLiveness.isAlive(chain.spawner.processIdentifier),
                      "起こした側は無傷のまま(子のキャンセルが親へ波及しない)")
    }

    // MARK: - 組み立て

    private func launchChain() throws -> Chain {
        let root = repoRoot()
        let fleetest = root.appendingPathComponent(".build/debug/fleetest")
        let runner = root.appendingPathComponent(".build/debug/fleetest-scenarios-E2E-CMP")
        for binary in [fleetest, runner] {
            guard FileManager.default.isExecutableFile(atPath: binary.path) else {
                // 黙って skip にしない(素通りで緑になると、この砦が無いのと同じになる)
                XCTFail("\(binary.lastPathComponent) が .build/debug に無い(swift test が建てる product。"
                        + "別の build path で回しているなら .build/debug に建ててから)")
                throw XCTSkip("binary missing")
            }
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-crosslayer-\(UUID().uuidString)")
        let reportDir = tempDir.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        let stdoutURL = tempDir.appendingPathComponent("out.ndjson")
        let stderrURL = tempDir.appendingPathComponent("err.log")

        // `$0` = fleetest / `$1` = シナリオ / `$2` = report-dir / `$3` = stdout / `$4` = stderr。
        // `&` の子は非対話シェルでは stdin が /dev/null にされるので、拡張と同じく開いたままにするため
        // fd 3 経由で明示的に継がせる。`exec sleep` で pid を保ったまま居座る(= 拡張ホストの役)
        let script = """
        exec 3<&0
        FT_PARENT_PID=$$ "$0" api run --project E2E-CMP --skip-build --dry-run --debug --pause-on-start \
          --scenario "$1" --report-dir "$2" <&3 >"$3" 2>"$4" &
        echo $!
        exec sleep 600
        """
        let spawner = Process()
        spawner.executableURL = URL(fileURLWithPath: "/bin/sh")
        spawner.arguments = ["-c", script, fleetest.path, Self.scenarioID,
                             reportDir.path, stdoutURL.path, stderrURL.path]
        spawner.currentDirectoryURL = root  // --project は cwd のパッケージから解決する
        let spawnerStdin = Pipe()
        spawner.standardInput = spawnerStdin
        let pidPipe = Pipe()
        spawner.standardOutput = pidPipe
        spawner.standardError = FileHandle.nullDevice
        try spawner.run()

        let childPID = try readPIDLine(from: pidPipe.fileHandleForReading)

        // 孫が最初のステップの手前で止まった(= 3層が揃って長生きしている)ことを、
        // 子の stdout に `paused` が出ることで確かめる。先に子が死んだら理由ごと赤にする
        let deadline = Date().addingTimeInterval(Self.readyTimeout)
        var paused = false
        while Date() < deadline {
            if let out = try? String(contentsOf: stdoutURL, encoding: .utf8),
               out.contains("\"kind\":\"paused\"") {
                paused = true
                break
            }
            guard ProcessLiveness.isAlive(childPID) else {
                let err = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
                kill(spawner.processIdentifier, SIGKILL)
                XCTFail("fleetest api run が paused の前に終わった。stderr:\n\(err)")
                throw XCTSkip("chain did not come up")
            }
            usleep(100_000)
        }
        guard paused else {
            kill(childPID, SIGKILL)
            kill(spawner.processIdentifier, SIGKILL)
            XCTFail("\(Self.readyTimeout) 秒待っても孫が paused にならない")
            throw XCTSkip("chain did not come up")
        }

        let grandchildPID = try findGrandchild(parent: childPID)
        return Chain(spawner: spawner, spawnerStdin: spawnerStdin, childPID: childPID,
                     grandchildPID: grandchildPID, stderrURL: stderrURL, tempDir: tempDir)
    }

    private func readPIDLine(from handle: FileHandle) throws -> pid_t {
        var bytes = Data()
        while true {
            let chunk = handle.readData(ofLength: 1)
            guard !chunk.isEmpty else { break }
            if chunk == Data("\n".utf8) { break }
            bytes.append(chunk)
        }
        guard let pid = pid_t(String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)) else {
            throw XCTSkip("起こした側が子の pid を出さなかった: \(String(decoding: bytes, as: UTF8.self))")
        }
        return pid
    }

    /// 子の直下に居るシナリオ実行バイナリの pid(`pgrep -P <子> -f <runner>`)
    private func findGrandchild(parent: pid_t) throws -> pid_t {
        let result = try Shell.run(["/usr/bin/pgrep", "-P", String(parent), "-f", "fleetest-scenarios-E2E-CMP"])
        let pids = result.output
            .split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        guard pids.count == 1, let pid = pids.first else {
            XCTFail("孫のシナリオ実行バイナリが子 \(parent) の直下にちょうど1本居るはず: \(pids)")
            throw XCTSkip("grandchild not found")
        }
        return pid
    }

    private func assertBothLayersExit(_ chain: Chain, within timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !ProcessLiveness.isAlive(chain.childPID), !ProcessLiveness.isAlive(chain.grandchildPID) {
                return
            }
            usleep(50_000)
        }
        let child = ProcessLiveness.isAlive(chain.childPID)
        let grandchild = ProcessLiveness.isAlive(chain.grandchildPID)
        let stderr = (try? String(contentsOf: chain.stderrURL, encoding: .utf8)) ?? ""
        XCTFail("\(timeout) 秒経っても残っている: fleetest api run=\(child ? "alive" : "gone") / "
                + "scenario runner=\(grandchild ? "alive" : "gone")。stderr:\n\(stderr)")
    }

    /// 赤になっても3層を残さない(次のテストや人の環境に孤児を置かない)
    private func tearDown(_ chain: Chain) {
        for pid in [chain.grandchildPID, chain.childPID, chain.spawner.processIdentifier]
        where ProcessLiveness.isAlive(pid) {
            kill(pid, SIGKILL)
        }
        chain.spawner.waitUntilExit()
        try? chain.spawnerStdin.fileHandleForWriting.close()
        try? FileManager.default.removeItem(at: chain.tempDir)
    }
}
