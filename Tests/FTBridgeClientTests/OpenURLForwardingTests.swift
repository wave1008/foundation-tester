// `openURL(_:bundleID:)` を**包むドライバが必ず素通しする**ことを守る。
//
// AppDriver の既定実装は 501("does not support opening a URL")を返すだけ。ラッパーが実装を
// 足し忘れると、その場所より外側からは常に 501 が返り、URL 配送がそのエンジン構成では
// 一度も届かない(AppDriverDefaultDispatchTests と対だが、あちらは「要件宣言漏れ」、
// こちらは「個々のラッパーの転送漏れ」を検出する)。
//
// **同じ型を1つずつ書き並べるのではなく、ソースを走査して
// 「snapshot() を実装している(= AppDriver を包む具象型)のに openURL が無い」型を検出する**
// (SnapshotCacheBypassForwardingTests と同じ作法。新しいラッパーを足したときも自動的に対象になる)。

import XCTest

final class OpenURLForwardingTests: XCTestCase {

    /// 対象外。**意図して既定(501)のままにしているドライバだけ**を入れること
    private static let exempt: Set<String> = [
        // プロトコル定義と既定実装そのもの
        "AppDriver.swift",
        // springboard 参照専用でアプリを持たない。URL を配送すべき対象アプリは
        // primary=in-app 側が持つので、そちらが受け持つ(SystemUIDriver.swift 側のコメント参照)
        "SystemUIDriver.swift",
    ]

    func testEveryDriverImplementingSnapshotAlsoForwardsOpenURL() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTBridgeClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
        var missing: [String] = []
        var checked = 0
        for dir in ["Sources/FTBridgeClient", "Sources/FTAndroid", "Sources/FTCore"] {
            let base = root.appendingPathComponent(dir)
            let files = (try? FileManager.default.contentsOfDirectory(at: base,
                                                                     includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "swift" {
                if Self.exempt.contains(file.lastPathComponent) { continue }
                guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
                guard source.contains("func snapshot() async throws -> SnapshotResponse") else { continue }
                checked += 1
                if !source.contains("func openURL(_ url: String, bundleID: String?)") {
                    missing.append(file.lastPathComponent)
                }
            }
        }
        XCTAssertGreaterThan(checked, 3, "走査対象が見つからない = パスかシグネチャの書式が変わった")
        XCTAssertTrue(missing.isEmpty,
                      "snapshot() を実装する型は openURL(_:bundleID:) も実装して base/primary へ"
                      + "素通しすること(既定実装のままだと最内まで届かない): \(missing)")
    }
}
