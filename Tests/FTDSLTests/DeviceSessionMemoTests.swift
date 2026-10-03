import XCTest
@testable import FTDSL
import FTCore

/// デバイスセッション(メモ + setUpDevice)の子側。親への通知イベントと、親が渡す `runSetUpDevice` への従い方を固定する。
final class DeviceSessionMemoTests: XCTestCase {

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ScenarioEvent] = []
        func add(_ event: ScenarioEvent) { lock.lock(); items.append(event); lock.unlock() }
        var events: [ScenarioEvent] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private final class NullDriver: AppDriver {
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
    }

    private func makeCore(sink: Sink, runSetUpDevice: Bool = true) -> FTDriveCore {
        let core = FTDriveCore(driver: NullDriver(), platform: "ios", app: "com.example.app",
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false, dryRun: true,
                               fingerprintCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                                   .appendingPathComponent("ft-memo-test.json"),
                               emit: { sink.add($0) })
        core.runSetUpDevice = runSetUpDevice
        return core
    }

    private func steps(_ core: FTDriveCore) -> [DSLStepRecord] {
        core.finalRecord.scenes.flatMap(\.steps)
    }

    private func setUpDeviceStatuses(_ sink: Sink) -> [String] {
        sink.events.filter { $0.kind == "deviceSetUp" }.compactMap(\.status)
    }

    func testRunSetUpDeviceFalseSkipsBodyAndEmitsNothing() {
        let sink = Sink()
        let core = makeCore(sink: sink, runSetUpDevice: false)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        var ran = false
        ftRunSetUpDevice { ran = true }
        XCTAssertFalse(ran)
        XCTAssertEqual(setUpDeviceStatuses(sink), [])
    }

    func testSetUpDeviceEmitsBeganThenPassedAndRecordsSection() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        ftRunSetUpDevice { writeMemo("k", "v") }
        XCTAssertEqual(setUpDeviceStatuses(sink), ["began", "passed"])
        XCTAssertEqual(steps(core).first?.section, "setUpDevice")
    }

    func testFailingSetUpDeviceEmitsFailed() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        ftRunSetUpDevice { core.scenarioAborted = true }
        XCTAssertEqual(setUpDeviceStatuses(sink), ["began", "failed"])
    }

    func testAlreadyAbortedScenarioDoesNotRunSetUpDevice() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        core.scenarioAborted = true
        var ran = false
        ftRunSetUpDevice { ran = true }
        XCTAssertFalse(ran)
        XCTAssertEqual(setUpDeviceStatuses(sink), [])
    }

    func testWriteMemoEmitsAndReadMemoReturnsLastValue() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        writeMemo("k", "first")
        writeMemo("k", "second")
        XCTAssertEqual(readMemo("k"), "second")
        let writes = sink.events.filter { $0.kind == "memoWrite" }
        XCTAssertEqual(writes.map { $0.memoKey }, ["k", "k"])
        XCTAssertEqual(writes.map { $0.memoValue }, ["first", "second"])
        XCTAssertEqual(steps(core).map(\.description),
                       ["writeMemo \"k\" = \"first\"", "writeMemo \"k\" = \"second\"", "readMemo \"k\" → \"second\""])
    }

    func testHandedOverMemoIsReadable() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        core.deviceMemo = ["k": ["a", "b"]]
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        XCTAssertEqual(readMemo("k"), "b")
    }

    func testReadMemoOfAbsentKeyReturnsEmptyWithNote() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        XCTAssertEqual(readMemo("nope"), "")
        let step = sink.events.last { $0.kind == "step" }
        XCTAssertEqual(step?.notes, [StepNote.memoKeyNotFound.rawValue])
        XCTAssertEqual(step?.status, "passed")
    }

    func testClearMemoEmptiesAndEmits() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        writeMemo("k", "v")
        clearMemo()
        XCTAssertEqual(readMemo("k"), "")
        XCTAssertEqual(sink.events.filter { $0.kind == "memoClear" }.count, 1)
    }

    func testStringMemoTextAsWritesAndReturnsTheString() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        XCTAssertEqual("hello".memoTextAs("g"), "hello")
        XCTAssertEqual(readMemo("g"), "hello")
    }

    private func element(label: String?, value: String?) -> FTElement {
        FTElement(selector: FTSelector.parse("#x"),
                  matched: ElementInfo(ref: 1, type: "textField", identifier: "x", label: label, value: value,
                                       placeholder: nil, enabled: true,
                                       frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 1))
    }

    /// 空のラベルは「無い」扱いで値へ進む(入力欄はラベル "" で値に文字を持つ)
    func testElementMemoTextAsSkipsEmptyLabel() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        element(label: "", value: "abc").memoTextAs("field")
        element(label: "Total", value: "9").memoTextAs("total")
        element(label: nil, value: nil).memoTextAs("blank")
        XCTAssertEqual(readMemo("field"), "abc")
        XCTAssertEqual(readMemo("total"), "Total")
        XCTAssertEqual(core.deviceMemo["blank"], [""])
        XCTAssertEqual(sink.events.filter { $0.kind == "memoWrite" }.compactMap(\.memoValue), ["abc", "Total", ""])
    }

    func testAbortedScenarioSkipsMemoCommandsAndEmitsNothing() {
        let sink = Sink()
        let core = makeCore(sink: sink)
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        core.scenarioAborted = true
        writeMemo("k", "v")
        clearMemo()
        XCTAssertEqual(readMemo("k"), "")
        XCTAssertTrue(sink.events.filter { $0.kind == "memoWrite" || $0.kind == "memoClear" }.isEmpty)
        XCTAssertTrue(core.deviceMemo.isEmpty)
        XCTAssertTrue(steps(core).allSatisfy {
            if case .skipped = $0.status { return true } else { return false }
        })
    }
}
