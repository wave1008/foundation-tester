import XCTest
import FTRemote

/// セッション行(`RemoteProbe.parseSessionInfo` の2行目)を採るシェル片は
/// `RemoteProbe.consoleUserCommand` の1箇所だけに置く。3つの呼び出し元
/// (RemoteStatusProbe.command / RemoteRunDispatcher.resolveLayout /
/// RemoteSetupCommand.remoteReach)のどれかが生の `stat` へ戻ると、ホストによって
/// ログイン判定が食い違う(画面共有ログインの機械が経路ごとに通ったり弾かれたりする)
final class RemoteConsoleUserProbeTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FleetestTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    /// 生の `stat -f%Su /dev/console` を書いてよいのは定義元のファイルだけ
    func testNoSourceFileOutsideTheDefinitionSiteSpellsTheRawStat() throws {
        let definitionSite = "Sources/FTRemote/RemoteDispatch.swift"
        var offenders: [String] = []
        let sources = repoRoot.appendingPathComponent("Sources")
        let walker = FileManager.default.enumerator(at: sources,
                                                    includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            guard relative != definitionSite else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("stat -f%Su /dev/console") { offenders.append(relative) }
        }
        XCTAssertEqual(offenders, [],
                       "これらは RemoteProbe.consoleUserCommand を使うこと: \(offenders)")
    }

    /// 3つの呼び出し元がすべて定数を参照している(生の literal へ戻っていない)
    func testAllThreeProbeSitesReferenceTheSharedCommand() throws {
        for relative in ["Sources/FTRemote/RemoteDispatch.swift",
                         "Sources/fleetest/RemoteRunDispatcher.swift",
                         "Sources/fleetest/RemoteSetupCommand.swift"] {
            let text = try String(contentsOf: repoRoot.appendingPathComponent(relative),
                                  encoding: .utf8)
            XCTAssertTrue(text.contains("RemoteProbe.consoleUserCommand"),
                          "\(relative) がセッション行の定義元を参照していない")
        }
    }

    /// **どちらの枝もちょうど1行**でなければ parseSessionInfo の行数判定(3行 or 5行)が崩れ、
    /// 判定不能へ落ちてログインチェックが黙って無効になる。実際にローカルの sh で撃って確かめる
    /// (この Mac はログイン済みなので通るのは then 側。else 側は分岐を反転した写しで確かめる)
    func testBothBranchesEmitExactlyOneLine() throws {
        let thenBranch = try runShell(RemoteProbe.consoleUserCommand)
        XCTAssertEqual(thenBranch.count, 1, "then 側が1行でない: \(thenBranch)")
        XCTAssertFalse(thenBranch[0].isEmpty)

        // 条件を必ず偽にした写し = else 側だけを通す
        let forcedElse = RemoteProbe.consoleUserCommand
            .replacingOccurrences(of: "launchctl print gui/$(id -u) >/dev/null 2>&1", with: "false")
        XCTAssertNotEqual(forcedElse, RemoteProbe.consoleUserCommand,
                          "条件式の綴りが変わった —— この写しは else 側を通していない")
        let elseBranch = try runShell(forcedElse)
        XCTAssertEqual(elseBranch.count, 1, "else 側が1行でない: \(elseBranch)")
        XCTAssertFalse(elseBranch[0].isEmpty)
    }

    /// `launchctl print gui/<uid>` は Aqua ログインセッションが作るドメインなので、
    /// セッションを持たない uid では失敗する = 「常に真を返す検出器」ではない(負の対照)
    func testTheGuiDomainProbeIsNotAlwaysTrue() throws {
        let probe = RemoteProbe.consoleUserCommand
            .replacingOccurrences(of: "gui/$(id -u)", with: "gui/999")
        XCTAssertNotEqual(probe, RemoteProbe.consoleUserCommand,
                          "uid の綴りが変わった —— この写しは負の対照になっていない")
        // else 側 = /dev/console の所有者。then 側(id -un)へ落ちたなら検出器が壊れている
        let out = try runShell(probe + "; echo '|'; stat -f%Su /dev/console")
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0], out[2],
                       "セッションを持たない uid で then 側へ落ちた = 検出器が常に真")
    }

    private func runShell(_ command: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty } ?? []
    }
}
