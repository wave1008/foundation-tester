// addMedia() の DSL 側。置き場の解決(dataFile と同じ)・送れる拡張子・ステップの記録・dry-run・中断後の skipped・
// ドライバの失敗の素性(DriverError から。文言の一致ではない)。

import XCTest
@testable import FTDSL
import FTCore

final class AddMediaCommandTests: XCTestCase {

    private final class MediaDriver: AppDriver, @unchecked Sendable {
        var added: [String] = []
        var error: Error?
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
                             elements: [], truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
        func addMedia(path: String) async throws {
            if let error { throw error }
            added.append(path)
        }
    }

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ScenarioEvent] = []
        func add(_ event: ScenarioEvent) { lock.lock(); items.append(event); lock.unlock() }
        var events: [ScenarioEvent] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private var project: URL!
    private let driver = MediaDriver()
    private let sink = Sink()

    override func setUpWithError() throws {
        project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-dsl-addmedia-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("dataset/img"),
                                                withIntermediateDirectories: true)
        for name in ["img/a.PNG", "clip.mov", "notes.txt"] {
            try Data([1]).write(to: project.appendingPathComponent("dataset/\(name)"))
        }
    }

    override func tearDown() { try? FileManager.default.removeItem(at: project) }

    private func makeCore(dryRun: Bool = false) -> FTDriveCore {
        FTDriveCore(driver: driver, platform: "ios", app: "com.example.app",
                    scenarioID: "T.S0010", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, tunables: RunTunables(),
                    visionClassifierProjectRoot: project, dryRun: dryRun,
                    fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ft-addmedia-test.json"),
                    emit: { [sink] in sink.add($0) })
    }

    private func steps(_ core: FTDriveCore) -> [DSLStepRecord] { core.finalRecord.scenes.flatMap(\.steps) }

    func testSendsTheResolvedDatasetFileAndRecordsTheStep() throws {
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        addMedia("img/a.PNG")
        addMedia("clip.mov")
        XCTAssertEqual(driver.added, [project.appendingPathComponent("dataset/img/a.PNG").path,
                                      project.appendingPathComponent("dataset/clip.mov").path])
        XCTAssertEqual(steps(core).map(\.description), ["addMedia \"img/a.PNG\"", "addMedia \"clip.mov\""])
        XCTAssertFalse(core.scenarioAborted)
    }

    func testAnUnsupportedExtensionFailsWithoutSending() throws {
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        addMedia("notes.txt")
        XCTAssertTrue(driver.added.isEmpty)
        XCTAssertTrue(core.scenarioAborted)
        guard case .failed(let reason) = try XCTUnwrap(steps(core).first).status else { return XCTFail() }
        XCTAssertTrue(reason.contains("unsupported file type"), reason)
    }

    func testAMissingFileFailsWithTheDataFileMessageAndSkipsTheRest() throws {
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        addMedia("missing.png")
        addMedia("clip.mov")
        XCTAssertTrue(driver.added.isEmpty)
        let recorded = steps(core)
        XCTAssertEqual(recorded.count, 2)
        guard case .failed(let reason) = recorded[0].status else { return XCTFail("\(recorded[0].status)") }
        XCTAssertTrue(reason.contains("not found"), reason)
        XCTAssertTrue(reason.contains(project.appendingPathComponent("dataset/missing.png").path), reason)
        guard case .skipped = recorded[1].status else { return XCTFail("中断後は skipped: \(recorded[1].status)") }
    }

    func testDryRunSendsNothingAndOnlyRecordsTheStep() {
        let core = makeCore(dryRun: true)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        addMedia("missing.png")
        XCTAssertTrue(driver.added.isEmpty)
        XCTAssertFalse(core.scenarioAborted)
        XCTAssertEqual(steps(core).map(\.description), ["addMedia \"missing.png\""])
    }

    func testADriverFailureIsClassifiedByTheErrorCaseNotTheMessage() throws {
        driver.error = DriverError.badResponse(status: 501, body: "anything at all")
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        addMedia("clip.mov")
        XCTAssertTrue(core.scenarioAborted)
        let step = try XCTUnwrap(steps(core).first)
        guard case .failed = step.status else { return XCTFail("\(step.status)") }
        let event = try XCTUnwrap(sink.events.first { $0.kind == "step" && $0.command == "addMedia" })
        XCTAssertEqual(event.failureKind, StepFailureKind.driverError.rawValue)
    }
}
