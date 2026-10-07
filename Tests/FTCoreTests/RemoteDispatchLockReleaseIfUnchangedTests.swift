// 他人(死んだ持ち主)のロックを外す経路の条件付き解放(RemoteDispatchLock.releaseIfUnchangedCommand)。
// 読む・判定する・消すが別の往復なので、間に持ち主が入れ替わると無条件の rm -rf は新しい持ち主の
// ロックを消し、同じ機械で run が2本走る。**実際のシェルで撃って**中身の比較を確かめる
// (文字列の完全一致だけでは、クォートや末尾改行の扱いの誤りで「常に changed」になっても気付けない)。

import Foundation
import XCTest
@testable import FTCore
import FTRemote

final class RemoteDispatchLockReleaseIfUnchangedTests: XCTestCase {
    private var home: String!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-lock-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    private func sh(_ command: String) throws -> String {
        try XCTUnwrap(Shell.run(["/bin/sh", "-c", command]).outputIfSucceeded)
    }

    private func acquire(pid: Int32) throws -> String {
        let info = RemoteDispatchLockInfo.now(issuerHost: "host'a", pid: pid, issuer: "me@x")
        XCTAssertTrue(try Shell.run(["/bin/sh", "-c",
            RemoteDispatchLock.acquireCommand(home: home, info: info)]).status == 0)
        return try sh(RemoteDispatchLock.readCommand(home: home))
    }

    private var lockExists: Bool {
        FileManager.default.fileExists(atPath: RemoteDispatchLock.lockDirPath(home: home))
    }

    func testReleasesWhenTheLockIsStillTheOneThatWasRead() throws {
        let observed = try acquire(pid: 111)
        let out = try sh(RemoteDispatchLock.releaseIfUnchangedCommand(home: home, observedInfo: observed))
        XCTAssertTrue(RemoteDispatchLock.releasedIfUnchanged(out), out)
        XCTAssertFalse(lockExists)
    }

    /// 末尾の改行の有無で結果が変わらない(probe 経由の控えは改行付きで来ることがある)
    func testTrailingNewlineInTheObservedTextDoesNotMatter() throws {
        let observed = try acquire(pid: 112)
        let out = try sh(RemoteDispatchLock.releaseIfUnchangedCommand(home: home, observedInfo: observed + "\n"))
        XCTAssertTrue(RemoteDispatchLock.releasedIfUnchanged(out), out)
        XCTAssertFalse(lockExists)
    }

    /// 読んだ後に別の run が取り直していたら消さない(これが無いと run が2本走る)
    func testKeepsALockThatChangedHandsAfterItWasRead() throws {
        let observed = try acquire(pid: 113)
        _ = try sh(RemoteDispatchLock.releaseCommand(home: home))
        _ = try acquire(pid: 114)
        let out = try sh(RemoteDispatchLock.releaseIfUnchangedCommand(home: home, observedInfo: observed))
        XCTAssertFalse(RemoteDispatchLock.releasedIfUnchanged(out), out)
        XCTAssertTrue(lockExists, "入れ替わった新しい持ち主のロックを消した")
    }

    func testAbsentLockIsNotReportedAsReleased() throws {
        let observed = try acquire(pid: 115)
        _ = try sh(RemoteDispatchLock.releaseCommand(home: home))
        let out = try sh(RemoteDispatchLock.releaseIfUnchangedCommand(home: home, observedInfo: observed))
        XCTAssertFalse(RemoteDispatchLock.releasedIfUnchanged(out), out)
    }

    func testProbeInfoTextIsTheInfoAfterTheHeldLine() throws {
        let observed = try acquire(pid: 116)
        let probe = try sh(RemoteDispatchLock.probeCommand(home: home))
        XCTAssertEqual(RemoteDispatchLock.probeInfoText(probe), observed)
        _ = try sh(RemoteDispatchLock.releaseCommand(home: home))
        XCTAssertNil(RemoteDispatchLock.probeInfoText(try sh(RemoteDispatchLock.probeCommand(home: home))))
    }

    /// **無条件の解放(`releaseCommand`)は自分が取ったロックの解放にだけ使う**。他人の(死んだ)ロックを
    /// 外す経路(自動回収・unlock)が無条件へ戻ると、入れ替わった新しい持ち主のロックを消す。
    /// 呼び手の集合を等号で固定する(足すときは「自分が取ったロックか」を判断して表へ足す)
    func testUnconditionalReleaseIsOnlyUsedForOwnLocks() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let allowed: [String: Int] = [
            "RemoteDispatchLock.swift": 1,   // releaseIfRunEndedCommand(このディスパッチ自身のロック)
            "LocalDispatchLock.swift": 1,    // makeHolder(取った run の defer)
            "RemoteRunDispatcher.swift": 1,  // releaseDispatchLock(取ったディスパッチの defer)
            "RemoteSetupCommand.swift": 1,   // setup/align が取ったロック
        ]
        var found: [String: Int] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let count = text.split(separator: "\n")
                .filter { $0.contains("releaseCommand(home:") && !$0.contains("static func") }.count
            if count > 0 { found[url.lastPathComponent, default: 0] += count }
        }
        XCTAssertEqual(found, allowed)
    }
}
