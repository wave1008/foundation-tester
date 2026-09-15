// SystemImageRepository のうち、ネットワークを伴わない部分(Google の sys-img2-3.xml から
// ダウンロード可能なシステムイメージを選ぶところ)のテスト。ここを間違えると、
// 別ホスト向け/未安定版/未対応の合成タグ(page-size 版等)を候補に出してしまう、
// あるいは既に入っているものを二重に出してしまう、という気付きにくい壊れ方をする。

import XCTest
@testable import FTAndroid

final class SystemImageRepositoryTests: XCTestCase {

    /// 実物(sys-img2-3.xml)と同じ構造を最小化したもの。channel は4つとも実物通り用意し、
    /// stable(channel-0)以外に解決されないことも一緒に確かめられるようにする
    private func xml(_ packages: String) -> Data {
        Data("""
        <?xml version='1.0' encoding='utf-8'?>
        <sys-img:sdk-sys-img xmlns:sys-img="http://schemas.android.com/sdk/android/repo/sys-img2/03"
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <channel id="channel-0">stable</channel>
          <channel id="channel-1">beta</channel>
          <channel id="channel-2">dev</channel>
          <channel id="channel-3">canary</channel>
        \(packages)
        </sys-img:sdk-sys-img>
        """.utf8)
    }

    private func remotePackage(
        path: String, channelRef: String = "channel-0",
        license: String? = "android-sdk-arm-dbt-license", size: Int? = 1_872_691_175
    ) -> String {
        let licenseLine = license.map { "<uses-license ref=\"\($0)\"/>" } ?? ""
        let sizeLine = size.map { "<size>\($0)</size>" } ?? ""
        return """
          <remotePackage path="\(path)">
            <revision><major>1</major></revision>
            \(licenseLine)
            <channelRef ref="\(channelRef)"/>
            <archives>
              <archive>
                <complete>
                  \(sizeLine)
                  <checksum type="sha1">deadbeef</checksum>
                  <url>x.zip</url>
                </complete>
              </archive>
            </archives>
          </remotePackage>
        """
    }

    // MARK: - フィルタリング

    func testStableChannelOnlyExcludesBetaEntries() throws {
        let data = xml(
            remotePackage(path: "system-images;android-36;google_apis;arm64-v8a", channelRef: "channel-0")
            + remotePackage(path: "system-images;android-35;google_apis;arm64-v8a", channelRef: "channel-1"))
        let entries = try SystemImageRepository.parse(xml: data, installedPackages: [], hostABI: "arm64-v8a")
        XCTAssertEqual(entries.map(\.apiLevel), [36])
    }

    func testDottedAPILevelIsExcluded() throws {
        // 実物: android-36.1 / android-37.2 のような拡張レベル付きパスが混じる。
        // インストール済みディレクトリ走査は整数の android-<N> しか見ないため、ここで拾うと
        // 「入れたのに一覧に出ない」システムイメージを作ってしまう
        let data = xml(
            remotePackage(path: "system-images;android-36;google_apis;arm64-v8a")
            + remotePackage(path: "system-images;android-36.1;google_apis;arm64-v8a"))
        let entries = try SystemImageRepository.parse(xml: data, installedPackages: [], hostABI: "arm64-v8a")
        XCTAssertEqual(entries.map(\.package), ["system-images;android-36;google_apis;arm64-v8a"])
    }

    func testOtherABIIsExcluded() throws {
        let data = xml(
            remotePackage(path: "system-images;android-36;google_apis;arm64-v8a")
            + remotePackage(path: "system-images;android-36;google_apis;x86_64"))
        let entries = try SystemImageRepository.parse(xml: data, installedPackages: [], hostABI: "arm64-v8a")
        XCTAssertEqual(entries.map(\.abi), ["arm64-v8a"])
    }

    func testPS16KVariantTagIsExcluded() throws {
        // 実物: google_apis の XML の中に google_apis_ps16k(16kbページサイズ版)が混在する。
        // avdmanager の models(id)一覧に対応が無いので候補に出さない
        let data = xml(
            remotePackage(path: "system-images;android-37;google_apis;arm64-v8a")
            + remotePackage(path: "system-images;android-37;google_apis_ps16k;arm64-v8a"))
        let entries = try SystemImageRepository.parse(xml: data, installedPackages: [], hostABI: "arm64-v8a")
        XCTAssertEqual(entries.map(\.tag), ["google_apis"])
    }

    func testInstalledPackageIsExcluded() throws {
        let path = "system-images;android-36;google_apis;arm64-v8a"
        let data = xml(remotePackage(path: path))
        let entries = try SystemImageRepository.parse(
            xml: data, installedPackages: [path], hostABI: "arm64-v8a")
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - フィールド抽出

    func testLicenseAndSizeAreExtracted() throws {
        let data = xml(remotePackage(
            path: "system-images;android-36;google_apis;arm64-v8a",
            license: "android-sdk-arm-dbt-license", size: 1_872_691_175))
        let entries = try SystemImageRepository.parse(xml: data, installedPackages: [], hostABI: "arm64-v8a")
        XCTAssertEqual(entries.first?.license, "android-sdk-arm-dbt-license")
        XCTAssertEqual(entries.first?.sizeBytes, 1_872_691_175)
        XCTAssertEqual(entries.first?.versionName, "Android 16")
    }

    func testMissingSizeBecomesNil() throws {
        let data = xml(remotePackage(path: "system-images;android-36;google_apis;arm64-v8a", size: nil))
        let entries = try SystemImageRepository.parse(xml: data, installedPackages: [], hostABI: "arm64-v8a")
        XCTAssertNil(entries.first?.sizeBytes)
    }

    /// "android/" タグ(AOSP のみ)の実ファイルは、remotePackage の path 自身が "default" を名乗る。
    /// URL/ファイル名("android")から "default" を推測してはいけない —— parse() には URL/ラベルを
    /// 渡していないので、この結果は XML の内容だけから出ていることの証明になる
    func testDefaultTagComesFromTheXMLPathNotFromAnyURLOrLabel() throws {
        let data = xml(remotePackage(path: "system-images;android-36;default;arm64-v8a"))
        let entries = try SystemImageRepository.parse(xml: data, installedPackages: [], hostABI: "arm64-v8a")
        XCTAssertEqual(entries.first?.tag, "default")
    }

    // MARK: - 整列

    func testSortOrderMatchesInstalledSystemImages() {
        let apiLevel35Google = SystemImageRepository.Entry(
            abi: "arm64-v8a", apiLevel: 35, license: nil, package: "p35-google-arm64",
            sizeBytes: nil, tag: "google_apis", versionName: "Android 15")
        let apiLevel36Default = SystemImageRepository.Entry(
            abi: "arm64-v8a", apiLevel: 36, license: nil, package: "p36-default-arm64",
            sizeBytes: nil, tag: "default", versionName: "Android 16")
        let apiLevel36GoogleX86 = SystemImageRepository.Entry(
            abi: "x86_64", apiLevel: 36, license: nil, package: "p36-google-x86_64",
            sizeBytes: nil, tag: "google_apis", versionName: "Android 16")
        let apiLevel36GoogleArm = SystemImageRepository.Entry(
            abi: "arm64-v8a", apiLevel: 36, license: nil, package: "p36-google-arm64",
            sizeBytes: nil, tag: "google_apis", versionName: "Android 16")

        let sorted = [apiLevel35Google, apiLevel36Default, apiLevel36GoogleX86, apiLevel36GoogleArm]
            .sorted(by: SystemImageRepository.sortsBefore)

        XCTAssertEqual(sorted.map(\.package), [
            "p36-google-arm64", "p36-google-x86_64", "p36-default-arm64", "p35-google-arm64",
        ])
    }

    func testTagRankOrder() {
        XCTAssertEqual(SystemImageRepository.tagRank("google_apis"), 0)
        XCTAssertEqual(SystemImageRepository.tagRank("google_apis_playstore"), 1)
        XCTAssertEqual(SystemImageRepository.tagRank("default"), 2)
        XCTAssertEqual(SystemImageRepository.tagRank("android-automotive"), 3)
    }

    // MARK: - 壊れた XML

    func testThrowsOnUnparsableXML() {
        XCTAssertThrowsError(
            try SystemImageRepository.parse(xml: Data("not xml".utf8), installedPackages: [], hostABI: "arm64-v8a"))
    }
}
