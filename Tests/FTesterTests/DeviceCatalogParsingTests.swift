// `ftester api device-catalog` の Android 側パースと整列規則。
// 出力は VSCode 拡張の「デバイス追加」ダイアログのモデル一覧・システムイメージ一覧になる。
// avdmanager の出力形式が変わる/整列規則を壊すと、一覧が静かに空になる・並びが崩れるが、
// 実機やエミュレータでは気付けない(実際に「avdmanager 不在でモデル一覧が空」の事故がある)。

import XCTest
@testable import ftester

final class DeviceCatalogParsingTests: XCTestCase {

    // MARK: - extractDeviceID

    func testExtractDeviceIDPicksQuotedIdentifier() {
        XCTAssertEqual(
            ApiDeviceCatalogCommand.extractDeviceID(from: #"    id: 26 or "pixel_9_pro""#),
            "pixel_9_pro")
    }

    func testExtractDeviceIDIgnoresNonIDLines() {
        XCTAssertNil(ApiDeviceCatalogCommand.extractDeviceID(from: "    Name: Pixel 9 Pro"))
        XCTAssertNil(ApiDeviceCatalogCommand.extractDeviceID(from: "---------"))
        XCTAssertNil(ApiDeviceCatalogCommand.extractDeviceID(from: ""))
    }

    func testExtractDeviceIDRequiresPairOfQuotes() {
        // 引用符が1つしかない行を id と誤認しない(壊れた出力で不正な id を掴まないため)
        XCTAssertNil(ApiDeviceCatalogCommand.extractDeviceID(from: #"    id: 26 or "pixel"#))
    }

    // MARK: - parseDeviceDefinitions

    /// avdmanager list device の実際の出力形。id 行 → Name 行 → OEM/Tag 行… が1機種分。
    private let sampleOutput = """
    Available devices definitions:
    id: 0 or "tv_1080p"
        Name: Android TV (1080p)
        OEM : Google
    ---------
    id: 26 or "pixel_9_pro"
        Name: Pixel 9 Pro
        OEM : Google
        Tag : google_apis
    ---------
    id: 27 or "pixel_10"
        Name: Pixel 10
        OEM : Google
    ---------
    id: 28 or "pixel"
        Name: Pixel
        OEM : Google
    """

    func testParseDeviceDefinitionsExtractsIDAndName() {
        let models = ApiDeviceCatalogCommand.parseDeviceDefinitions(sampleOutput)
        XCTAssertEqual(Set(models.map(\.id)), ["tv_1080p", "pixel_9_pro", "pixel_10", "pixel"])
        XCTAssertEqual(models.first(where: { $0.id == "pixel_9_pro" })?.name, "Pixel 9 Pro")
    }

    func testParseDeviceDefinitionsOrdersPixelsFirstByDescendingNumber() {
        let models = ApiDeviceCatalogCommand.parseDeviceDefinitions(sampleOutput)
        // Pixel 系が先頭・id 中の数値の降順。無番の "pixel" は数値 0 として同グループ末尾へ
        XCTAssertEqual(models.map(\.id), ["pixel_10", "pixel_9_pro", "pixel", "tv_1080p"])
    }

    func testParseDeviceDefinitionsIgnoresTrailingLinesOfSameEntry() {
        // Name 確定後の OEM/Tag 行を拾って二重登録しない
        let models = ApiDeviceCatalogCommand.parseDeviceDefinitions(sampleOutput)
        XCTAssertEqual(models.filter { $0.id == "pixel_9_pro" }.count, 1)
    }

    func testParseDeviceDefinitionsReturnsEmptyForUnparsableOutput() {
        // avdmanager が無い/エラーを吐いたときに壊れず空を返す(呼び出し側が理由を出す前提)
        XCTAssertTrue(ApiDeviceCatalogCommand.parseDeviceDefinitions("").isEmpty)
        XCTAssertTrue(ApiDeviceCatalogCommand.parseDeviceDefinitions(
            "Error: could not find avdmanager").isEmpty)
    }

    func testParseDeviceDefinitionsSkipsEntryWithoutName() {
        let models = ApiDeviceCatalogCommand.parseDeviceDefinitions("""
        id: 1 or "no_name"
            OEM : Google
        """)
        XCTAssertTrue(models.isEmpty)
    }

    // MARK: - firstNumber

    func testFirstNumberTakesFirstRunOfDigits() {
        XCTAssertEqual(ApiDeviceCatalogCommand.firstNumber(in: "pixel_9_pro"), 9)
        XCTAssertEqual(ApiDeviceCatalogCommand.firstNumber(in: "pixel_10"), 10)
        XCTAssertEqual(ApiDeviceCatalogCommand.firstNumber(in: "tv_1080p"), 1080)
    }

    func testFirstNumberIsZeroWhenAbsent() {
        // 無番機種を同グループ末尾へ寄せる sentinel
        XCTAssertEqual(ApiDeviceCatalogCommand.firstNumber(in: "pixel"), 0)
        XCTAssertEqual(ApiDeviceCatalogCommand.firstNumber(in: ""), 0)
    }

    // MARK: - modelSortsBefore

    func testModelSortsBeforePutsPixelAhead() {
        let pixel = ApiAndroidModel(id: "pixel_9", name: "Pixel 9")
        let other = ApiAndroidModel(id: "tv_1080p", name: "Android TV")
        XCTAssertTrue(ApiDeviceCatalogCommand.modelSortsBefore(pixel, other))
        XCTAssertFalse(ApiDeviceCatalogCommand.modelSortsBefore(other, pixel))
    }

    func testModelSortsBeforeUsesNameForNonPixels() {
        let a = ApiAndroidModel(id: "tv_1080p", name: "Android TV")
        let b = ApiAndroidModel(id: "wear_round", name: "Wear Round")
        XCTAssertTrue(ApiDeviceCatalogCommand.modelSortsBefore(a, b))
    }

    // MARK: - システムイメージの整列

    private func image(api: Int, tag: String, abi: String = "arm64-v8a") -> ApiAndroidSystemImage {
        ApiAndroidSystemImage(abi: abi, apiLevel: api, package: "system-images;android-\(api);\(tag);\(abi)",
                              tag: tag, versionName: "Android \(api)")
    }

    func testSystemImageSortsByDescendingAPILevelFirst() {
        XCTAssertTrue(ApiDeviceCatalogCommand.systemImageSortsBefore(
            image(api: 36, tag: "google_apis"), image(api: 35, tag: "google_apis")))
    }

    func testSystemImageTagRankOrder() {
        // google_apis < google_apis_playstore < default < その他
        XCTAssertEqual(ApiDeviceCatalogCommand.tagRank("google_apis"), 0)
        XCTAssertEqual(ApiDeviceCatalogCommand.tagRank("google_apis_playstore"), 1)
        XCTAssertEqual(ApiDeviceCatalogCommand.tagRank("default"), 2)
        XCTAssertEqual(ApiDeviceCatalogCommand.tagRank("android-automotive"), 3)

        XCTAssertTrue(ApiDeviceCatalogCommand.systemImageSortsBefore(
            image(api: 36, tag: "google_apis"), image(api: 36, tag: "default")))
    }

    func testSystemImagePrefersArm64WithinSameTag() {
        // Apple Silicon で動くのは arm64。x86_64 を先に出すと既定選択が動かない機種になる
        XCTAssertTrue(ApiDeviceCatalogCommand.systemImageSortsBefore(
            image(api: 36, tag: "google_apis", abi: "arm64-v8a"),
            image(api: 36, tag: "google_apis", abi: "x86_64")))
    }
}
