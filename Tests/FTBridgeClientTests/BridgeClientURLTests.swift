// ブリッジへ投げる URL の組み立て。**クエリ付きの経路がここで壊れた実績がある**。
//
// 2026-08-02: `snapshot(bypassingCache:)` が "/snapshot?refresh=1" を path として渡していたため
// `appendingPathComponent` が "?" を %3F へ逃がし、ブリッジ側で
// `GET /snapshot%3Frefresh=1` = 404 になった。フェイクドライバの単体テストは
// 「どちらのドライバへ流れたか」しか見ないので配線が通らず、**期限切れ時にしか撃たない経路**
// だったため E2E でも長く表面化しなかった(実データで初めて出た)。
// URL 組み立てだけを純粋関数として切り出し、ここで固定する。

import XCTest
@testable import FTBridgeClient

final class BridgeClientURLTests: XCTestCase {

    private let base = URL(string: "http://127.0.0.1:8123")!

    func testPlainPathHasNoQuery() {
        let url = BridgeClient.url(base: base, path: "/snapshot", query: nil)
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:8123/snapshot")
    }

    /// "?" がパス要素としてエスケープされないこと(これが 404 の正体だった)
    func testQueryIsAppendedAsQueryNotEscapedIntoThePath() {
        let url = BridgeClient.url(base: base, path: "/snapshot", query: "refresh=1")
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:8123/snapshot?refresh=1")
        XCTAssertFalse(url.absoluteString.contains("%3F"), "'?' がパスへ逃げている")
        XCTAssertEqual(url.path, "/snapshot", "ルーティングに使う path はクエリを含まないこと")
        XCTAssertEqual(url.query, "refresh=1")
    }

    func testEmptyQueryIsTreatedAsNone() {
        let url = BridgeClient.url(base: base, path: "/snapshot", query: "")
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:8123/snapshot")
    }
}
