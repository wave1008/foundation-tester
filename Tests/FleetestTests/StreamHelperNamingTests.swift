import FTCore
import XCTest

@testable import fleetest

/// 配信ヘルパーの名前を `api device-stream` が**リテラルで持たない**ことを固定する。
///
/// 持たせると、新しいヘルパーを足したときに `RemoteSetupPlan.alignRevisionCommand`(= リモート機で
/// 建てるもの)へ追随しなくても全部緑のまま通り、**そのランナーのタイルだけが黙って「映像なし」**
/// になる(2026-08-28 の実害。既存3本が丸ごとこれだった)。`StreamHelpers` を通していれば
/// 追加はそこに現れ、align のリテラル等号テストが落ちる。
final class StreamHelperNamingTests: XCTestCase {

    func testDeviceStreamNamesHelpersOnlyThroughStreamHelpers() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiDeviceStreamCommand.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("\"fleetest-"),
                       "配信ヘルパーは StreamHelpers 経由で名指しする"
                       + "(リテラルで書くと alignRevisionCommand が建て忘れても誰も落ちない)")
    }

    /// 名前が実際の実行ファイル名と食い違えば、リモートでは exec が失敗し手元では
    /// resolveSimStream(config.ts)が外れる。3本とも `fleetest-` 接頭辞の実在プロダクト名
    func testHelperNamesAreTheBuiltProductNames() {
        XCTAssertEqual(StreamHelpers.all,
                       ["fleetest-simstream", "fleetest-androidstream", "fleetest-devicepoll"])
    }
}
