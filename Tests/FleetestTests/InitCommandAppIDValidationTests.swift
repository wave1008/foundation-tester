import XCTest
@testable import fleetest

/// `--app-id` was written straight into profiles/apps/*.json and the scaffolded scenario
/// (`@TestClass(app:)` / `appIs(...)`) without any character check. `InitCommand.isValidAppID`
/// is shared by `init`/`project create`/`profile setup` (all three feed the same scaffold/profile
/// sinks) — the allowed set matches `AndroidWebViewDOM.probeCommand`'s.
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
