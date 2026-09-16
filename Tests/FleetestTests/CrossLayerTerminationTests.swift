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

    // MARK: - ① 親の異常終了(FIFO 経路)

    /// 上のテストは stdout/stderr を**ファイル**へ流すので、子の書き込みは常に成功し
    /// (親が死んでも読み手はファイルシステムのまま)、「読み手が消えて write が失敗する」経路
    /// (本番のパイプと同じ形)を1度も踏まない。ここは stdout+stderr を1本の FIFO へまとめ、
    /// spawner 自身が `exec cat` で読み手になる(pid を保ったまま)ことで、spawner の SIGKILL が
    /// 読み手の消失 = 子の write の EPIPE を再現する
    /// (`ParentDeathWatch.writeNotice` の abort/SIGPIPE バグはこの経路でしか踏めなかった)
    func testKillingTheSpawnerTakesDownFleetestAndItsScenarioRunnerWhenOnlyTheParentReadsTheOutput() throws {
        let chain = try launchChain(outputMode: .fifo)
        defer { tearDown(chain) }

        kill(chain.spawner.processIdentifier, SIGKILL)
        chain.spawner.waitUntilExit()

        // FIFO の読み手は spawner と共に消えるので、文言照合はできない(既存のファイル経路の
        // テストが担う)。ここで確かめるのは「両層が時限の SIGKILL 無しで消えること」だけ
        try assertBothLayersExit(chain, within: Self.exitTimeout)
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

    private enum OutputMode {
        /// 通常経路: stdout/stderr を別ファイルへ。readiness は stdout の `paused` を読んで判定
        case files
        /// ①FIFO 経路: stdout+stderr を1本の FIFO へまとめ、spawner 自身が `exec cat` で読み手になる。
        /// FIFO の中身は読み捨てるので readiness は孫プロセスの出現+安定で判定し、stderr の文言も読めない
        case fifo
    }

    private func launchChain(outputMode: OutputMode = .files) throws -> Chain {
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

        let spawner = Process()
        spawner.executableURL = URL(fileURLWithPath: "/bin/sh")
        spawner.currentDirectoryURL = root  // --project は cwd のパッケージから解決する
        let spawnerStdin = Pipe()
        spawner.standardInput = spawnerStdin
        let pidPipe = Pipe()
        spawner.standardOutput = pidPipe
        spawner.standardError = FileHandle.nullDevice

        switch outputMode {
        case .files:
            let stdoutURL = tempDir.appendingPathComponent("out.ndjson")
            let stderrURL = tempDir.appendingPathComponent("err.log")
            // `$0` = fleetest / `$1` = シナリオ / `$2` = report-dir / `$3` = stdout / `$4` = stderr。
            // `&` の子は非対話シェルでは stdin が /dev/null にされるので、拡張と同じく開いたままにする
            // ため fd 3 経由で明示的に継がせる。`exec sleep` で pid を保ったまま居座る(= 拡張ホストの役)
            let script = """
            exec 3<&0
            FT_PARENT_PID=$$ "$0" api run --project E2E-CMP --skip-build --dry-run --debug --pause-on-start \
              --scenario "$1" --report-dir "$2" <&3 >"$3" 2>"$4" &
            echo $!
            exec sleep 600
            """
            spawner.arguments = ["-c", script, fleetest.path, Self.scenarioID,
                                 reportDir.path, stdoutURL.path, stderrURL.path]
            try spawner.run()
            let childPID = try readPIDLine(from: pidPipe.fileHandleForReading)
            try waitForPausedOutput(spawner: spawner, childPID: childPID,
                                    stdoutURL: stdoutURL, stderrURL: stderrURL)
            let grandchildPID = try findGrandchild(parent: childPID)
            return Chain(spawner: spawner, spawnerStdin: spawnerStdin, childPID: childPID,
                         grandchildPID: grandchildPID, stderrURL: stderrURL, tempDir: tempDir)

        case .fifo:
            let fifoURL = tempDir.appendingPathComponent("out.fifo")
            // `$0` = fleetest / `$1` = シナリオ / `$2` = report-dir / `$3` = FIFO。
            // `exec cat` は pid を保ったまま読み手になる(= 拡張ホストの役)ので、spawner を殺すと
            // 読み手が消え、子の write は(ファイル経路と違って)EPIPE になる
            let script = """
            exec 3<&0
            mkfifo "$3"
            FT_PARENT_PID=$$ "$0" api run --project E2E-CMP --skip-build --dry-run --debug --pause-on-start \
              --scenario "$1" --report-dir "$2" <&3 >"$3" 2>&1 &
            echo $!
            exec cat "$3" >/dev/null
            """
            spawner.arguments = ["-c", script, fleetest.path, Self.scenarioID,
                                 reportDir.path, fifoURL.path]
            try spawner.run()
            let childPID = try readPIDLine(from: pidPipe.fileHandleForReading)
            let grandchildPID = try waitForStableGrandchild(spawner: spawner, childPID: childPID,
                                                             timeout: Self.readyTimeout)
            // このモードでは stderr を読めない(FIFO の読み手は spawner の死と共に消える)。
            // 存在しないパスにしておけば、失敗時のメッセージ組み立て(`try? String(contentsOf:)`)が
            // FIFO を開いてブロックすることなく空文字へ落ちる
            let unreadableStderrURL = tempDir.appendingPathComponent("stderr-not-captured")
            return Chain(spawner: spawner, spawnerStdin: spawnerStdin, childPID: childPID,
                         grandchildPID: grandchildPID, stderrURL: unreadableStderrURL, tempDir: tempDir)
        }
    }

    /// 孫が最初のステップの手前で止まった(= 3層が揃って長生きしている)ことを、
    /// 子の stdout に `paused` が出ることで確かめる。先に子が死んだら理由ごと赤にする
    private func waitForPausedOutput(spawner: Process, childPID: pid_t,
                                     stdoutURL: URL, stderrURL: URL) throws {
        let deadline = Date().addingTimeInterval(Self.readyTimeout)
        while Date() < deadline {
            if let out = try? String(contentsOf: stdoutURL, encoding: .utf8),
               out.contains("\"kind\":\"paused\"") {
                return
            }
            guard ProcessLiveness.isAlive(childPID) else {
                let err = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
                kill(spawner.processIdentifier, SIGKILL)
                XCTFail("fleetest api run が paused の前に終わった。stderr:\n\(err)")
                throw XCTSkip("chain did not come up")
            }
            usleep(100_000)
        }
        kill(childPID, SIGKILL)
        kill(spawner.processIdentifier, SIGKILL)
        XCTFail("\(Self.readyTimeout) 秒待っても孫が paused にならない")
        throw XCTSkip("chain did not come up")
    }

    /// FIFO 経路用: `paused` の文言が読めない代わりに、孫プロセスが現れて**見つかった後も
    /// 生き続ける**ことで readiness を判定する(見つかった直後にたまたま終了していた、という
    /// 誤検知を避けるための安定待ち)
    private func waitForStableGrandchild(spawner: Process, childPID: pid_t,
                                         timeout: TimeInterval) throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard ProcessLiveness.isAlive(childPID) else {
                kill(spawner.processIdentifier, SIGKILL)
                XCTFail("fleetest api run が孫を起こす前に終わった")
                throw XCTSkip("chain did not come up")
            }
            if let pid = try grandchildIfPresent(parent: childPID) {
                usleep(300_000)
                if ProcessLiveness.isAlive(pid) {
                    return pid
                }
            }
            usleep(100_000)
        }
        kill(childPID, SIGKILL)
        kill(spawner.processIdentifier, SIGKILL)
        XCTFail("\(timeout) 秒待っても孫が安定して現れない")
        throw XCTSkip("chain did not come up")
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

    /// 子の直下に居るシナリオ実行バイナリの pid(`pgrep -P <子> -f <runner>`)。
    /// **0 件は「まだ起こしていないだけ」であって失敗ではない**ので nil を返す(呼び手がポーリングで
    /// 使う)。複数件は取り違えなので即座に失敗させる
    private func grandchildIfPresent(parent: pid_t) throws -> pid_t? {
        let result = try Shell.run(["/usr/bin/pgrep", "-P", String(parent), "-f", "fleetest-scenarios-E2E-CMP"])
        let pids = result.output
            .split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        if pids.count > 1 {
            XCTFail("孫のシナリオ実行バイナリが子 \(parent) の直下に複数居る: \(pids)")
            throw XCTSkip("ambiguous grandchild")
        }
        return pids.first
    }

    private func findGrandchild(parent: pid_t) throws -> pid_t {
        guard let pid = try grandchildIfPresent(parent: parent) else {
            XCTFail("孫のシナリオ実行バイナリが子 \(parent) の直下にちょうど1本居るはず")
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
