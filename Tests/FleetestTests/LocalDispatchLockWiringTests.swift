// `fleetest run` と `fleetest api run` が**手元のロックをどこで取るか**の配線。
//
// 型では守れない継ぎ目(2つの手写しの実装・関数のどこに置くか・dry-run の除外)なので
// ソース走査で縛る。緑の run では**取れた**経路しか通らないので、位置がずれていても
// E2E は何も言わない —— ずれると「デバイスに触ってからロックを取る」形になり、
// 断られる run が既に台を消去・再起動したあとになる。

import Foundation
import XCTest
@testable import fleetest

final class LocalDispatchLockWiringTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// 2つの入口が**どちらも1回だけ**取り、**必ず defer で外す**。
    /// 片方だけだとその経路の run が緑のままロック無しで走る
    func testBothRunEntryPointsTakeTheLockOnceAndReleaseItOnEveryExit() throws {
        for path in ["Sources/fleetest/Fleetest.swift", "Sources/fleetest/ApiRunCommand.swift"] {
            let text = try source(path)
            XCTAssertEqual(text.components(separatedBy: "LocalDispatchLock(").count - 1, 1,
                           "\(path): 手元のロックを取る箇所が1つでない")
            XCTAssertTrue(text.contains("defer { dispatchLock?.release() }"),
                          "\(path): 解放が defer に無い(失敗・中断でロックが残る)")
        }
    }

    /// **`--dry-run` は取らない** —— デバイスにも FM にも触らないので、取ると dry-run が
    /// 走っている run を待つ(あるいは断られる)。両方向を見る = 「常に取る」変異も
    /// 「常に取らない」変異も落とす
    func testNeitherEntryPointTakesTheLockForADryRun() throws {
        for path in ["Sources/fleetest/Fleetest.swift", "Sources/fleetest/ApiRunCommand.swift"] {
            let text = try source(path)
            let acquire = try XCTUnwrap(text.range(of: "LocalDispatchLock("), path)
            let head = text[text.startIndex..<acquire.lowerBound].suffix(400)
            XCTAssertTrue(head.contains("if !dryRun {"),
                          "\(path): dry-run を除いていない(デバイスに触らない run がロックを待つ)")
        }
    }

    /// **デバイスにもビルドにも触る前**に取る。`fleetest run` はホスト側のビルドが
    /// この関数の中にある(`swift build` 自体が重い負荷 = 直列化したいものの一部)、
    /// `api run` は run フック・ワークスペースのステージング・供給がこの後に来る
    func testTheLockIsTakenBeforeAnythingHeavy() throws {
        for (path, later) in [("Sources/fleetest/Fleetest.swift", "try ScenarioHost.build(project: testProject)"),
                              ("Sources/fleetest/ApiRunCommand.swift", "RunHookRunner.begin(")] {
            let text = try source(path)
            let acquire = try XCTUnwrap(text.range(of: "LocalDispatchLock("), path)
            let heavy = try XCTUnwrap(text.range(of: later), "\(path): \(later) が見つからない")
            XCTAssertLessThan(acquire.lowerBound, heavy.lowerBound,
                              "\(path): \(later) の後にロックを取っている")
        }
    }

    /// **リモートへ配る経路より後**に取る(`--runner` / 機械分担 / `--fleet` はここへ来る前に
    /// return する)—— 先に取ると、リモートだけで走る run が手元のロックまで握る
    func testTheLockIsTakenAfterTheRemoteDispatchBranches() throws {
        for (path, dispatch) in [("Sources/fleetest/Fleetest.swift", "try await dispatchToFleet(fleet)"),
                                 ("Sources/fleetest/ApiRunCommand.swift",
                                  "try await dispatchToRemoteHost(dispatch, project: testProject)")] {
            let text = try source(path)
            let acquire = try XCTUnwrap(text.range(of: "LocalDispatchLock("), path)
            let branch = try XCTUnwrap(text.range(of: dispatch), "\(path): \(dispatch) が見つからない")
            XCTAssertLessThan(branch.lowerBound, acquire.lowerBound,
                              "\(path): リモートへ配る分岐より前にロックを取っている")
        }
    }

    /// **run-lease(台ごと)より先に取る** —— dispatch.lock はマシン全体の門で、台ごとの
    /// 二重使用(= MCP のセッションとの調停)はその内側。逆順にすると、断られる run が
    /// 先に台を掴みに行く
    func testTheMachineLockComesBeforeThePerDeviceLease() throws {
        let text = try source("Sources/fleetest/ApiRunCommand.swift")
        let acquire = try XCTUnwrap(text.range(of: "LocalDispatchLock("))
        let lease = try XCTUnwrap(
            text.range(of: "ProfileRunner.rejectIfDevicesLeasedBeforePreparation("))
        XCTAssertLessThan(acquire.lowerBound, lease.lowerBound)
    }

    /// 手元のロックを**もう1つの実装で**取らない(取得の定義元はリモートと同じ1つ)
    func testThereIsOnlyOneLocalAcquisitionImplementation() throws {
        let text = try source("Sources/fleetest/LocalDispatchLock.swift")
        for shared in ["RemoteDispatchQueue.enqueueAndTryAcquireCommand(",
                       "RemoteDispatchQueue.parseOutcome(",
                       "RemoteDispatchQueue.dequeueCommand(",
                       "RemoteDispatchLock.releaseCommand(",
                       "RemoteDispatchLock.forceAcquireCommand(",
                       "WaitLockPolling."] {
            XCTAssertTrue(text.contains(shared), "共有の定義元を通っていない: \(shared)")
        }
        // 置き場は**機械グローバルなホーム**(`RemoteDispatchLock.lockDirPath(home:)` が
        // `FTCore.MachineStateDirectory` を通す)。プロジェクトの `.fleetest/` を渡すと、
        // 同じ Mac にロックが何本もできて排他が黙って成立しなくなる
        XCTAssertTrue(text.contains("home: String = NSHomeDirectory()"),
                      "ロックの置き場がこの機械のホームでない")
    }
}
