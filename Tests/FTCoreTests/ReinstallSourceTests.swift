// 実機の clearAppData を「入れ直し」で代替するときの判定。
// **uninstall を撃つ前に結論を出す**ための純粋型なので、3分岐すべてを実ファイル無しで固定する。

import XCTest
@testable import FTCore

final class ReinstallSourceTests: XCTestCase {

    func testExplicitWinsOverTheRemembered() {
        let source = ReinstallSource.resolve(explicit: "/a/App.app", remembered: "/b/App.app",
                                             exists: { _ in true })
        XCTAssertEqual(source, .usable("/a/App.app"))
    }

    func testFallsBackToTheRemembered() {
        let source = ReinstallSource.resolve(explicit: nil, remembered: "/b/App.app",
                                             exists: { _ in true })
        XCTAssertEqual(source, .usable("/b/App.app"))
    }

    /// **どこからも渡っていない**。呼び手は「消さずに拒否」へ倒す
    func testUnknownWhenNothingIsGiven() {
        XCTAssertEqual(ReinstallSource.resolve(explicit: nil, remembered: nil,
                                               exists: { _ in true }), .unknown)
        XCTAssertEqual(ReinstallSource.resolve(explicit: "", remembered: nil,
                                               exists: { _ in true }), .unknown)
    }

    /// 控えはあるが実体が無い形。**ここを usable にすると端末からアプリだけ消える**
    func testMissingWhenThePathIsGone() {
        XCTAssertEqual(ReinstallSource.resolve(explicit: nil, remembered: "/gone/App.app",
                                               exists: { _ in false }), .missing("/gone/App.app"))
    }

    func testExpandsTildeBeforeCheckingAndReporting() {
        var asked: [String] = []
        let source = ReinstallSource.resolve(explicit: "~/builds/App.app", remembered: nil,
                                             exists: { asked.append($0); return true })
        let expected = NSString(string: "~/builds/App.app").expandingTildeInPath
        XCTAssertEqual(asked, [expected], "実在確認は展開後のパスで行う")
        XCTAssertEqual(source, .usable(expected), "install へ渡すのも展開後のパス")
    }

    // MARK: - どの失敗を入れ直しへ回すか

    /// **この形だけ**を入れ直しへ回す。広げると直すべき失敗を握り潰して黙って再インストールする
    func testOnlyTheSimulatorOnly501IsRoutedToAReinstall() {
        XCTAssertTrue(ReinstallSource.isClearAppDataUnsupported(
            DriverError.badResponse(status: 501,
                                    body: "clearAppData is simulator-only on iOS (devicectl ...)")))
        XCTAssertFalse(ReinstallSource.isClearAppDataUnsupported(
            DriverError.badResponse(status: 501, body: "not implemented")),
            "同じ 501 でも別の理由なら回さない")
        XCTAssertFalse(ReinstallSource.isClearAppDataUnsupported(
            DriverError.badResponse(status: 500, body: "simulator-only")),
            "本文が一致しても 5xx の別状態は回さない")
        XCTAssertFalse(ReinstallSource.isClearAppDataUnsupported(
            DriverError.bridgeConnectionRefused("nothing listening")))
        XCTAssertFalse(ReinstallSource.isClearAppDataUnsupported(
            NSError(domain: "x", code: 1)))
    }
}
