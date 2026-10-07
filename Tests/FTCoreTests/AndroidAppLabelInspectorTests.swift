import XCTest
@testable import FTCore

final class AndroidAppLabelInspectorTests: XCTestCase {
    private let badging = """
        package: name='com.example.app' versionCode='1' versionName='1.0' platformBuildVersionName='14'
        sdkVersion:'24'
        application-label:'Shop'
        application-label-ja:'ショップ'
        application-label-de:'Laden'
        application-icon-160:'res/mipmap/ic_launcher.png'
        application: label='Shop' icon='res/mipmap/ic_launcher.png'
        launchable-activity: name='com.example.app.MainActivity'  label='Shop' icon=''
        """

    func testDefaultLabelFirstThenLocalesInOrder() {
        XCTAssertEqual(AndroidAppLabelInspector.labelCandidates(badging: badging), ["Shop", "ショップ", "Laden"])
    }

    func testOnlyLocalizedLabelsStillGiveCandidates() {
        XCTAssertEqual(AndroidAppLabelInspector.labelCandidates(badging: "application-label-ja:'ショップ'\n"), ["ショップ"])
    }

    func testEscapedQuoteEmptyAndDuplicateLabels() {
        let text = "application-label:'Bob\\'s'\napplication-label-fr:'Bob\\'s'\napplication-label-es:''\n"
        XCTAssertEqual(AndroidAppLabelInspector.labelCandidates(badging: text), ["Bob's"])
    }

    func testNoLabelOrGarbageIsEmpty() {
        XCTAssertEqual(AndroidAppLabelInspector.labelCandidates(badging: ""), [])
        XCTAssertEqual(AndroidAppLabelInspector.labelCandidates(badging: "ERROR: dump failed"), [])
    }

    func testBuildToolsNewestFirstComparesNumerically() {
        XCTAssertEqual(AndroidAppLabelInspector.newestFirst(["9.0.0", "34.0.0", "33.0.2"]),
                       ["34.0.0", "33.0.2", "9.0.0"])
    }

    func testUnreadablePathsAreEmpty() {
        XCTAssertEqual(AndroidAppLabelInspector.labelCandidates(apkPath: nil), [])
        XCTAssertEqual(AndroidAppLabelInspector.labelCandidates(apkPath: "/nonexistent/app.apk"), [])
        XCTAssertEqual(AndroidAppLabelInspector.labelCandidates(apkPath: "/tmp/app.aab"), [])
    }

    /// 食い違いの警告は iOS と同じ文(platform だけ android)。候補のどれかに一致すれば黙る
    func testMismatchWarningSharedWithIOS() {
        let candidates = AndroidAppLabelInspector.labelCandidates(badging: badging)
        XCTAssertNil(AppBundleInspector.appNameMismatchWarning(
            appRef: "shop", platform: "android", appName: "ショップ", candidates: candidates))
        let warning = AppBundleInspector.appNameMismatchWarning(
            appRef: "shop", platform: "android", appName: "Shop (dev)", candidates: candidates)
        XCTAssertTrue(warning?.contains("android.appName \"Shop (dev)\"") == true)
        XCTAssertNil(AppBundleInspector.appNameMismatchWarning(
            appRef: "shop", platform: "android", appName: "x", candidates: []))
    }
}
