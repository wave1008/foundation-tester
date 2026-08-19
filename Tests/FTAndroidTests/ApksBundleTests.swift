// .apks(スプリット APK の束)の判定・パース・bundletool 解決。デバイス不要。
// FT_LIVE_APKS=<.apks のパス> のときだけ、実デバイスへの install と差分判定のスモークも回す。

import XCTest
@testable import FTAndroid
import FTTestSupport

final class ApksBundleTests: XCTestCase {

    /// 実物(79MB・88 エントリ)の `unzip -l` から抜いた形。**master が2つある**のがこの形の要点
    private let listing = """
        Archive:  /apps/LAX_v10.48.6(5353)-stub-release.apks
          Length      Date    Time    Name
        ---------  ---------- -----   ----
             9819  01-01-1981 01:01   toc.pb
            45402  01-01-1981 01:01   splits/base-ja.apk
         16362882  01-01-1981 01:01   splits/base-master.apk
         38808962  01-01-1981 01:01   splits/base-master_2.apk
          4703264  01-01-1981 01:01   splits/base-arm64_v8a.apk
          1307582  01-01-1981 01:01   splits/base-xxhdpi.apk
        ---------                     -------
         78823436                     88 files
        """

    func testParseZipListingKeepsApksOnly() {
        let entries = ApksBundle.parseZipListing(listing)
        XCTAssertEqual(entries.map(\.name), [
            "splits/base-ja.apk", "splits/base-master.apk", "splits/base-master_2.apk",
            "splits/base-arm64_v8a.apk", "splits/base-xxhdpi.apk",
        ], "toc.pb と飾り行が混じっている")
        XCTAssertEqual(entries.first(where: { $0.name == "splits/base-master_2.apk" })?.size, 38_808_962)
    }

    func testParseZipListingKeepsNamesWithSpaces() {
        let entries = ApksBundle.parseZipListing("    123  01-01-1981 01:01   splits/my app-master.apk")
        XCTAssertEqual(entries, [ApksBundle.Entry(name: "splits/my app-master.apk", size: 123)])
    }

    /// 端末側スクリプトの出力(実測。`<大きさ> <md5>` の1行1ファイル)
    func testParseInstalledFiles() {
        let output = """
            38808962 5765704ac5a622576aad448144722189
            4703264 29ef2fe8cc8427f7117dc5672448c937
            """
        XCTAssertEqual(ApksBundle.parseInstalledFiles(output), [
            ApksBundle.InstalledFile(size: 38_808_962, md5: "5765704ac5a622576aad448144722189"),
            ApksBundle.InstalledFile(size: 4_703_264, md5: "29ef2fe8cc8427f7117dc5672448c937"),
        ])
        XCTAssertNil(ApksBundle.parseInstalledFiles(""), "未インストールは判定不能=nil")
        XCTAssertNil(ApksBundle.parseInstalledFiles("Failure [not installed]"))
    }

    // MARK: - installedIsFromBundle

    private var entries: [ApksBundle.Entry] { ApksBundle.parseZipListing(listing) }

    /// 実測の組み合わせ: 端末には master_2 が入っている(master ではない)
    func testMatchesWhenEveryInstalledFileComesFromTheBundle() {
        let installed = [
            ApksBundle.InstalledFile(size: 38_808_962, md5: "aa"),
            ApksBundle.InstalledFile(size: 4_703_264, md5: "bb"),
            ApksBundle.InstalledFile(size: 45_402, md5: "cc"),
        ]
        let hashes = ["splits/base-master_2.apk": "aa", "splits/base-arm64_v8a.apk": "bb",
                      "splits/base-ja.apk": "cc"]
        XCTAssertTrue(ApksBundle.installedIsFromBundle(installed: installed, entries: entries) {
            hashes[$0]
        })
    }

    func testRejectsWhenAnInstalledFileHasNoEntryOfThatSize() {
        let installed = [ApksBundle.InstalledFile(size: 999, md5: "aa")]
        XCTAssertFalse(ApksBundle.installedIsFromBundle(installed: installed, entries: entries) { _ in "aa" })
    }

    func testRejectsWhenTheSizeMatchesButTheContentDiffers() {
        let installed = [ApksBundle.InstalledFile(size: 45_402, md5: "aa")]
        XCTAssertFalse(ApksBundle.installedIsFromBundle(installed: installed, entries: entries) { _ in "zz" })
    }

    /// 大きさで絞ってから md5 を取る(展開は候補だけ。79MB を毎回ほどかない)
    func testHashesOnlyTheEntriesOfTheSameSize() {
        var hashed: [String] = []
        _ = ApksBundle.installedIsFromBundle(
            installed: [ApksBundle.InstalledFile(size: 45_402, md5: "cc")], entries: entries
        ) { name in
            hashed.append(name)
            return "cc"
        }
        XCTAssertEqual(hashed, ["splits/base-ja.apk"])
    }

    func testUnverifiableEntryIsNotAMatch() {
        let installed = [ApksBundle.InstalledFile(size: 45_402, md5: "cc")]
        XCTAssertFalse(ApksBundle.installedIsFromBundle(installed: installed, entries: entries) { _ in nil },
                       "展開できないエントリを一致扱いにしてはいけない")
    }

    func testEmptyInputsAreNotAMatch() {
        XCTAssertFalse(ApksBundle.installedIsFromBundle(installed: [], entries: entries) { _ in "aa" })
        XCTAssertFalse(ApksBundle.installedIsFromBundle(
            installed: [ApksBundle.InstalledFile(size: 1, md5: "aa")], entries: []) { _ in "aa" })
    }

    // MARK: - 入口

    func testIsApks() {
        XCTAssertTrue(ApksBundle.isApks(path: "/apps/app.apks"))
        XCTAssertTrue(ApksBundle.isApks(path: "/apps/APP.APKS"))
        XCTAssertFalse(ApksBundle.isApks(path: "/apps/app.apk"))
        XCTAssertFalse(ApksBundle.isApks(path: "/apps/app.aab"))
    }

    func testInstallArgs() {
        XCTAssertEqual(
            ApksBundle.installArgs(bundletool: ["/opt/homebrew/bin/bundletool"],
                                   apksPath: "/apps/a b.apks", serial: "emulator-5554"),
            ["/opt/homebrew/bin/bundletool", "install-apks", "--apks=/apps/a b.apks",
             "--device-id=emulator-5554"])
        XCTAssertEqual(
            ApksBundle.installArgs(bundletool: ["java", "-jar", "/t/bundletool.jar"],
                                   apksPath: "/apps/a.apks", serial: nil),
            ["java", "-jar", "/t/bundletool.jar", "install-apks", "--apks=/apps/a.apks"],
            "serial 無しは --device-id を付けない(接続1台のときだけ通る adb と同じ意味論)")
    }

    func testFindBundletool() {
        let executables: Set<String> = ["/opt/homebrew/bin/bundletool", "/usr/local/bin/bundletool",
                                        "/custom/bt"]
        func find(_ env: [String: String]) -> [String]? {
            ApksBundle.findBundletool(environment: env, isExecutable: { executables.contains($0) })
        }
        XCTAssertEqual(find(["PATH": "/usr/bin:/opt/homebrew/bin"]), ["/opt/homebrew/bin/bundletool"])
        XCTAssertEqual(find(["PATH": "/usr/bin"]), ["/opt/homebrew/bin/bundletool"],
                       "非対話 PATH に /opt/homebrew が無くても既知の場所は見る")
        XCTAssertEqual(find(["PATH": "/usr/bin", "FT_BUNDLETOOL": "/custom/bt"]), ["/custom/bt"])
        XCTAssertEqual(find(["FT_BUNDLETOOL": "/t/bundletool-all.jar"]),
                       ["java", "-jar", "/t/bundletool-all.jar"])
        XCTAssertNil(find(["FT_BUNDLETOOL": "/nope/bt"]), "指定された実行ファイルが無ければ nil")
        XCTAssertNil(ApksBundle.findBundletool(environment: ["PATH": "/usr/bin"],
                                               isExecutable: { _ in false }))
    }

    func testMissingBundletoolMessageSaysWhatToRun() {
        let message = ApksBundle.missingBundletoolMessage(apksPath: "/apps/a.apks")
        XCTAssertTrue(message.contains("brew install bundletool"), message)
        XCTAssertTrue(message.contains("FT_BUNDLETOOL"), message)
    }

    // MARK: - 実デバイス

    /// FT_LIVE_APKS=<.apks> FT_LIVE_APKS_PACKAGE=<id> [FT_LIVE_APKS_SERIAL=<serial>] のときだけ。
    /// **対象機へ実際にインストールする**
    func testLiveInstallAndFreshnessSmoke() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let apks = env["FT_LIVE_APKS"], let packageID = env["FT_LIVE_APKS_PACKAGE"] else {
            throw XCTSkip("FT_LIVE_APKS と FT_LIVE_APKS_PACKAGE を指定したときのみ")
        }
        try await SharedResource.androidEmulatorHost.locked {
            let driver = try AndroidDriver(serial: env["FT_LIVE_APKS_SERIAL"])
            try await driver.install(packagePath: apks)
            XCTAssertTrue(driver.installedPackageIsCurrent(packageID: packageID, apkPath: apks),
                          "入れた直後なのに差分ありと判定される")
            if let other = env["FT_LIVE_APKS_OTHER"] {
                XCTAssertFalse(driver.installedPackageIsCurrent(packageID: packageID, apkPath: other),
                               "別ビルドの .apks を最新と判定している(\(other))")
            }
        }
    }
}
