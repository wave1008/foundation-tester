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

    /// bash 側(clone 前・ビルド前に走るので Swift を呼べない)の比較と文言が同じ版を持つ
    func testShellGatesUseTheSameMinimum() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let comparison = try NSRegularExpression(
            pattern: #"-lt (\d+) \] \|\| \{ \[ "[^"]+" -eq (\d+) \] && \[ "[^"]+" -lt (\d+) \]"#)
        for script in ["Scripts/preflight.sh", "Scripts/install.sh"] {
            let text = try String(contentsOf: repo.appendingPathComponent(script), encoding: .utf8)
            let matches = comparison.matches(in: text, range: NSRange(text.startIndex..., in: text))
            XCTAssertEqual(matches.count, 1, "\(script) の版の比較が見つからない(走査の前提が崩れた)")
            guard let match = matches.first else { continue }
            let numbers = (1...3).compactMap { Range(match.range(at: $0), in: text).flatMap { Int(text[$0]) } }
            XCTAssertEqual(numbers, [XcodeRequirement.minimumMajor, XcodeRequirement.minimumMajor,
                                     XcodeRequirement.minimumMinor], script)
            XCTAssertTrue(text.contains("\(XcodeRequirement.display) or later is required"), script)
        }
    }
}
