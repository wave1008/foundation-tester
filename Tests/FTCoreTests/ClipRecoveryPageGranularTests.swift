// 見切れの戻し(runScrollSearch の isClippedByViewport)を、in-app の自前描画では距離どおりのドラッグで寄せる。
// witness: E2EY-CMP の反転チャット(iOS in-app)で、容器の下端の外の #msg_40 を戻す1本が a11y の scroll = 1ページになり、
// 逆側へ飛び越して往復し 8 本を使い切った(1/5)

import XCTest
@testable import FTCore

final class ClipRecoveryPageGranularTests: XCTestCase {

    private func el(_ ref: Int, _ id: String, _ frame: FTRect, scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: "other", identifier: id, label: id, value: nil, placeholder: nil,
                    enabled: true, frame: frame, depth: 1, scrollable: scrollable)
    }

    /// 1枚目: 容器(200〜600)の下端で見切れた行 / 2枚目以降: 容器の中へ入った行
    private func run(_ framework: AppUIFramework) async -> FakeAppDriver {
        let list = el(1, "list_chat", FTRect(x: 0, y: 200, width: 400, height: 400), scrollable: true)
        let clipped = el(2, "msg_40", FTRect(x: 0, y: 580, width: 400, height: 56))
        let inside = el(2, "msg_40", FTRect(x: 0, y: 500, width: 400, height: 56))
        let primary = FakeAppDriver(name: "primary", log: CallLog(),
                                    snapshotElements: [[list, clipped], [list, clipped], [list, inside]])
        let typeDriver = FakeAppDriver(name: "typedriver", log: CallLog(), snapshotElements: [[]])
        var step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "msg_40"), direction: "up", maxSwipes: 4)
        step.scrollFrame = FlowLocator(id: "list_chat")
        _ = await StepExecutor(driver: primary, typeDriver: typeDriver, isAndroid: false, tunables: RunTunables(),
                               uiFramework: framework).execute(step)
        return primary
    }

    func testSelfRenderedInAppRecoversTheClipWithADistanceDrag() async {
        let primary = await run(.compose)
        XCTAssertFalse(primary.dragCalls.isEmpty, "見切れの戻しが距離のドラッグになっていない: \(primary.log.entries)")
        XCTAssertFalse(primary.log.entries.contains("primary.swipe"), "1ページ送りの払いで戻している")
    }

    /// 縁にぴったり(浮動小数の一致で見切れ扱い・戻す量が無い)なら見つかったとする。実測は下端 766.67 = 容器の下端
    func testSelfRenderedInAppAcceptsAMatchFlushWithTheEdge() async {
        let list = el(1, "list_chat", FTRect(x: 0, y: 200, width: 400, height: 400.0000001), scrollable: true)
        let flush = el(2, "msg_40", FTRect(x: 0, y: 544, width: 400, height: 56.0000002))
        let primary = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[list, flush]])
        var step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "msg_40"), direction: "up", maxSwipes: 4)
        step.scrollFrame = FlowLocator(id: "list_chat")
        let outcome = await StepExecutor(driver: primary, typeDriver: FakeAppDriver(name: "td", log: CallLog()),
                                         isAndroid: false, tunables: RunTunables(), uiFramework: .flutter).execute(step)
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(primary.dragCalls.isEmpty && !primary.log.entries.contains("primary.swipe"),
                      "\(primary.log.entries)")
    }

    /// 戻す量が小さい(40 未満)見切れも、1ページの払いでなく広げたドラッグで寄せる
    func testSelfRenderedInAppDragsASmallClipInsteadOfPaging() async {
        let list = el(1, "list_chat", FTRect(x: 0, y: 200, width: 400, height: 400), scrollable: true)
        let small = el(2, "msg_40", FTRect(x: 0, y: 194, width: 400, height: 56))   // 上へ 6 はみ出す
        let inside = el(2, "msg_40", FTRect(x: 0, y: 260, width: 400, height: 56))
        let primary = FakeAppDriver(name: "primary", log: CallLog(),
                                    snapshotElements: [[list, small], [list, small], [list, inside]])
        var step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "msg_40"), direction: "down", maxSwipes: 4)
        step.scrollFrame = FlowLocator(id: "list_chat")
        _ = await StepExecutor(driver: primary, typeDriver: FakeAppDriver(name: "td", log: CallLog()),
                               isAndroid: false, tunables: RunTunables(), uiFramework: .compose).execute(step)
        XCTAssertFalse(primary.dragCalls.isEmpty, "\(primary.log.entries)")
        XCTAssertFalse(primary.log.entries.contains("primary.swipe"), "小さい見切れを1ページの払いで戻している")
    }

    func testSwiftUIKeepsTheContainerSwipe() async {
        let primary = await run(.swiftUI)
        XCTAssertTrue(primary.log.entries.contains("primary.swipe"), "SwiftUI は容器基準の短い送りのまま(置き換えると退行する)")
    }
}
