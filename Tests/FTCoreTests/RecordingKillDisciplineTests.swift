// 録画(simctl io recordVideo)の停止規律のソース走査。
//
// **実測 2026-09-09**: SIGINT 以外で recordVideo の client を殺すと、**端末側のセッションが
// 握られたまま残る**(実験: 該当デバイスは "Host recording is already in progress" を返し続け、
// シャットダウンで初めて解けた)。ツールは猶予切れで SIGKILL していたため、**自分で作った
// セッションを自分で「残っている」と警告する**形になっていた。
//
// 停止は SIGINT だけ。止まらない個体は放置する(次の run の smokeCheck が busy として報告する)。
// 型では守れない規律なのでソースで見る(ShellSourceScanTests / ProcessLivenessSourceScanTests と同型)。

import XCTest
@testable import FTCore

final class RecordingKillDisciplineTests: XCTestCase {

    private func recorderSource(file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()  // FTCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
        let path = root.appendingPathComponent("Sources/FTCore/IOSSimulatorVideoRecorder.swift")
        return try String(contentsOf: path, encoding: .utf8)
    }

    /// コメントは対象外(規律の理由を書いてあるため)。**コードの行だけ**を見る。
    private func codeLines(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 録画側と見張り側の両方を見る。SIGKILL / SIGTERM / `.terminate()` のどれも、端末側の録画セッションを残す
    func testRecorderNeverSendsSIGKILL() throws {
        for relative in ["Sources/FTCore/IOSSimulatorVideoRecorder.swift", "Sources/FTCore/RecorderWatch.swift"] {
            let source = codeLines(try source(relative))
            for forbidden in ["SIGKILL", "SIGTERM", ".terminate()"] {
                XCTAssertFalse(source.contains(forbidden),
                               "\(relative): recordVideo の client を \(forbidden) で止めると端末側の録画セッションが残り、"
                               + "その台は再起動まで録画できなくなる(停止は SIGINT だけ)")
            }
        }
    }

    /// 見張りは親(fleetest)より長生きするのが目的 = `ParentDeathWatch.childEnvironment()` を渡さない(process-lifecycle.md の例外)。
    /// 実際の環境は IOSSimulatorVideoRecorderStartTests が `ps -E` で見る。ここは「規律どおりに直した」事故を止める
    func testHandOffDoesNotArmParentDeathWatch() throws {
        let source = codeLines(try recorderSource())
        XCTAssertFalse(source.contains("childEnvironment("), "見張りに FT_PARENT_PID を渡してはいけない")
    }

    /// 身元(pid + 起動時刻)は **spawn の直後にだけ採る**(その時点の pid は自分の子で使い回されていない)。handOff で採り直すと、
    /// 終わって回収された pid が別のプロセスに使い回された形を見張りが追う。挙動では検出できないので置き場を走査で固定する
    func testClientIdentityIsCapturedRightAfterSpawnOnly() throws {
        for (relative, expected) in [("Sources/FTCore/IOSSimulatorVideoRecorder.swift", 2), ("Sources/FTCore/HostRecordingProbe.swift", 1)] {
            let lines = try source(relative).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let captures = lines.indices.filter { lines[$0].contains("RecorderWatch.Target.of(") }
            XCTAssertEqual(captures.count, expected, "\(relative): 身元を採る箇所の数")
            for index in captures {
                let window = lines[max(0, index - 8)..<index].joined(separator: "\n")
                XCTAssertTrue(window.contains("try process.run()"), "\(relative):\(index + 1): 身元は process.run() の直後に採る")
            }
        }
        let recorder = try source("Sources/FTCore/IOSSimulatorVideoRecorder.swift")
        let handOff = recorder.components(separatedBy: "static func handOff(")[1].components(separatedBy: "static func handOffNotice(")[0]
        XCTAssertFalse(handOff.contains("Target.of("), "handOff は身元を採り直さない")
    }

    /// 見張りへ渡した結果の発話は `handOffNotice` の 1 か所: start() の didNotStop・spawnNextPart の試行の行・probe の 3 つの呼び手が通す
    /// (ConsoleOut の実出力は捕まえられないので、呼び手の数を走査で固定する)
    func testEveryHandOffCallerSpeaksThroughTheSharedNotice() throws {
        let recorder = codeLines(try recorderSource())
        XCTAssertEqual(recorder.components(separatedBy: "Self.handOffNotice(").count - 1, 2, "start() と spawnPartOnce")
        let probe = codeLines(try source("Sources/FTCore/HostRecordingProbe.swift"))
        XCTAssertEqual(probe.components(separatedBy: "IOSSimulatorVideoRecorder.handOffNotice(").count - 1, 1)
    }

    private func source(_ relative: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// stale な client の掃除も SIGINT(pkill の既定は SIGTERM で、同じ穴に落ちる)
    func testStaleRecorderCleanupUsesSIGINT() throws {
        let source = codeLines(try recorderSource())
        XCTAssertTrue(source.contains("\"pkill\", \"-INT\""),
                      "killStaleRecording は pkill -INT で止めること(既定の SIGTERM は不可)")
    }

    /// 走査が本物のソースに当たっていることの確認(パスを間違えたまま緑になる型を塞ぐ)
    func testScanReachesTheRealSource() throws {
        let source = codeLines(try recorderSource())
        XCTAssertTrue(source.contains("recordVideo"), "走査対象のソースを読めていない")
        XCTAssertTrue(source.contains("process.interrupt()"), "SIGINT で止める実装が見当たらない")
    }
    // MARK: - 再試行の仕分け

    /// **一過性の空振りだけ再試行する**(実測 2026-09-10: M1Ultra の6台が run 開始直後に同時に
    /// 空になり、数分後には同じデバイスで 1 秒 66KB が撮れた)。端末側にセッションが残っている形は
    /// 待っても解けない(シャットダウンが要る)ので、繰り返して時間を捨てない。
    func testOnlyTransientSmokeFailuresAreRetried() {
        XCTAssertTrue(IOSSimulatorVideoRecorder.isTransient(.emptyFile))
        XCTAssertFalse(IOSSimulatorVideoRecorder.isTransient(.didNotStop(.clientGone(client: 1))),
                       "止まらなかった試し撮りはセッションを握ったまま撮り続ける = 撮り直しは必ず「録画中」で断られる")
        XCTAssertFalse(IOSSimulatorVideoRecorder.isTransient(.hostRecordingBusy),
                       "端末側のセッションは再試行では解けない")
        XCTAssertFalse(IOSSimulatorVideoRecorder.isTransient(.cannotStart("boom")))
    }

    // MARK: - 撮り始める前の SIGINT

    func testRecorderStopConstantsArePinned() {
        XCTAssertEqual(IOSSimulatorVideoRecorder.startConfirmSeconds, 10)
        XCTAssertEqual(IOSSimulatorVideoRecorder.interruptRepeatSeconds, 0.2)
    }

    /// simctl recordVideo は撮り始める前の SIGINT を無視する(実測)。止める側は撮り始めるまで送り直すはず
    func testInterruptIsResentUntilTheRecorderHasStarted() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fleetest-fake-recorder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let started = dir.appendingPathComponent("started")
        let ignoring = dir.appendingPathComponent("ignoring")
        let script = dir.appendingPathComponent("recorder")
        // 0.6 秒は SIGINT を無視し、その後に撮り始めて SIGINT で終わる
        try """
        #!/bin/bash
        trap '' INT
        touch '\(ignoring.path)'
        for i in $(seq 1 12); do sleep 0.05; done
        trap 'exit 0' INT
        touch '\(started.path)'
        while true; do sleep 0.05; done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let process = Process()
        process.executableURL = script
        try process.run()
        addTeardownBlock {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? FileManager.default.removeItem(at: dir)
        }
        // 無視の設定より前の SIGINT は既定の動作でスクリプトを終わらせ、送り直しを見られない
        let readyDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: ignoring.path), Date() < readyDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let path = started.path
        let stopped = await IOSSimulatorVideoRecorder.interruptRecorder(
            process, started: { FileManager.default.fileExists(atPath: path) }, grace: 3)
        XCTAssertTrue(stopped, "撮り始める前に無視された SIGINT を送り直し、撮り始めた後に止めるはず")
    }
}
