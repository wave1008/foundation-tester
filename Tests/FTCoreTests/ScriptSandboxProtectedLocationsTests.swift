import Foundation
import XCTest
@testable import FTCore

/// `hooks.writablePaths` に含めさせない場所の一覧。どれも親(枠の外)が実行・解釈するか、秘密の置き場
final class ScriptSandboxProtectedLocationsTests: XCTestCase {
    func testTheListNamesEveryPlaceTheParentInterprets() {
        let protected = ScriptSandbox.protectedLocations(
            workspace: URL(fileURLWithPath: "/ws"), projectRoot: URL(fileURLWithPath: "/proj"),
            stateRoots: ["/tool"], buildSources: ["/src/ext"], home: "/home/u")
        let paths = protected.map(\.path)
        XCTAssertEqual(paths, ["/ws/scripts", "/proj", "/home/u/.config/fleetest", "/home/u/.fleetest", "/tool", "/src/ext"])
        // ラベルは利用者への文言に入るので空にしない
        XCTAssertTrue(protected.allSatisfy { !$0.label.isEmpty })
    }

    /// 検めの入口(`HooksSettings.validate`)と組み合わせたとき、設定ファイルの置き場を含む指定は断られる
    func testASettingsDirectoryEntryIsRefusedByTheValidation() {
        let protected = ScriptSandbox.protectedLocations(
            workspace: URL(fileURLWithPath: "/ws"), projectRoot: URL(fileURLWithPath: "/proj"),
            stateRoots: [], buildSources: [], home: "/home/u")
        XCTAssertThrowsError(try HooksSettings.validate(writablePaths: ["/home/u/.config"], protected: protected))
        XCTAssertThrowsError(try HooksSettings.validate(writablePaths: ["/proj/scenarios"], protected: protected))
        XCTAssertNoThrow(try HooksSettings.validate(writablePaths: ["/home/u/shared/fixtures"], protected: protected))
    }
}
