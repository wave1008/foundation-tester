// FMHealth.describe が入れ子エラーを畳めることの検証。
// FM の失敗は最上位が常に「The operation couldn't be completed.」で、真因は
// NSMultipleUnderlyingErrors の奥にしかない。ここが壊れると「FM 全滅」は分かるが理由が消える。

import XCTest
@testable import FTCore

final class FMHealthDescribeTests: XCTestCase {

    private func error(_ domain: String, _ code: Int, underlying: [NSError] = [],
                       single: NSError? = nil) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: "\(domain) の説明"]
        if !underlying.isEmpty { info[NSMultipleUnderlyingErrorsKey] = underlying }
        if let single { info[NSUnderlyingErrorKey] = single }
        return NSError(domain: domain, code: code, userInfo: info)
    }

    /// 実際に観測した連鎖(LanguageModelError → SCA → BackendError → ModelManagerError)を畳む
    func testUnwrapsMultipleUnderlyingErrorChain() {
        let root = error("ModelManagerServices.ModelManagerError", 1001)
        let backend = error("CombinedTextSanitizerBackend.BackendError", 1, single: root)
        let sca = error("com.apple.SensitiveContentAnalysisML", 15, underlying: [backend])
        let top = error("FoundationModels.LanguageModelError", -1, underlying: [sca])

        let described = FMHealth.describe(top)
        XCTAssertTrue(described.contains("FoundationModels.LanguageModelError(-1)"), described)
        XCTAssertTrue(described.contains("com.apple.SensitiveContentAnalysisML(15)"), described)
        // **真因**がここに出ることがこの関数の存在理由
        XCTAssertTrue(described.contains("ModelManagerServices.ModelManagerError(1001)"), described)
        XCTAssertTrue(described.contains("←"), described)
    }

    /// 入れ子が無いエラーも 1 段だけで畳める(素通り)
    func testFlatErrorIsDescribedAsIs() {
        XCTAssertEqual(FMHealth.describe(error("Some.Domain", 42)), "Some.Domain(42): Some.Domain の説明")
    }

    /// 暴走した入れ子で無限に伸びないよう limit で打ち切る
    func testStopsAtLimit() {
        var current = error("Leaf", 0)
        for i in 1...10 { current = error("Level\(i)", i, single: current) }
        let described = FMHealth.describe(current, limit: 3)
        XCTAssertEqual(described.components(separatedBy: " ← ").count, 3, described)
    }
}
