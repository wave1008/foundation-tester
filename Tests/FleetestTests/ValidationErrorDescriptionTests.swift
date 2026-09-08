import ArgumentParser
import XCTest

@testable import fleetest

/// `api *` の NDJSON `finished.error` は `error.localizedDescription` を写す(19 箇所)。
/// ArgumentParser の ValidationError は素のままだと本文を持たない localizedDescription を返し、
/// 拡張のバナーが「ValidationError error 1」だけになる(実害 2026-09-08: 実行プロファイルが
/// 参照する台が1台も無い理由が受け手に届かなかった)
final class ValidationErrorDescriptionTests: XCTestCase {

    func testLocalizedDescriptionCarriesTheMessage() {
        let error: Error = ValidationError("none of the devices referenced by run profile x exist")
        XCTAssertEqual(error.localizedDescription,
                       "none of the devices referenced by run profile x exist")
    }
}
