// シナリオ実行バイナリ(子)に入るモジュールは一時領域を `TemporaryDirectory.url` で引く。
// `NSTemporaryDirectory()` / `FileManager.temporaryDirectory` は `TMPDIR` を見ないので、サンドボックスの子が
// 書けない `/var/folders/xx/yy/T/` を返し、書き込みが EPERM で黙って効かなくなる。

import XCTest
@testable import FTCore

final class TemporaryDirectoryScanTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// 子にリンクされるモジュール(Package.swift の FTScenarioRunner / FTDSL の依存)
    private static let childModules = ["FTCore", "FTBridgeClient", "FTAndroid", "FTDSL", "FTScenarioRunner",
                                       "FTFoundationModels", "FTEmulatorGrpc"]

    /// 親(枠の外)でしか通らないので直接使ってよいファイル
    private static let parentOnly: [String: String] = [
        "TemporaryDirectory.swift": "the definition itself",
        "ScenarioHost.swift": "the parent that launches the runner",
        "ScenarioHost+Sandbox.swift": "the parent's broker socket",
        // 子の TMPDIR ではなく親だけの一時領域へ書くのが目的(子に書き換えさせない = 144bb1cd)
        "SandboxBroker.swift": "the parent's broker (parent-only output files)",
        "ProfileWorkerFactory.swift": "device provisioning in the parent",
        "CmdlineToolsInstaller.swift": "fleetest setup",
    ]

    func testChildModulesDoNotUseTheSystemTemporaryDirectoryDirectly() throws {
        var scanned = 0
        var offenders: [String] = []
        for module in Self.childModules {
            let dir = Self.repoRoot.appendingPathComponent("Sources/" + module)
            guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                scanned += 1
                guard Self.parentOnly[url.lastPathComponent] == nil else { continue }
                // コメントと文字列リテラル(索引の説明文が名前を出す)を除き、呼び出しの形だけを見る
                // (`.temporaryDirectory` の部分一致にすると `TestLogPaths.temporaryDirectory(...)` に当たる)
                let code = try String(contentsOf: url, encoding: .utf8)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .map { $0.replacingOccurrences(of: #""([^"\\]|\\.)*""#, with: "\"\"", options: .regularExpression) }
                if code.contains(where: { $0.contains("NSTemporaryDirectory()")
                    || $0.contains("FileManager.default.temporaryDirectory") }) {
                    offenders.append(module + "/" + url.lastPathComponent)
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the scan did not reach Sources")
        XCTAssertEqual(offenders, [], "use TemporaryDirectory.url — NSTemporaryDirectory() ignores TMPDIR")
    }

    func testTemporaryDirectoryFollowsAnAbsoluteTMPDIR() {
        XCTAssertEqual(TemporaryDirectory.url(environment: ["TMPDIR": "/private/var/folders/x/T/fleetest-sandbox/r/"]).path,
                       "/private/var/folders/x/T/fleetest-sandbox/r")
        XCTAssertEqual(TemporaryDirectory.url(environment: ["TMPDIR": "relative"]).path,
                       URL(fileURLWithPath: NSTemporaryDirectory()).path)
        XCTAssertEqual(TemporaryDirectory.url(environment: [:]).path, URL(fileURLWithPath: NSTemporaryDirectory()).path)
    }
}
