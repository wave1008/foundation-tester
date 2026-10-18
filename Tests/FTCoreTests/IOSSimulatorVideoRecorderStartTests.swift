// iOS の録画の開始(試し撮り・開始前の掃除)と、止める期限を過ぎた client の見張りへの引き渡しを、偽の xcrun と
// **製品バイナリの fleetest(`api recorder-watch`)**で確かめる。偽物は simctl recordVideo の実測の性質を真似る:
// "Recording started" より前の SIGINT は無視する / 撮り始めた直後に止めると中身が空になる / 一時ファイル `<名前>.sb-…` を作る。
// 偽の UDID はテストごとに作る(本物のシミュレータの録画に pkill が当たらない)。
//
// 順序の固定: 録画クラスの期限は差し替えた時計で測る。テストは時計を止めたまま偽 client の準備("ready")を確かめ、
// その後に時計を解放して期限を越えさせる = 「ファイル作成 → 期限切れ → 見張りへ渡す → 呼び手の復帰」が構成で決まる。
// 偽 client は "go" が置かれるまで SIGINT を無視し続ける = 復帰後に client が生きている状態を観測できる。

import XCTest
@testable import FTCore

final class IOSSimulatorVideoRecorderStartTests: XCTestCase {
    private struct MissingBinary: Error {}

    /// `swift test` は製品もビルドする(`.build/out/Products/Debug/` に xctest と並ぶ)。無ければ落とす(skip にしない)
    private func fleetestBinary() throws -> URL {
        let url = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("fleetest")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            XCTFail("製品バイナリ fleetest が \(url.path) に無い")
            throw MissingBinary()
        }
        return url
    }

    /// 作業ディレクトリ。後始末: "go" を置いて待っている偽 client を解放し、残った偽物と見張り(コマンド行にこのパスを持つ)だけを SIGKILL する
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fleetest-fake-xcrun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? Data().write(to: dir.appendingPathComponent("go"))
            for _ in 0..<20 where Self.processCount(matching: dir.path) > 0 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            _ = try? Shell.run(["pkill", "-KILL", "-f", dir.path])
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    private func writeScript(_ body: String, to url: URL) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func processCount(matching pattern: String) -> Int {
        guard let out = (try? Shell.run(["pgrep", "-f", pattern]))?.outputIfSucceeded else { return 0 }
        return out.split(separator: "\n").count
    }

    private func recorderRunning(udid: String) -> Bool {
        Self.processCount(matching: "simctl io \(udid) recordVideo") > 0
    }

    private func watcherPIDs(file: URL) -> [pid_t] {
        guard let out = (try? Shell.run(["pgrep", "-f", "recorder-watch .*--file \(file.path)"]))?.outputIfSucceeded else { return [] }
        return out.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        return condition()
    }

    /// `seconds` 以内に `condition` が成り立つことを検証する(XCTAssert の自動クロージャは await を含めない)
    private func expectEventually(_ seconds: TimeInterval, _ message: String = "", file: StaticString = #filePath,
                                  line: UInt = #line, _ condition: () -> Bool) async throws {
        let satisfied = try await waitUntil(seconds, condition)
        XCTAssertTrue(satisfied, message, file: file, line: line)
    }

    private func readPID(_ url: URL) throws -> pid_t {
        try XCTUnwrap(pid_t(String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// 止めた時計。`release()` までは固定、以後は実時間で流れる
    private final class FrozenClock: @unchecked Sendable {
        private let lock = NSLock()
        private let base: TimeInterval = 1_000
        private var releasedAt: Date?
        func read() -> TimeInterval {
            lock.lock(); defer { lock.unlock() }
            guard let releasedAt else { return base }
            return base + Date().timeIntervalSince(releasedAt)
        }
        func release() { lock.lock(); releasedAt = Date(); lock.unlock() }
        var now: @Sendable () -> TimeInterval { { [self] in read() } }
    }

    /// 偽の xcrun。出力名が `handOffPattern` に当たる client は、SIGINT を無視 → 最終名と `<最終名>.sb-test` を作る → "ready-<名前>" →
    /// "go" が現れるまで待つ → SIGINT で終わる、の順。それ以外は正常(撮り始めを言い、SIGINT で中身を書いて終わる)。
    /// どの client も自分の pid を `client-<名前>.pid` に書く(見張りが起きなくても後始末できる)
    private func fakeXcrun(in dir: URL, handOffPattern: String) throws -> String {
        let xcrun = dir.appendingPathComponent("xcrun")
        try writeScript("""
        #!/bin/bash
        D='\(dir.path)'
        out="${!#}"; name=$(basename "$out")
        echo $$ > "$D/client-$name.pid"
        case "$name" in
          \(handOffPattern))
            trap '' INT
            : > "$out"; : > "$out.sb-test"
            touch "$D/ready-$name"
            while [ ! -f "$D/go" ]; do sleep 0.05; done
            trap 'exit 0' INT
            echo "\(HostRecordingProbe.startedMarker)" >&2
            while true; do sleep 0.05; done ;;
          *)
            trap 'printf data > "$out"; exit 0' INT
            echo "\(HostRecordingProbe.startedMarker)" >&2
            while true; do sleep 0.05; done ;;
        esac
        """, to: xcrun)
        return xcrun.path
    }

    /// SIGINT を無視する偽 client(xcrun の形をとらない直接の相手)。"ignoring" の後に "go" を待ち、現れたら SIGINT で終わる
    private func ignoringClient(in dir: URL, name: String, extra: String = "") throws -> URL {
        let script = dir.appendingPathComponent(name)
        try writeScript("""
        #!/bin/bash
        D='\(dir.path)'
        trap '' INT
        \(extra)
        touch "$D/ignoring-\(name)"
        while [ ! -f "$D/go" ]; do sleep 0.05; done
        trap 'exit 0' INT
        while true; do echo "\(HostRecordingProbe.startedMarker)" >&2; sleep 0.05; done
        """, to: script)
        return script
    }

    private func launch(_ script: URL, udid: String, stderr: Pipe) throws -> Process {
        let process = Process()
        process.executableURL = script
        process.arguments = ["simctl", "io", udid, "recordVideo"]
        process.standardError = stderr
        try process.run()
        return process
    }

    // MARK: - 開始(既存の性質)

    /// 撮り始めが 1.5 秒遅れても、試し撮りは撮り始めを待ってから撮るので空にならず、録画が始まるはず
    func testSmokeRecordingWaitsForTheRecorderToStart() async throws {
        let dir = try makeDir()
        let xcrun = dir.appendingPathComponent("xcrun")
        try writeScript("""
        #!/bin/bash
        out="${!#}"
        trap '' INT
        for i in $(seq 1 30); do sleep 0.05; done
        trap 'now=$(python3 -c "import time;print(time.time_ns())"); if [ $(( (now - began) / 1000000 )) -ge 500 ]; then printf data > "$out"; else : > "$out"; fi; exit 0' INT
        began=$(python3 -c 'import time;print(time.time_ns())')
        echo "Recording started" >&2
        while true; do sleep 0.05; done
        """, to: xcrun)
        let udid = "FAKE-\(UUID().uuidString)"
        let recorder = IOSSimulatorVideoRecorder(udid: udid, workDir: dir, fileStem: "src", xcrunPath: xcrun.path)
        let started = await recorder.start()
        _ = await recorder.stop()
        XCTAssertTrue(started, "撮り始めの遅い録画でも、撮り始めてから 1 秒撮った試し撮りは空にならないはず")
        XCTAssertFalse(recorderRunning(udid: udid), "止めた録画が残っていないはず")
    }

    /// busy を言って自分から終わった client は、stderr の読み手が遅れても busy と名乗るはず(cannotLaunchRecorder にしない)
    func testBusyReportedAfterTheClientExitedIsStillBusy() async throws {
        let dir = try makeDir()
        let xcrun = dir.appendingPathComponent("xcrun")
        // client は即 exit 1。busy の行は stderr を継いだ孫が 0.3 秒後に書く = 読み手が遅れた形
        try writeScript("""
        #!/bin/bash
        ( sleep 0.3; echo "\(HostRecordingProbe.busyMarkers[1])" >&2 ) &
        exit 1
        """, to: xcrun)
        let recorder = IOSSimulatorVideoRecorder(udid: "FAKE-\(UUID().uuidString)", workDir: dir, fileStem: "src",
                                                 xcrunPath: xcrun.path)
        let started = await recorder.start()
        let failure = await recorder.startFailure()
        XCTAssertFalse(started)
        XCTAssertEqual(failure, .hostRecordingBusy, "読み手が読み切ってから busy を見るはず")
    }

    /// 開始前の掃除は、撮り始める前で SIGINT を無視している残りの録画も、止まるまで送り直して待つはず
    func testStaleRecorderCleanupWaitsUntilItStops() async throws {
        let dir = try makeDir()
        let stale = dir.appendingPathComponent("stale-recorder")
        let ignoring = dir.appendingPathComponent("ignoring")
        try writeScript("""
        #!/bin/bash
        trap '' INT
        touch '\(ignoring.path)'
        for i in $(seq 1 12); do sleep 0.05; done
        trap 'exit 0' INT
        while true; do sleep 0.05; done
        """, to: stale)
        let udid = "FAKE-\(UUID().uuidString)"
        let process = Process()
        process.executableURL = stale
        process.arguments = ["simctl", "io", udid, "recordVideo"]
        try process.run()
        _ = try await waitUntil(5) { self.exists(ignoring) }
        let recorder = IOSSimulatorVideoRecorder(udid: udid, workDir: dir, fileStem: "src")
        await recorder.killStaleRecording()
        XCTAssertFalse(recorderRunning(udid: udid), "掃除は残りの録画が止まるまで待ってから戻るはず")
    }

    // MARK: - 期限切れの client を見張りへ渡す(製品バイナリ)

    /// 本番の part1 が両方の期限を過ぎても撮り始めない → 見張りへ渡し(呼び手はファイルを消さない)、part2 で録画が始まる。
    /// "go" の後に見張りが client を止め、最終名と一時ファイルを消して終わる
    func testPartClientThatOutlivesBothLimitsIsHandedOffAndCleanedUp() async throws {
        let dir = try makeDir()
        let xcrun = try fakeXcrun(in: dir, handOffPattern: "src.mov")
        let clock = FrozenClock()
        let udid = "FAKE-\(UUID().uuidString)"
        let recorder = IOSSimulatorVideoRecorder(udid: udid, workDir: dir, fileStem: "src", xcrunPath: xcrun,
                                                 startConfirmLimit: 0.3, stopGraceLimit: 0.3, clock: clock.now,
                                                 watcherExecutable: try fleetestBinary())
        let starting = Task { await recorder.start() }
        try await expectEventually(10, "part1 の偽 client が準備を終えるはず") { self.exists(dir.appendingPathComponent("ready-src.mov")) }
        clock.release()
        let started = await raceWithDeadline(seconds: 20, onTimeout: Bool?.none) { await starting.value }
        XCTAssertEqual(started, true, "part1 は期限切れで見張りへ渡り、part2 が撮り始めるはず")
        let part1 = dir.appendingPathComponent("src.mov")
        let temp = dir.appendingPathComponent("src.mov.sb-test")
        let client = try readPID(dir.appendingPathComponent("client-src.mov.pid"))
        XCTAssertTrue(ProcessLiveness.isAlive(client), "復帰時に part1 の client はまだ生きているはず(go まで止まらない)")
        XCTAssertTrue(exists(part1), "見張りへ渡したファイルを呼び手が先に消してはいけない")
        XCTAssertTrue(exists(temp), "一時ファイルも同じ")
        let watcher = try XCTUnwrap(watcherPIDs(file: part1).first, "part1 の見張りが起きているはず")
        _ = await recorder.stop()
        try Data().write(to: dir.appendingPathComponent("go"))
        try await expectEventually(10, "見張りが client を止めるはず") { !ProcessLiveness.isAlive(client) }
        try await expectEventually(5, "client が終わったら最終名と一時ファイルを消すはず") { !self.exists(part1) && !self.exists(temp) }
        try await expectEventually(5, "見張りは client と一緒に終わるはず") { !ProcessLiveness.isAlive(watcher) }
    }

    /// 試し撮りの client が両方の期限を過ぎても撮り始めない → 見張りへ渡し、didNotStop(再試行しない)。呼び手はファイルを消さない
    func testSmokeClientThatOutlivesBothLimitsIsHandedOff() async throws {
        let dir = try makeDir()
        let xcrun = try fakeXcrun(in: dir, handOffPattern: "*~smoke.mov")
        let clock = FrozenClock()
        let udid = "FAKE-\(UUID().uuidString)"
        let recorder = IOSSimulatorVideoRecorder(udid: udid, workDir: dir, fileStem: "src", xcrunPath: xcrun,
                                                 startConfirmLimit: 0.3, stopGraceLimit: 0.3, clock: clock.now,
                                                 watcherExecutable: try fleetestBinary())
        let starting = Task { await recorder.start() }
        try await expectEventually(10) { self.exists(dir.appendingPathComponent("ready-src~smoke.mov")) }
        clock.release()
        let started = await raceWithDeadline(seconds: 20, onTimeout: Bool?.none) { await starting.value }
        XCTAssertEqual(started, false)
        let failure = await recorder.startFailure()
        XCTAssertEqual(failure, .testRecordingDidNotStop)
        let smoke = dir.appendingPathComponent("src~smoke.mov")
        let temp = dir.appendingPathComponent("src~smoke.mov.sb-test")
        let client = try readPID(dir.appendingPathComponent("client-src~smoke.mov.pid"))
        XCTAssertTrue(ProcessLiveness.isAlive(client))
        XCTAssertTrue(exists(smoke), "見張りへ渡した試し撮りを呼び手(defer)が先に消してはいけない")
        XCTAssertTrue(exists(temp))
        let watcher = try XCTUnwrap(watcherPIDs(file: smoke).first)
        try Data().write(to: dir.appendingPathComponent("go"))
        try await expectEventually(10) { !ProcessLiveness.isAlive(client) }
        try await expectEventually(5) { !self.exists(smoke) && !self.exists(temp) }
        try await expectEventually(5) { !ProcessLiveness.isAlive(watcher) }
    }

    /// 見張りを起こせないとき(実行ファイルが無い)は、呼び手が今あるファイルを消し、didNotStop(再試行しない)で戻る。client は止めない
    func testSmokeClientIsCleanedUpByTheCallerWhenNoWatcherCanStart() async throws {
        let dir = try makeDir()
        let xcrun = try fakeXcrun(in: dir, handOffPattern: "*~smoke.mov")
        let clock = FrozenClock()
        let udid = "FAKE-\(UUID().uuidString)"
        let recorder = IOSSimulatorVideoRecorder(udid: udid, workDir: dir, fileStem: "src", xcrunPath: xcrun,
                                                 startConfirmLimit: 0.3, stopGraceLimit: 0.3, clock: clock.now, watcherExecutable: nil)
        let starting = Task { await recorder.start() }
        try await expectEventually(10) { self.exists(dir.appendingPathComponent("ready-src~smoke.mov")) }
        clock.release()
        let started = await raceWithDeadline(seconds: 20, onTimeout: Bool?.none) { await starting.value }
        XCTAssertEqual(started, false)
        let failure = await recorder.startFailure()
        XCTAssertEqual(failure, .testRecordingDidNotStop)
        let client = try readPID(dir.appendingPathComponent("client-src~smoke.mov.pid"))
        XCTAssertTrue(ProcessLiveness.isAlive(client), "見張りが無くても呼び手は client を止めない")
        XCTAssertFalse(exists(dir.appendingPathComponent("src~smoke.mov")), "見張りが無いので呼び手が今あるファイルを消す")
        XCTAssertFalse(exists(dir.appendingPathComponent("src~smoke.mov.sb-test")))
        XCTAssertEqual(watcherPIDs(file: dir.appendingPathComponent("src~smoke.mov")), [])
        // 見張りが無いので誰も止めない: "go" の後にテストが SIGINT を送ると終わる(= それまで生きていた証拠)
        try Data().write(to: dir.appendingPathComponent("go"))
        try await Task.sleep(nanoseconds: 200_000_000)
        kill(client, SIGINT)
        try await expectEventually(10) { !ProcessLiveness.isAlive(client) }
    }

    /// 撮り始めてすぐ終わった part(読み手が印を置く前に終了が見える)は、開始済みとして exit 監視へ渡す = 開始未確認として捨てない
    func testPartThatExitsRightAfterStartingCountsAsStarted() async throws {
        let dir = try makeDir()
        let xcrun = dir.appendingPathComponent("xcrun")
        // 試し撮りは正常。本番の part は中身を書いてすぐ終わり、撮り始めの行は stderr を継いだ孫が 0.3 秒後に書く
        // (= 終了の検知より stderr の到着が遅れる形。読み切る前に判定すると「開始未確認」になる)
        try writeScript("""
        #!/bin/bash
        out="${!#}"; name=$(basename "$out")
        case "$name" in
          *~smoke.mov) trap 'printf data > "$out"; exit 0' INT; echo "\(HostRecordingProbe.startedMarker)" >&2; while true; do sleep 0.05; done ;;
          *) ( sleep 0.3; echo "\(HostRecordingProbe.startedMarker)" >&2 ) & printf data > "$out"; exit 0 ;;
        esac
        """, to: xcrun)
        let recorder = IOSSimulatorVideoRecorder(udid: "FAKE-\(UUID().uuidString)", workDir: dir, fileStem: "src", xcrunPath: xcrun.path,
                                                 startConfirmLimit: 0.3, stopGraceLimit: 0.3)
        let started = await raceWithDeadline(seconds: 30, onTimeout: Bool?.none) { await recorder.start() }
        XCTAssertEqual(started, true, "撮り始めてから終わった part は開始済み(撮り直しの対象)で、開始未確認(startNotConfirmed)ではない")
        let failure = await recorder.startFailure()
        XCTAssertNil(failure)
        _ = await raceWithDeadline(seconds: 30, onTimeout: RecordingSource?.none) { await recorder.stop() }
    }

    /// run 前の確認(HostRecordingProbe)も、判定と止める期限を過ぎた client を見張りへ渡し、ファイルを消さずに戻る
    func testProbeHandsOffAClientThatOutlivesItsLimits() async throws {
        let dir = try makeDir()
        let xcrun = try fakeXcrun(in: dir, handOffPattern: "host-recording-probe-*")
        let clock = FrozenClock()
        let udid = "FAKE-\(UUID().uuidString)"
        let fleetest = try fleetestBinary()
        let probing = Task {
            await HostRecordingProbe.probe(udid: udid, workDir: dir, xcrunPath: xcrun, decisionTimeout: 0.3, stopGrace: 0.3,
                                           clock: clock.now, watcherExecutable: fleetest)
        }
        let readyName = { () -> String? in
            (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.first { $0.hasPrefix("ready-host-recording-probe-") }
        }
        try await expectEventually(10) { readyName() != nil }
        clock.release()
        let outcome = await raceWithDeadline(seconds: 20, onTimeout: HostRecordingProbe.Outcome?.none) { await probing.value }
        XCTAssertEqual(outcome, .unknown)
        let name = String(try XCTUnwrap(readyName()).dropFirst("ready-".count))
        let file = dir.appendingPathComponent(name)
        let temp = dir.appendingPathComponent(name + ".sb-test")
        let client = try readPID(dir.appendingPathComponent("client-\(name).pid"))
        XCTAssertTrue(ProcessLiveness.isAlive(client))
        XCTAssertTrue(exists(file), "見張りへ渡した検査のファイルを probe の後始末が先に消してはいけない")
        XCTAssertTrue(exists(temp))
        let watcher = try XCTUnwrap(watcherPIDs(file: file).first)
        try Data().write(to: dir.appendingPathComponent("go"))
        try await expectEventually(10) { !ProcessLiveness.isAlive(client) }
        try await expectEventually(5) { !self.exists(file) && !self.exists(temp) }
        try await expectEventually(5) { !ProcessLiveness.isAlive(watcher) }
    }

    /// busy を言って自分から終わった client は、読み手が遅れても busy と判定する(.unknown にすると供給が再起動しない)
    func testProbeSeesBusyReportedAfterTheClientExited() async throws {
        let dir = try makeDir()
        let xcrun = dir.appendingPathComponent("xcrun")
        try writeScript("""
        #!/bin/bash
        ( sleep 0.3; echo "\(HostRecordingProbe.busyMarkers[1])" >&2 ) &
        exit 1
        """, to: xcrun)
        let outcome = await HostRecordingProbe.probe(udid: "FAKE-\(UUID().uuidString)", workDir: dir, xcrunPath: xcrun.path,
                                                     decisionTimeout: 10, stopGrace: 1)
        XCTAssertEqual(outcome, .busy)
    }

    // MARK: - 見張りの性質(handOff / api recorder-watch を直接)

    /// fleetest(元の読み手)が先に終わっても、見張りが stderr を読み継ぐので、遅れて撮り始めた client は SIGPIPE で死なず SIGINT で止まるはず
    func testHandedOffClientIsNotKilledBySIGPIPEAfterTheParentReaderIsGone() async throws {
        let dir = try makeDir()
        let script = try ignoringClient(in: dir, name: "recorder")
        let pipe = Pipe()
        let process = try launch(script, udid: "FAKE-\(UUID().uuidString)", stderr: pipe)
        let exited = ProcessExitWait.prepare(process)
        try await expectEventually(5) { self.exists(dir.appendingPathComponent("ignoring-recorder")) }
        let file = dir.appendingPathComponent("x.mov")
        let outcome = IOSSimulatorVideoRecorder.handOff(process, target: RecorderWatch.Target.of(process.processIdentifier),
                                                        stderr: pipe.fileHandleForReading, leaving: file, watcher: try fleetestBinary())
        guard case .watching = outcome else { return XCTFail("\(outcome)") }
        try pipe.fileHandleForReading.close()  // 元の読み手が消えた形
        try Data().write(to: dir.appendingPathComponent("go"))
        _ = await raceWithDeadline(seconds: 10, onTimeout: ()) { for await _ in exited {} }
        if process.isRunning {
            XCTFail("client が 10 秒以内に終わらなかった")  // 生きている Process の terminationReason は例外
        } else {
            XCTAssertEqual(process.terminationReason, .exit,
                           "SIGPIPE で死なず、見張りの SIGINT で自分から終わるはず(status \(process.terminationStatus))")
        }
    }

    /// 見張りは client の stderr を継いだ孫が書き端を握っていても(EOF が来なくても)、client の終了で終わる
    func testWatcherExitsWhenAGrandchildKeepsStderrOpen() async throws {
        let dir = try makeDir()
        let script = try ignoringClient(in: dir, name: "recorder", extra: "( sleep 15 ) &")
        let pipe = Pipe()
        let process = try launch(script, udid: "FAKE-\(UUID().uuidString)", stderr: pipe)
        try await expectEventually(5) { self.exists(dir.appendingPathComponent("ignoring-recorder")) }
        let file = dir.appendingPathComponent("x.mov")
        try Data().write(to: file)
        let outcome = IOSSimulatorVideoRecorder.handOff(process, target: RecorderWatch.Target.of(process.processIdentifier),
                                                        stderr: pipe.fileHandleForReading, leaving: file, watcher: try fleetestBinary())
        guard case .watching(let watcher, _) = outcome else { return XCTFail("\(outcome)") }
        try pipe.fileHandleForReading.close()
        try Data().write(to: dir.appendingPathComponent("go"))
        try await expectEventually(10) { !process.isRunning }
        try await expectEventually(3, "読み捨てを待たずに終わるはず(孫は 15 秒握ったまま)") { !ProcessLiveness.isAlive(watcher) }
        XCTAssertFalse(exists(file))
    }

    /// 見張りは起動元(fleetest)が先に終わっても生き、client の stderr を読み進め、撮り始めた client を止めてファイルを消して終わる
    func testWatcherSurvivesTheSpawnerExit() async throws {
        let dir = try makeDir()
        let fleetest = try fleetestBinary()
        // "go" の後にパイプの容量(64KB)を超える 256KB を書き切ってから "flushed" を置き、そこで初めて SIGINT を受け付ける
        // = 読み手が読み進めないと書き込みで止まり、印も出ず、SIGINT も効かない
        let client = dir.appendingPathComponent("recorder")
        try writeScript("""
        #!/bin/bash
        D='\(dir.path)'
        trap '' INT
        touch "$D/ignoring-recorder"
        while [ ! -f "$D/go" ]; do sleep 0.05; done
        head -c 262144 /dev/zero | tr '\\0' x >&2
        touch "$D/flushed"
        trap 'exit 0' INT
        while true; do sleep 0.05; done
        """, to: client)
        let pipe = Pipe()
        let process = try launch(client, udid: "FAKE-\(UUID().uuidString)", stderr: pipe)
        let exited = ProcessExitWait.prepare(process)
        try await expectEventually(5) { self.exists(dir.appendingPathComponent("ignoring-recorder")) }
        let target = try XCTUnwrap(RecorderWatch.Target.of(process.processIdentifier))
        let file = dir.appendingPathComponent("x.mov")
        try Data().write(to: file)
        // 起動元: 見張りを `&` で起こし、その pid を言って先に終わる。stdin(client の stderr の読み口)は fd 3 で継がせる
        // (`&` の子は非対話シェルでは stdin が /dev/null になる = CrossLayerTerminationTests と同じ形)
        let spawner = Process()
        spawner.executableURL = URL(fileURLWithPath: "/bin/sh")
        spawner.arguments = ["-c", """
            exec 3<&0
            "$0" api recorder-watch --pid "$1" --started-us "$2" --file "$3" <&3 >/dev/null 2>&1 &
            echo $!
            exit 0
            """, fleetest.path, String(target.pid), String(target.startedMicroseconds), file.path]
        spawner.standardInput = pipe.fileHandleForReading
        let pidPipe = Pipe()
        spawner.standardOutput = pidPipe
        try spawner.run()
        spawner.waitUntilExit()
        let watcher = try XCTUnwrap(pid_t(String(data: pidPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        XCTAssertTrue(ProcessLiveness.isAlive(watcher), "起動元が終わった後も見張りは生きているはず")
        XCTAssertTrue(process.isRunning, "client はまだ go を待っているはず")
        XCTAssertFalse(exists(dir.appendingPathComponent("go")))
        try pipe.fileHandleForReading.close()  // テスト側の読み口も閉じる = 読み手は見張りだけ
        try Data().write(to: dir.appendingPathComponent("go"))
        try await expectEventually(10, "見張りが読み進めないと 256KB を書き切れないはず") { self.exists(dir.appendingPathComponent("flushed")) }
        _ = await raceWithDeadline(seconds: 10, onTimeout: ()) { for await _ in exited {} }
        if process.isRunning {
            XCTFail("client が 10 秒以内に終わらなかった")  // 生きている Process の terminationReason は例外
        } else {
            XCTAssertEqual(process.terminationReason, .exit, "SIGPIPE でなく SIGINT で終わるはず")
        }
        try await expectEventually(5) { !self.exists(file) }
        try await expectEventually(5) { !ProcessLiveness.isAlive(watcher) }
    }

    /// 見張りは渡された起動時刻をそのまま使う(1 µs 違えば別のプロセスとみなして送らず、ファイルだけ消して終わる)
    func testCommandUsesTheGivenStartTime() async throws {
        let dir = try makeDir()
        let script = try ignoringClient(in: dir, name: "recorder")
        let process = try launch(script, udid: "FAKE-\(UUID().uuidString)", stderr: Pipe())
        try await expectEventually(5) { self.exists(dir.appendingPathComponent("ignoring-recorder")) }
        let target = try XCTUnwrap(RecorderWatch.Target.of(process.processIdentifier))
        let file = dir.appendingPathComponent("x.mov")
        try Data().write(to: file)
        let watcher = Process()
        watcher.executableURL = try fleetestBinary()
        watcher.arguments = ["api", "recorder-watch", "--pid", String(target.pid),
                             "--started-us", String(target.startedMicroseconds + 1), "--file", file.path]
        watcher.standardInput = FileHandle.nullDevice
        watcher.standardOutput = FileHandle.nullDevice
        watcher.standardError = FileHandle.nullDevice
        let exited = ProcessExitWait.prepare(watcher)
        try watcher.run()
        _ = await raceWithDeadline(seconds: 5, onTimeout: ()) { for await _ in exited {} }
        XCTAssertFalse(watcher.isRunning, "身元が合わない相手にはすぐ終わるはず")
        if !watcher.isRunning { XCTAssertEqual(watcher.terminationStatus, 0) }  // 生きている Process の terminationStatus は例外
        XCTAssertTrue(process.isRunning, "SIGINT を送っていないはず(偽 client は無視するので、送っても分からない = 見張りの終了で見る)")
        XCTAssertFalse(exists(file))
    }

    /// 見張りの環境は Process に設定され、FT_PARENT_PID を含まない(親より長生きするため)
    func testWatcherEnvironmentIsAppliedWithoutTheParentPID() async throws {
        let dir = try makeDir()
        let script = try ignoringClient(in: dir, name: "recorder")
        let pipe = Pipe()
        let process = try launch(script, udid: "FAKE-\(UUID().uuidString)", stderr: pipe)
        try await expectEventually(5) { self.exists(dir.appendingPathComponent("ignoring-recorder")) }
        let file = dir.appendingPathComponent("x.mov")
        let outcome = IOSSimulatorVideoRecorder.handOff(
            process, target: RecorderWatch.Target.of(process.processIdentifier), stderr: pipe.fileHandleForReading,
            leaving: file, watcher: try fleetestBinary(),
            environment: ["FT_PARENT_PID": "1", "FT_RECORDER_WATCH_TEST": "x", "PATH": "/usr/bin:/bin"])
        guard case .watching(let watcher, let client) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(client, process.processIdentifier)
        let env = try XCTUnwrap((try? Shell.run(["ps", "-Eo", "command=", "-p", String(watcher)]))?.outputIfSucceeded)
        XCTAssertTrue(env.contains("FT_RECORDER_WATCH_TEST=x"), "渡した環境が見張りに設定されているはず: \(env)")
        XCTAssertFalse(env.contains("FT_PARENT_PID="), "FT_PARENT_PID は外すはず: \(env)")
    }

    func testWatcherLaunchStripsTheParentPIDAndNamesTheCommand() {
        let target = RecorderWatch.Target(pid: 123, startedMicroseconds: 456)
        let launch = IOSSimulatorVideoRecorder.watcherLaunch(
            executable: URL(fileURLWithPath: "/x/fleetest"), target: target, file: URL(fileURLWithPath: "/tmp/a.mov"),
            environment: ["FT_PARENT_PID": "9", "HOME": "/h"])
        XCTAssertEqual(launch.arguments, ["api", "recorder-watch", "--pid", "123", "--started-us", "456", "--file", "/tmp/a.mov"])
        XCTAssertEqual(launch.environment, ["HOME": "/h"])
    }

    /// 見張りを起こせない 4 通りと、終わった client。handOff 自身はファイルを消さない
    func testHandOffOutcomesWhenTheWatcherCannotStart() async throws {
        let dir = try makeDir()
        let file = dir.appendingPathComponent("x.mov")
        let done = Process()
        done.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try done.run()
        done.waitUntilExit()
        XCTAssertEqual(IOSSimulatorVideoRecorder.handOff(done, target: nil, stderr: Pipe().fileHandleForReading, leaving: file,
                                                         watcher: try fleetestBinary()),
                       .clientGone(client: done.processIdentifier))

        let live = Process()
        live.executableURL = URL(fileURLWithPath: "/bin/sleep")
        live.arguments = ["30"]
        try live.run()
        addTeardownBlock { if live.isRunning { live.terminate() } }
        let target = RecorderWatch.Target.of(live.processIdentifier)
        let fleetest = try fleetestBinary()
        guard case .unwatched(_, let noIdentity) = IOSSimulatorVideoRecorder.handOff(
            live, target: nil, stderr: Pipe().fileHandleForReading, leaving: file, watcher: fleetest) else { return XCTFail() }
        XCTAssertTrue(noIdentity.contains("identity"), noIdentity)
        guard case .unwatched(_, let noWatcher) = IOSSimulatorVideoRecorder.handOff(
            live, target: target, stderr: Pipe().fileHandleForReading, leaving: file, watcher: nil) else { return XCTFail() }
        XCTAssertTrue(noWatcher.contains("not fleetest"), noWatcher)
        guard case .unwatched(_, let wrongName) = IOSSimulatorVideoRecorder.handOff(
            live, target: target, stderr: Pipe().fileHandleForReading, leaving: file, watcher: URL(fileURLWithPath: "/usr/bin/true")) else { return XCTFail() }
        XCTAssertTrue(wrongName.contains("not fleetest"), wrongName)
        let broken = dir.appendingPathComponent("fleetest")
        try Data().write(to: broken)  // 実行権限の無い "fleetest"
        guard case .unwatched(_, let launchFailed) = IOSSimulatorVideoRecorder.handOff(
            live, target: target, stderr: Pipe().fileHandleForReading, leaving: file, watcher: broken) else { return XCTFail() }
        XCTAssertTrue(launchFailed.contains("could not be started"), launchFailed)
        XCTAssertTrue(live.isRunning, "handOff は client を止めない")
    }

    func testHandOffNoticesStateFactsOnly() {
        let file = URL(fileURLWithPath: "/r/src.mov")
        let watching = IOSSimulatorVideoRecorder.handOffNotice(.watching(watcherPID: 77, client: 55), file: file, udid: "U1")
        XCTAssertTrue(watching.contains("a watcher (pid 77)") && watching.contains("client 55") && watching.contains("/r/src.mov"), watching)
        let gone = IOSSimulatorVideoRecorder.handOffNotice(.clientGone(client: 55), file: file, udid: "U1")
        XCTAssertTrue(gone.contains("client 55") && gone.contains("was deleted"), gone)
        let unwatched = IOSSimulatorVideoRecorder.handOffNotice(.unwatched(client: 55, reason: "why"), file: file, udid: "U1")
        XCTAssertTrue(unwatched.contains("client 55") && unwatched.contains("(why)") && unwatched.contains("/r/src.mov")
                      && unwatched.contains("--udid U1"), unwatched)
        XCTAssertFalse(unwatched.contains("restart-devices --name"), "restart-devices --name は論理名しか受けない")
    }

    // MARK: - 命名

    /// 出力名は recorder をまたいで一意(stem と接尾辞の重なりで同じ名前にならない)。probe は呼び出しごとに違う
    func testOutputNamesDoNotCollideAcrossStems() {
        let dir = URL(fileURLWithPath: "/r")
        var names: Set<String> = []
        for stem in ["phone", "phone-smoke", "phone-part2", "phone~2"] {
            for kind in [IOSSimulatorVideoRecorder.OutputKind.smoke, .part(1), .part(2)] {
                names.insert(IOSSimulatorVideoRecorder.outputURL(workDir: dir, fileStem: stem, kind: kind).lastPathComponent)
            }
        }
        XCTAssertEqual(names.count, 12, "\(names.sorted())")
        XCTAssertEqual(RecordingIndexIO.sanitizedFileName(for: "a~b c"), "a-b-c", "stem は `~` を含まない(接尾辞の区切りに使う根拠)")
        XCTAssertNotEqual(HostRecordingProbe.probeFileURL(udid: "U", workDir: dir, nonce: "1"),
                          HostRecordingProbe.probeFileURL(udid: "U", workDir: dir, nonce: "2"))
    }
}
