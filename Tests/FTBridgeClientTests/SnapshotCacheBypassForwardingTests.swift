// `snapshot(bypassingCache:)` と `supportsCacheBypass` を**包むドライバが必ず素通しする**ことを守る。
//
// AppDriver の既定実装は bypassingCache を捨てて自分の `snapshot()` を呼び、supportsCacheBypass は
// false を返す。ラッパーがこの既定に頼ると、フラグは**最初のラッパーで落ちて**最内の Android まで
// 届かない。届かないと StepExecutor の AssertFreshRetry が arm すらしなくなり、
// 「アプリは正しいのに古い a11y ツリーで検証だけが落ちる」偽陰性が黙って戻る —— 失敗モードが
// 沈黙なので、テストは緑のまま気付けない(AppDriver.swift の該当宣言のコメントと対)。
//
// 各ラッパーの型を1つずつ書き並べるのではなく、**ソースを走査して
// 「snapshot() を実装しているのに bypassingCache 版 / supportsCacheBypass が無い」型を検出する**。
// 新しいラッパーを足したときも自動的に対象になる(SwipeForScrollForwardingTests と同じ作法)。

import XCTest

final class SnapshotCacheBypassForwardingTests: XCTestCase {

    /// 対象外。**包む相手を持たないドライバだけ**を入れること
    /// (包むのに入れると、この防波堤が守りたい事故そのものを見逃す)
    private static let exempt: Set<String> = [
        // プロトコル定義と既定実装そのもの
        "AppDriver.swift",
        // HTTP を話す葉。bypassingCache 版は実装済みだが、そのフラグが意味を持つかは
        // **所有するドライバの判断**(Android だけが true。iOS ブリッジは鮮度問題を持たない)
        // なので supportsCacheBypass はここで宣言しない
        "BridgeClient.swift",
    ]

    func testEveryDriverImplementingSnapshotAlsoForwardsCacheBypass() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTBridgeClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
        var missingBypass: [String] = []
        var missingSupports: [String] = []
        var missingElementLimit: [String] = []
        var missingPointScale: [String] = []
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
                if !source.contains("func snapshot(bypassingCache: Bool)") {
                    missingBypass.append(file.lastPathComponent)
                }
                if !source.contains("var supportsCacheBypass: Bool") {
                    missingSupports.append(file.lastPathComponent)
                }
                // 同型の3本目: 1回限りの要素上限も**包む側が転送しないと
                // 最内のブリッジ接続へ届かず**、上げたつもりで 120 のまま黙って返る
                if !source.contains("func raiseElementLimitOnNextSnapshot(_ max: Int?)") {
                    missingElementLimit.append(file.lastPathComponent)
                }
                // 同型の4本目: 木の単位(px か pt か)も**包む側が透過しないと
                // 既定の 1 に落ち**、Android で幾何の床が密度ぶん緩む(誤タップは沈黙する)
                if !source.contains("var pointScale: Double") {
                    missingPointScale.append(file.lastPathComponent)
                }
            }
        }
        XCTAssertGreaterThan(checked, 3, "走査対象が見つからない = パスかシグネチャの書式が変わった")
        XCTAssertTrue(missingBypass.isEmpty,
                      "snapshot() を実装する型は bypassingCache 版も実装して base へ素通しすること"
                      + "(既定実装に任せるとフラグが落ちて最内の Android へ届かない): \(missingBypass)")
        XCTAssertTrue(missingSupports.isEmpty,
                      "同じ型は supportsCacheBypass も base の値を透過すること"
                      + "(既定の false 固定だと検証側が取り直しの周回自体を行わない): \(missingSupports)")
        XCTAssertTrue(missingElementLimit.isEmpty,
                      "同じ型は raiseElementLimitOnNextSnapshot も base へ素通しすること"
                      + "(既定の no-op に落ちると maxElements が黙って効かない): \(missingElementLimit)")
        XCTAssertTrue(missingPointScale.isEmpty,
                      "同じ型は pointScale も base の値を透過すること"
                      + "(既定の 1 に落ちると Android の木が px なのに pt の床で判定される): \(missingPointScale)")
    }
}
