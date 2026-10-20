// 実機の「画面が暗い」観測が Android の供給に配線されていることをソース走査で固定する。
//
// この砦が要る理由: Android の凍結 triage(`excludeOrRepairBlankScreenWorkers`)は実機を対象外にしている
// (閾値がエミュレータ較正で、誤判定すると健全な実機へ `adb reboot` を撃つ)ので、実機は観測専用の口を
// 別に通さないと無観測のまま。iOS は `excludeBlankScreenWorkers` が実機も拾う。
// 供給の手順は `ProfileSupplyLanes` の1箇所で、run / api run の全経路がそこを通る(ProfileSupplyLanesWiringTests)。
// 2経路に別々に持っていた間は api run の並列経路だけ Android 実機が無観測だった(このテストは呼び出しの
// 有無をファイル単位で見ていたため、同じファイルの --debug 経路の1本で緑になって見逃した)

import XCTest

final class PhysicalDarkScreenWiringTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/fleetest/\(name)"),
                          encoding: .utf8)
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// **本数を等号で固定する**(観測専用の口は Android のレーンに1本だけ)。`contains` では駄目 ——
    /// iOS 側にも triage の呼び出しがあるので、Android 実機ぶんを消しても文字列が残って通る
    func testTheAndroidLaneObservesPhysicalScreensOnce() throws {
        XCTAssertEqual(occurrences(of: "BlankWorkerTriage.observePhysicalScreens(",
                                   in: try source("ProfileSupplyLanes.swift")), 1,
                       "Android のレーンが実機の観測を失っている")
    }

    /// 材料と修復は同じものを渡す(`PhysicalScreenProbes` に括ってある)
    func testTheObservationGetsTheSharedProbes() throws {
        let text = try source("ProfileSupplyLanes.swift")
        XCTAssertTrue(text.contains("awake: PhysicalScreenProbes.awake"), "awake の材料")
        XCTAssertTrue(text.contains("repair: PhysicalScreenProbes.cycleScreen"), "修復")
    }

    /// **Android 側のトリアージの直後**に通すこと(あちらは実機を対象外にしているので、順序が逆だと実機が素通りする)。
    /// iOS のレーンの中へ紛れていないこと
    func testTheObservationFollowsTheAndroidTriage() throws {
        let text = try source("ProfileSupplyLanes.swift")
        guard let androidTriage = text.range(of: "excludeOrRepairBlankScreenWorkers("),
              let observation = text.range(of: "BlankWorkerTriage.observePhysicalScreens("),
              let iosLane = text.range(of: "static func ios(") else {
            return XCTFail("ProfileSupplyLanes に Android の triage・観測・iOS のレーンが要る")
        }
        XCTAssertTrue(androidTriage.upperBound < observation.lowerBound,
                      "観測は Android 側のトリアージ(実機は対象外)の後に置く")
        XCTAssertTrue(observation.lowerBound < iosLane.lowerBound, "Android 側の観測が iOS のレーンの中へ紛れている")
    }
}
