// 各シナリオの前に残ったシステムアラートを「消すか・警告だけか・何もしないか」と、その文言

import XCTest
@testable import FTCore

final class ResidualSystemAlertClearingTests: XCTestCase {

    private let photos = SystemAlertProbeResponse(
        present: true, title: "“App”に写真ライブラリへのアクセスを許可しますか?",
        buttons: ["写真を選択", "フルアクセスを許可", "許可しない"])

    private func plan(_ probe: SystemAlertProbeResponse?, physical: Bool = false,
                      canRebuildBridge: Bool = true) -> ResidualSystemAlertClearing.Plan {
        ResidualSystemAlertClearing.plan(probe: probe, label: "iPhone-07(ios:8126)", physical: physical,
                                         canRebuildBridge: canRebuildBridge)
    }

    /// 判定できない(旧ランナー・問い合わせの失敗)とき・居ないときは何もしない
    func testNothingWhenAbsentOrUnknown() {
        XCTAssertEqual(plan(nil), .nothing)
        XCTAssertEqual(plan(SystemAlertProbeResponse(present: false)), .nothing)
    }

    /// Simulator でブリッジを作り直せるときだけ消す
    func testClearsOnASimulatorThatCanRebuildItsBridge() {
        XCTAssertEqual(plan(photos), .clear)
    }

    /// 実機は SpringBoard を起こし直せない・プロファイルの無い run はブリッジを作り直せない = 警告だけ。
    /// どちらもボタンは押さない(押してよいのは iosAlertHandler の登録だけ)
    func testWarnsOnlyWhereItCannotBeDismissedWithoutPressingAButton() {
        guard case .warnOnly(let physical) = plan(photos, physical: true) else { return XCTFail() }
        XCTAssertTrue(physical.contains("physical device"), physical)
        XCTAssertTrue(physical.contains("iPhone-07(ios:8126)"))
        guard case .warnOnly(let noProfile) = plan(photos, canRebuildBridge: false) else { return XCTFail() }
        XCTAssertTrue(noProfile.contains("--profile"), noProfile)
        // 実機の判定が先(実機ならブリッジを作り直せても消せない)
        guard case .warnOnly(let both) = plan(photos, physical: true, canRebuildBridge: false) else { return XCTFail() }
        XCTAssertTrue(both.contains("physical device"), both)
    }

    func testDescribeShowsTitleAndButtons() {
        XCTAssertEqual(ResidualSystemAlertClearing.describe(photos),
                       "“App”に写真ライブラリへのアクセスを許可しますか?, buttons: 写真を選択 / フルアクセスを許可 / 許可しない")
        XCTAssertEqual(ResidualSystemAlertClearing.describe(SystemAlertProbeResponse(present: true)), "no title")
    }

    func testClearedMessageSaysNoButtonWasPressed() {
        let line = ResidualSystemAlertClearing.clearedMessage(label: "L", alert: "A", seconds: 19.04)
        XCTAssertTrue(line.contains("without pressing any button"), line)
        XCTAssertTrue(line.contains("19.0s"), line)
    }
}
