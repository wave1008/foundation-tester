// 最低版の判定(XcodeRequirement)。Scripts/preflight.sh・install.sh の同じ判定と同期する。

import XCTest
@testable import FTCore

final class XcodeRequirementTests: XCTestCase {
    func testSupportedVersions() {
        for out in ["Xcode 27.2\nBuild version 27C1", "Xcode 27.2.1", "Xcode 28.0"] {
            XCTAssertEqual(XcodeRequirement.isSupported(versionOutput: out), true, out)
        }
    }

    func testOlderVersionsAreUnsupported() {
        for out in ["Xcode 27.1", "Xcode 26.4", "Xcode 26.9.9"] {
            XCTAssertEqual(XcodeRequirement.isSupported(versionOutput: out), false, out)
        }
    }

    func testUnreadableOutputIsNil() {
        for out in ["", "unknown", "Xcode", "Xcode x.y", "xcodebuild: error: ..."] {
            XCTAssertNil(XcodeRequirement.isSupported(versionOutput: out), out)
        }
    }

    func testDisplayIsPinned() {
        XCTAssertEqual(XcodeRequirement.display, "Xcode 27.2")
    }
}
