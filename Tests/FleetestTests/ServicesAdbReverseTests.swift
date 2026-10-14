import FTServices
import Foundation
import XCTest
@testable import fleetest

/// Android 実機への `adb reverse`(張る・外す)。adb は差し替え口で受ける = デバイスに触れない。
final class ServicesAdbReverseTests: XCTestCase {
    func testArguments() {
        XCTAssertEqual(ServicesAdbReverse.addArguments(adb: "/adb", serial: "14141JEC204922", hostPort: 8090),
                       ["/adb", "-s", "14141JEC204922", "reverse", "--no-rebind", "tcp:8090", "tcp:8090"])
        XCTAssertEqual(ServicesAdbReverse.removeArguments(adb: "/adb", serial: "14141JEC204922", hostPort: 8090),
                       ["/adb", "-s", "14141JEC204922", "reverse", "--remove", "tcp:8090"])
    }

    func testAddAllKeepsOnlySuccessfulEntriesAndWarnsForTheRest() {
        var calls: [[String]] = []
        var logs: [String] = []
        let entries = ServicesAdbReverse.addAll(
            serials: ["A", "B"], hostPorts: [8090, 9000], adb: "/adb",
            run: { argv in
                calls.append(argv)
                return argv[2] == "A" ? (0, "") : (1, "adb: device 'B' not found")
            },
            log: { logs.append($0) })
        XCTAssertEqual(entries, [.init(serial: "A", hostPort: 8090), .init(serial: "A", hostPort: 9000)])
        XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(logs.contains { $0.contains("`adb -s B reverse --no-rebind tcp:8090 tcp:8090` failed (exit 1: adb: device 'B' not found)") }, "\(logs)")
        XCTAssertTrue(logs.contains { $0.contains("cannot reach 127.0.0.1:8090") }, "\(logs)")
        XCTAssertTrue(logs.contains { $0 == "→ services: adb reverse set (A tcp:8090, A tcp:9000)" }, "\(logs)")
    }

    /// 既にある転送は上書きしない(--no-rebind)。失敗の警告には外し方を添える
    func testExistingForwardIsNotRebound() {
        var logs: [String] = []
        let entries = ServicesAdbReverse.addAll(serials: ["A"], hostPorts: [8090], adb: "/adb",
                                                run: { _ in (1, "error: cannot rebind existing socket") }, log: { logs.append($0) })
        XCTAssertEqual(entries, [])
        XCTAssertTrue(logs.contains { $0.contains("the device already forwards tcp:8090 — remove it with `adb -s A reverse --remove tcp:8090` if it is stale") }, "\(logs)")
    }

    func testAddAllWithoutAdbWarnsAndRunsNothing() {
        var ran = 0
        var logs: [String] = []
        let entries = ServicesAdbReverse.addAll(serials: ["A"], hostPorts: [8090], adb: nil,
                                                run: { _ in ran += 1; return (0, "") }, log: { logs.append($0) })
        XCTAssertEqual(entries, [])
        XCTAssertEqual(ran, 0)
        XCTAssertTrue(logs.contains { $0.contains("adb is not installed, so no `adb reverse` was set for A") }, "\(logs)")
    }

    func testAddAllWithNoSerialsOrPortsDoesNothing() {
        var ran = 0
        var logs: [String] = []
        // adb が無い機械でも、張る相手(シリアル × ポート)が無ければ何も言わない(警告は張れないときだけ)
        XCTAssertEqual(ServicesAdbReverse.addAll(serials: [], hostPorts: [8090], adb: nil, run: { _ in ran += 1; return (0, "") }, log: { logs.append($0) }), [])
        XCTAssertEqual(ServicesAdbReverse.addAll(serials: ["A"], hostPorts: [], adb: nil, run: { _ in ran += 1; return (0, "") }, log: { logs.append($0) }), [])
        XCTAssertEqual(ran, 0)
        XCTAssertEqual(logs, [])
    }

    func testRemoveAllReportsFailuresButRemovesEverything() {
        var calls: [[String]] = []
        var logs: [String] = []
        ServicesAdbReverse.removeAll([.init(serial: "A", hostPort: 8090), .init(serial: "B", hostPort: 8090)], adb: "/adb",
                                     run: { argv in calls.append(argv); return argv[2] == "A" ? (0, "") : nil },
                                     log: { logs.append($0) })
        XCTAssertEqual(calls, [["/adb", "-s", "A", "reverse", "--remove", "tcp:8090"], ["/adb", "-s", "B", "reverse", "--remove", "tcp:8090"]])
        XCTAssertEqual(logs, ["⚠️ services: `adb -s B reverse --remove tcp:8090` failed (timed out)"])
    }
}
