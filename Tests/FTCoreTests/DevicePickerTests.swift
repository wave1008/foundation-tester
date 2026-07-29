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

    // MARK: - シミュレータ選定

    /// **入力順に依存しない**: SimulatorCatalog は起動中を先頭に寄せるので、先頭を最新 OS と
    /// みなすと「古い OS の起動中デバイス」を掴む(実際にその実装だった)
    func testPicksNewestOSEvenWhenAnOlderOneIsListedFirst() {
        let devices = [
            (name: "iPhone 16", os: "iOS 26.2"),      // 起動中なので先頭に来ている想定
            (name: "iPhone 17 Pro", os: "iOS 27.0"),
            (name: "iPhone 17", os: "iOS 27.0"),
        ]
        let index = DevicePicker.pickSimulatorIndex(devices)
        XCTAssertEqual(index.map { devices[$0].name }, "iPhone 17 Pro")
    }

    /// 最新 OS の中では "Pro" を優先する
    func testPrefersProWithinNewestOS() {
        let devices = [
            (name: "iPhone 17", os: "iOS 27.0"),
            (name: "iPhone 17 Pro Max", os: "iOS 27.0"),
            (name: "iPhone 17 Pro", os: "iOS 26.2"),  // Pro だが OS が古い
        ]
        let index = DevicePicker.pickSimulatorIndex(devices)
        XCTAssertEqual(index.map { devices[$0].name }, "iPhone 17 Pro Max")
    }

    /// Pro が無ければ最新 OS の先頭(= 呼び出し側の並び順 = 起動中優先 を尊重する)
    func testFallsBackToFirstOfNewestOS() {
        let devices = [
            (name: "iPhone 16", os: "iOS 26.2"),
            (name: "iPhone Air", os: "iOS 27.0"),
            (name: "iPhone 17e", os: "iOS 27.0"),
        ]
        let index = DevicePicker.pickSimulatorIndex(devices)
        XCTAssertEqual(index.map { devices[$0].name }, "iPhone Air")
    }

    func testReturnsNilWhenNoSimulators() {
        XCTAssertNil(DevicePicker.pickSimulatorIndex([]))
    }

    /// iPad は自動選定の対象外。"Pro" 優先の規則があるので、除外しないと最新 OS の
    /// iPad Pro を掴む(iPhone より前に並んでいても選ばない)
    func testExcludesIPad() {
        let devices = [
            (name: "iPad Pro 13-inch (M4)", os: "iOS 27.0"),
            (name: "iPhone 17", os: "iOS 27.0"),
            (name: "iPad mini (A17 Pro)", os: "iOS 27.0"),
        ]
        let index = DevicePicker.pickSimulatorIndex(devices)
        XCTAssertEqual(index.map { devices[$0].name }, "iPhone 17")
    }

    /// iPad しか無ければ選ばない(呼び出し側が「明示指定してください」と案内する)
    func testReturnsNilWhenOnlyIPads() {
        XCTAssertNil(DevicePicker.pickSimulatorIndex([
            (name: "iPad Pro 13-inch (M4)", os: "iOS 27.0"),
            (name: "iPad Air 11-inch (M3)", os: "iOS 26.2"),
        ]))
        XCTAssertTrue(DevicePicker.isIPad(name: "iPad Pro 13-inch (M4)"))
        XCTAssertFalse(DevicePicker.isIPad(name: "iPhone 17 Pro"))
    }

    /// iPad を除いた後で最新 OS を決める(iPad だけが最新 OS でも、iPhone の最新に落ちる)
    func testNewestOSIsComputedAfterExcludingIPad() {
        let devices = [
            (name: "iPad Pro 13-inch (M4)", os: "iOS 27.0"),
            (name: "iPhone 16", os: "iOS 26.2"),
            (name: "iPhone 16 Pro", os: "iOS 26.2"),
        ]
        let index = DevicePicker.pickSimulatorIndex(devices)
        XCTAssertEqual(index.map { devices[$0].name }, "iPhone 16 Pro")
    }

    // MARK: - AVD 選定

    func testPicksHighestAPILevel() {
        let picked = DevicePicker.pickAVD([
            ("Pixel_8_Android_14", 34),
            ("Pixel_10_Pro_Android_17", 37),
            ("Pixel_9a", 35),
        ])
        XCTAssertEqual(picked, "Pixel_10_Pro_Android_17")
    }

    /// 同点・不明(-1)は名前順で決定的に(実行ごとに選択が変わらない)
    func testTiesAndUnknownsAreDeterministic() {
        XCTAssertEqual(DevicePicker.pickAVD([("b", 36), ("a", 36)]), "a")
        XCTAssertEqual(DevicePicker.pickAVD([("unknown", -1), ("known", 30)]), "known")
        XCTAssertNil(DevicePicker.pickAVD([]))
    }

    func testAPILevelFromConfigINI() {
        let ini = """
        avd.ini.encoding=UTF-8
        image.sysdir.1=system-images/android-36/google_apis_playstore/arm64-v8a/
        tag.id=google_apis_playstore
        """
        XCTAssertEqual(DevicePicker.apiLevel(fromConfigINI: ini), 36)
    }

    /// 読めない/書式が違うときは -1(判定不能。選定の最後尾へ回る)
    func testAPILevelUnknownWhenNotFound() {
        XCTAssertEqual(DevicePicker.apiLevel(fromConfigINI: ""), -1)
        XCTAssertEqual(DevicePicker.apiLevel(fromConfigINI: "image.sysdir.1=system-images/x/"), -1)
    }

    // MARK: - 実機判定

    /// エミュレータを実機扱いすると実機向けの準備処理が走って run が壊れる
    func testEmulatorSerialIsNotPhysical() {
        XCTAssertFalse(DevicePicker.isPhysicalAndroidSerial("emulator-5554"))
        XCTAssertTrue(DevicePicker.isPhysicalAndroidSerial("14141JEC204922"))
    }
}
