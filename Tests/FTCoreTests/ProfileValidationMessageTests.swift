// `api validate-profile`(ProfileResolver.validate)の発話が、直す場所を言うこと:
// ①最上位が配列の JSON を「構文エラー」と言わない(正しい JSON で、要るのがオブジェクトなだけ)
// ②型の違いはキーと期待した型を名指しする(どの欄を直すか分からないため)

import XCTest
@testable import FTCore

final class ProfileValidationMessageTests: XCTestCase {
    private func errors(_ json: String, kind: ProfileFileKind = .run) -> [String] {
        ProfileResolver.validate(kind: kind, data: Data(json.utf8), context: "x").errors
    }

    func testAnArrayIsNotCalledASyntaxError() {
        let found = errors("[]")
        XCTAssertTrue(found.contains { $0.contains("top level must be a JSON object") && $0.contains("an array") }, "\(found)")
        XCTAssertFalse(found.contains { $0.contains("syntax error") }, "\(found)")
    }

    func testRealSyntaxErrorsStillSaySo() {
        XCTAssertTrue(errors("{").contains { $0.contains("syntax error") })
    }

    func testATypeMismatchNamesTheKeyAndTheExpectedType() {
        let found = errors(#"{"app":"a","devices":[{"platform":"ios","name":"d"}],"record":"yes"}"#)
        XCTAssertTrue(found.contains { $0.contains("\"record\": expected Bool") }, "\(found)")
    }

    func testANestedTypeMismatchNamesThePath() {
        let found = errors(#"{"app":"a","devices":[{"platform":"ios","name":1}]}"#)
        XCTAssertTrue(found.contains { $0.contains("\"devices[0].name\": expected String") }, "\(found)")
    }

    func testAnUnsupportedPlatformNamesTheKey() {
        let found = errors(#"{"app":"a","devices":[{"platform":"tvos","name":"d"}]}"#)
        XCTAssertTrue(found.contains { $0.contains("devices[0].platform") && $0.contains("tvos") }, "\(found)")
    }
}
