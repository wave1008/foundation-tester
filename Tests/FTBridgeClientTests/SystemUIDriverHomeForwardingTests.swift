// tapAppIcon の homeScreenDriver 契約を守る: SystemUIDriver は home()/snapshot()/drag() を
// 自前で client へ素通しすること。
//
// home() は AppDriver のプロトコル要件だが extension に 501 の既定実装があり、素通しを
// 書き忘れても**コンパイルは通って実行時に 501 で失敗する**(2026-08-03 に実機で踏んだ。
// 単体テストの代役ドライバは home を実装しているため気付けない)。
// SystemUIDriver は BridgeClient を内部生成しネットワーク無しで代役に差し替えられないため、
// SwipeForScrollForwardingTests と同じソース走査で守る。

import XCTest

final class SystemUIDriverHomeForwardingTests: XCTestCase {

    func testSystemUIDriverForwardsTheMethodsTapAppIconNeeds() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTBridgeClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
            .appendingPathComponent("Sources/FTBridgeClient/SystemUIDriver.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        // tapAppIcon が homeScreenDriver に対して呼ぶもの(Commands.swift の tapAppIcon 参照)
        for needle in ["func home()", "func snapshot(", "func drag(", "func tap(ref:", "func swipe("] {
            XCTAssertTrue(source.contains(needle),
                          "SystemUIDriver が \(needle) を素通ししていない。既定実装(501)に落ちて "
                          + "tapAppIcon が実行時に失敗する(ヘッダコメント参照)")
        }
    }
}
