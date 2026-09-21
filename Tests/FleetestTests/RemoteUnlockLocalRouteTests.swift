// `fleetest remote unlock --runner local` の配線。**型で守れない継ぎ目**が2つある:
// ①`local` を ssh の宛先として解決してしまうと、この Mac へ ssh しに行く(語彙の分岐は
// `MachineDispatch.isExplicitLocal` の1箇所)②手元の経路が判定やコマンドを自前で持つと、
// リモートと答えが割れる。どちらもコンパイルでは止まらないのでソースで固定する。
// 判定そのものの回帰は Tests/FTCoreTests/DispatchUnlockThisMachineTests.swift。

import Foundation
import XCTest

final class RemoteUnlockLocalRouteTests: XCTestCase {

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func unlockSource() throws -> String {
        let text = try Self.source("Sources/fleetest/RemoteCommands.swift")
        guard let start = text.range(of: "struct Unlock: AsyncParsableCommand"),
              let end = text.range(of: "private func unlockOne(", range: start.upperBound..<text.endIndex)
        else { throw XCTSkip("unlock の実装が見つからない(切り出しの目印を変えたら直す)") }
        return String(text[start.lowerBound..<end.lowerBound])
    }

    /// `local` の判定は共有の1箇所を通す(自前の `== "local"` を置かない)
    func testTheLocalRunnerIsRecognisedByTheSharedVocabulary() throws {
        let unlock = try unlockSource()
        XCTAssertTrue(unlock.contains("MachineDispatch.isExplicitLocal(raw)"),
                      "--runner local を共有の語彙で受けていない")
        XCTAssertTrue(unlock.contains("RemoteDispatchUnlock.decideThisMachine("),
                      "手元のロックの判定が共有の1箇所を通っていない")
    }

    /// 手元の経路は **ssh を張らない**(`local` を宛先にして自分へ ssh しに行かない)。
    /// 生存の確認も base を絞らない pgrep の1つを通す
    func testTheLocalRouteNeverGoesThroughSsh() throws {
        let unlock = try unlockSource()
        guard let start = unlock.range(of: "static func unlockThisMachine()") else {
            return XCTFail("手元の経路が見つからない")
        }
        let localRoute = String(unlock[start.lowerBound...])
        XCTAssertFalse(localRoute.contains("remoteSSHBase"), "手元のロックを ssh 越しに触っている")
        XCTAssertTrue(localRoute.contains("RemoteDispatchLock.liveDispatchedRunsAnyBaseCommand()"),
                      "生存の確認が base 依存になっている(発行側の --remote-dir は控えに残らない)")
        XCTAssertTrue(localRoute.contains("\"/bin/sh\", \"-c\""),
                      "共有のコマンドをシェルへ渡していない")
    }

    /// **奪う口は unlock に置かない**(「死んだロックを外す」と「奪う」を分けてあるのが既存の設計。
    /// 奪うのは run 側の `--force-lock` だけ)
    func testUnlockHasNoStealingSwitch() throws {
        let unlock = try unlockSource()
        XCTAssertFalse(unlock.contains("@Flag"), "unlock にフラグを足している(奪う口を作っていないか)")
        XCTAssertFalse(unlock.contains("forceAcquireCommand"), "unlock が奪う経路を呼んでいる")
    }
}
