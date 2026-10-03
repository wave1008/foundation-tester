import XCTest
@testable import FTCore

final class VirtualDeviceNamingTests: XCTestCase {

    // MARK: - 正解表(vscode-fleetest/test/deviceNaming.test.mjs と共有)

    private static let casesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/VirtualDeviceNaming/cases.json")

    private func loadCases() throws -> [String: [[String: Any]]] {
        let data = try Data(contentsOf: Self.casesURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]])
    }

    func testBaseNameMatchesSharedCases() throws {
        let rows = try XCTUnwrap(loadCases()["baseName"])
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            XCTAssertEqual(
                VirtualDeviceNaming.baseName(model: row["model"] as! String, osLabel: row["osLabel"] as! String),
                row["expected"] as? String)
        }
    }

    func testNextUnusedNamesMatchesSharedCases() throws {
        let rows = try XCTUnwrap(loadCases()["nextUnusedNames"])
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            XCTAssertEqual(
                VirtualDeviceNaming.nextUnusedNames(
                    base: row["base"] as! String, existing: row["existing"] as! [String],
                    count: row["count"] as! Int),
                row["expected"] as? [String], "\(row["base"] ?? "")")
        }
    }

    // MARK: - リテラル

    func testAndroidOSLabelMarksOnlyPlayStoreTags() {
        XCTAssertEqual(VirtualDeviceNaming.androidOSLabel(apiLevel: 36, tag: "google_apis"),
                       "Android 16, API 36, APIs")
        XCTAssertEqual(VirtualDeviceNaming.androidOSLabel(apiLevel: 36, tag: "google_apis_playstore"),
                       "Android 16, API 36, Play")
        XCTAssertEqual(VirtualDeviceNaming.androidOSLabel(apiLevel: 36, tag: "google_apis_playstore_ps16k"),
                       "Android 16, API 36, Play")
        XCTAssertEqual(VirtualDeviceNaming.androidOSLabel(apiLevel: 36, tag: "google_apis_ps16k"),
                       "Android 16, API 36, APIs")
        XCTAssertEqual(VirtualDeviceNaming.androidOSLabel(apiLevel: 35, tag: "default"),
                       "Android 15, API 35, default")
        XCTAssertEqual(VirtualDeviceNaming.androidOSLabel(apiLevel: 32, tag: "google_apis"),
                       "Android 12L, API 32, APIs")
        XCTAssertEqual(VirtualDeviceNaming.androidOSLabel(apiLevel: 19, tag: "google_apis"),
                       "API 19, APIs")
    }

    func testSerialNumberRequiresExactlyTwoAsciiDigits() {
        let base = "Pixel 9(Android 15)"
        XCTAssertEqual(VirtualDeviceNaming.serialNumber(of: base + "-07", base: base), 7)
        for bad in ["-1", "-001", "-ab", "-", "", "-1a", "-٠١"] {
            XCTAssertNil(VirtualDeviceNaming.serialNumber(of: base + bad, base: base), bad)
        }
        XCTAssertNil(VirtualDeviceNaming.serialNumber(of: "iPhone 17 Pro Max(iOS 27.0)-01",
                                                      base: "iPhone 17 Pro(iOS 27.0)"))
    }

    func testAndroidImageFromSysdir() {
        let image = VirtualDeviceNaming.androidImage(
            fromSysdir: "system-images/android-35/google_apis/arm64-v8a/")
        XCTAssertEqual(image?.package, "system-images;android-35;google_apis;arm64-v8a")
        XCTAssertEqual(image?.apiLevel, 35)
        XCTAssertEqual(image?.tag, "google_apis")
        let minor = VirtualDeviceNaming.androidImage(
            fromSysdir: "system-images/android-36.1/google_apis_playstore/arm64-v8a")
        XCTAssertEqual(minor?.package, "system-images;android-36.1;google_apis_playstore;arm64-v8a")
        XCTAssertEqual(minor?.apiLevel, 36)
        XCTAssertEqual(minor?.tag, "google_apis_playstore")
        XCTAssertNil(VirtualDeviceNaming.androidImage(fromSysdir: ""))
        XCTAssertNil(VirtualDeviceNaming.androidImage(fromSysdir: "system-images/android-35/"))
        XCTAssertNil(VirtualDeviceNaming.androidImage(fromSysdir: "x/android-35/a/b/"))
        XCTAssertNil(VirtualDeviceNaming.androidImage(fromSysdir: "system-images/android-x/a/b/"))
    }

    func testLowestMatchingSkipsCandidatesWithDifferentContent() {
        let base = "iPhone 17 Pro(iOS 27.0)"
        let names = [base + "-03", base + "-01", base + "-02", "other"]
        XCTAssertEqual(VirtualDeviceNaming.lowestMatching(base: base, names: names, matches: { _ in true }),
                       base + "-01")
        XCTAssertEqual(VirtualDeviceNaming.lowestMatching(base: base, names: names,
                                                          matches: { $0 != base + "-01" }),
                       base + "-02")
        XCTAssertEqual(VirtualDeviceNaming.lowestMatching(base: base, names: names,
                                                          matches: { $0 == base + "-03" }),
                       base + "-03")
        XCTAssertNil(VirtualDeviceNaming.lowestMatching(base: base, names: names, matches: { _ in false }))
        XCTAssertNil(VirtualDeviceNaming.lowestMatching(
            base: base, names: ["iPhone 17 Pro Max(iOS 27.0)-01"], matches: { _ in true }))
    }
}
