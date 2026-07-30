// doctor の管理外ブリッジ処遇(UnmanagedBridgeTriage.decide)。
// 「自動停止は証拠が決定的な2行だけ・他人の資産は殺さない」の規律をここで固定する。

import XCTest
@testable import ftester

final class UnmanagedBridgeTriageTests: XCTestCase {

    func testOwnCurrentBridgeIsHealthy() {
        XCTAssertEqual(
            UnmanagedBridgeTriage.decide(ownerRepo: "/repo", ownerExists: true,
                                         isOwnRepo: true, hasStateFile: true, stale: false),
            .skipHealthy)
        // 状態ファイルだけで所有と分かる場合(自己申告の無い旧ブリッジでも自リポジトリ資産)
        XCTAssertEqual(
            UnmanagedBridgeTriage.decide(ownerRepo: nil, ownerExists: false,
                                         isOwnRepo: false, hasStateFile: true, stale: false),
            .skipHealthy)
    }

    func testOwnStaleBridgeIsReaped() {
        XCTAssertEqual(
            UnmanagedBridgeTriage.decide(ownerRepo: "/repo", ownerExists: true,
                                         isOwnRepo: true, hasStateFile: true, stale: true),
            .reapOwnStale)
        XCTAssertEqual(
            UnmanagedBridgeTriage.decide(ownerRepo: nil, ownerExists: false,
                                         isOwnRepo: false, hasStateFile: true, stale: true),
            .reapOwnStale)
    }

    func testOrphanIsReapedOnlyWhenOwnerRepoIsGone() {
        XCTAssertEqual(
            UnmanagedBridgeTriage.decide(ownerRepo: "/deleted-clone", ownerExists: false,
                                         isOwnRepo: false, hasStateFile: false, stale: true),
            .reapOrphan(owner: "/deleted-clone"))
    }

    func testForeignLiveWorkspaceIsNeverReaped() {
        // 版が古くても、実在する別ワークスペースの資産は報告のみ(古いクローンの正当な運用があり得る)
        XCTAssertEqual(
            UnmanagedBridgeTriage.decide(ownerRepo: "/other-clone", ownerExists: true,
                                         isOwnRepo: false, hasStateFile: false, stale: true),
            .reportForeign(owner: "/other-clone"))
    }

    func testUnknownOwnerIsReportedOnly() {
        XCTAssertEqual(
            UnmanagedBridgeTriage.decide(ownerRepo: nil, ownerExists: false,
                                         isOwnRepo: false, hasStateFile: false, stale: true),
            .reportUnknown)
    }
}
