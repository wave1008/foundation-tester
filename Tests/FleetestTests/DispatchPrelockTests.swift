// 親(fan-out)が子より先に、機械の全順序どおりに1台ずつ dispatch.lock を取る配線。
//
// **この経路は緑の run では1度も実行されない** —— 競合が起きないと順序も待ちも観測できないので、
// フル E2E を回しても情報はゼロ。代わりに `DispatchPrelock.Actions`(取得・解放の差し替え口)へ
// 偽のランナー群を注入し、「2つ目の run が来たときに順序どおりに待つ」ことを単体で通す。
// 陽性対照(順序付けが無ければ同じ2台で循環が作れる)も同じ偽ランナーで撃つ。

import FTRemote
import Foundation
import XCTest
@testable import fleetest

/// 偽のランナー群。`dispatch.lock` の本質(ホスト1台につき保持者は1人・解放されるまで待つ)だけを持つ
private final class FakeRunnerFleet: @unchecked Sendable {
    private let condition = NSCondition()
    private var holders: [String: String] = [:]
    private var acquisitions: [String] = []
    /// 取得が**待ちに入った**瞬間の通知(テストが sleep で間合いを測らないための口)
    var onBlocked: ((_ owner: String, _ host: String) -> Void)?

    /// 取れたら true。`waitSeconds` 以内に取れなければ false(実機の `--wait-lock` 切れと同じ)
    func acquire(host: String, owner: String, waitSeconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(waitSeconds)
        condition.lock()
        var announced = false
        while holders[host] != nil {
            if !announced {
                announced = true
                condition.unlock()
                onBlocked?(owner, host)
                condition.lock()
                continue
            }
            if !condition.wait(until: deadline) {
                condition.unlock()
                return false
            }
        }
        holders[host] = owner
        acquisitions.append("\(owner):\(host)")
        condition.unlock()
        return true
    }

    func release(host: String, owner: String) {
        condition.lock()
        if holders[host] == owner { holders[host] = nil }
        condition.broadcast()
        condition.unlock()
    }

    var log: [String] {
        condition.lock()
        defer { condition.unlock() }
        return acquisitions
    }

    var heldHosts: Set<String> {
        condition.lock()
        defer { condition.unlock() }
        return Set(holders.keys)
    }
}

final class DispatchPrelockTests: XCTestCase {

    private static let uuids = [
        "M1Ultra": "0A1B2C3D-0000-0000-0000-000000000000",
        "M1mini": "7FFFFFFF-0000-0000-0000-000000000000",
        "M1Max": "C0FFEE00-0000-0000-0000-000000000000",
    ]

    private static func host(_ machine: String) -> String { "\(machine.lowercased()).local" }

    /// 「キャッシュに載っている」前提のテスト用。採りに行ったら落とす
    private static func noProbe(_ machine: DispatchOrder.Machine) throws -> String? {
        XCTFail("キャッシュに UUID がある機械へ採取しに行った: \(machine.machine)")
        return nil
    }

    private static func keys(_ labels: [String], unknown: Set<String> = []) -> [DispatchOrder.Machine] {
        labels.map { label in
            DispatchOrder.Machine(machine: label, host: host(label),
                                  hardwareUUID: unknown.contains(label) ? nil : uuids[label])
        }
    }

    // MARK: - 取る順序

    /// **UUID 昇順に、1台ずつ**取る(並列に撃っていない = 呼び出し順がそのまま記録される)
    func testTheParentAcquiresOneAtATimeInHardwareUUIDOrder() {
        let recorder = Recorder()
        let prelock = DispatchPrelock(actions: DispatchPrelock.Actions(
            keys: { Self.keys($0) },
            probeHardwareUUID: Self.noProbe,
            acquire: { machine in
                recorder.append("acquire:\(machine.machine)")
                return (machine.host, { recorder.append("release:\(machine.machine)") })
            },
            log: { _ in }))

        // 入力の並びは UUID 順とわざと食い違わせる
        prelock.acquireInOrder(machines: ["M1Max", "M1mini", "M1Ultra"])
        XCTAssertEqual(recorder.entries, ["acquire:M1Ultra", "acquire:M1mini", "acquire:M1Max"])
        XCTAssertEqual(prelock.markers, ["M1Ultra": Self.host("M1Ultra"),
                                         "M1mini": Self.host("M1mini"),
                                         "M1Max": Self.host("M1Max")])

        // 解放は取った逆順で、握ったぶんだけ
        prelock.releaseAll()
        XCTAssertEqual(Array(recorder.entries.suffix(3)),
                       ["release:M1Max", "release:M1mini", "release:M1Ultra"])
        recorder.reset()
        prelock.releaseAll()
        XCTAssertEqual(recorder.entries, [], "二重解放している")
    }

    /// 採りに行っても UUID を引けない機械は最後尾(接続したことのある機械どうしの保護は失わない)
    func testMachinesWithoutACachedUUIDAreTakenLast() {
        let recorder = Recorder()
        let prelock = DispatchPrelock(actions: DispatchPrelock.Actions(
            keys: { Self.keys($0, unknown: ["M1Max"]) },
            // 接続はできたが読めなかった(= 採りに行っても不明のまま)
            probeHardwareUUID: { _ in nil },
            acquire: { machine in
                recorder.append(machine.machine)
                return (machine.host, {})
            },
            log: { _ in }))
        prelock.acquireInOrder(machines: ["M1Max", "M1mini", "M1Ultra"])
        XCTAssertEqual(recorder.entries, ["M1Ultra", "M1mini", "M1Max"])
        prelock.releaseAll()
    }

    // MARK: - 順序を決める前の UUID 採取

    /// **定常状態で往復を1本も増やさない** —— キャッシュに UUID がある機械へは接続しに行かない。
    /// 呼び出し回数を等号で固定する(「念のため全機械を叩く」実装になったら落ちる)
    func testMachinesWithACachedUUIDAreNeverProbed() {
        let recorder = Recorder()
        let prelock = DispatchPrelock(actions: DispatchPrelock.Actions(
            keys: { Self.keys($0) },
            probeHardwareUUID: { machine in
                recorder.append("probe:\(machine.machine)")
                return Self.uuids[machine.machine]
            },
            acquire: { machine in
                recorder.append("acquire:\(machine.machine)")
                return (machine.host, {})
            },
            log: { _ in }))

        prelock.acquireInOrder(machines: ["M1Max", "M1mini", "M1Ultra"])
        XCTAssertEqual(recorder.entries,
                       ["acquire:M1Ultra", "acquire:M1mini", "acquire:M1Max"],
                       "キャッシュに載っている機械へ ssh を足している")
        prelock.releaseAll()
    }

    /// **キャッシュに無い機械だけ**採りに行く(載っている機械は飛ばす)
    func testOnlyTheMachinesMissingFromTheCacheAreProbed() {
        let recorder = Recorder()
        let prelock = DispatchPrelock(actions: DispatchPrelock.Actions(
            keys: { Self.keys($0, unknown: ["M1Max", "M1Ultra"]) },
            probeHardwareUUID: { machine in
                recorder.append(machine.machine)
                return Self.uuids[machine.machine]
            },
            acquire: { machine in return (machine.host, {}) },
            log: { _ in }))

        prelock.acquireInOrder(machines: ["M1Max", "M1mini", "M1Ultra"])
        XCTAssertEqual(recorder.entries, ["M1Max", "M1Ultra"],
                       "キャッシュの有無で採取先を絞れていない")
        prelock.releaseAll()
    }

    /// 採れた値が**その run の順序に効く** —— 採らなければ最後尾だった機械が先頭に来る
    /// (`testMachinesWithoutACachedUUIDAreTakenLast` が「採れなければ最後尾」の対照)
    func testAProbedUUIDDecidesTheOrderOfThisRun() {
        let recorder = Recorder()
        let prelock = DispatchPrelock(actions: DispatchPrelock.Actions(
            // 最小の UUID を持つ機械(= 本来は先頭)だけキャッシュに無い
            keys: { Self.keys($0, unknown: ["M1Ultra"]) },
            probeHardwareUUID: { machine in Self.uuids[machine.machine] },
            acquire: { machine in
                recorder.append(machine.machine)
                return (machine.host, {})
            },
            log: { _ in }))

        prelock.acquireInOrder(machines: ["M1Max", "M1mini", "M1Ultra"])
        XCTAssertEqual(recorder.entries, ["M1Ultra", "M1mini", "M1Max"],
                       "採った UUID が順序に反映されていない(不明のまま最後尾になっている)")
        prelock.releaseAll()
    }

    /// **採取に失敗しても run は止まらない**(接続できない機械は不明のまま最後尾で、取得は続く)
    func testAFailedProbeLeavesTheMachineUnknownAndTheRunContinues() {
        let recorder = Recorder()
        var logged: [String] = []
        let prelock = DispatchPrelock(actions: DispatchPrelock.Actions(
            keys: { Self.keys($0, unknown: ["M1Ultra"]) },
            probeHardwareUUID: { _ in
                throw RemoteDispatchError.remoteSetupFailed("cannot reach the host over ssh")
            },
            acquire: { machine in
                recorder.append(machine.machine)
                return (machine.host, {})
            },
            log: { logged.append($0) }))

        prelock.acquireInOrder(machines: ["M1Max", "M1mini", "M1Ultra"])
        XCTAssertEqual(recorder.entries, ["M1mini", "M1Max", "M1Ultra"],
                       "採れなかった機械が最後尾に居ない / 取得が止まっている")
        XCTAssertEqual(Set(prelock.markers.keys), ["M1Ultra", "M1mini", "M1Max"])
        XCTAssertEqual(logged, [
            "warning: could not determine the hardware UUID of m1ultra.local"
            + " — this run cannot put the machines in a global order,"
            + " so it has no protection against two runs waiting on each other"])
        prelock.releaseAll()
    }

    /// 宛先が1つの run では採りに行かない(1台では循環が作れず、順序に意味が無い)・警告も出さない
    func testASingleDestinationIsNeitherProbedNorWarnedAbout() {
        var logged: [String] = []
        let prelock = DispatchPrelock(actions: DispatchPrelock.Actions(
            keys: { Self.keys($0, unknown: ["M1Max"]) },
            probeHardwareUUID: { machine in
                XCTFail("1台しか居ない run で採りに行った: \(machine.machine)")
                return nil
            },
            acquire: { machine in return (machine.host, {}) },
            log: { logged.append($0) }))

        prelock.acquireInOrder(machines: ["M1Max"])
        XCTAssertEqual(logged, [])
        prelock.releaseAll()
    }

    // MARK: - 順序が確定しないことの警告

    /// **不明が残る run では1行だけ言う**(文言は完全一致で固定)。
    /// 不明は host 昇順に並ぶので、並べ方も決定的
    func testTheWarningNamesEveryMachineWhoseUUIDIsStillUnknown() {
        var logged: [String] = []
        let prelock = DispatchPrelock(actions: DispatchPrelock.Actions(
            keys: { Self.keys($0, unknown: ["M1Ultra", "M1Max"]) },
            // 接続はできたが読めなかった(ioreg の出力形式が変わった等)
            probeHardwareUUID: { _ in nil },
            acquire: { machine in return (machine.host, {}) },
            log: { logged.append($0) }))

        prelock.acquireInOrder(machines: ["M1Max", "M1mini", "M1Ultra"])
        XCTAssertEqual(logged, [
            "warning: could not determine the hardware UUID of m1max.local, m1ultra.local"
            + " — this run cannot put the machines in a global order,"
            + " so it has no protection against two runs waiting on each other"])
        prelock.releaseAll()
    }

    /// **UUID が全部揃っていれば黙る**(毎ディスパッチ鳴り続ける警告にしない)
    func testNoWarningWhenEveryMachineHasAUUID() {
        var logged: [String] = []
        let prelock = DispatchPrelock(actions: DispatchPrelock.Actions(
            keys: { Self.keys($0) },
            probeHardwareUUID: Self.noProbe,
            acquire: { machine in return (machine.host, {}) },
            log: { logged.append($0) }))

        prelock.acquireInOrder(machines: ["M1Max", "M1mini", "M1Ultra"])
        XCTAssertEqual(logged, [])
        prelock.releaseAll()
    }

    // MARK: - 取れなかった機械

    /// **印が載るのは、親がその機械のロックを取れたときだけ**。取れなかった機械は飛ばし、
    /// 残りはそのまま取り切る(1台の失敗で run ごと止めない)
    func testOnlyTheMachinesWeLockedGetTheHandoffMarker() {
        var logged: [String] = []
        let prelock = DispatchPrelock(actions: DispatchPrelock.Actions(
            keys: { Self.keys($0) },
            probeHardwareUUID: Self.noProbe,
            acquire: { machine in
                guard machine.machine != "M1mini" else {
                    throw RemoteDispatchError.remoteSetupFailed("held by someone else")
                }
                return (machine.host, {})
            },
            log: { logged.append($0) }))

        prelock.acquireInOrder(machines: ["M1Ultra", "M1mini", "M1Max"])
        XCTAssertEqual(Set(prelock.markers.keys), ["M1Ultra", "M1Max"])
        XCTAssertNil(prelock.markers["M1mini"], "取れていない機械の子に印を渡している")
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].contains(Self.host("M1mini")), "どの機械を飛ばしたか言っていない")
        prelock.releaseAll()
    }

    /// 同じ Mac を指す別名が2つ並んでも取得は1回(2度目は自分の握ったロックを待って詰む)
    func testAliasesOfOneMachineShareASingleLock() {
        let recorder = Recorder()
        let uuid = Self.uuids["M1Max"]!
        let prelock = DispatchPrelock(actions: DispatchPrelock.Actions(
            keys: { labels in
                labels.map { DispatchOrder.Machine(machine: $0, host: "max.local", hardwareUUID: uuid) }
            },
            probeHardwareUUID: Self.noProbe,
            acquire: { machine in
                recorder.append(machine.machine)
                return (machine.host, {})
            },
            log: { _ in }))
        prelock.acquireInOrder(machines: ["max", "max-alias"])
        XCTAssertEqual(recorder.entries, ["max"])
        XCTAssertEqual(prelock.markers, ["max": "max.local", "max-alias": "max.local"])
        prelock.releaseAll()
    }

    func testNoRemoteMachinesIsANoOp() {
        let recorder = Recorder()
        let prelock = DispatchPrelock(actions: DispatchPrelock.Actions(
            keys: { Self.keys($0) },
            probeHardwareUUID: Self.noProbe,
            acquire: { machine in
                recorder.append(machine.machine)
                return (machine.host, {})
            },
            log: { _ in }))
        prelock.acquireInOrder(machines: [])
        XCTAssertEqual(recorder.entries, [])
        XCTAssertEqual(prelock.markers, [:])
    }

    /// **手元も他の機械と同じくロックを取る**(2026-09-21)—— 落とすと fan-out の local 枠だけが
    /// ロック無しで走る。重複だけを畳み、並びは入力のまま(順序を決めるのは `DispatchOrder`)
    func testMachinesToLockKeepsLocalAndDropsOnlyDuplicates() {
        XCTAssertEqual(DispatchPrelock.machinesToLock(["local", "M1Max", "M1Max", "local", "M1Ultra"]),
                       ["local", "M1Max", "M1Ultra"])
    }

    /// **手元も他の機械と同じ全順序に並び、local の子にも印が渡る**(2026-09-21)。
    /// 印の綴りは `LocalDispatchLock` が読むものと同じ1つ —— 違うと local の子が自分で
    /// 取りに行き、**親が握っているロックを待って詰む**
    func testTheLocalEntryIsLockedAndHandedOffLikeAnyOtherMachine() {
        let recorder = Recorder()
        let localUUID = "00000000-0000-0000-0000-00000000000A"  // M1Max より小さい = 先頭に来る
        let prelock = DispatchPrelock(actions: DispatchPrelock.Actions(
            keys: { labels in
                labels.map { label in
                    DispatchOrder.Machine(
                        machine: label,
                        host: label == "local" ? "my-mac" : Self.host(label),
                        hardwareUUID: label == "local" ? localUUID : Self.uuids[label])
                }
            },
            probeHardwareUUID: Self.noProbe,
            acquire: { machine in
                recorder.append(machine.machine)
                let marker = machine.machine == "local"
                    ? DispatchLockHandoff.localTarget : machine.host
                return (marker, { recorder.append("release:\(machine.machine)") })
            },
            log: { _ in }))

        prelock.acquireInOrder(machines: DispatchPrelock.machinesToLock(["M1Max", "local"]))
        XCTAssertEqual(recorder.entries, ["local", "M1Max"], "手元が全順序に並んでいない")

        let childEnv = DispatchTicketIssuer.childEnvironment(
            ticket: DispatchTicket(requestedAtMillis: 1, issuer: "alice", group: "G"),
            lockHeldTarget: prelock.markers["local"], base: [:])
        XCTAssertTrue(LocalDispatchLock.parentHoldsTheLock(environment: childEnv),
                      "local の子が親の印を読めない(子が自分で取りに行って詰む)")
        prelock.releaseAll()
        XCTAssertEqual(Array(recorder.entries.suffix(2)), ["release:M1Max", "release:local"])
    }

    // MARK: - 2つ目の run(この経路の存在理由)

    /// **2つ目の run は列の先頭で待ち、1つ目が外してから同じ順序で取り切る**。
    /// 入力の並びは run ごとに逆にしてある —— それでも取る順序は `DispatchOrder` が揃える
    func testASecondRunWaitsAtTheHeadOfTheOrderInsteadOfDeadlocking() {
        let fleet = FakeRunnerFleet()
        let blocked = expectation(description: "B は先頭の機械で待つ")
        blocked.assertForOverFulfill = false
        fleet.onBlocked = { owner, host in
            if owner == "B", host == Self.host("M1Ultra") { blocked.fulfill() }
        }
        let runA = DispatchPrelock(actions: Self.fleetActions(fleet: fleet, owner: "A"))
        let runB = DispatchPrelock(actions: Self.fleetActions(fleet: fleet, owner: "B"))

        runA.acquireInOrder(machines: ["M1Max", "M1Ultra"])
        XCTAssertEqual(fleet.log, ["A:\(Self.host("M1Ultra"))", "A:\(Self.host("M1Max"))"])

        let finished = expectation(description: "B が取り切る")
        DispatchQueue.global().async {
            runB.acquireInOrder(machines: ["M1Ultra", "M1Max"])
            finished.fulfill()
        }
        wait(for: [blocked], timeout: 10)
        XCTAssertEqual(fleet.heldHosts, [Self.host("M1Ultra"), Self.host("M1Max")],
                       "A が握っている間に B が横取りしている")

        runA.releaseAll()
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(Set(runB.markers.keys), ["M1Ultra", "M1Max"])
        XCTAssertEqual(fleet.log, ["A:\(Self.host("M1Ultra"))", "A:\(Self.host("M1Max"))",
                                   "B:\(Self.host("M1Ultra"))", "B:\(Self.host("M1Max"))"])
        runB.releaseAll()
        XCTAssertEqual(fleet.heldHosts, [])
    }

    /// **陽性対照**: 順序付けが無い(= 子が機械ごとに勝手な順で取りに行く)形なら、
    /// 同じ2台で循環が作れて両方とも取れない。上のテストが「常に成功する仕掛け」でないことの witness
    func testWithoutAGlobalOrderTheSameTwoMachinesDeadlock() {
        let fleet = FakeRunnerFleet()
        let first = Self.host("M1Ultra")
        let second = Self.host("M1Max")
        let aTookFirst = DispatchSemaphore(value: 0)
        let bTookSecond = DispatchSemaphore(value: 0)
        var aGotSecond = true
        var bGotFirst = true
        let done = expectation(description: "両者が諦める")
        done.expectedFulfillmentCount = 2

        DispatchQueue.global().async {
            XCTAssertTrue(fleet.acquire(host: first, owner: "A", waitSeconds: 5))
            aTookFirst.signal()
            bTookSecond.wait()
            aGotSecond = fleet.acquire(host: second, owner: "A", waitSeconds: 0.5)
            done.fulfill()
        }
        DispatchQueue.global().async {
            XCTAssertTrue(fleet.acquire(host: second, owner: "B", waitSeconds: 5))
            bTookSecond.signal()
            aTookFirst.wait()
            bGotFirst = fleet.acquire(host: first, owner: "B", waitSeconds: 0.5)
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        XCTAssertFalse(aGotSecond, "循環が再現していない(陽性対照になっていない)")
        XCTAssertFalse(bGotFirst, "循環が再現していない(陽性対照になっていない)")
    }

    private static func fleetActions(fleet: FakeRunnerFleet, owner: String) -> DispatchPrelock.Actions {
        DispatchPrelock.Actions(
            keys: { keys($0) },
            probeHardwareUUID: noProbe,
            acquire: { machine in
                guard fleet.acquire(host: machine.host, owner: owner, waitSeconds: 10) else {
                    throw RemoteDispatchError.remoteSetupFailed("wait-lock expired")
                }
                return (machine.host, { fleet.release(host: machine.host, owner: owner) })
            },
            log: { _ in })
    }

    /// 取得・解放の呼び出し順を記録する(別スレッドからは触らない)
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ item: String) {
            lock.lock(); defer { lock.unlock() }
            items.append(item)
        }
        func reset() {
            lock.lock(); defer { lock.unlock() }
            items.removeAll()
        }
        var entries: [String] {
            lock.lock(); defer { lock.unlock() }
            return items
        }
    }
}
