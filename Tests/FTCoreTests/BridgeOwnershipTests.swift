// ブリッジの持ち主の仕分け(BridgeOwnership.classify)。doctor と供給の計画段が共有する。

import XCTest
@testable import FTCore

final class BridgeOwnershipTests: XCTestCase {

    func testClassifiesTheFourOwnerships() {
        XCTAssertEqual(BridgeOwnership.classify(ownerRepo: "/repo", isOwnRepo: true,
                                                ownerExists: true, hasStateFile: false), .own)
        XCTAssertEqual(BridgeOwnership.classify(ownerRepo: "/other", isOwnRepo: false,
                                                ownerExists: true, hasStateFile: false),
                       .foreign(owner: "/other"))
        XCTAssertEqual(BridgeOwnership.classify(ownerRepo: "/gone", isOwnRepo: false,
                                                ownerExists: false, hasStateFile: false),
                       .orphan(owner: "/gone"))
        XCTAssertEqual(BridgeOwnership.classify(ownerRepo: nil, isOwnRepo: false,
                                                ownerExists: false, hasStateFile: false), .unknown)
        // 申告の無い旧ブリッジは自分の台帳で自分のものと分かる
        XCTAssertEqual(BridgeOwnership.classify(ownerRepo: nil, isOwnRepo: false,
                                                ownerExists: false, hasStateFile: true), .own)
    }

    /// 台帳はポートしか持たない。自分の古い台帳が残るポートに別のクローンのブリッジが居ても、
    /// 申告が別なら別のワークスペースのもの(台帳を先に見ると自分のものと誤って止める)
    func testTheReportedOwnerWinsOverAStaleLedgerOnTheSamePort() {
        XCTAssertEqual(BridgeOwnership.classify(ownerRepo: "/other", isOwnRepo: false,
                                                ownerExists: true, hasStateFile: true),
                       .foreign(owner: "/other"))
    }

    func testSameRepoFoldsPathSpellings() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftowner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(BridgeOwnership.isSameRepo(dir.path + "/", dir))
        // /var と /private/var は同じ場所(temporaryDirectory は /var/folders/... 側)
        let privatePath = dir.path.hasPrefix("/var/") ? "/private" + dir.path : dir.path
        XCTAssertTrue(BridgeOwnership.isSameRepo(privatePath, dir))
        XCTAssertFalse(BridgeOwnership.isSameRepo(dir.path + "-other", dir))
    }
}
