// テスト開始時の WebView 揃え(`AndroidWebViewUpdate`。2026-08-14)。
// 守るのは **供給元の選び方**(古いものを配らない)と **24 時間の間引き**。

import XCTest
@testable import FTAndroid

final class AndroidWebViewUpdateTests: XCTestCase {

    /// **実測した組み合わせそのもの**(実機 150 / エミュレータ 124)
    func testPlansToCopyFromTheNewestConnectedDevice() throws {
        let plan = try XCTUnwrap(AndroidWebViewUpdate.plan(
            candidates: ["phone": "150.0.7871.181", "emu-1": "124.0.6367.219", "emu-2": "124.0.6367.219"],
            targets: ["emu-1", "emu-2"]))
        XCTAssertEqual(plan.source, .device("phone"))
        XCTAssertEqual(plan.targets, ["emu-1", "emu-2"])
    }

    /// **供給元は run の対象外でよい**(実機は普通プロファイルに入っていない。これが無いと
    /// 「供給元が居ない」で何も起きなかった —— 実際に踏んだ)
    func testTheSourceMayBeOutsideTheRun() throws {
        let plan = try XCTUnwrap(AndroidWebViewUpdate.plan(
            candidates: ["phone": "150.0.7871.181", "emu-1": "124.0.6367.219"],
            targets: ["emu-1"]))
        XCTAssertEqual(plan.source, .device("phone"))
        XCTAssertEqual(plan.targets, ["emu-1"])
    }

    /// **キャッシュの APK が全端末より新しければ供給元になる**(実機の無い機械のドナー。
    /// ディスパッチ元が転送してくる。2026-09-01 の M1Max 取り残しの再発防止)
    func testCachedAPKBecomesTheDonorWhenNewerThanEveryDevice() throws {
        let plan = try XCTUnwrap(AndroidWebViewUpdate.plan(
            candidates: ["emu-1": "124.0.6367.219", "emu-2": "124.0.6367.219"],
            targets: ["emu-1", "emu-2"],
            cachedAPKs: ["/cache/com.google.android.webview-151.0.7922.199.apk": "151.0.7922.199"]))
        XCTAssertEqual(plan.source,
                       .cachedAPK("/cache/com.google.android.webview-151.0.7922.199.apk"))
        XCTAssertEqual(plan.sourceVersion, "151.0.7922.199")
        XCTAssertEqual(plan.targets, ["emu-1", "emu-2"])
    }

    /// **同版なら端末を優先**(従来と挙動が変わらない側。キャッシュが勝つのは真に新しいときだけ)
    func testDeviceDonorWinsOverAnEquallyNewCache() throws {
        let plan = try XCTUnwrap(AndroidWebViewUpdate.plan(
            candidates: ["phone": "151.0.7922.199", "emu-1": "124.0.6367.219"],
            targets: ["emu-1"],
            cachedAPKs: ["/cache/com.google.android.webview-151.0.7922.199.apk": "151.0.7922.199"]))
        XCTAssertEqual(plan.source, .device("phone"))
    }

    /// 古いキャッシュは供給元にしない(古いものを配らない、の既存規律のまま)
    func testAnOlderCacheNeverDowngrades() {
        XCTAssertNil(AndroidWebViewUpdate.plan(
            candidates: ["emu-1": "151.0.7922.199"],
            targets: ["emu-1"],
            cachedAPKs: ["/cache/com.google.android.webview-124.0.6367.219.apk": "124.0.6367.219"]))
    }

    /// キャッシュのファイル名契約(`com.google.android.webview-<版>.apk`)の読み取り
    func testCachedVersionsParsesTheFilenameContract() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-webview-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("com.google.android.webview-151.0.7922.199.apk").path,
            contents: Data())
        FileManager.default.createFile(atPath: dir.appendingPathComponent("junk.txt").path,
                                       contents: Data())
        let versions = AndroidWebViewUpdate.cachedVersions(in: dir)
        XCTAssertEqual(Array(versions.values), ["151.0.7922.199"])
    }

    /// **run の対象外の端末は書き換えない**(テストが触っていない端末を変えない)
    func testDevicesOutsideTheRunAreNeverTargets() throws {
        let plan = try XCTUnwrap(AndroidWebViewUpdate.plan(
            candidates: ["phone": "150.0.7871.181", "emu-1": "124.0.6367.219", "emu-9": "124.0.6367.219"],
            targets: ["emu-1"]))
        XCTAssertEqual(plan.targets, ["emu-1"], "emu-9 は run の対象外なので含めない")
    }

    /// キャッシュは**版ごとに別ファイル**(古い版を消す判断ができる)
    func testCachesTheAPKPerVersionOutsideTheRepository() {
        let dir = AndroidWebViewUpdate.cacheDirectory(home: URL(fileURLWithPath: "/Users/x"))
        XCTAssertEqual(dir.path, "/Users/x/Library/Caches/fleetest/webview")
        let a = AndroidWebViewUpdate.cachedAPK(version: "150.0.1.1", in: dir)
        let b = AndroidWebViewUpdate.cachedAPK(version: "124.0.1.1", in: dir)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.lastPathComponent.contains("150.0.1.1"))
    }

    /// **揃っていれば何もしない**(265MB を無駄に配らない)
    func testNoPlanWhenEveryDeviceMatches() {
        XCTAssertNil(AndroidWebViewUpdate.plan(candidates: ["a": "124.0.6367.219", "b": "124.0.6367.219"], targets: ["a", "b"]))
        XCTAssertNil(AndroidWebViewUpdate.plan(candidates: [:], targets: []))
    }

    /// **数値として比べる**(文字列比較だと "9" > "150" になる)
    func testComparesVersionsNumerically() {
        XCTAssertTrue(AndroidWebViewUpdate.isNewer("150.0.1.0", than: "99.0.9999.9"))
        XCTAssertFalse(AndroidWebViewUpdate.isNewer("124.0.6367.219", than: "124.0.6367.219"))
        XCTAssertTrue(AndroidWebViewUpdate.isNewer("124.0.6367.220", than: "124.0.6367.219"))
    }

    /// **run の対象が揃っていれば黙る**。供給元が繋がっているのに「新しい端末が無い」と
    /// 言ってしまい事実と食い違った(2026-08-14 に実測で踏んだ)
    func testSaysNothingWhenTheRunTargetsAlreadyMatch() {
        XCTAssertNil(AndroidWebViewUpdate.cannotUpdateMessage(
            candidates: ["phone": "150.0.7871.181", "a": "150.0.7871.181", "b": "150.0.7871.181"],
            targets: ["a", "b"]))
    }

    /// 供給元が繋がっていれば黙る(配れるので「できない」ではない)
    func testSaysNothingWhenASourceIsAvailable() {
        XCTAssertNil(AndroidWebViewUpdate.cannotUpdateMessage(
            candidates: ["phone": "150.0.7871.181", "a": "124.0.6367.219"], targets: ["a"]))
    }

    /// **自動化できないときは理由と次の一手を言う**(黙って古いまま走らせない)
    func testExplainsWhenNoSourceIsAvailable() throws {
        let msg = try XCTUnwrap(AndroidWebViewUpdate.cannotUpdateMessage(
            candidates: ["a": "124.0.6367.219", "b": "150.0.7871.181"], targets: ["a", "b"]))
        XCTAssertTrue(msg.contains("Play Store"), msg)
        XCTAssertTrue(msg.lowercased().contains("no adb command"), "adb では更新できない事実を言うこと")
    }
}
