import XCTest
@testable import FTCore

final class LastResultsStoreTests: XCTestCase {
    var stateDir: URL!

    override func setUpWithError() throws {
        stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LastResultsStoreTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir)
    }

    func testMissingDirReturnsEmptySet() {
        XCTAssertEqual(LastResultsStore.failedIDs(stateDir: stateDir), [])
    }

    func testRecordFailedAppearsInFailedIDs() {
        LastResultsStore.record(stateDir: stateDir, scenarioID: "Foo.bar", passed: false)
        XCTAssertEqual(LastResultsStore.failedIDs(stateDir: stateDir), ["Foo.bar"])
    }

    func testRecordPassedIsExcluded() {
        LastResultsStore.record(stateDir: stateDir, scenarioID: "Foo.bar", passed: true)
        XCTAssertEqual(LastResultsStore.failedIDs(stateDir: stateDir), [])
    }

    func testOverwriteFailedWithPassedRemovesFromFailedIDs() {
        LastResultsStore.record(stateDir: stateDir, scenarioID: "Foo.bar", passed: false)
        LastResultsStore.record(stateDir: stateDir, scenarioID: "Foo.bar", passed: true)
        XCTAssertEqual(LastResultsStore.failedIDs(stateDir: stateDir), [])
    }

    func testMultipleScenariosOnlyFailedOnesReturned() {
        LastResultsStore.record(stateDir: stateDir, scenarioID: "A.one", passed: false)
        LastResultsStore.record(stateDir: stateDir, scenarioID: "B.two", passed: true)
        LastResultsStore.record(stateDir: stateDir, scenarioID: "C.three", passed: false)
        XCTAssertEqual(LastResultsStore.failedIDs(stateDir: stateDir), ["A.one", "C.three"])
    }
}
