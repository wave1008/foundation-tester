import XCTest
@testable import FTCore

/// 環境変数の名前("FT_…")の生の文字列は1ファイルにだけ書く。2つ以上のファイルに写すと、片方の綴りがずれたときに
/// 黙って効かなくなる(書き手の名前とサンドボックスの置き場の一覧 `ScenarioSandbox.redirectedDirectoryKeys` がずれると、
/// 置き場の差し替えの確かめが外れる 等)。他のファイルは持ち主の定数(`ProcessEnvironmentKey` か持ち主の型の
/// `directoryOverrideKey` 等)を参照する。別ビルドの InAppBridge・Runner は Sources の外なので対象外
final class EnvironmentKeyLiteralTests: XCTestCase {
    func testEachEnvironmentKeyLiteralLivesInOneFile() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let literal = try NSRegularExpression(pattern: #""(FT_[A-Z0-9_]+)""#)
        var files: [String: Set<String>] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" && !url.path.contains("/Generated/") {
            let code = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for match in literal.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                guard let range = Range(match.range(at: 1), in: code) else { continue }
                files[String(code[range]), default: []].insert(url.lastPathComponent)
            }
        }
        XCTAssertGreaterThan(files.count, 50, "走査が環境変数の名前にほとんど届いていない")
        let duplicated = files.filter { $0.value.count > 1 }.mapValues { $0.sorted() }
        XCTAssertEqual(duplicated, [:], "同じ環境変数の名前を生の文字列で複数のファイルに書いている。持ち主の定数を参照すること")
    }

    /// シナリオの子が書く置き場を差し替える鍵(`FT_*_DIR`)は、サンドボックスが差し替え先を確かめる一覧に載せる。
    /// 載せ忘れると、書ける場所の外を指したときに起動前に止まらず、子が黙って書けずに効かなくなる。
    /// 子が書かない置き場は理由つきでこの表に置く(新しい `FT_*_DIR` はどちらかに分類するまで落ちる)
    private static let notWrittenByTheScenarioChild: [String: String] = [
        "FT_VIDEO_ENCODER_LIVENESS_DIR": "書くのは親(録画の切り出し・host-metrics)だけ",
        "FT_REPORT_DIR": "run の前後のスクリプトへ渡す出力先(シナリオの子ではない。スクリプトの枠は ScriptSandbox)",
    ]

    func testEveryDirectoryOverrideKeyIsCheckedByTheSandbox() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let literal = try NSRegularExpression(pattern: #""(FT_[A-Z0-9_]*_DIR)""#)
        var keys: Set<String> = []
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" && !url.path.contains("/Generated/") {
            let code = try String(contentsOf: url, encoding: .utf8)
            for match in literal.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                if let range = Range(match.range(at: 1), in: code) { keys.insert(String(code[range])) }
            }
        }
        XCTAssertGreaterThan(keys.count, 5, "走査が置き場の鍵に届いていない")
        let checked = Set(ScenarioSandbox.redirectedDirectoryKeys)
        let unclassified = keys.subtracting(checked).subtracting(Self.notWrittenByTheScenarioChild.keys)
        XCTAssertEqual(unclassified, [], "サンドボックスの一覧(redirectedDirectoryKeys)にも、子が書かない表にも無い置き場の鍵")
        XCTAssertEqual(checked.intersection(Self.notWrittenByTheScenarioChild.keys), [], "両方に載っている")
    }
}
