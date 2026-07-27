// VideoRecordingCoordinator の判定ロジック(recordFailuresOnly の区間スキップ)と、
// finalize のエクスポート制御(期限超過→残りクリップ断念・同時実行制限)を検証する。
// 実セッション(simctl/adb)や実エンコードは makeSession/extractClip 注入で置き換える。

import XCTest
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
    func launch(bundleID: String) async throws { throw Unused() }
    func snapshot() async throws -> SnapshotResponse { throw Unused() }
    func tap(ref: Int) async throws { throw Unused() }
    func tap(x: Double, y: Double) async throws { throw Unused() }
    func type(ref: Int?, text: String) async throws { throw Unused() }
    func swipe(_ direction: FTSwipeDirection) async throws { throw Unused() }
    func press(ref: Int, duration: Double) async throws { throw Unused() }
    func screenshot() async throws -> Data { throw Unused() }
    func terminate() async throws { throw Unused() }
}

private struct FixedSourceSession: DeviceVideoRecorderSession {
    let source: RecordingSource
    func start() async -> Bool { true }
    func stop() async -> RecordingSource? { source }
}

/// extractClip 呼び出しの回数・同時実行数の観測
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

final class VideoRecordingCoordinatorExportTests: XCTestCase {
    /// 全テスト共通の録画開始時刻(壁時計はソース segments との相対関係だけが意味を持つ)
    private let recordStart = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftester-export-tests-\(UUID().uuidString)")
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
        -> (RunWorker, URL, String) -> (any DeviceVideoRecorderSession)? {
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

    func testExportTimeoutAbandonsRemainingClips() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let probe = ExportProbe()
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp),
            makeSession: fixedSessionFactory(tmp: tmp),
            extractClip: { _, _, _, _, _, _ in
                await probe.began()
                // 無応答エンコーダの再現(テスト終了まで返らない)
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
                return true
            },
            exportDeadline: { _ in 0.2 })
        let w1 = makeWorker(1)
        let w2 = makeWorker(2)
        let started1 = await coordinator.start(w1)
        let started2 = await coordinator.start(w2)
        XCTAssertTrue(started1)
        XCTAssertTrue(started2)
        await registerInterval(coordinator, worker: w1, scenarioID: "TimeoutTest.S0010")
        await registerInterval(coordinator, worker: w2, scenarioID: "TimeoutTest.S0020")

        let stopStart = Date()
        await coordinator.stop(w1)  // 期限 0.2 秒で戻り、以降のエクスポートを断念するはず
        await coordinator.stop(w2)  // エクスポートに入らず即返るはず
        XCTAssertLessThan(Date().timeIntervalSince(stopStart), 5,
                          "期限超過後の stop はエンコーダを待たずに返るはず")
        let calls = await probe.calls
        XCTAssertEqual(calls, 1, "期限超過後は残りのクリップを断念するはず")

        await coordinator.finish()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent("recordings/index.json").path),
            "クリップが 1 本も取れなければ index.json は書かないはず")
    }

    func testExportConcurrencyIsLimitedToTwo() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let probe = ExportProbe()
        let coordinator = VideoRecordingCoordinator(
            config: VideoRecordingConfig(runDir: tmp),
            makeSession: fixedSessionFactory(tmp: tmp),
            extractClip: { _, _, _, _, _, _ in
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
            extractClip: { _, _, _, _, _, _ in
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
}
