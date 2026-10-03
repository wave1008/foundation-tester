// `--auto-device` の選定規則。実機/シミュレータを用意せず確かめられるよう純粋ロジックにしてある。
import XCTest
@testable import FTCore

final class DevicePickerTests: XCTestCase {

    // MARK: - OS バージョン比較

    /// 文字列比較だと "26.10" < "26.9" になる(桁数の違いで新旧が逆転する)
    func testVersionComparisonIsNumericNotLexical() {
        XCTAssertTrue(DevicePicker.isNewer("iOS 26.10", than: "iOS 26.9"))
        XCTAssertFalse(DevicePicker.isNewer("iOS 26.9", than: "iOS 26.10"))
        XCTAssertTrue(DevicePicker.isNewer("iOS 27.0", than: "iOS 26.10"))
    }

    /// 桁数が違っても比較できる("27" と "27.0" は同値)
    func testVersionComparisonPadsMissingComponents() {
        XCTAssertFalse(DevicePicker.isNewer("iOS 27", than: "iOS 27.0"))
        XCTAssertTrue(DevicePicker.isNewer("iOS 27.1", than: "iOS 27"))
    }

    // MARK: - iOS ランタイム選定

    private typealias RT = (identifier: String, version: String, name: String)
    private let ios26: RT = ("com.apple.CoreSimulator.SimRuntime.iOS-26-2", "26.2", "iOS 26.2")
    private let ios27: RT = ("com.apple.CoreSimulator.SimRuntime.iOS-27-0", "27.0", "iOS 27.0")

    func testRuntimeUsesInstalledWhenItReachesTheSDK() {
        XCTAssertEqual(DevicePicker.newestIOSRuntime(installed: [ios26, ios27], sdkVersion: "27.0"),
                       .installed(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0"))
        // SDK より新しい導入済み(ベータ等)もそのまま使う
        XCTAssertEqual(DevicePicker.newestIOSRuntime(installed: [ios26, ios27], sdkVersion: "26.4"),
                       .installed(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0"))
    }

    func testRuntimeNeedsDownloadWhenInstalledIsOlderThanSDK() {
        XCTAssertEqual(DevicePicker.newestIOSRuntime(installed: [ios26], sdkVersion: "27.0"),
                       .needsDownload(version: "27.0"))
        XCTAssertEqual(DevicePicker.newestIOSRuntime(installed: [], sdkVersion: "27.0"),
                       .needsDownload(version: "27.0"))
    }

    /// 文字列比較だと "26.10" < "26.9" になる
    func testRuntimeComparisonIsNumeric() {
        let ios2610: RT = ("com.apple.CoreSimulator.SimRuntime.iOS-26-10", "26.10", "iOS 26.10")
        let ios269: RT = ("com.apple.CoreSimulator.SimRuntime.iOS-26-9", "26.9", "iOS 26.9")
        XCTAssertEqual(DevicePicker.newestIOSRuntime(installed: [ios269, ios2610], sdkVersion: "26.9"),
                       .installed(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-10"))
    }

    func testRuntimeFallsBackToInstalledWhenSDKUnreadable() {
        XCTAssertEqual(DevicePicker.newestIOSRuntime(installed: [ios26, ios27], sdkVersion: nil),
                       .installed(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0"))
        XCTAssertEqual(DevicePicker.newestIOSRuntime(installed: [ios26], sdkVersion: ""),
                       .installed(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-2"))
        XCTAssertNil(DevicePicker.newestIOSRuntime(installed: [], sdkVersion: nil))
    }

    func testPredictedRuntimeIdentifier() {
        XCTAssertEqual(DevicePicker.predictedIOSRuntimeIdentifier(version: "27.0"),
                       "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        XCTAssertEqual(DevicePicker.predictedIOSRuntimeIdentifier(version: "26.10"),
                       "com.apple.CoreSimulator.SimRuntime.iOS-26-10")
        XCTAssertEqual(DevicePicker.predictedIOSRuntimeIdentifier(version: "27"),
                       "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        XCTAssertNil(DevicePicker.predictedIOSRuntimeIdentifier(version: "beta"))
    }

    // MARK: - iPhone <数字> 選定

    private func type(_ suffix: String) -> String { "com.apple.CoreSimulator.SimDeviceType.\(suffix)" }

    func testPicksHighestPlainNumberAndExcludesDecoratedVariants() {
        let ids = ["iPhone-17", "iPhone-18-Pro", "iPhone-17e", "iPhone-Air", "iPhone-Duo", "iPhone-18",
                   "iPhone-SE-3rd-generation"].map(type)
        XCTAssertEqual(DevicePicker.newestIPhoneDeviceType(identifiers: ids, supportedBy: nil),
                       "com.apple.CoreSimulator.SimDeviceType.iPhone-18")
    }

    func testNumberIsNumericNotLexical() {
        XCTAssertEqual(DevicePicker.newestIPhoneDeviceType(
            identifiers: ["iPhone-9", "iPhone-10"].map(type), supportedBy: nil),
            "com.apple.CoreSimulator.SimDeviceType.iPhone-10")
    }

    func testIsRestrictedToRuntimeSupportedTypesWhenInstalled() {
        let ids = ["iPhone-18", "iPhone-17"].map(type)
        XCTAssertEqual(DevicePicker.newestIPhoneDeviceType(
            identifiers: ids, supportedBy: [type("iPhone-17")]),
            "com.apple.CoreSimulator.SimDeviceType.iPhone-17")
        XCTAssertNil(DevicePicker.newestIPhoneDeviceType(identifiers: ids, supportedBy: []))
    }

    func testNoPlainIPhoneYieldsNil() {
        XCTAssertNil(DevicePicker.newestIPhoneDeviceType(
            identifiers: ["iPhone-18-Pro", "iPhone-17e", "iPhone-Air", "iPad-Pro-13-inch-M4"].map(type),
            supportedBy: nil))
    }

    func testIOSAutoTargetCombinesRuntimeAndDeviceType() {
        let runtime = DevicePicker.IOSRuntimeInfo(
            identifier: ios26.identifier, version: "26.2", name: "iOS 26.2",
            supportedDeviceTypeIdentifiers: [type("iPhone-17")])
        let ids = ["iPhone-18", "iPhone-17"].map(type)
        // 導入済みで SDK に届いている → ランタイムが対応する中の最新
        XCTAssertEqual(
            DevicePicker.iosAutoTarget(runtimes: [runtime], deviceTypeIdentifiers: ids, sdkVersion: "26.2"),
            DevicePicker.IOSAutoTarget(runtime: .installed(identifier: ios26.identifier),
                                       deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17"))
        // 要ダウンロード → 絞らず最新
        XCTAssertEqual(
            DevicePicker.iosAutoTarget(runtimes: [runtime], deviceTypeIdentifiers: ids, sdkVersion: "27.0"),
            DevicePicker.IOSAutoTarget(runtime: .needsDownload(version: "27.0"),
                                       deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-18"))
        XCTAssertNil(DevicePicker.iosAutoTarget(runtimes: [], deviceTypeIdentifiers: [], sdkVersion: nil))
    }

    // MARK: - Android の機種・システムイメージ選定

    func testNewestPixelPhonePicksHighestNumber() {
        let models: [(id: String, name: String)] = [
            ("pixel_9", "Pixel 9"), ("pixel_10", "Pixel 10"), ("pixel_9a", "Pixel 9a"),
            ("pixel_10_pro", "Pixel 10 Pro"), ("pixel_fold", "Pixel Fold"), ("pixel_11_pro", "Pixel 11 Pro"),
        ]
        let picked = DevicePicker.newestPixelPhone(models)
        XCTAssertEqual(picked?.id, "pixel_10")
        XCTAssertEqual(picked?.name, "Pixel 10")
    }

    func testNewestPixelPhoneIgnoresUnnumberedAndNonPixel() {
        XCTAssertNil(DevicePicker.newestPixelPhone([
            ("pixel_c", "Pixel C"), ("pixel_xl", "Pixel XL"), ("pixel", "Pixel"),
            ("pixel_tablet", "Pixel Tablet"), ("medium_phone", "Medium Phone"),
        ]))
        XCTAssertNil(DevicePicker.newestPixelPhone([]))
        XCTAssertEqual(DevicePicker.newestPixelPhone([("pixel_c", "Pixel C"), ("pixel_2", "Pixel 2")])?.id, "pixel_2")
    }

    /// 「Pixel N」と「Pixel Na」だけが対象。同じ N なら無印、a の N が大きければ a
    func testNewestPixelPhoneAcceptsAModels() {
        let decorated: [(id: String, name: String)] = [
            ("pixel_11_pro", "Pixel 11 Pro"), ("pixel_11_pro_xl", "Pixel 11 Pro XL"),
            ("pixel_11_pro_fold", "Pixel 11 Pro Fold"), ("pixel_fold", "Pixel Fold"),
            ("pixel_tablet", "Pixel Tablet"), ("pixel_11ab", "Pixel 11ab"),
        ]
        XCTAssertEqual(DevicePicker.newestPixelPhone(
            decorated + [("pixel_10a", "Pixel 10a"), ("pixel_10", "Pixel 10"), ("pixel_9a", "Pixel 9a")])?.id,
            "pixel_10")
        XCTAssertEqual(DevicePicker.newestPixelPhone(
            [("pixel_10", "Pixel 10"), ("pixel_10a", "Pixel 10a")])?.id, "pixel_10", "並び順に依らず無印")
        XCTAssertEqual(DevicePicker.newestPixelPhone(
            decorated + [("pixel_9", "Pixel 9"), ("pixel_10a", "Pixel 10a")])?.id, "pixel_10a")
        XCTAssertNil(DevicePicker.newestPixelPhone(decorated + [("pixel_a", "Pixel a")]))
    }

    private func image(_ api: Int, tag: String = "google_apis", abi: String = "arm64-v8a")
        -> DevicePicker.SystemImageCandidate {
        .init(package: "system-images;android-\(api);\(tag);\(abi)", apiLevel: api, tag: tag, abi: abi)
    }

    func testNewestSystemImagePrefersInstalledOnTie() {
        let picked = DevicePicker.newestSystemImage(
            installed: [image(35), image(36)], downloadable: [image(36), image(34)],
            tag: "google_apis", abi: "arm64-v8a")
        XCTAssertEqual(picked?.image.apiLevel, 36)
        XCTAssertEqual(picked?.isInstalled, true)
    }

    func testNewestSystemImagePicksNewerDownloadable() {
        let picked = DevicePicker.newestSystemImage(
            installed: [image(35)], downloadable: [image(37), image(36)],
            tag: "google_apis", abi: "arm64-v8a")
        XCTAssertEqual(picked?.image.package, "system-images;android-37;google_apis;arm64-v8a")
        XCTAssertEqual(picked?.isInstalled, false)
    }

    func testNewestSystemImageFiltersTagAndABI() {
        let picked = DevicePicker.newestSystemImage(
            installed: [image(36, tag: "google_apis_playstore"), image(36, abi: "x86_64"), image(33)],
            downloadable: [image(37, tag: "default")],
            tag: "google_apis", abi: "arm64-v8a")
        XCTAssertEqual(picked?.image.apiLevel, 33)
        XCTAssertNil(DevicePicker.newestSystemImage(
            installed: [image(36, tag: "default")], downloadable: [], tag: "google_apis", abi: "arm64-v8a"))
    }

    func testAndroidAutoTargetNeedsBothModelAndImage() {
        let models: [(id: String, name: String)] = [("pixel_10", "Pixel 10"), ("pixel_9", "Pixel 9")]
        let target = DevicePicker.androidAutoTarget(
            models: models, installed: [image(35)], downloadable: [image(36)],
            tag: "google_apis", abi: "arm64-v8a")
        XCTAssertEqual(target?.model.id, "pixel_10")
        XCTAssertEqual(target?.image.package, "system-images;android-36;google_apis;arm64-v8a")
        XCTAssertEqual(target?.isInstalled, false)
        XCTAssertNil(DevicePicker.androidAutoTarget(
            models: [], installed: [image(35)], downloadable: [], tag: "google_apis", abi: "arm64-v8a"))
        XCTAssertNil(DevicePicker.androidAutoTarget(
            models: models, installed: [], downloadable: [], tag: "google_apis", abi: "arm64-v8a"))
    }

    // MARK: - 実機判定

    /// エミュレータを実機扱いすると実機向けの準備処理が走って run が壊れる
    func testEmulatorSerialIsNotPhysical() {
        XCTAssertFalse(DevicePicker.isPhysicalAndroidSerial("emulator-5554"))
        XCTAssertTrue(DevicePicker.isPhysicalAndroidSerial("14141JEC204922"))
    }
}
