// `swipe(_:forScroll:)` を**包むドライバが必ず素通しする**ことを守る。
//
// AppDriver の既定実装は forScroll を捨てて自分の `swipe(_:)` を呼ぶ。ラッパーがこの既定に
// 頼ると、フラグは**最初のラッパーで落ちて**ブリッジまで届かない。届かないと in-app の
// Compose/Flutter はスクロール要求をジェスチャ要求と読んで 501 を返し、スクロールが丸ごと
// XCUITest へ回る —— つまり「動くが遅いまま」で、テストは緑のまま気付けない
// (2026-07-31 に実際にこれを踏み、フルスイートを2周回してから気付いた)。
//
// 各ラッパーの型を1つずつ書き並べるのではなく、**ソースを走査して
// 「swipe(_:) を実装しているのに forScroll 版が無い」型を検出する**。
// 新しいラッパーを足したときも自動的に対象になる。

import XCTest

final class SwipeForScrollForwardingTests: XCTestCase {

    /// 対象外。**包む相手を持たないドライバだけ**を入れること
    /// (包むのに入れると、この防波堤が守りたい事故そのものを見逃す)
    private static let exempt: Set<String> = [
        // プロトコル定義と既定実装そのもの
        "AppDriver.swift",
        // Android ブリッジを直接叩く葉ドライバ。素通しする base が無く、Android 側は
        // フラグを読まない(スクロールはネイティブに効くので in-app のような代替経路が要らない)
        "AndroidDriver.swift",
    ]

    func testEveryDriverImplementingSwipeAlsoForwardsForScroll() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTBridgeClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
        var offenders: [String] = []
        var checked = 0
        for dir in ["Sources/FTBridgeClient", "Sources/FTAndroid", "Sources/FTCore"] {
            let base = root.appendingPathComponent(dir)
            let files = (try? FileManager.default.contentsOfDirectory(at: base,
                                                                     includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "swift" {
                if Self.exempt.contains(file.lastPathComponent) { continue }
                guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
                guard source.contains("func swipe(_ direction: FTSwipeDirection) async throws") else { continue }
                checked += 1
                if !source.contains("func swipe(_ direction: FTSwipeDirection, forScroll: Bool)") {
                    offenders.append(file.lastPathComponent)
                }
            }
        }
        XCTAssertGreaterThan(checked, 3, "走査対象が見つからない = パスかシグネチャの書式が変わった")
        XCTAssertTrue(offenders.isEmpty,
                      "swipe(_:) を実装する型は forScroll 版も実装して base へ素通しすること"
                      + "(既定実装に任せるとフラグが落ちてスクロールが XCUITest へ回る): \(offenders)")
    }
}
