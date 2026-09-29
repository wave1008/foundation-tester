// `RemoteDispatchUnlock` の判定関数(decide/decideLocalSweep/decideThisMachine/decideAutomaticSweep)は
// `pidAlive`/`startTime` に「実在のホストを引く」既定値を持たせない ―― 既定値があると、呼び出し側
// (production もテストも)が渡し忘れてもコンパイルが通り、その機械のプロセス表でテストの合否が
// 決まる。実害 2026-09-29: `DispatchUnlockThisMachineTests.testMyLiveRunsLockIsKept` が、
// `startTime` を渡し忘れたテストの補助関数のせいで、たまたま pid 4242 が実在した Mac でだけ落ちた
// (`startTime` が既定値 `ProcessLiveness.startTime` のまま実プロセス表を引いていた)。
// production の呼び手(Sources/fleetest/RemoteCommands.swift・RemoteRunDispatcher.swift・
// LocalDispatchLock.swift)は `ProcessLiveness.startTime` を明示して渡す。

import Foundation
import XCTest

final class RemoteDispatchUnlockNoHostDefaultTests: XCTestCase {

    /// `RemoteDispatchUnlock` の宣言以降のコード(行コメントより右側は落とす ―― このファイル自身の
    /// doc コメントの引用がここに一致してしまわないため)
    private static func enumBodyWithoutComments() -> String? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FTCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
            .appendingPathComponent("Sources/FTRemote/RemoteDispatchLock.swift")
        guard let text = try? String(contentsOf: root, encoding: .utf8),
              let start = text.range(of: "public enum RemoteDispatchUnlock") else { return nil }
        return String(text[start.lowerBound...])
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: "\n")
    }

    func testDecideFunctionsHaveNoHostBackedDefault() throws {
        let body = try XCTUnwrap(Self.enumBodyWithoutComments(),
                                 "RemoteDispatchUnlock が見つからない(切り出しの目印を変えたら直す)")
        XCTAssertFalse(body.contains("= ProcessLiveness."), """
            RemoteDispatchUnlock の判定関数に `= ProcessLiveness.*` の既定値が付いている ――
            渡し忘れがコンパイルを通り、その機械のプロセス表でテストの合否が変わる。
            production の呼び手に明示させること(Sources/fleetest/RemoteCommands.swift 等)。
            """)
    }
}
