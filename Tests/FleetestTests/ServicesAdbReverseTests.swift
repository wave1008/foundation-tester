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

    /// 張れたものだけ控えに入る。張れず、転送の状態も読めないデバイス(不在・offline・通信断)は状態不明として起動を止める
    func testAddAllRecordsSuccessesAndStopsOnDevicesWhoseStateCannotBeRead() throws {
        var calls: [[String]] = []
        var logs: [String] = []
        let outcome = ServicesAdbReverse.addAll(
            serials: ["A", "B"], hostPorts: [8090, 9000], adb: "/adb",
            run: { argv in
                calls.append(argv)
                return argv[2] == "A" ? (0, "") : (1, "adb: device 'B' not found")
            },
            log: { logs.append($0) })
        XCTAssertEqual(outcome.entries, [.init(serial: "A", hostPort: 8090), .init(serial: "A", hostPort: 9000)])
        // A: list + 2 adds / B: list(失敗)+ ポートごとに add(失敗)+ list(失敗)
        XCTAssertEqual(calls.count, 8, "\(calls)")
        XCTAssertEqual(calls[0], ["/adb", "-s", "A", "reverse", "--list"])
        XCTAssertEqual(outcome.conflicts.count, 2)
        for conflict in outcome.conflicts {
            XCTAssertTrue(conflict.contains("device B: `adb reverse --no-rebind"), conflict)
            XCTAssertTrue(conflict.contains("adb: device 'B' not found") && conflict.contains("could not be read"), conflict)
        }
        XCTAssertFalse(logs.contains { $0.contains("cannot reach") }, "確認できないものを「届かない」と言わない: \(logs)")
        XCTAssertTrue(logs.contains { $0 == "→ services: adb reverse set (A tcp:8090, A tcp:9000)" }, "\(logs)")
    }

    /// 張れなかったが、一覧で転送が無いと確認できた = 警告(その端末のアプリは届かない)で起動は止めない
    func testAddFailureWithConfirmedAbsenceIsAWarning() {
        var logs: [String] = []
        let outcome = ServicesAdbReverse.addAll(
            serials: ["A"], hostPorts: [8090], adb: "/adb",
            run: { argv in argv.contains("--list") ? (0, "") : nil },
            log: { logs.append($0) })
        XCTAssertEqual(outcome, ServicesAdbReverse.Outcome())
        XCTAssertTrue(logs.contains { $0.hasPrefix("⚠️") && $0.contains("the device has no forward for tcp:8090") && $0.contains("cannot reach 127.0.0.1:8090") }, "\(logs)")
    }

    /// 既にある転送は上書きしない(--no-rebind)。一覧が取れずに張って既存に当たり、照会し直しても宛先が分からなければ衝突
    /// (同じ宛先と確認できないものは通さない)
    func testRebindFailureWithoutAConfirmedDestinationIsAConflict() throws {
        var logs: [String] = []
        let outcome = ServicesAdbReverse.addAll(serials: ["A"], hostPorts: [8090], adb: "/adb",
                                                run: { _ in (1, "error: cannot rebind existing socket") }, log: { logs.append($0) })
        XCTAssertEqual(outcome.entries, [])
        XCTAssertEqual(outcome.conflicts.count, 1)
        let conflict = try XCTUnwrap(outcome.conflicts.first)
        XCTAssertTrue(conflict.contains("device A: `adb reverse --no-rebind tcp:8090 tcp:8090` failed") && conflict.contains("could not be read"), conflict)
        XCTAssertTrue(conflict.contains("`adb -s A reverse --list`"), conflict)
        XCTAssertFalse(logs.contains { $0.contains("cannot reach") }, "宛先が分からないので届く・届かないは言わない: \(logs)")
    }

    /// 一覧が取れずに張って既存に当たっても、照会し直して同じ宛先と確認できれば触らずに通す(控えにも書かない)
    func testRebindFailureConfirmedSameDestinationIsLeftAlone() {
        var calls: [[String]] = []
        var logs: [String] = []
        let outcome = ServicesAdbReverse.addAll(
            serials: ["A"], hostPorts: [8090], adb: "/adb",
            run: { argv in
                calls.append(argv)
                if argv.contains("--list") { return calls.count == 1 ? (1, "error: closed") : (0, "UsbFfs tcp:8090 tcp:8090\n") }
                return (1, "error: cannot rebind existing socket")
            },
            log: { logs.append($0) })
        XCTAssertEqual(outcome, ServicesAdbReverse.Outcome())
        XCTAssertEqual(calls.count, 3, "list → add → list: \(calls)")
        XCTAssertTrue(logs.contains { $0.contains("A already forwards tcp:8090 to tcp:8090; left as it is") }, "\(logs)")
    }

    /// `adb reverse --list` の行 = `<transport> tcp:<デバイス側> tcp:<ホスト側>`。先頭の語は見ない・形の違う行は捨てる
    func testParseList() {
        let map = ServicesAdbReverse.parseList("UsbFfs tcp:8090 tcp:9000\nhost-5 tcp:18080 tcp:18080\ngarbage\nX localabstract:foo tcp:1\n")
        XCTAssertEqual(map, [8090: "tcp:9000", 18080: "tcp:18080"])
    }

    /// 同じ宛先(tcp:P → tcp:P)が既にあれば触らない: 張らず・控えにも書かない(`down` で外さない)
    func testSameDestinationIsLeftAloneAndNotRecorded() {
        var calls: [[String]] = []
        var logs: [String] = []
        let outcome = ServicesAdbReverse.addAll(
            serials: ["A"], hostPorts: [8090, 9000], adb: "/adb",
            run: { argv in calls.append(argv); return argv.contains("--list") ? (0, "UsbFfs tcp:8090 tcp:8090\n") : (0, "") },
            log: { logs.append($0) })
        XCTAssertEqual(outcome.entries, [.init(serial: "A", hostPort: 9000)])
        XCTAssertEqual(outcome.conflicts, [])
        XCTAssertFalse(calls.contains { $0.contains("--no-rebind") && $0.contains("tcp:8090") }, "\(calls)")
        XCTAssertTrue(logs.contains { $0.contains("A already forwards tcp:8090 to tcp:8090; left as it is") }, "\(logs)")
    }

    /// 別の宛先へ既に転送があれば衝突(呼び手が起動を止める): 張らず・外し方を添える。他のポートは普通に張る
    func testDifferentDestinationIsAConflict() throws {
        var calls: [[String]] = []
        let outcome = ServicesAdbReverse.addAll(
            serials: ["A"], hostPorts: [8090, 9000], adb: "/adb",
            run: { argv in calls.append(argv); return argv.contains("--list") ? (0, "UsbFfs tcp:8090 tcp:3000\n") : (0, "") },
            log: { _ in })
        XCTAssertEqual(outcome.entries, [.init(serial: "A", hostPort: 9000)])
        XCTAssertEqual(outcome.conflicts.count, 1)
        let conflict = try XCTUnwrap(outcome.conflicts.first)
        XCTAssertTrue(conflict.contains("device A already forwards tcp:8090 to tcp:3000"), conflict)
        XCTAssertTrue(conflict.contains("`adb -s A reverse --remove tcp:8090`"), conflict)
        XCTAssertFalse(calls.contains { $0.contains("--no-rebind") && $0.contains("tcp:8090") }, "\(calls)")
    }

    func testAddAllWithoutAdbWarnsAndRunsNothing() {
        var ran = 0
        var logs: [String] = []
        let outcome = ServicesAdbReverse.addAll(serials: ["A"], hostPorts: [8090], adb: nil,
                                                run: { _ in ran += 1; return (0, "") }, log: { logs.append($0) })
        XCTAssertEqual(outcome, ServicesAdbReverse.Outcome())
        XCTAssertEqual(ran, 0)
        XCTAssertTrue(logs.contains { $0.contains("adb is not installed, so no `adb reverse` was set for A") }, "\(logs)")
    }

    func testAddAllWithNoSerialsOrPortsDoesNothing() {
        var ran = 0
        var logs: [String] = []
        // adb が無い機械でも、張る相手(シリアル × ポート)が無ければ何も言わない(警告は張れないときだけ)
        XCTAssertEqual(ServicesAdbReverse.addAll(serials: [], hostPorts: [8090], adb: nil, run: { _ in ran += 1; return (0, "") }, log: { logs.append($0) }), ServicesAdbReverse.Outcome())
        XCTAssertEqual(ServicesAdbReverse.addAll(serials: ["A"], hostPorts: [], adb: nil, run: { _ in ran += 1; return (0, "") }, log: { logs.append($0) }), ServicesAdbReverse.Outcome())
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
