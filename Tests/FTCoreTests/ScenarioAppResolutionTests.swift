import XCTest
@testable import FTCore

/// 実行プロファイルが解決した値だけを採ることと、決められないときの言い方を固定する。
/// **この規則の定義元は ScenarioAppResolution だけ** —— ランナーは結果を転写するのみ
final class ScenarioAppResolutionTests: XCTestCase {

    private func resolve(_ profile: String?, dryRun: Bool = false) -> ScenarioAppResolution.Result {
        ScenarioAppResolution.resolve(fromProfile: profile, scenarioID: "T.S0010", dryRun: dryRun)
    }

    func testプロファイルがあればそれを使う() {
        XCTAssertEqual(resolve("com.b"), .resolved(bundleID: "com.b"))
    }

    func test前後の空白は落とす() {
        XCTAssertEqual(resolve(" com.b "), .resolved(bundleID: "com.b"))
    }

    /// 空文字・空白だけは「無い」として扱う。素通しすると空の bundle ID で起動を試みる
    func test空文字と空白だけは未解決として扱う() {
        for blank in ["", "   "] {
            guard case .unresolved = resolve(blank) else { return XCTFail("unresolved を期待: \(blank.debugDescription)") }
        }
    }

    /// 決められないまま走ると「どこかのアプリ」を叩くので止める。文言は逃げ道を全部出す
    func test無ければ実行時はエラーで逃げ道を列挙する() {
        guard case .unresolved(let message) = resolve(nil) else {
            return XCTFail("unresolved を期待")
        }
        XCTAssertTrue(message.contains("--profile"), message)
        XCTAssertTrue(message.contains("--app-id"), message)
        XCTAssertFalse(message.contains("@TestClass"), message)
        XCTAssertTrue(message.contains("T.S0010"), message)
    }

    /// dry-run はデバイスに触らず bundle ID を使わない。ここで落とすと
    /// 「実行プロファイル無しでは構文検査もできない」になる
    func testDryRunは未解決でも代替表記で通す() {
        XCTAssertEqual(resolve(nil, dryRun: true),
                       .resolved(bundleID: ScenarioAppResolution.dryRunPlaceholder))
    }

    /// dry-run でも解決できるなら本物を使う(代替表記に倒さない)
    func testDryRunでも解決できれば本物を使う() {
        XCTAssertEqual(resolve("com.b", dryRun: true), .resolved(bundleID: "com.b"))
    }
}
