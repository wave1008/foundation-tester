// addMedia の規則(`PhotoLibraryMedia`)と、サンドボックスの方針(`SimctlPolicy` の addmedia・`AdbPolicy` の push / 再スキャン / 登録確認)。
// 親は子の代わりにファイルを読むので、**データセットのフォルダの外を写真ライブラリへ送り出す口にならない**ことが要点。

import XCTest
@testable import FTCore

final class PhotoLibraryMediaTests: XCTestCase {

    private var root: URL!
    private var project: String { root.appendingPathComponent("proj").path }
    private var machineDataset: String { root.appendingPathComponent("home/.config/fleetest/dataset/proj").path }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-media-\(UUID().uuidString)", isDirectory: true)
        for sub in ["proj/dataset/img", "home/.config/fleetest/dataset/proj", "outside", "home/.ssh"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        for sub in ["proj/dataset/img/a.png", "proj/dataset/clip.MOV", "proj/dataset/doc.txt",
                    "home/.config/fleetest/dataset/proj/m.jpg", "outside/o.png", "home/.ssh/id_rsa.png"] {
            try Data([1]).write(to: root.appendingPathComponent(sub))
        }
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: project + "/dataset/escape.png", withDestinationPath: root.path + "/outside/o.png")
        try fm.createSymbolicLink(atPath: project + "/dataset/inner.png", withDestinationPath: project + "/dataset/img/a.png")
        try fm.createSymbolicLink(atPath: project + "/dataset/linkdir", withDestinationPath: root.path + "/outside")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private var context: SimctlPolicy.Context {
        SimctlPolicy.Context(udid: "UDID-1", deviceName: "iPhone", toolRoots: [], childWritableRoots: [],
                             serial: "emulator-5554", adbPath: "/parent/adb",
                             datasetRoots: [project + "/dataset", machineDataset])
    }

    private func simctl(_ args: String...) -> String? {
        BrokerPolicy.check(["xcrun", "simctl"] + args, context: context)?.reason
    }

    private func adb(_ args: String...) -> String? {
        BrokerPolicy.check(["/any/adb", "-s", "emulator-5554"] + args, context: context)?.reason
    }

    // MARK: 規則

    func testKindByExtensionIsCaseInsensitiveAndClosed() {
        for name in ["a.jpg", "a.JPEG", "a.png", "a.HEIC", "a.gif"] { XCTAssertEqual(PhotoLibraryMedia.kind(ofFileName: name), .image, name) }
        for name in ["a.mp4", "a.MOV"] { XCTAssertEqual(PhotoLibraryMedia.kind(ofFileName: name), .video, name) }
        for name in ["a.txt", "a.webp", "a.apk", "a", "a.png.txt", ".png", "a.pdf"] {
            XCTAssertNil(PhotoLibraryMedia.kind(ofFileName: name), name)
        }
    }

    func testResolveUsesTheDatasetFolderAndChecksTheExtensionFirst() throws {
        let projectURL = URL(fileURLWithPath: project)
        let home = root.appendingPathComponent("home").path
        let found = try PhotoLibraryMedia.resolve("img/a.png", projectDir: projectURL, home: home).get()
        XCTAssertEqual(found.kind, .image)
        XCTAssertEqual(found.url.path, project + "/dataset/img/a.png")
        // マシン側の置き場が優先(dataFile と同じ)
        XCTAssertEqual(try PhotoLibraryMedia.resolve("m.jpg", projectDir: projectURL, home: home).get().url.path,
                       machineDataset + "/m.jpg")
        guard case .failure(let type) = PhotoLibraryMedia.resolve("doc.txt", projectDir: projectURL, home: home) else { return XCTFail() }
        XCTAssertTrue(type.message.contains("unsupported file type"), type.message)
        guard case .failure(let missing) = PhotoLibraryMedia.resolve("none.png", projectDir: projectURL, home: home) else { return XCTFail() }
        XCTAssertTrue(missing.message.contains("not found"), missing.message)
        guard case .failure = PhotoLibraryMedia.resolve("../x.png", projectDir: projectURL, home: home) else { return XCTFail() }
    }

    func testShellSafeBasename() {
        for ok in ["a.png", "A-b_c.1.JPG", "photo.mov"] { XCTAssertTrue(PhotoLibraryMedia.isShellSafeBasename(ok), ok) }
        for bad in ["", "a b.png", "a;b.png", "a$(x).png", "a'b.png", "a\"b.png", "a&b.png", "a|b.png", "日本語.png",
                    "a`b`.png", "a\nb.png", "a*.png", "a\\b.png"] {
            XCTAssertFalse(PhotoLibraryMedia.isShellSafeBasename(bad), bad.debugDescription)
        }
    }

    func testQueryOutputMatchesTheWholeDisplayName() {
        let output = "Row: 0 _display_name=other.png\nRow: 1 _display_name=a.png\n"
        XCTAssertTrue(PhotoLibraryMedia.queryOutputContains(output, basename: "a.png"))
        XCTAssertFalse(PhotoLibraryMedia.queryOutputContains(output, basename: "r.png"), "部分一致で拾わない")
        XCTAssertFalse(PhotoLibraryMedia.queryOutputContains("No result found.\n", basename: "a.png"))
    }

    // MARK: simctl addmedia

    func testSimctlAddMediaAllowsADatasetFile() {
        XCTAssertNil(simctl("addmedia", "UDID-1", project + "/dataset/img/a.png"))
        XCTAssertNil(simctl("addmedia", "UDID-1", project + "/dataset/clip.MOV"))
        XCTAssertNil(simctl("addmedia", "iPhone", machineDataset + "/m.jpg"))
        XCTAssertNil(simctl("addmedia", "UDID-1", project + "/dataset/inner.png"), "データセットの中を指す symlink は通る")
    }

    func testSimctlAddMediaRefusesEverythingElse() {
        XCTAssertNotNil(simctl("addmedia", "OTHER", project + "/dataset/img/a.png"), "別デバイス")
        XCTAssertNotNil(simctl("addmedia", "UDID-1", root.path + "/outside/o.png"), "データセットの外")
        XCTAssertNotNil(simctl("addmedia", "UDID-1", root.path + "/home/.ssh/id_rsa.png"), "ホームの鍵に見立てた外")
        XCTAssertNotNil(simctl("addmedia", "UDID-1", project + "/dataset/../../outside/o.png"), ".. で外へ出る")
        XCTAssertNotNil(simctl("addmedia", "UDID-1", project + "/dataset/escape.png"), "symlink で外へ出る")
        XCTAssertNotNil(simctl("addmedia", "UDID-1", project + "/dataset/linkdir/o.png"), "ディレクトリの symlink で外へ出る")
        XCTAssertNotNil(simctl("addmedia", "UDID-1", project + "/dataset/doc.txt"), "許可外の拡張子")
        XCTAssertNotNil(simctl("addmedia", "UDID-1", "dataset/img/a.png"), "相対パス")
        XCTAssertNotNil(simctl("addmedia", "UDID-1"))
        XCTAssertNotNil(simctl("addmedia", "UDID-1", project + "/dataset/img/a.png", project + "/dataset/clip.MOV"), "複数ファイル")
        var bare = context
        bare.datasetRoots = []
        XCTAssertNotNil(BrokerPolicy.check(["xcrun", "simctl", "addmedia", "UDID-1", project + "/dataset/img/a.png"], context: bare),
                        "データセットの根を持たない文脈では何も送らない")
    }

    func testSimctlAddMediaIsPinnedToTheCheckedRealPath() {
        let link = project + "/dataset/inner.png"
        let pinned = BrokerPolicy.pinned(["xcrun", "simctl", "addmedia", "UDID-1", link], outputDirectory: NSTemporaryDirectory())
        XCTAssertEqual(pinned.argv.last, ScenarioSandbox.canonicalPath(project + "/dataset/img/a.png"))
    }

    // MARK: adb push / 再スキャン / 登録確認

    func testAdbMediaShapesAreAllowed() {
        XCTAssertNil(adb("push", project + "/dataset/img/a.png", "/sdcard/Pictures/a.png"))
        XCTAssertNil(adb("push", project + "/dataset/clip.MOV", "/sdcard/Movies/clip.MOV"))
        XCTAssertNil(adb("push", machineDataset + "/m.jpg", "/sdcard/Pictures/m.jpg"))
        for args in [PhotoLibraryMedia.androidScanArguments(kind: .image, basename: "a.png"),
                     PhotoLibraryMedia.androidScanArguments(kind: .video, basename: "clip.MOV"),
                     PhotoLibraryMedia.androidQueryArguments(kind: .image),
                     PhotoLibraryMedia.androidQueryArguments(kind: .video)] {
            XCTAssertNil(BrokerPolicy.check(["/any/adb", "-s", "emulator-5554"] + args, context: context), args.joined(separator: " "))
        }
        let push = PhotoLibraryMedia.androidPushArguments(local: project + "/dataset/img/a.png", kind: .image, basename: "a.png")
        XCTAssertNil(BrokerPolicy.check(["/any/adb", "-s", "emulator-5554"] + push, context: context))
    }

    func testAdbPushRefusesAnythingOutsideTheDatasetOrTheMediaFolders() {
        let ok = project + "/dataset/img/a.png"
        XCTAssertNotNil(adb("push", root.path + "/outside/o.png", "/sdcard/Pictures/o.png"), "データセットの外")
        XCTAssertNotNil(adb("push", root.path + "/home/.ssh/id_rsa.png", "/sdcard/Pictures/id_rsa.png"))
        XCTAssertNotNil(adb("push", project + "/dataset/escape.png", "/sdcard/Pictures/o.png"), "symlink で外へ出る")
        XCTAssertNotNil(adb("push", project + "/dataset/../../outside/o.png", "/sdcard/Pictures/o.png"), ".. で外へ出る")
        XCTAssertNotNil(adb("push", project + "/dataset/doc.txt", "/sdcard/Pictures/doc.txt"), "許可外の拡張子")
        XCTAssertNotNil(adb("push", ok, "/sdcard/Download/a.png"), "宛先が Pictures / Movies 以外")
        XCTAssertNotNil(adb("push", ok, "/data/local/tmp/a.png"))
        XCTAssertNotNil(adb("push", ok, "/sdcard/Pictures/sub/a.png"), "入れ子")
        XCTAssertNotNil(adb("push", ok, "/sdcard/Pictures/../Download/a.png"))
        XCTAssertNotNil(adb("push", ok, "/sdcard/Pictures/a.apk"), "宛先の拡張子")
        XCTAssertNotNil(adb("push", ok, "/sdcard/Movies/a.png"), "種類と置き場の食い違い")
        for bad in ["a b.png", "a;id.png", "a$(id).png", "a'b.png", "a&b.png", "a`id`.png"] {
            XCTAssertNotNil(adb("push", ok, "/sdcard/Pictures/\(bad)"), bad)
        }
        XCTAssertNotNil(adb("push", ok), "宛先なし")
        XCTAssertNotNil(adb("pull", "/sdcard/Pictures/a.png", project + "/dataset/img/a.png"))
        XCTAssertNotNil(BrokerPolicy.check(["/any/adb", "-s", "emulator-OTHER", "push", ok, "/sdcard/Pictures/a.png"], context: context),
                        "別の端末")
    }

    func testAdbBroadcastAndQueryOnlyInTheirFixedShapes() {
        let scan = PhotoLibraryMedia.androidScanArguments(kind: .image, basename: "a.png")
        func check(_ args: [String]) -> String? {
            BrokerPolicy.check(["/any/adb", "-s", "emulator-5554"] + args, context: context)?.reason
        }
        var other = scan; other[4] = "android.intent.action.VIEW"
        XCTAssertNotNil(check(other), "別の action")
        var wrongDir = scan; wrongDir[6] = "file:///sdcard/Download/a.png"
        XCTAssertNotNil(check(wrongDir))
        var unsafe = scan; unsafe[6] = "file:///sdcard/Pictures/a;id.png"
        XCTAssertNotNil(check(unsafe))
        var mismatch = scan; mismatch[6] = "file:///sdcard/Movies/a.png"
        XCTAssertNotNil(check(mismatch))
        XCTAssertNotNil(check(scan + ["--es", "x", "y"]), "引数の追加")
        var query = PhotoLibraryMedia.androidQueryArguments(kind: .image)
        query[4] = "content://sms/inbox"
        XCTAssertNotNil(check(query), "別の URI")
        query = PhotoLibraryMedia.androidQueryArguments(kind: .image)
        query[6] = "_data"
        XCTAssertNotNil(check(query), "別の projection")
    }

    func testAdbPushIsPinnedToTheCheckedRealPath() {
        let link = project + "/dataset/inner.png"
        let pinned = BrokerPolicy.pinned(["/any/adb", "-s", "emulator-5554", "push", link, "/sdcard/Pictures/inner.png"],
                                         outputDirectory: NSTemporaryDirectory())
        XCTAssertEqual(pinned.argv[4], ScenarioSandbox.canonicalPath(project + "/dataset/img/a.png"))
        XCTAssertEqual(pinned.argv[5], "/sdcard/Pictures/inner.png")
    }

    func testBrokerContextCarriesTheDatasetRoots() {
        XCTAssertEqual(PhotoLibraryMedia.datasetRoots(projectRoot: "/w/proj1", home: "/Users/me"),
                       ["/w/proj1/dataset", "/Users/me/.config/fleetest/dataset/proj1"])
    }
}
