// procedure { } のブロックの中で DSL のコマンドを呼べること(Shirates の procedure = describe + silent)と、
// レポートでの畳み方・前段の失敗で中を実行しないこと・throw・中の失敗を重ねて記録しないこと。

import XCTest
@testable import FTDSL
@testable import FTCore

final class ProcedureDSLTests: XCTestCase {

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ScenarioEvent] = []
        func add(_ event: ScenarioEvent) { lock.lock(); items.append(event); lock.unlock() }
        var steps: [ScenarioEvent] { lock.lock(); defer { lock.unlock() }; return items.filter { $0.kind == "step" } }
    }

    /// 木には `#counter` だけがある。タップの回数を数える
    private final class CountingDriver: AppDriver {
        private let taps = LockedValue(0)
        var tapCount: Int { taps.value }

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: [ElementInfo(ref: 1, type: "button", identifier: "counter", label: "count",
                                                    value: nil, placeholder: nil, enabled: true,
                                                    frame: FTRect(x: 100, y: 200, width: 50, height: 40), depth: 1)],
                             truncatedCount: 0)
        }
        func tap(ref: Int) async throws { taps.withLock { $0 += 1 } }
        func tap(x: Double, y: Double) async throws { taps.withLock { $0 += 1 } }
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private let sink = Sink()
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-procedure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func makeCore(driver: AppDriver) -> FTDriveCore {
        FTDriveCore(driver: driver, platform: "ios", app: "com.example.app",
                    scenarioID: "T.S0010", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, tunables: RunTunables(),
                    visionClassifierProjectRoot: dir, dryRun: false,
                    fingerprintCacheURL: dir.appendingPathComponent("fp.json"),
                    emit: { [sink] in sink.add($0) })
    }

    private func report(_ core: FTDriveCore) throws -> String {
        let url = try ScenarioReportWriter.write(record: core.finalRecord, to: dir, notices: [])
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testDSLCommandsRunInsideAndTheReportFoldsThePassedOnes() throws {
        let driver = CountingDriver()
        let core = makeCore(driver: driver)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") {
                action {
                    procedure("2 回押す") {
                        tap("#counter", settle: false)
                        tap("#counter", settle: false)
                    }
                    tap("#counter", settle: false)
                }
            }
        }

        XCTAssertTrue(core.finalRecord.passed, "\(sink.steps.map { "\($0.description ?? ""): \($0.status ?? "")" })")
        XCTAssertEqual(driver.tapCount, 3, "中の tap が実際に撃たれている")
        let descriptions = sink.steps.map { $0.description ?? "" }
        XCTAssertFalse(descriptions.contains { $0.hasPrefix("thread violation") })
        XCTAssertEqual(descriptions.filter { $0.hasPrefix("[2 回押す] tap") }.count, 2, "結果のイベントには中のステップが全部残る")
        XCTAssertTrue(descriptions.contains("procedure \"2 回押す\""))

        let md = try report(core)
        XCTAssertTrue(md.contains("procedure \"2 回押す\""), md)
        XCTAssertFalse(md.contains("[2 回押す] tap"), "レポートでは中の成功したステップを畳む:\n\(md)")
        XCTAssertTrue(md.contains("tap \"#counter\""), "procedure の外のステップは畳まない:\n\(md)")
    }

    func testAFailedStepInsideStaysVisibleAndIsNotRecordedTwice() throws {
        let core = makeCore(driver: CountingDriver())
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var reachedAfterFailure = false
        scenario {
            scene(1, "s") {
                action {
                    procedure("無い要素を押す") {
                        tap("#counter", settle: false)
                        tap("#missing", settle: false, waitSeconds: 0)
                        reachedAfterFailure = true
                    }
                }
            }
        }

        XCTAssertFalse(core.finalRecord.passed)
        let failed = sink.steps.filter { $0.status == "failed" }
        XCTAssertEqual(failed.map { $0.description ?? "" }.count, 1, "中の失敗だけが記録される: \(failed.map { $0.description ?? "" })")
        XCTAssertTrue(failed.first?.description?.hasPrefix("[無い要素を押す] tap") == true)
        XCTAssertFalse(sink.steps.contains { $0.description == "procedure \"無い要素を押す\"" },
                       "中が失敗したのに procedure の行(成功)を残さない")
        _ = reachedAfterFailure  // 生の Swift は中断後も走りうる(scene のブロックと同じ)。ここでは数えない

        let md = try report(core)
        XCTAssertTrue(md.contains("[無い要素を押す] tap \"#missing\""), "失敗したステップは畳まない:\n\(md)")
        XCTAssertFalse(md.contains("[無い要素を押す] tap \"#counter\""), "成功したステップは畳む:\n\(md)")
    }

    func testTheBlockDoesNotRunAfterAnEarlierFailure() {
        let core = makeCore(driver: CountingDriver())
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        var ran = false
        scenario {
            scene(1, "s") {
                action {
                    tap("#missing", settle: false, waitSeconds: 0)
                    procedure("後始末") { ran = true }
                }
            }
        }
        XCTAssertFalse(ran, "前段が失敗していれば中を実行しない(失敗後に走らせたくない処理の置き場)")
        XCTAssertEqual(sink.steps.last?.status, "skipped")
    }

    func testAThrowFailsTheProcedure() {
        let core = makeCore(driver: CountingDriver())
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        struct Boom: Error {}
        scenario {
            scene(1, "s") {
                action { procedure("投げる") { throw Boom() } }
            }
        }
        XCTAssertFalse(core.finalRecord.passed)
        XCTAssertEqual(sink.steps.last?.description, "procedure \"投げる\"")
        XCTAssertEqual(sink.steps.last?.status, "failed")
    }
}
