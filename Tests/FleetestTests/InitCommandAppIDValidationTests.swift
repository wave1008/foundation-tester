import XCTest
@testable import fleetest

/// `--app-id` of `profile setup` is written straight into profiles/apps/*.json, so
/// `InitCommand.isValidAppID` checks it — the allowed set matches `AndroidWebViewDOM.probeCommand`'s.
final class InitCommandAppIDValidationTests: XCTestCase {

    func testAcceptsOrdinaryBundleIDsAndPackageNames() {
        XCTAssertTrue(InitCommand.isValidAppID("com.example.myapp"))
        XCTAssertTrue(InitCommand.isValidAppID("com.example.my_app-2"))
        XCTAssertTrue(InitCommand.isValidAppID("A"))
    }

    func testRejectsEmpty() {
        XCTAssertFalse(InitCommand.isValidAppID(""))
    }

    func testRejectsShellMetacharacters() {
        XCTAssertFalse(InitCommand.isValidAppID("com.example.x;rm"))
        XCTAssertFalse(InitCommand.isValidAppID("com.example.x rm"))
        XCTAssertFalse(InitCommand.isValidAppID("com.example.x$(rm)"))
        XCTAssertFalse(InitCommand.isValidAppID("com.example.x\nrm"))
        XCTAssertFalse(InitCommand.isValidAppID("com.example.x/rm"))
    }
}
