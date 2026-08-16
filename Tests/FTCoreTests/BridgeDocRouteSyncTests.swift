// docs/design.md のエンドポイント表が**実態(BridgeContractTests のルート表)とズレていない**ことを守る。
//
// 設計文書は受け手も保守者も最初に読む場所なので、本数が古いと「ここに無いルートは無い」と
// 誤読される。実際 2026-08-04 にジェスチャ2本を足したとき、表は 11/16/13/13 のまま残った。
// **唯一の正は BridgeContractTests のルート表**で、design.md はその写し(あちらにもそう書いてある)。

import XCTest
@testable import FTCore

final class BridgeDocRouteSyncTests: XCTestCase {

    private var design: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // FTCoreTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // リポジトリルート
                .appendingPathComponent("docs/design.md")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// 3実装に共通するルート(= 表が「共通のコア」と呼んでいるもの)
    private var commonCore: Set<String> {
        BridgeContractTests.inAppRoutes
            .intersection(BridgeContractTests.xcuiTestRoutes)
            .intersection(BridgeContractTests.androidRoutes)
    }

    func testCommonCoreCountMatches() throws {
        let text = try design
        // **数字だけを取り出す範囲を「上記」と「個」の間に限る**(文全体から数字を集めると
        // 「3実装」の 3 まで拾って 133 になる)
        guard let range = text.range(of: #"上記\d+個は3実装共通のコア"#, options: .regularExpression),
              let digits = text[range].split(separator: "個").first?.filter(\.isNumber),
              let count = Int(digits) else {
            return XCTFail("design.md の「上記N個は3実装共通のコア」が見つかりません")
        }
        XCTAssertEqual(count, commonCore.count,
                       "design.md の共通コア本数が実態とズレています(唯一の正は BridgeContractTests)")
    }

    /// 各ブリッジの合計本数(表の右端の数)
    func testPerBridgeTotalsMatch() throws {
        let text = try design
        let expected: [(label: String, routes: Set<String>)] = [
            ("XCUITest(Runner/)", BridgeContractTests.xcuiTestRoutes),
            ("Android(AndroidRunner/)", BridgeContractTests.androidRoutes),
            ("InApp", BridgeContractTests.inAppRoutes),
        ]
        for (label, routes) in expected {
            guard let line = text.split(separator: "\n").first(where: {
                $0.hasPrefix("| \(label) |")
            }) else {
                XCTFail("design.md に \(label) の行がありません")
                continue
            }
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertEqual(Int(cells.last ?? ""), routes.count,
                           "\(label) の本数が実態とズレています: \(line)")
        }
    }

    /// 「共通コアへの追加」欄に挙げたルートが、実際の差分と一致すること
    /// (本数だけ合わせて中身が違う、を防ぐ)
    func testPerBridgeExtrasMatch() throws {
        let text = try design
        let expected: [(label: String, routes: Set<String>)] = [
            ("XCUITest(Runner/)", BridgeContractTests.xcuiTestRoutes),
            ("Android(AndroidRunner/)", BridgeContractTests.androidRoutes),
            ("InApp", BridgeContractTests.inAppRoutes),
        ]
        for (label, routes) in expected {
            guard let line = text.split(separator: "\n").first(where: {
                $0.hasPrefix("| \(label) |")
            }) else { continue }
            let listed = Set(line.components(separatedBy: "`")
                .filter { $0.hasPrefix("POST /") || $0.hasPrefix("GET /") })
            XCTAssertEqual(listed, routes.subtracting(commonCore),
                           "\(label) の「共通コアへの追加」欄が実際の差分と違います")
        }
    }
}
