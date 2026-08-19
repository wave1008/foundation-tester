import XCTest
@testable import FTCore

/// 既定アプリの優先順(明示 > 実行プロファイル)と、決められないときの言い方を固定する。
/// **この規則の定義元は ScenarioAppResolution だけ** —— ランナーは結果を転写するのみ
final class ScenarioAppResolutionTests: XCTestCase {

    private func resolve(_ declared: String?, _ profile: String?,
                         dryRun: Bool = false) -> ScenarioAppResolution.Result {
        ScenarioAppResolution.resolve(declared: declared, fromProfile: profile,
                                      scenarioID: "T.S0010", dryRun: dryRun)
    }

    func test明示だけあれば明示を使い警告は出さない() {
        XCTAssertEqual(resolve("com.a", nil), .resolved(bundleID: "com.a", warning: nil))
    }

    func testプロファイルだけあればプロファイルを使う() {
        XCTAssertEqual(resolve(nil, "com.b"), .resolved(bundleID: "com.b", warning: nil))
    }

    func test同値なら警告は出ない() {
        XCTAssertEqual(resolve("com.a", "com.a"), .resolved(bundleID: "com.a", warning: nil))
    }

    /// 明示が勝つ(多アプリ混在プロジェクトを壊さないため)。ただし黙らない
    func test食い違えば明示が勝ち両方の値を名指しで警告する() {
        guard case .resolved(let bundleID, let warning) = resolve("com.a", "com.b") else {
            return XCTFail("resolved を期待")
        }
        XCTAssertEqual(bundleID, "com.a")
        guard let warning else { return XCTFail("警告を期待") }
        XCTAssertTrue(warning.contains("com.a"), "採った側を名指しすること: \(warning)")
        XCTAssertTrue(warning.contains("com.b"), "捨てた側も名指しすること: \(warning)")
        XCTAssertTrue(warning.contains("T.S0010"), "どのシナリオの話か出すこと: \(warning)")
    }

    /// 旧 descriptor(マクロが app 省略時に "" を入れていた頃)や手書き conformance の空文字は
    /// 「書かれていない」として扱う。ここを素通しするとプロファイルへ落ちない
    func test空文字と空白だけの明示は未指定として扱う() {
        XCTAssertEqual(resolve("", "com.b"), .resolved(bundleID: "com.b", warning: nil))
        XCTAssertEqual(resolve("   ", "com.b"), .resolved(bundleID: "com.b", warning: nil))
        XCTAssertEqual(resolve("com.a", "  "), .resolved(bundleID: "com.a", warning: nil))
    }

    func test前後の空白は落として比較する() {
        XCTAssertEqual(resolve(" com.a ", "com.a"), .resolved(bundleID: "com.a", warning: nil))
    }

    /// 決められないまま走ると「どこかのアプリ」を叩くので止める。文言は逃げ道を全部出す
    func test両方無ければ実行時はエラーで逃げ道を列挙する() {
        guard case .unresolved(let message) = resolve(nil, nil) else {
            return XCTFail("unresolved を期待")
        }
        XCTAssertTrue(message.contains("--profile"), message)
        XCTAssertTrue(message.contains("--app"), message)
        XCTAssertTrue(message.contains("@TestClass(app:"), message)
        XCTAssertTrue(message.contains("T.S0010"), message)
    }

    /// dry-run はデバイスに触らず bundle ID を使わない。ここで落とすと
    /// 「実行プロファイル無しでは構文検査もできない」になる
    func testDryRunは未解決でも代替表記で通す() {
        XCTAssertEqual(resolve(nil, nil, dryRun: true),
                       .resolved(bundleID: ScenarioAppResolution.dryRunPlaceholder, warning: nil))
    }

    /// dry-run でも解決できるなら本物を使う(代替表記に倒さない)
    func testDryRunでも解決できれば本物を使う() {
        XCTAssertEqual(resolve(nil, "com.b", dryRun: true),
                       .resolved(bundleID: "com.b", warning: nil))
    }
}
