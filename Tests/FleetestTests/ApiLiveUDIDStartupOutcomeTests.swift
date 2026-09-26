import XCTest
@testable import fleetest
import FTBridgeClient

/// ライブ操作(api live serve)の起動時、`--udid` がこの Mac に実在するかの判定
/// (`ApiLiveServe.udidStartupOutcome`)を実ブリッジ無しで固定する。判定そのもの
/// (`SimulatorCatalog.UDIDLookup`)は Tests/FTBridgeClientTests 側が固定するので、ここで見るのは
/// 「その4値を起動時にどう扱うか」だけ。**`.notFound` のときだけ止める** —— それ以外
/// (`.simulator`/`.physical`/`.unreadable`)は進めて、実在しない udid でだけ `LiveBridgeAutoStarter`
/// の xcodebuild build-for-testing の空撃ちを避ける。
final class ApiLiveUDIDStartupOutcomeTests: XCTestCase {

    func testProceedsWhenTheUDIDIsAKnownSimulator() {
        XCTAssertEqual(ApiLiveServe.udidStartupOutcome(.simulator), .proceed)
    }

    func testProceedsWhenTheUDIDIsAKnownPhysicalDevice() {
        XCTAssertEqual(ApiLiveServe.udidStartupOutcome(.physical), .proceed)
    }

    /// **本題**: 一覧を読めたうえで載っていなければ止める
    func testStopsWhenTheListWasReadableAndTheUDIDIsNotInIt() {
        XCTAssertEqual(ApiLiveServe.udidStartupOutcome(.notFound), .missing)
    }

    /// **不明を確定値に畳まない**: 一覧そのものが読めなかったときは「居ない」と決めつけず進む
    /// (自動起動の再試行に委ねる)
    func testProceedsWhenTheListCouldNotBeRead() {
        XCTAssertEqual(ApiLiveServe.udidStartupOutcome(.unreadable("simctl timed out")), .proceed)
    }

    /// 拒否文は人間向け(拡張のライブ操作パネルを見ている人が読む)・英語(CLI の表示文字列は英語のみ)。
    /// 確かめ方(`fleetest api list-devices`)まで案内する
    func testUDIDNotFoundMessageNamesTheUDIDAndTheWayToCheck() {
        let message = ApiLiveServe.udidNotFoundMessage(udid: "257324AF-0000")
        XCTAssertTrue(message.contains("257324AF-0000"), message)
        XCTAssertTrue(message.contains("fleetest api list-devices"), message)
    }
}
