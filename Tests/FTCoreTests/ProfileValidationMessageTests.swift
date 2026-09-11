// `api validate-profile`(ProfileResolver.validate)と machine 未決定の発話が、直す場所を言うこと:
// ①最上位が配列の JSON を「構文エラー」と言わない(正しい JSON で、要るのがオブジェクトなだけ)
// ②型の違いはキーと期待した型を名指しする(どの欄を直すか分からないため)
// ③machines/ が空なのに「複数あるので決められない」と言わない

import XCTest
@testable import FTCore

final class ProfileValidationMessageTests: XCTestCase {
    private let project = TestProject(name: "dummy", rootURL: URL(fileURLWithPath: "/tmp/dummy-\(UUID().uuidString)"))

    private func errors(_ json: String, kind: ProfileFileKind = .run) -> [String] {
        ProfileResolver.validate(kind: kind, data: Data(json.utf8), context: "x", project: project).errors
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
        let found = errors(#"{"app":"a","devices":[{"name":"d"}],"record":"yes"}"#)
        XCTAssertTrue(found.contains { $0.contains("\"record\": expected Bool") }, "\(found)")
    }

    func testANestedTypeMismatchNamesThePath() {
        let found = errors(#"{"ios":{"devices":[{"name":1}]}}"#, kind: .machine)
        XCTAssertTrue(found.contains { $0.contains("\"ios.devices[0].name\": expected String") }, "\(found)")
    }

    func testAnEmptyMachinesFolderIsNotCalledAmbiguous() {
        let message = ProfileError.machineUndetermined(available: []).localizedDescription
        XCTAssertTrue(message.contains("profiles/machines/ is empty"), message)
        XCTAssertFalse(message.contains("holds more than one"), message)
        XCTAssertTrue(ProfileError.machineUndetermined(available: ["a", "b"]).localizedDescription
            .contains("holds more than one"))
    }
}
