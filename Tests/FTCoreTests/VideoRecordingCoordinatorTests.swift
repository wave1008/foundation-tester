// VideoRecordingCoordinator の判定ロジック(recordFailuresOnly の区間スキップ)と、
// finalize のエクスポート制御(ハードウェア→ソフトウェアへのフォールバック・断念判定・
// 同時実行制限・attempted/failed 集計)を検証する。
// 実セッション(simctl/adb)や実エンコードは makeSession/extractClip 注入で置き換える。

import XCTest
import CoreGraphics
import ImageIO
@testable import FTCore

final class VideoRecordingCoordinatorTests: XCTestCase {

    func testShouldSkipWhenFailuresOnlyAndPassed() {
        XCTAssertTrue(VideoRecordingCoordinator.shouldSkip(failuresOnly: true, passed: true),
                      "recordFailuresOnly かつ確実に成功したシナリオはスキップするはず")
    }

    func testShouldNotSkipWhenFailuresOnlyAndFailed() {
        XCTAssertFalse(VideoRecordingCoordinator.shouldSkip(failuresOnly: true, passed: false))
    }

    func testShouldNotSkipWhenFailuresOnlyAndUnknown() {
        XCTAssertFalse(VideoRecordingCoordinator.shouldSkip(failuresOnly: true, passed: nil),
                      "判定不能(scenarioFinished 未着等)は安全側に倒して保存対象に残すはず")
    }

    func testShouldNotSkipWhenFailuresOnlyDisabled() {
        XCTAssertFalse(VideoRecordingCoordinator.shouldSkip(failuresOnly: false, passed: true),
                      "recordFailuresOnly が無効なら成功シナリオも保存するはず")
        XCTAssertFalse(VideoRecordingCoordinator.shouldSkip(failuresOnly: false, passed: false))
        XCTAssertFalse(VideoRecordingCoordinator.shouldSkip(failuresOnly: false, passed: nil))
    }
}

// MARK: - finalize のエクスポート制御(期限・断念・同時実行制限)

/// coordinator はワーカーの label/platform しか使わないため、driver は呼ばれない前提のスタブ
private struct UnusedDriver: AppDriver {
    struct Unused: Error {}
    func status() async throws -> StatusResponse { throw Unused() }
    func install(packagePath: String) async throws { throw Unused() }
    func uninstall(bundleID: String) async throws { throw Unused() }
    func launch(bundleID: String) async throws { throw Unused() }
    func snapshot() async throws -> SnapshotResponse { throw Unused() }
    func tap(ref: Int) async throws { throw Unused() }
    func tap(x: Double, y: Double) async throws { throw Unused() }
    func type(ref: Int?, text: String) async throws { throw Unused() }
    func swipe(_ direction: FTSwipeDirection) async throws { throw Unused() }
    func press(ref: Int, duration: Double) async throws { throw Unused() }
    func screenshot() async throws -> Data { throw Unused() }
    func terminate() async throws { throw Unused() }
    func isAppForeground(bundleID: String) async throws -> Bool { throw Unused() }
    func foregroundAppID() async throws -> String? { throw Unused() }
}

private struct FixedSourceSession: DeviceVideoRecorderSession {
    let source: RecordingSource
    func start() async -> Bool { true }
    func stop() async -> RecordingSource? { source }
}

/// extractClip 呼び出しの回数・同時実行数・ソフトウェアエンコーダでの呼び出し数の観測
private actor ExportProbe {
    private(set) var calls = 0
    private(set) var current = 0
    private(set) var maxConcurrent = 0
    func began() {
        calls += 1
        current += 1
        maxConcurrent = max(maxConcurrent, current)
    }
    func ended() { current -= 1 }
}

/// 切り出しの代役を包む: true を返したら出力ファイルを書く(本番の extractClip は成功時に必ず書く。
/// コーディネータは一時フォルダの出力を recordings/ へ移すので、書かない代役は失敗になる)
private func writing(_ extract: @escaping VideoRecordingCoordinator.ClipExtractor) -> VideoRecordingCoordinator.ClipExtractor {
    { files, start, end, bitrate, full, hardware, outputURL in
        let ok = await extract(files, start, end, bitrate, full, hardware, outputURL)
        if ok, !FileManager.default.fileExists(atPath: outputURL.path) {
            FileManager.default.createFile(atPath: outputURL.path, contents: Data([0]))
        }
        return ok
    }
}

final class VideoRecordingCoordinatorExportTests: XCTestCase {
    /// 全テスト共通の録画開始時刻(壁時計はソース segments との相対関係だけが意味を持つ)
    private let recordStart = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeWorker(_ n: Int) -> RunWorker {
        RunWorker(label: "ios:test\(n)", platform: "ios", driver: UnusedDriver(),
                  connection: DriverConnection(platform: "ios"), logicalName: "test\(n)")
    }

    /// 60 秒 1 セグメントのソースを返すセッションを生成する makeSession(sourceStem 由来の
    /// ダミーファイルは実在しなくてよい。finalize は削除を試みるだけで読まない)
    private func fixedSessionFactory(tmp: URL)
        -> @Sendable (RunWorker, URL, String) -> (any DeviceVideoRecorderSession)? {
        let startedAt = ISO8601Millis.string(from: recordStart)
        return { _, recordingsDir, sourceStem in
            FixedSourceSession(source: RecordingSource(
                files: [recordingsDir.appendingPathComponent("\(sourceStem).mov")],
                segments: [RecordingIndexSegment(startedAt: startedAt, durationMs: 60_000)]))
        }
    }

    /// worker に「録画区間と重なる 4 秒のシナリオ 1 本」を登録する
    private func registerInterval(_ coordinator: VideoRecordingCoordinator, worker: RunWorker,
                                  scenarioID: String, offsetSeconds: TimeInterval = 1) async {
        await coordinator.scenarioStarted(
            workerLabel: worker.label, scenarioID: scenarioID,
            at: recordStart.addingTimeInterval(offsetSeconds))
        await coordinator.scenarioFinished(
            workerLabel: worker.label, at: recordStart.addingTimeInterval(offsetSeconds + 4),
            passed: false)
    }

    /// **録画を始められなかった/使えるソースが残らなかったワーカーを数える**(2026-08-26)。
    /// 数えないと index を書かず、その run は録画タブから消えて「録画していない run」と
    /// 区別が付かない(実害: 端末に刺さった録画セッションで 0 バイトの .mov ができ続けた)
    func testFailedSourcesAreCountedAndKeepTheRunVisible() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp, androidADBPath: nil, failuresOnly: false),
            makeSession: { _, _, _ in DeadSession() })

        let worker = makeWorker(1)
        let started = await coordinator.start(worker)
        XCTAssertTrue(started, "動画を起動できなければ静止画方式へ切り替える")
        await registerInterval(coordinator, worker: worker, scenarioID: "T.S0010")
        // 静止画が1枚も撮られないまま止まる = 切り替えた先でも何も残らなかった
        await coordinator.stop(worker)
        await coordinator.finish()

        let indexURL = tmp.appendingPathComponent("recordings/index.json")
        let decoded = try JSONDecoder().decode(RecordingIndex.self, from: Data(contentsOf: indexURL))
        XCTAssertEqual(decoded.sourcesFailed, 1, "録画できなかった台数を残す")
        XCTAssertEqual(decoded.recordings.count, 0)
        XCTAssertEqual(decoded.sourceIssues, [
            RecordingSourceIssue(worker: "ios:test1", phase: .start, reason: .emptyTestRecording,
                                 stillFramesFallback: true),
            RecordingSourceIssue(worker: "ios:test1", phase: .stop),
        ], "起動時に切り替えた事実と、止めたら何も無かった事実の両方を残す")
    }

    /// **物理 iPhone は静止画の録画**(StillFrameRecorder)—— 撮影先を子へ渡せ、置かれた静止画が
    /// 停止時に mp4 になってシナリオのクリップとして index に載る(実エンコード・実切り出し)
    func testPhysicalIPhoneRecordsStillFramesIntoAClip() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp, androidADBPath: nil, failuresOnly: false))
        let physicalIOS = DriverConnection(platform: "ios", port: 8150, udid: "00008030-XXXX", physical: true)
        let worker = RunWorker(label: "SE3(ios:8150)", platform: "ios", driver: UnusedDriver(),
                               connection: physicalIOS, logicalName: "SE3")
        let started = await coordinator.start(worker)
        XCTAssertTrue(started, "物理 iPhone も録画を開始する")
        let maybeDir = await coordinator.stillFramesDir(workerLabel: worker.label)
        let dir = try XCTUnwrap(maybeDir, "物理 iPhone には撮影先がある")
        XCTAssertTrue(dir.path.hasPrefix(tmp.appendingPathComponent("recordings").path), dir.path)

        let t0 = Date().addingTimeInterval(-3)
        await coordinator.scenarioStarted(workerLabel: worker.label, scenarioID: "T.S0010", at: t0)
        let capture = StillFrameCapture(dir: dir)
        capture.save(try Self.png(width: 100, height: 200), at: t0.addingTimeInterval(0.2))
        capture.save(try Self.png(width: 100, height: 200), at: t0.addingTimeInterval(0.8))
        await coordinator.scenarioFinished(workerLabel: worker.label, at: t0.addingTimeInterval(1.5), passed: false)
        await coordinator.stop(worker)
        await coordinator.finish()

        let decoded = try JSONDecoder().decode(
            RecordingIndex.self, from: Data(contentsOf: tmp.appendingPathComponent("recordings/index.json")))
        XCTAssertEqual(decoded.recordings.map(\.scenarioID), ["T.S0010"])
        XCTAssertNil(decoded.sourcesFailed, "録画に失敗した台は無い(0 は欄ごと省かれる)")
        let clip = try XCTUnwrap(decoded.recordings.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent(clip.file).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "撮影先は停止時に消す")
    }

    /// 動画を起動できたデバイス(シミュレータ・Android)には撮影先が無い = 静止画のコストを払わせない
    /// (撮影先があるのは物理 iPhone と、動画を起動できず切り替えたデバイスだけ)
    func testOnlyPhysicalIPhoneHasAStillFramesDir() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp),
            makeSession: fixedSessionFactory(tmp: tmp))
        let simulator = makeWorker(1)
        _ = await coordinator.start(simulator)
        let stillsDir = await coordinator.stillFramesDir(workerLabel: simulator.label)
        XCTAssertNil(stillsDir)
    }

    /// **動画の録画を起動できないデバイスは静止画方式へ切り替わり**、子が置いた静止画がクリップになる
    /// (iOS シミュレータの試し撮りが空になる等で、そのデバイスの録画が丸ごと消えていた)
    func testFailedVideoStartFallsBackToStillFramesAndProducesAClip() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp, androidADBPath: nil, failuresOnly: false),
            makeSession: { _, _, _ in DeadSession() })
        let worker = makeWorker(1)
        let started = await coordinator.start(worker)
        XCTAssertTrue(started)
        let maybeDir = await coordinator.stillFramesDir(workerLabel: worker.label)
        let dir = try XCTUnwrap(maybeDir, "切り替えたのに子へ渡す撮影先が無い")

        let t0 = Date().addingTimeInterval(-3)
        await coordinator.scenarioStarted(workerLabel: worker.label, scenarioID: "T.S0010", at: t0)
        let capture = StillFrameCapture(dir: dir)
        capture.save(try Self.png(width: 100, height: 200), at: t0.addingTimeInterval(0.2))
        capture.save(try Self.png(width: 100, height: 200), at: t0.addingTimeInterval(0.8))
        await coordinator.scenarioFinished(workerLabel: worker.label, at: t0.addingTimeInterval(1.5), passed: true)
        await coordinator.stop(worker)
        await coordinator.finish()

        let decoded = try JSONDecoder().decode(
            RecordingIndex.self, from: Data(contentsOf: tmp.appendingPathComponent("recordings/index.json")))
        XCTAssertEqual(decoded.recordings.map(\.scenarioID), ["T.S0010"])
        XCTAssertNil(decoded.sourcesFailed, "切り替えて録れたデバイスは録画失敗に数えない")
        XCTAssertEqual(decoded.sourceIssues, [
            RecordingSourceIssue(worker: "ios:test1", phase: .start, reason: .emptyTestRecording,
                                 stillFramesFallback: true),
        ], "救えた切り替えも事実として残す(後から頻度と理由を数えるため)")
    }

    /// 配線: 子へ撮影先を渡す(RunOrchestrator → runOne → ScenarioHost の引数)、子は操作と失敗のステップで撮る
    func testStillFramesDirIsWiredToTheScenarioProcess() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let orchestrator = try source("Sources/FTCore/RunOrchestrator.swift")
        guard let start = orchestrator.range(of: "if await videoRecording?.start(worker) == true {"),
              let lookup = orchestrator.range(of: "let stillFramesDir = await videoRecording?.prepareScenario(workerLabel: worker.label)"),
              let interval = orchestrator.range(of: "await videoRecording?.scenarioStarted(")
        else { return XCTFail("録画の起動・シナリオ前の確かめ・区間の開始が見つからない = 走査を見直す") }
        XCTAssertTrue(start.lowerBound < lookup.lowerBound, "撮影先は録画を起動した後に引く")
        XCTAssertTrue(lookup.lowerBound < interval.lowerBound,
                      "録画の確かめ(撮り直しの待ち)はシナリオの区間を始める前に済ませる = 待ちをシナリオに数えない")
        XCTAssertTrue(orchestrator.contains("stillFramesDir: stillFramesDir,\n                onEvent:"),
                      "runOne へ撮影先を渡していない")
        XCTAssertTrue(orchestrator.contains("registerChildProcess: registerChildProcess, stillFramesDir: stillFramesDir)"),
                      "runOne が ScenarioHost.run へ撮影先を渡していない")
        XCTAssertTrue(try source("Sources/FTCore/ScenarioHost.swift")
                        .contains(#"args += ["--still-frames-dir", stillFramesDir.path]"#))
        let runner = try source("Sources/FTScenarioRunner/ScenarioRunnerMain.swift")
        XCTAssertTrue(runner.contains(#"@Option(name: .customLong("still-frames-dir"),"#))
        XCTAssertTrue(runner.contains("core.stillFrameCapture = stillFramesDir.map"))
        let runtime = try source("Sources/FTDSL/FTRuntime.swift")
        XCTAssertTrue(runtime.contains("captureStillFrameIfRecording(changedScreen: step.action != nil, status: status)"),
                      "StepExecutor 経由のステップで撮っていない")
        XCTAssertTrue(runtime.contains("captureStillFrameIfRecording(changedScreen: !isAssertion, status: status)"),
                      "performCustom 経由のステップ(launchApp 等)で撮っていない")
    }

    private static func png(width: Int, height: Int) throws -> Data {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(ctx.makeImage())
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    /// 切り出しが期限超過したら、そこで断念する(スロット待ちだった残りのクリップは1件も試みない)はず
    func testTimeoutAbandonsRemainingClips() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let probe = ExportProbe()
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp),
            makeSession: fixedSessionFactory(tmp: tmp),
            extractClip: writing { _, _, _, _, _, _, _ in
                await probe.began()
                // 無応答エンコーダの再現(テスト終了まで返らない)
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
                return true
            },
            exportDeadline: { _ in 0.2 },
            hardwareFirst: false)
        // 同時実行の上限 + 1 本 = 1本はスロット待ちになる
        let workers = (1...3).map { makeWorker($0) }
        for (n, worker) in workers.enumerated() {
            let started = await coordinator.start(worker)
            XCTAssertTrue(started)
            await registerInterval(coordinator, worker: worker, scenarioID: "TimeoutTest.S00\(n)0")
        }
        for worker in workers { await coordinator.stop(worker) }

        let finishStart = Date()
        await coordinator.finish()
        XCTAssertLessThan(Date().timeIntervalSince(finishStart), 5,
                          "期限超過したら残りを待たずに断念するはず")
        let calls = await probe.calls
        XCTAssertEqual(calls, 2, "スロットの2本を1回ずつだけ試し(撮り直さない)、待っていた3本目は試さないはず")
        let indexURL = tmp.appendingPathComponent("recordings/index.json")
        let data = try Data(contentsOf: indexURL)
        let decoded = try JSONDecoder().decode(RecordingIndex.self, from: data)
        XCTAssertEqual(decoded.recordings.count, 0, "クリップは1本も取れないはず")
        XCTAssertEqual(decoded.clipsAttempted, 3)
        XCTAssertEqual(decoded.clipsFailed, 3)
    }

    /// 実在するソースファイルを返すセッションを生成する makeSession(ソースを消す/残すの観測用)
    private func realFileSessionFactory()
        -> @Sendable (RunWorker, URL, String) -> (any DeviceVideoRecorderSession)? {
        let startedAt = ISO8601Millis.string(from: recordStart)
        return { _, recordingsDir, sourceStem in
            let url = recordingsDir.appendingPathComponent("\(sourceStem).mov")
            FileManager.default.createFile(atPath: url.path, contents: Data([0]))
            return FixedSourceSession(source: RecordingSource(
                files: [url],
                segments: [RecordingIndexSegment(startedAt: startedAt, durationMs: 60_000)]))
        }
    }

    /// 切り出しは run の途中(stop)では行わず finish でまとめて行い、false(期限内の失敗)なら1回だけ切り出し直すはず。
    /// 成功すればクリップは index に載り、ソースは消える
    func testFailedClipIsRetriedOnceAtFinishAndSucceeds() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let probe = ExportProbe()
        let failedOnce = LockedValue(false)
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp),
            makeSession: realFileSessionFactory(),
            extractClip: writing { _, _, _, _, _, _, outputURL in
                await probe.began()
                guard outputURL.lastPathComponent.contains("S0010") else { return true }
                return failedOnce.withLock { failed in
                    defer { failed = true }
                    return failed  // S0010 は1回目だけ失敗させる
                }
            })
        let w1 = makeWorker(1)
        let w2 = makeWorker(2)
        let started1 = await coordinator.start(w1)
        let started2 = await coordinator.start(w2)
        XCTAssertTrue(started1)
        XCTAssertTrue(started2)
        await registerInterval(coordinator, worker: w1, scenarioID: "RetryTest.S0010")
        await registerInterval(coordinator, worker: w2, scenarioID: "RetryTest.S0020")
        await coordinator.stop(w1)
        await coordinator.stop(w2)
        let callsBeforeFinish = await probe.calls
        XCTAssertEqual(callsBeforeFinish, 0, "run の途中(stop)では切り出さないはず")
        await coordinator.finish()

        let calls = await probe.calls
        XCTAssertEqual(calls, 3, "2本を切り出し、失敗した1本だけを1回切り出し直すはず")
        let decoded = try JSONDecoder().decode(
            RecordingIndex.self, from: Data(contentsOf: tmp.appendingPathComponent("recordings/index.json")))
        XCTAssertEqual(Set(decoded.recordings.map(\.scenarioID)), ["RetryTest.S0010", "RetryTest.S0020"])
        XCTAssertEqual(decoded.clipsAttempted, 2, "再試行は attempted に二重に数えないはず")
        XCTAssertEqual(decoded.clipsFailed, 0)
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: tmp.appendingPathComponent("recordings"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mov" }
        XCTAssertEqual(leftovers, [], "再試行で取れたらソースは消すはず")
    }

    /// 再試行でも失敗したら失敗として数え、**そのソースだけ**診断用に残すはず(成功したワーカーのソースは消す)
    func testClipFailingTwiceIsCountedAndKeepsItsSource() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let probe = ExportProbe()
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp),
            makeSession: realFileSessionFactory(),
            extractClip: writing { _, _, _, _, _, _, outputURL in
                await probe.began()
                return !outputURL.lastPathComponent.contains("S0010")  // S0010 は毎回失敗させる
            })
        let w1 = makeWorker(1)
        let w2 = makeWorker(2)
        let started1 = await coordinator.start(w1)
        let started2 = await coordinator.start(w2)
        XCTAssertTrue(started1)
        XCTAssertTrue(started2)
        await registerInterval(coordinator, worker: w1, scenarioID: "FailTest.S0010")
        await registerInterval(coordinator, worker: w2, scenarioID: "FailTest.S0020")
        await coordinator.stop(w1)
        await coordinator.stop(w2)
        await coordinator.finish()

        let calls = await probe.calls
        XCTAssertEqual(calls, 3, "失敗したクリップは1回だけ撮り直すはず")
        let decoded = try JSONDecoder().decode(
            RecordingIndex.self, from: Data(contentsOf: tmp.appendingPathComponent("recordings/index.json")))
        XCTAssertEqual(decoded.recordings.map(\.scenarioID), ["FailTest.S0020"], "失敗しても次のクリップは取るはず")
        XCTAssertEqual(decoded.clipsAttempted, 2)
        XCTAssertEqual(decoded.clipsFailed, 1)
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: tmp.appendingPathComponent("recordings"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mov" }
        XCTAssertEqual(leftovers.count, 1, "2回とも失敗したワーカーのソースだけ残すはず")
    }

    // MARK: ハードウェアエンコーダ(run 完了時)

    /// ハードウェアが期限内に終わらなければ、この run の残りをソフトウェアへ切り替え、そのクリップも別名で切り出し直すはず
    func testHardwareTimeoutSwitchesTheRestOfTheRunToSoftware() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let calls = LockedValue<[(hardware: Bool, file: String)]>([])
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp),
            makeSession: fixedSessionFactory(tmp: tmp),
            extractClip: writing { _, _, _, _, _, hardware, outputURL in
                calls.withLock { $0.append((hardware, outputURL.path)) }
                if hardware { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }  // 固着の再現
                return true
            },
            hardwareDeadline: { _ in 0.2 })
        let workers = (1...3).map { makeWorker($0) }
        for (n, worker) in workers.enumerated() {
            let started = await coordinator.start(worker)
            XCTAssertTrue(started)
            await registerInterval(coordinator, worker: worker, scenarioID: "HwHang.S00\(n)0")
        }
        for worker in workers { await coordinator.stop(worker) }
        await coordinator.finish()

        let made = calls.withLock { $0 }
        XCTAssertEqual(made.filter(\.hardware).count, 2, "固着を検知するまでに撃つのはスロットの2本だけのはず")
        XCTAssertEqual(made.filter { !$0.hardware }.count, 3, "3本ともソフトウェアで取れるはず")
        let swFiles = Set(made.filter { !$0.hardware }.map(\.file))
        for hwFile in made.filter(\.hardware).map(\.file) {
            XCTAssertFalse(swFiles.contains(hwFile), "固着したハードウェアの書き先へソフトウェアを書かないはず: \(hwFile)")
        }
        let decoded = try readIndex(tmp)
        XCTAssertEqual(decoded.recordings.count, 3)
        XCTAssertEqual(decoded.clipsFailed, 0)
    }

    /// ハードウェアが失敗(false)したら、ソフトウェアで1回やり直すはず
    func testHardwareFailureIsRetriedWithSoftware() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let calls = LockedValue<[Bool]>([])
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp),
            makeSession: fixedSessionFactory(tmp: tmp),
            extractClip: writing { _, _, _, _, _, hardware, _ in
                calls.withLock { $0.append(hardware) }
                return !hardware
            })
        let worker = makeWorker(1)
        let started = await coordinator.start(worker)
        XCTAssertTrue(started)
        await registerInterval(coordinator, worker: worker, scenarioID: "HwFail.S0010")
        await coordinator.stop(worker)
        await coordinator.finish()
        XCTAssertEqual(calls.withLock { $0 }, [true, false])
        let decoded = try readIndex(tmp)
        XCTAssertEqual(decoded.recordings.map(\.scenarioID), ["HwFail.S0010"])
        XCTAssertEqual(decoded.clipsFailed, 0)
    }

    /// ハードウェアが失敗したら台帳のための確かめを run につき1回だけ撃ち、残りはハードウェアを撃たないはず
    func testHardwareFailureProbesOnceAndSkipsHardwareWhenTheEncoderIsDead() async throws {
        let (hw, probes, recorded) = try await runWithFailingHardware(probe: .dead, clips: 4)
        XCTAssertEqual(probes, 1, "確かめは run につき1回のはず")
        XCTAssertLessThanOrEqual(hw, 2, "死と分かった後はハードウェアを撃たないはず(並走していた分だけ)")
        XCTAssertEqual(recorded, 4, "全部ソフトウェアで取れるはず")
    }

    /// 確かめが生でも、ハードウェアの失敗が1回出たらその run の残りはソフトウェアのはず(壊れる前に手を引く)
    func testSingleHardwareFailureSwitchesTheRunToSoftwareEvenIfTheProbeIsHealthy() async throws {
        let (hw, probes, recorded) = try await runWithFailingHardware(probe: .alive, clips: 4)
        XCTAssertEqual(probes, 1, "台帳のための確かめは1回だけのはず")
        XCTAssertLessThanOrEqual(hw, 2, "失敗の後はハードウェアを撃たないはず(並走していた分だけ)")
        XCTAssertEqual(recorded, 4)
    }

    private func runWithFailingHardware(probe state: VideoEncoderLiveness.State, clips: Int) async throws
        -> (hardwareCalls: Int, probeCalls: Int, recorded: Int) {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let hardwareCalls = LockedValue(0)
        let probeCalls = LockedValue(0)
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp),
            makeSession: fixedSessionFactory(tmp: tmp),
            extractClip: writing { _, _, _, _, _, hardware, _ in
                if hardware { hardwareCalls.withLock { $0 += 1 } }
                return !hardware
            },
            probeHardwareEncoder: {
                probeCalls.withLock { $0 += 1 }
                return .init(state: state, checkedAt: 1, source: .probe, error: state == .dead ? "broken" : nil)
            })
        let workers = (1...clips).map { makeWorker($0) }
        for (n, worker) in workers.enumerated() {
            let started = await coordinator.start(worker)
            XCTAssertTrue(started)
            await registerInterval(coordinator, worker: worker, scenarioID: "Probe.S00\(n)0")
        }
        for worker in workers { await coordinator.stop(worker) }
        await coordinator.finish()
        return (hardwareCalls.withLock { $0 }, probeCalls.withLock { $0 }, try readIndex(tmp).recordings.count)
    }

    /// 静止画の末尾だけに収まるシナリオは、ファイルの終わりより後の位置で切り出し、index の区間も末尾の1区間になるはず
    /// (開始をファイルの終わりへ丸めると、末尾の手前の空白まで含んで長くなり、index の区間が空になっていた)
    func testScenarioInsideTheStillTailGetsItsOwnRangeAndSegment() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let ranges = LockedValue<[(Int, Int)]>([])
        let start = recordStart
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp),
            makeSession: { _, recordingsDir, stem in
                FixedSourceSession(source: RecordingSource(
                    files: [recordingsDir.appendingPathComponent("\(stem).mov")],
                    segments: [RecordingIndexSegment(startedAt: ISO8601Millis.string(from: start), durationMs: 2000)],
                    closedAt: [start.addingTimeInterval(5)]))
            },
            extractClip: writing { _, clipStart, clipEnd, _, _, _, _ in
                ranges.withLock { $0.append((clipStart, clipEnd)) }
                return true
            })
        let worker = makeWorker(1)
        let started = await coordinator.start(worker)
        XCTAssertTrue(started)
        await coordinator.scenarioStarted(workerLabel: worker.label, scenarioID: "TailOnly.S0010",
                                          at: start.addingTimeInterval(3))
        await coordinator.scenarioFinished(workerLabel: worker.label, at: start.addingTimeInterval(4), passed: false)
        await coordinator.stop(worker)
        await coordinator.finish()
        XCTAssertEqual(ranges.withLock { $0.first?.0 }, 3000)
        XCTAssertEqual(ranges.withLock { $0.first?.1 }, 4000)
        let segments = try readIndex(tmp).recordings.first?.segments
        XCTAssertEqual(segments?.map(\.durationMs), [1000])
        XCTAssertEqual(segments?.first?.startedAt, ISO8601Millis.string(from: start.addingTimeInterval(3)))
    }

    func testScenarioCrossingPartsKeepsTheEarlierStillTailAndSkipsTheGap() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let ranges = LockedValue<[(Int, Int)]>([])
        let durations = LockedValue<[Int?]>([])
        let start = recordStart
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp),
            makeSession: { _, recordingsDir, _ in
                FixedSourceSession(source: RecordingSource(
                    files: [recordingsDir.appendingPathComponent("first.mov"), recordingsDir.appendingPathComponent("second.mov")],
                    segments: [
                        RecordingIndexSegment(startedAt: ISO8601Millis.string(from: start), durationMs: 2000),
                        RecordingIndexSegment(startedAt: ISO8601Millis.string(from: start.addingTimeInterval(7)), durationMs: 2000),
                    ], closedAt: [start.addingTimeInterval(5), start.addingTimeInterval(9)]))
            },
            extractClip: writing { sources, clipStart, clipEnd, _, _, _, _ in
                ranges.withLock { $0.append((clipStart, clipEnd)) }
                durations.value = sources.map(\.durationMs)
                return true
            })
        let worker = makeWorker(1)
        _ = await coordinator.start(worker)
        await coordinator.scenarioStarted(workerLabel: worker.label, scenarioID: "Parts.S0010", at: start.addingTimeInterval(3))
        await coordinator.scenarioFinished(workerLabel: worker.label, at: start.addingTimeInterval(9), passed: false)
        await coordinator.stop(worker)
        await coordinator.finish()
        XCTAssertEqual(ranges.value.first?.0, 3000)
        XCTAssertEqual(ranges.value.first?.1, 7000)
        XCTAssertEqual(durations.value, [5000, 2000])
        let index = try readIndex(tmp)
        let segments = try XCTUnwrap(index.recordings.first).segments
        XCTAssertEqual(segments.map(\.durationMs), [2000, 2000])
        XCTAssertEqual(segments.map(\.startedAt), [ISO8601Millis.string(from: start.addingTimeInterval(3)),
                                                ISO8601Millis.string(from: start.addingTimeInterval(7))])
    }

    func testLongScenarioNameFitsTheTemporaryOutputAndFinalFile() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let scenarioID = String(repeating: "A", count: 220)
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp), makeSession: realFileSessionFactory(),
            extractClip: writing { _, _, _, _, _, _, _ in true })
        let worker = makeWorker(1)
        _ = await coordinator.start(worker)
        await registerInterval(coordinator, worker: worker, scenarioID: scenarioID)
        await coordinator.stop(worker)
        await coordinator.finish()
        let index = try readIndex(tmp)
        XCTAssertEqual(index.clipsFailed, 0)
        let clip = try XCTUnwrap(index.recordings.first)
        XCTAssertEqual(clip.file, "recordings/\(scenarioID).mp4")
        XCTAssertEqual(try Data(contentsOf: tmp.appendingPathComponent(clip.file)), Data([0]))
    }

    // MARK: シナリオの前の録画の確認

    /// 録画が撮れていれば、シナリオの前の確認は何も変えずに nil(動画のまま)を返すはず
    func testPrepareScenarioKeepsAWorkingRecording() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let session = EnsureSession(recording: true, start: recordStart, dir: tmp)
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp), makeSession: { _, _, _ in session },
            extractClip: writing { _, _, _, _, _, _, _ in true })
        let worker = makeWorker(1)
        let started = await coordinator.start(worker)
        XCTAssertTrue(started)
        let dir = await coordinator.prepareScenario(workerLabel: worker.label)
        XCTAssertNil(dir)
        let stops = await session.stops
        XCTAssertEqual(stops, 0, "撮れている録画を止めないはず")
    }

    /// 撮り直しても録画が始まらなければ、そのワーカーの残りを静止画方式へ切り替え、それまでの動画も切り出すはず
    func testPrepareScenarioFallsBackToStillFramesAndKeepsEarlierVideo() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let session = EnsureSession(recording: false, start: recordStart, dir: tmp)
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp), makeSession: { _, _, _ in session },
            extractClip: writing { _, _, _, _, _, _, _ in true })
        let worker = makeWorker(1)
        let started = await coordinator.start(worker)
        XCTAssertTrue(started)
        await registerInterval(coordinator, worker: worker, scenarioID: "Before.S0010")
        let stills = await coordinator.prepareScenario(workerLabel: worker.label)
        XCTAssertNotNil(stills, "撮り直せなければ静止画の置き場を返すはず")
        let again = await coordinator.prepareScenario(workerLabel: worker.label)
        XCTAssertEqual(again, stills, "切り替えた後は同じ置き場のまま(撮り直しを繰り返さない)")
        let ensures = await session.ensures
        XCTAssertEqual(ensures, 1)
        await coordinator.stop(worker)
        await coordinator.finish()
        let index = try readIndex(tmp)
        XCTAssertEqual(index.recordings.map(\.scenarioID), ["Before.S0010"], "切り替える前の動画からも切り出すはず")
        XCTAssertEqual(index.sourceIssues?.contains { $0.stillFramesFallback == true }, true)
    }

    // MARK: 配信中のハードウェアの余力

    /// 配信中は1本目だけを先にハードウェアで切り出し、基準より遅ければ残りはソフトウェアのはず
    func testSlowFirstHardwareClipWhileStreamingSwitchesTheRestToSoftware() async throws {
        let flags = try await hardwareFlagsWhileStreaming(streaming: true, firstClipSeconds: 1)
        XCTAssertEqual(flags.first, true)
        XCTAssertEqual(Array(flags.dropFirst()), [false, false], "1本目が 4 秒のクリップに 1 秒 = 4 倍速 < 基準 → 残りはソフトウェア")
    }

    /// 1本目が速ければ残りもハードウェアのはず
    func testFastFirstHardwareClipWhileStreamingKeepsHardware() async throws {
        let flags = try await hardwareFlagsWhileStreaming(streaming: true, firstClipSeconds: 0)
        XCTAssertEqual(flags, [true, true, true])
    }

    /// 配信が無ければ速さで判定しない(遅くてもハードウェアのまま)はず
    func testWithoutStreamsTheFirstClipIsNotATrial() async throws {
        let flags = try await hardwareFlagsWhileStreaming(streaming: false, firstClipSeconds: 1)
        XCTAssertEqual(flags, [true, true, true])
    }

    private func hardwareFlagsWhileStreaming(streaming: Bool, firstClipSeconds: Double) async throws -> [Bool] {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let calls = LockedValue<[Bool]>([])
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp),
            makeSession: fixedSessionFactory(tmp: tmp),
            extractClip: writing { _, _, _, _, _, hardware, _ in
                let first = calls.withLock { list -> Bool in
                    list.append(hardware)
                    return list.count == 1
                }
                if first, firstClipSeconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(firstClipSeconds * 1_000_000_000))
                }
                return true
            },
            liveStreamsActive: { streaming })
        let workers = (1...3).map { makeWorker($0) }
        for (n, worker) in workers.enumerated() {
            let started = await coordinator.start(worker)
            XCTAssertTrue(started)
            await registerInterval(coordinator, worker: worker, scenarioID: "Stream.S00\(n)0")
        }
        for worker in workers { await coordinator.stop(worker) }
        await coordinator.finish()
        XCTAssertEqual(try readIndex(tmp).recordings.count, 3)
        return calls.withLock { $0 }
    }

    /// 本番の配線: 配信の有無と合成映像の確かめは RunOrchestrator が本物を渡す(init の既定は「しない」= テスト用)
    func testOrchestratorWiresLiveStreamsAndProbe() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let orchestrator = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/RunOrchestrator.swift"),
                                      encoding: .utf8)
        XCTAssertTrue(orchestrator.contains("probeHardwareEncoder: { await HardwareEncoderProbe.check() }"))
        XCTAssertTrue(orchestrator.contains("liveStreamsActive: { LiveEncodeStreams.anyActive() })"))
    }

    /// 基準値はソフトウェアの典型的な速さ(実測の中央値 約 8.5 倍)。リテラルで固定する
    func testMinimumHardwareSpeedWhileStreamingIsPinned() {
        XCTAssertEqual(VideoRecordingCoordinator.minHardwareSpeedWhileStreaming, 8)
    }

    func testHardwareDeadlineConstantsArePinned() {
        XCTAssertEqual(VideoRecordingCoordinator.hardwareDeadlineFloorSeconds, 10)
        XCTAssertEqual(VideoRecordingCoordinator.hardwareMinSpeedRatio, 4)
    }

    /// ハードウェアが固まったクリップの書きかけは recordings/ に残らないはず(一時フォルダへ書いて成功したときだけ移す =
    /// 期限を過ぎた敗者 task が後から書いても recordings/ には現れない)
    func testHungHardwareLeavesNoPartialFileInRecordings() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let partials = LockedValue<[URL]>([])
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp),
            makeSession: fixedSessionFactory(tmp: tmp),
            extractClip: writing { _, _, _, _, _, hardware, outputURL in
                guard hardware else { return true }
                FileManager.default.createFile(atPath: outputURL.path, contents: Data([0]))
                partials.withLock { $0.append(outputURL) }
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
                return true
            },
            hardwareDeadline: { _ in 0.2 })
        let worker = makeWorker(1)
        let started = await coordinator.start(worker)
        XCTAssertTrue(started)
        await registerInterval(coordinator, worker: worker, scenarioID: "Partial.S0010")
        await coordinator.stop(worker)
        await coordinator.finish()
        let written = partials.withLock { $0 }
        XCTAssertEqual(written.count, 1)
        for url in written {
            XCTAssertFalse(url.path.hasPrefix(tmp.path), "書きかけを run の結果の中に書かないはず: \(url.path)")
            try? FileManager.default.removeItem(at: url)
        }
        let index = try readIndex(tmp)
        XCTAssertEqual(index.recordings.count, 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: tmp.appendingPathComponent("recordings").path).sorted()
        XCTAssertEqual(files, ["Partial-S0010.mp4", "index.json"], "recordings/ には切り出せたクリップと index だけ")
    }

    // MARK: 静止画の末尾

    /// ファイルが閉じた時刻より前に終わっている(VFR = 最後に画面が変わった所で終わる)なら、
    /// シナリオの終わりまで最終フレームを伸ばすはず(clipEndMs がソースを越え、index の segment も伸びる)
    func testClipExtendsTheStillTailUpToTheScenarioEnd() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let ranges = LockedValue<[(Int, Int)]>([])
        let start = recordStart
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp),
            makeSession: { _, recordingsDir, stem in
                FixedSourceSession(source: RecordingSource(
                    files: [recordingsDir.appendingPathComponent("\(stem).mov")],
                    segments: [RecordingIndexSegment(startedAt: ISO8601Millis.string(from: start), durationMs: 2000)],
                    closedAt: [start.addingTimeInterval(5)]))
            },
            extractClip: writing { _, clipStart, clipEnd, _, _, _, _ in
                ranges.withLock { $0.append((clipStart, clipEnd)) }
                return true
            })
        let worker = makeWorker(1)
        let started = await coordinator.start(worker)
        XCTAssertTrue(started)
        await coordinator.scenarioStarted(workerLabel: worker.label, scenarioID: "Tail.S0010",
                                          at: start.addingTimeInterval(1))
        await coordinator.scenarioFinished(workerLabel: worker.label, at: start.addingTimeInterval(4), passed: false)
        await coordinator.stop(worker)
        await coordinator.finish()
        let got = ranges.withLock { $0 }
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.0, 1000)
        XCTAssertEqual(got.first?.1, 4000, "ファイルの終わり(2000)から閉じた時刻までは最終フレームで埋めるはず")
        XCTAssertEqual(try readIndex(tmp).recordings.first?.segments.map(\.durationMs), [3000])
    }

    private func readIndex(_ tmp: URL) throws -> RecordingIndex {
        try JSONDecoder().decode(
            RecordingIndex.self, from: Data(contentsOf: tmp.appendingPathComponent("recordings/index.json")))
    }

    /// 本番の切り出しはハードウェアを「使ってよい」だけでなく「必須」にも同じ引数を渡す
    /// (必須にしないと、ハードウェアが使えないときに黙ってソフトウェアへ落ち、期限がハードウェアの短い値のまま走る)
    func testProductionExtractorRequiresHardwareWhenAsked() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTCore/VideoRecordingFinalizer.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        guard let settings = code.range(of: "let outputSettings: [String: Any] = ["),
              let end = code.range(of: "]\n        let writerInput", range: settings.upperBound..<code.endIndex) else {
            return XCTFail("outputSettings の宣言が見つからない = 走査を見直す")
        }
        let literal = String(code[settings.upperBound..<end.lowerBound])
        XCTAssertTrue(literal.contains(
            "kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: hardware,"))
        XCTAssertTrue(literal.contains(
            "kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: hardware,"))
        XCTAssertFalse(code.contains("outputSettings["), "outputSettings を後から書き換えない(条件付きの切り替えを戻さない)")
    }

    /// 切り出しを1件も試みなければ index.json は書かない(recordFailuresOnly かつ全シナリオ
    /// 成功のケース。既存の掃除の維持)
    func testFinishSkipsIndexWhenNoClipsAttempted() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let probe = ExportProbe()
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp, failuresOnly: true),
            makeSession: fixedSessionFactory(tmp: tmp),
            extractClip: writing { _, _, _, _, _, _, _ in
                await probe.began()
                return true
            })
        let worker = makeWorker(1)
        let started = await coordinator.start(worker)
        XCTAssertTrue(started)
        await coordinator.scenarioStarted(workerLabel: worker.label, scenarioID: "SkipTest.S0010",
                                          at: recordStart.addingTimeInterval(1))
        await coordinator.scenarioFinished(workerLabel: worker.label,
                                           at: recordStart.addingTimeInterval(5), passed: true)
        await coordinator.stop(worker)
        await coordinator.finish()

        let calls = await probe.calls
        XCTAssertEqual(calls, 0, "recordFailuresOnly かつ確実に成功したシナリオは切り出さないはず")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent("recordings/index.json").path),
            "切り出しを1件も試みなければ index.json は書かないはず")
    }

    func testExportConcurrencyIsLimitedToTwo() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let probe = ExportProbe()
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp),
            makeSession: fixedSessionFactory(tmp: tmp),
            extractClip: writing { _, _, _, _, _, _, _ in
                await probe.began()
                try? await Task.sleep(nanoseconds: 150_000_000)
                await probe.ended()
                return true
            })
        let workers = (1...4).map { makeWorker($0) }
        for (n, worker) in workers.enumerated() {
            let started = await coordinator.start(worker)
            XCTAssertTrue(started)
            await registerInterval(coordinator, worker: worker, scenarioID: "Parallel.S00\(n)0")
        }
        await withTaskGroup(of: Void.self) { group in
            for worker in workers {
                group.addTask { await coordinator.stop(worker) }
            }
        }
        let callsBeforeFinish = await probe.calls
        XCTAssertEqual(callsBeforeFinish, 0, "切り出しは finish でまとめて行うはず")
        await coordinator.finish()
        let calls = await probe.calls
        let maxConcurrent = await probe.maxConcurrent
        XCTAssertEqual(calls, 4, "全ワーカーのクリップが切り出されるはず")
        XCTAssertLessThanOrEqual(maxConcurrent, 2, "エクスポートの同時実行は 2 までのはず")
    }

    func testFinalizeWritesClipsAndIndexOnSuccess() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let probe = ExportProbe()
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp),
            makeSession: fixedSessionFactory(tmp: tmp),
            extractClip: writing { _, _, _, _, _, _, _ in
                await probe.began()
                await probe.ended()
                return true
            })
        let worker = makeWorker(1)
        let started = await coordinator.start(worker)
        XCTAssertTrue(started)
        await registerInterval(coordinator, worker: worker, scenarioID: "Normal.S0010", offsetSeconds: 1)
        await registerInterval(coordinator, worker: worker, scenarioID: "Normal.S0020", offsetSeconds: 6)
        await coordinator.stop(worker)
        await coordinator.finish()

        let calls = await probe.calls
        XCTAssertEqual(calls, 2)
        let indexURL = tmp.appendingPathComponent("recordings/index.json")
        let data = try Data(contentsOf: indexURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let recordings = try XCTUnwrap(json["recordings"] as? [[String: Any]])
        XCTAssertEqual(recordings.count, 2, "シナリオ区間ごとに 1 エントリのはず")
    }

    /// **アイドルワーカーの空ソースは失敗に数えない**。`deviceKeepCount` は本数+予備1台を
    /// 残すので、本数 < 台数の run では予備が必ず空になる。数えると小さい run のたびに
    /// 誤警報が出て「録画が本当に全滅した run」と見分けが付かなくなる
    func testIdleWorkerWithEmptySourceIsNotCountedAsFailure() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp, androidADBPath: nil, failuresOnly: false),
            makeSession: { _, _, _ in EmptySourceSession() })

        let worker = makeWorker(1)
        let started = await coordinator.start(worker)
        XCTAssertTrue(started, "開始自体は成功する")
        // シナリオ区間を1つも登録しない = 予備のデバイス
        await coordinator.finish()

        let indexURL = tmp.appendingPathComponent("recordings/index.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path),
                       "アイドルだけの run は失敗 0 件なので index を書かない")
    }

    /// 逆向き: **実際にシナリオを回したデバイスの空ソースは数える**(全滅の検出はこちらが担う)。
    /// 片方向だけだと「常に数えない」変異を素通しする
    func testWorkerThatRanScenariosWithEmptySourceIsCounted() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp, androidADBPath: nil, failuresOnly: false),
            makeSession: { _, _, _ in EmptySourceSession() })

        let worker = makeWorker(1)
        _ = await coordinator.start(worker)
        await registerInterval(coordinator, worker: worker, scenarioID: "T.S0010")
        await coordinator.finish()

        let indexURL = tmp.appendingPathComponent("recordings/index.json")
        let decoded = try JSONDecoder().decode(RecordingIndex.self, from: Data(contentsOf: indexURL))
        XCTAssertEqual(decoded.sourcesFailed, 1, "シナリオを回した台の空ソースは失敗として残す")
    }
}

/// 録画を開始できないセッション(端末側に録画が刺さっている状態の代役)
private actor DeadSession: DeviceVideoRecorderSession {
    func start() async -> Bool { false }
    func stop() async -> RecordingSource? { nil }
    /// 理由が存在型越しに届くか(要件でなく既定実装だけだと nil に落ちる)を見るため、既定と違う値を返す
    func startFailure() async -> RecordingStartFailure? { .emptyTestRecording }
}

/// 開始はできるが読めるソースが残らないセッション(録画プロセスは動いたのに空だった形)
private actor EmptySourceSession: DeviceVideoRecorderSession {
    func start() async -> Bool { true }
    func stop() async -> RecordingSource? { nil }
}

/// シナリオの前の確認の代役。recording = ensureRecording の答え。stop は録画開始から 60 秒の実在ファイルを返す
private actor EnsureSession: DeviceVideoRecorderSession {
    let recording: Bool
    let start: Date
    let dir: URL
    private(set) var ensures = 0
    private(set) var stops = 0

    init(recording: Bool, start: Date, dir: URL) {
        self.recording = recording
        self.start = start
        self.dir = dir
    }

    func start() async -> Bool { true }

    func ensureRecording() async -> Bool {
        ensures += 1
        return recording
    }

    func stop() async -> RecordingSource? {
        stops += 1
        guard stops == 1 else { return nil }
        let url = dir.appendingPathComponent("ensure-\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: url.path, contents: Data([0]))
        return RecordingSource(
            files: [url],
            segments: [RecordingIndexSegment(startedAt: ISO8601Millis.string(from: start), durationMs: 60_000)])
    }
}
