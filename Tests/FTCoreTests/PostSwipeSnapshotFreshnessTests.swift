// **スワイプ後に読む snapshot は必ずキャッシュを捨てる**ことを守る。
//
// Android の a11y ノードはキャッシュ供給で、ブリッジの整定を通っても数十 ms 遅れて公開される。
// 素の `driver.snapshot()` はスワイプ**前**の位置を返す瞬間があり(2026-08-03 実測: 4回中2回)、
// 古い木で探索を続けると「動かなかった」と誤認する / 見つけた要素が直後の解決で消えて
// `cannot resolve the locator` になる。静止判定はさらに悪く、古い木は連続して同じ署名を返すので
// **「2回続けて同じ = 止まった」が古い位置で成立する**(黙って誤った成功)。
//
// 型ではなく**関数の本文を走査する**: これらの関数に素の `driver.snapshot()` が1つでも
// 戻ると、失敗モードは沈黙(緑のまま誤った要素を掴む)なのでテストでは捕まらない。
// 撮り直す理由は `SnapshotFreshness` で書くので、走査もその語彙で行う(理由を書く形にしても
// 「素取得に戻す」「swiped を false 固定にする」は**コンパイラでは防げない**ため、この検査は残す)。
// 機構と実測は docs/verification.md「Compose の探索直後タップ」。

import XCTest

final class PostSwipeSnapshotFreshnessTests: XCTestCase {

    /// 本文に素の `driver.snapshot()` を置いてはいけない関数(すべて「スワイプ後に読む」経路)
    private static let mustBypass = [
        "func runScrollSearch(",
        "func settledSignature(",
        "func settleAfterScroll(",
    ]

    /// StepExecutor は StepExecutor*.swift に分割されている(+ScrollSearch/+Actions/+Settle 等)。
    /// 走査対象の関数がどのファイルへ移っても追えるよう、全ファイルを対象にする
    private static func sources() throws -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
        let dir = root.appendingPathComponent("Sources/FTCore")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("StepExecutor") && $0.hasSuffix(".swift") }
            .sorted()
        return try names.map {
            try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)
        }
    }

    /// 宣言行から**次のメンバ宣言(インデント4の func)まで**を本文とみなす。
    /// 完全なパーサではないが、この検査には十分(取りこぼすと関数が見つからず失敗する)。
    /// **宣言行はコメント行を除いて全ファイルで一意であること** —— 別ファイルのコメントが
    /// シグネチャに言及しただけで先勝ちすると、偽の「本文」を走査して黙って素通しする
    private static func body(of signature: String, in sources: [String]) -> [String]? {
        let hits: [(lines: [String], start: Int)] = sources.compactMap { source in
            let lines = source.components(separatedBy: "\n")
            let starts = lines.indices.filter { index in
                lines[index].contains(signature)
                    && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("//")
            }
            guard let start = starts.first else { return nil }
            guard starts.count == 1 else { return (lines, -1) }   // ファイル内重複 = 曖昧
            return (lines, start)
        }
        guard hits.count == 1, let hit = hits.first, hit.start >= 0 else { return nil }
        let (lines, start) = hit
        var end = lines.count
        for index in (start + 1)..<lines.count {
            let line = lines[index]
            if line.hasPrefix("    ") && !line.hasPrefix("     "),
               line.contains("func "), !line.contains("//") {
                end = index
                break
            }
        }
        return Array(lines[start..<end])
    }

    func testPostSwipeReadsBypassTheSnapshotCache() throws {
        let sources = try Self.sources()
        for signature in Self.mustBypass {
            guard let body = Self.body(of: signature, in: sources) else {
                XCTFail("走査対象が一意に見つからない = 書式が変わったか、他ファイルの非コメント行がシグネチャに触れている: \(signature)")
                continue
            }
            let bare = body.filter { $0.contains("driver.snapshot()") }
            XCTAssertTrue(bare.isEmpty,
                          "\(signature) はスワイプ後に読む経路なので freshSnapshot(.afterOwnMove) を使うこと。"
                          + "素取得だと古いツリーを掴んで黙って誤る: \(bare.map { $0.trimmingCharacters(in: .whitespaces) })")
            XCTAssertTrue(body.contains { $0.contains("freshSnapshot(.afterOwnMove)") },
                          "\(signature) にキャッシュ迂回の snapshot が1つも無い = 手当てが消えている")
        }
    }

    /// 探索がスワイプを撃った後の**ロケータ解決とその再試行**も迂回すること。
    /// 初回だけ迂回して再試行を素取得に戻すと、古い木は撮り直しても同じものが返るので
    /// **再試行の予算をまるごと空振りに使う**
    func testResolutionAfterScrollSearchBypassesOnEveryRetry() throws {
        let sources = try Self.sources()
        guard let body = Self.body(of: "func executeAction(", in: sources) else {
            return XCTFail("走査対象が一意に見つからない = executeAction の書式が変わったか、他ファイルの非コメント行がシグネチャに触れている")
        }
        // **`swiped:` の実引数まで見る**: `.afterSearch(swiped: false)` に固定されると
        // 理由は書かれたまま迂回が消えるので、語彙の存在だけでは検出できない
        let gated = body.filter { $0.contains("freshSnapshot(.afterSearch(swiped: searchSwiped))") }
        XCTAssertGreaterThanOrEqual(gated.count, 3,
                                    "探索後の解決 snapshot は初回と再試行2経路(timeout 指定 / 既定3回)の"
                                    + "計3箇所すべてを searchSwiped で迂回すること。現在 \(gated.count) 箇所")
    }
}
