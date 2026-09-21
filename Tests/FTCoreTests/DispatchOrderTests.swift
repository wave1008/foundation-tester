import XCTest
import FTRemote

/// 機械をどの順で取るか(`DispatchOrder`)と、親が取ったロックを子へ引き渡す印
/// (`DispatchLockHandoff`)。**順序が全順序であること**がこの仕組みの前提なので、
/// 並びだけでなく「入力順を変えても同じ出力」まで等号で固定する。
final class DispatchOrderTests: XCTestCase {

    private func machine(_ name: String, _ host: String, _ uuid: String?) -> DispatchOrder.Machine {
        DispatchOrder.Machine(machine: name, host: host, hardwareUUID: uuid)
    }

    // MARK: - 順序

    func testKnownUUIDsSortAscending() {
        let sorted = DispatchOrder.sorted([
            machine("M1Max", "max.local", "C0FFEE00-0000-0000-0000-000000000000"),
            machine("M1Ultra", "ultra.local", "0A1B2C3D-0000-0000-0000-000000000000"),
            machine("M1mini", "mini.local", "7FFFFFFF-0000-0000-0000-000000000000"),
        ])
        XCTAssertEqual(sorted.map(\.machine), ["M1Ultra", "M1mini", "M1Max"])
    }

    /// **不明は最後尾**。引ける機械どうしの相対順は守る(1台の不明で順序付け全体を諦めない)
    func testUnknownUUIDsGoLastWhileKnownOnesKeepTheirOrder() {
        let sorted = DispatchOrder.sorted([
            machine("unknownB", "b.local", nil),
            machine("M1Max", "max.local", "C0FFEE00-0000-0000-0000-000000000000"),
            machine("unknownA", "a.local", nil),
            machine("M1Ultra", "ultra.local", "0A1B2C3D-0000-0000-0000-000000000000"),
        ])
        XCTAssertEqual(sorted.map(\.machine), ["M1Ultra", "M1Max", "unknownA", "unknownB"])
    }

    /// 不明どうしは host 昇順(エイリアスではなく host —— 機械ごとに違いうる名前で
    /// 順序を決めると、別の Mac から見た順序と食い違う)
    func testUnknownsAreOrderedByHostNotByAlias() {
        let sorted = DispatchOrder.sorted([
            machine("zulu", "alpha.local", nil),
            machine("alpha", "zulu.local", nil),
        ])
        XCTAssertEqual(sorted.map(\.host), ["alpha.local", "zulu.local"])
    }

    /// **同じ入力集合なら誰が呼んでも同じ並び**(順序付けの前提そのもの)。
    /// 入力の並びを全部試して出力が1つに畳まれることを見る
    func testTheOutputIsIndependentOfTheInputOrder() {
        let machines = [
            machine("M1Max", "max.local", "C0FFEE00-0000-0000-0000-000000000000"),
            machine("M1Ultra", "ultra.local", "0A1B2C3D-0000-0000-0000-000000000000"),
            machine("fresh", "fresh.local", nil),
        ]
        let expected = DispatchOrder.sorted(machines).map(\.machine)
        XCTAssertEqual(expected, ["M1Ultra", "M1Max", "fresh"])
        for permutation in Self.permutations(machines) {
            XCTAssertEqual(DispatchOrder.sorted(permutation).map(\.machine), expected,
                           "入力の並びで出力が変わる(全順序になっていない)")
        }
    }

    /// 同じ UUID・同じ host が2件(同じ Mac を指す別名)でも並びは決定的
    func testDuplicateKeysStillYieldADeterministicOrder() {
        let uuid = "0A1B2C3D-0000-0000-0000-000000000000"
        let forward = DispatchOrder.sorted([machine("zulu", "one.local", uuid),
                                            machine("alpha", "one.local", uuid)])
        let backward = DispatchOrder.sorted([machine("alpha", "one.local", uuid),
                                             machine("zulu", "one.local", uuid)])
        XCTAssertEqual(forward.map(\.machine), ["alpha", "zulu"])
        XCTAssertEqual(forward, backward)
    }

    func testEmptyAndSingleInputs() {
        XCTAssertEqual(DispatchOrder.sorted([]), [])
        let one = [machine("only", "only.local", nil)]
        XCTAssertEqual(DispatchOrder.sorted(one), one)
    }

    // MARK: - 印(親 → 子)

    /// **宛先が一致したときだけ true** —— 真偽値にすると、子孫へ継がれた印で別の宛先へ向かう子まで
    /// 取得を飛ばし、誰もロックを持たないまま走る
    func testTheHandoffMarkerOnlyMatchesItsOwnTarget() {
        let env = [DispatchLockHandoff.environmentKey:
                    DispatchLockHandoff.environmentValue(sshTarget: "tester@max.local")]
        XCTAssertTrue(DispatchLockHandoff.isHeldByParent(environment: env, sshTarget: "tester@max.local"))
        XCTAssertFalse(DispatchLockHandoff.isHeldByParent(environment: env, sshTarget: "tester@ultra.local"))
    }

    /// 印が無い / 空 = 親は取っていない(子は従来どおり自分で取る = 単発 run の縮退)
    func testNoMarkerMeansTheChildAcquiresOnItsOwn() {
        XCTAssertFalse(DispatchLockHandoff.isHeldByParent(environment: [:], sshTarget: "max.local"))
        XCTAssertFalse(DispatchLockHandoff.isHeldByParent(
            environment: [DispatchLockHandoff.environmentKey: ""], sshTarget: "max.local"))
    }

    /// 綴りは `FT_DISPATCH_TICKET` の隣(親と子が別プロセスなので型では守れない)
    func testTheEnvironmentKeyIsPinned() {
        XCTAssertEqual(DispatchLockHandoff.environmentKey, "FT_DISPATCH_LOCK_HELD")
    }

    private static func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        var result: [[T]] = []
        for index in items.indices {
            var rest = items
            let picked = rest.remove(at: index)
            for tail in permutations(rest) { result.append([picked] + tail) }
        }
        return result
    }
}
