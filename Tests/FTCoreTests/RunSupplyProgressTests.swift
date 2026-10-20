// RunSupplyProgress(run の準備中の端末ごとの供給の段階。docs/design.md §18.1)の検証。
// 守るもの: ①snapshot は名前順(共有の段階が先頭)②同じ内容への書き込みは通知しない
// ③クリアは行を消して通知する ④reporter は step nil を消去に写す ⑤通知はロックの外(通知の中で snapshot を読める)。

import XCTest
@testable import FTCore

final class RunSupplyProgressTests: XCTestCase {

    func testSnapshotIsSortedByNameWithTheSharedStageFirst() {
        let box = RunSupplyProgress()
        box.set(name: "iPhone 17-02", platform: "ios", step: .bridge)
        box.set(name: "Pixel 9-01", platform: "android", step: .booting)
        box.set(name: "", platform: "ios", step: .runnerBuild)
        box.set(name: "iPhone 17-01", platform: "ios", step: .ready)
        XCTAssertEqual(box.snapshot().map(\.name), ["", "Pixel 9-01", "iPhone 17-01", "iPhone 17-02"])
        XCTAssertEqual(box.snapshot().first,
                       RunProgressSupply(name: "", platform: "ios", step: "runnerBuild"))
    }

    func testSettingTheSameRowTwiceNotifiesOnce() {
        let box = RunSupplyProgress()
        let calls = LockedValue(0)
        box.setOnChange(owner: Self.ownerA) { calls.withLock { $0 += 1 } }
        box.set(name: "iPhone 17-01", platform: "ios", step: .booting)
        box.set(name: "iPhone 17-01", platform: "ios", step: .booting)
        XCTAssertEqual(calls.value, 1)
        box.set(name: "iPhone 17-01", platform: "ios", step: .bridge)
        XCTAssertEqual(calls.value, 2, "段階が進めば通知する")
        XCTAssertEqual(box.snapshot().map(\.step), ["bridge"], "同じ名前は1行(上書き)")
    }

    func testClearRunnerBuildRemovesOnlyTheSharedRow() {
        let box = RunSupplyProgress()
        let calls = LockedValue(0)
        box.set(name: "", platform: "ios", step: .runnerBuild)
        box.set(name: "iPhone 17-01", platform: "ios", step: .ready)
        box.setOnChange(owner: Self.ownerA) { calls.withLock { $0 += 1 } }
        box.clearRunnerBuild()
        XCTAssertEqual(box.snapshot().map(\.name), ["iPhone 17-01"], "端末の行は ready でも残る")
        XCTAssertEqual(calls.value, 1)
        box.clearRunnerBuild()
        XCTAssertEqual(calls.value, 1, "既に無い行のクリアは通知しない")
    }

    func testReporterMapsNilStepToClear() {
        let box = RunSupplyProgress()
        let report = box.reporter
        report("Pixel 9-01", "android", .installing)
        XCTAssertEqual(box.snapshot(), [RunProgressSupply(name: "Pixel 9-01", platform: "android", step: "installing")])
        report("Pixel 9-01", "android", nil)
        XCTAssertEqual(box.snapshot(), [])
    }

    func testHandlerMayReadTheSnapshotWithoutDeadlock() {
        let box = RunSupplyProgress()
        let seen = LockedValue<[RunProgressSupply]>([])
        box.setOnChange(owner: Self.ownerA) { seen.value = box.snapshot() }
        box.set(name: "iPhone 17-01", platform: "ios", step: .booting)
        XCTAssertEqual(seen.value.map(\.step), ["booting"])
    }

    func testRemovingTheHandlerStopsNotifications() {
        let box = RunSupplyProgress()
        let calls = LockedValue(0)
        box.setOnChange(owner: Self.ownerA) { calls.withLock { $0 += 1 } }
        box.releaseOnChange(owner: Self.ownerA)
        box.set(name: "iPhone 17-01", platform: "ios", step: .booting)
        XCTAssertEqual(calls.value, 0)
    }

    /// **先に退いた書き手の後片付けが、引き継いだ書き手の通知を消さない**(入口 → 準備中 → RunProgressState と引き継ぐ)
    func testReleaseByAPreviousWriterKeepsTheCurrentHandler() {
        let box = RunSupplyProgress()
        let first = LockedValue(0), second = LockedValue(0)
        box.setOnChange(owner: Self.ownerA) { first.withLock { $0 += 1 } }
        box.setOnChange(owner: Self.ownerB) { second.withLock { $0 += 1 } }
        box.releaseOnChange(owner: Self.ownerA)
        box.set(name: "iPhone 17-01", platform: "ios", step: .booting)
        XCTAssertEqual(first.value, 0)
        XCTAssertEqual(second.value, 1, "引き継いだ書き手の通知は残る")
    }

    private final class Owner: Sendable {}
    private static let ownerObjectA = Owner(), ownerObjectB = Owner()
    private static var ownerA: ObjectIdentifier { ObjectIdentifier(ownerObjectA) }
    private static var ownerB: ObjectIdentifier { ObjectIdentifier(ownerObjectB) }
}
