import XCTest

@testable import fleetest

/// ブリッジを持たない iOS シミュレータの「1サイクル1台の順繰り」を固定する。
/// この経路は**配信が張れない台にとって唯一の絵の出所**なので、選ばれなくなる退行は
/// タイルが黙って真っ黒になる形で出る(2026-08-28 の実害と同じ見え方)。
final class MonitorSimctlCaptureTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testPicksNothingWhenThereAreNoCandidates() {
        var last: [String: Date] = [:]
        XCTAssertNil(ApiMonitorCommand.simctlCapturePick(ids: [], lastCapturedAt: &last, now: t0))
        XCTAssertTrue(last.isEmpty)
    }

    /// 1サイクルに撮るのは1台だけ(戻り値が1つ・時計が進むのもその台だけ)
    func testPicksOneDevicePerCycle() {
        var last: [String: Date] = [:]
        let pick = ApiMonitorCommand.simctlCapturePick(ids: ["a", "b", "c"],
                                                       lastCapturedAt: &last, now: t0)
        XCTAssertEqual(pick, "a")
        XCTAssertEqual(last, ["a": t0])
    }

    /// 順繰り: 3台なら3サイクルで一巡し、4サイクル目は最初の台へ戻る
    func testCyclesThroughEveryDevice() {
        var last: [String: Date] = [:]
        var picks: [String] = []
        for i in 0..<4 {
            let now = t0.addingTimeInterval(Double(i) * 2)
            if let pick = ApiMonitorCommand.simctlCapturePick(ids: ["a", "b", "c"],
                                                              lastCapturedAt: &last, now: now) {
                picks.append(pick)
            }
        }
        XCTAssertEqual(picks, ["a", "b", "c", "a"])
    }

    /// 途中で増えた台は「一度も撮っていない」= 最優先で拾う(新しいタイルが一巡待ちで
    /// 真っ黒のまま残らない)
    func testANewlyAppearedDeviceIsPickedFirst() {
        var last: [String: Date] = ["a": t0, "b": t0.addingTimeInterval(2)]
        let pick = ApiMonitorCommand.simctlCapturePick(ids: ["a", "b", "fresh"],
                                                       lastCapturedAt: &last,
                                                       now: t0.addingTimeInterval(4))
        XCTAssertEqual(pick, "fresh")
    }

    /// 候補から消えた台の時計は残っていても選択を歪めない(消えた台を選ばない)
    func testDoesNotPickADeviceThatLeftTheCandidateSet() {
        var last: [String: Date] = ["gone": .distantPast, "a": t0]
        let pick = ApiMonitorCommand.simctlCapturePick(ids: ["a"], lastCapturedAt: &last,
                                                       now: t0.addingTimeInterval(2))
        XCTAssertEqual(pick, "a")
    }
}
