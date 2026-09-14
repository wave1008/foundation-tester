// Android の目印の規則と、バイナリ XML の AndroidManifest からパッケージ名を読む口の固定。
// マニフェストは E2E の SUT 4 つの実 APK から取り出したもの(Tests/Fixtures/AndroidManifest/。
// 期待値は aapt2 dump packagename の出力 = このパーサ以外の読み手の答え)

import XCTest
@testable import FTCore

final class AndroidPackageInspectorTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func manifest(_ name: String) throws -> Data {
        try Data(contentsOf: Self.repoRoot.appendingPathComponent("Tests/Fixtures/AndroidManifest/\(name).axml"))
    }

    func testPackageNameIsReadFromRealManifests() throws {
        let expected = ["e2e-android": "com.ftester.e2e.android", "e2e-cmp": "com.ftester.e2e",
                        "e2e-flutter": "com.ftester.e2e.flutter", "e2e-rn": "com.ftester.e2e.rn"]
        for (name, package) in expected {
            XCTAssertEqual(AndroidPackageInspector.manifestPackage(axml: try manifest(name)), package, name)
        }
    }

    /// リポジトリに入っている実 APK(ブリッジ)を丸ごと読む: パッケージ名と、目印が無い = androidView
    func testTheCommittedBridgeAPKIsReadEndToEnd() throws {
        let apk = Self.repoRoot.appendingPathComponent("AndroidRunner/prebuilt/ftbridge.apk").path
        let reader = try XCTUnwrap(AppPackageReader.open(path: apk))
        XCTAssertEqual(AndroidPackageInspector.packageName(in: reader), "com.example.ftbridge")
        XCTAssertEqual(AndroidPackageInspector.detect(in: reader), .androidView)
    }

    /// 実 APK(aapt2)の文字列表は 4 つとも UTF-16。UTF-8 の表(flags 0x100)は手で組んだ最小形で確かめる
    /// (AOSP ResourceTypes.h の ResStringPool_header / ResXMLTree_attrExt の配置どおり)
    func testUTF8StringPoolIsRead() {
        XCTAssertEqual(AndroidPackageInspector.manifestPackage(axml: utf8Manifest(rawIndex: 2)), "com.example.utf8")
        XCTAssertEqual(AndroidPackageInspector.manifestPackage(axml: utf8Manifest(rawIndex: -1 & 0xFFFF_FFFF)),
                       "com.example.utf8", "生の文字列が無く型付きの値(TYPE_STRING)だけの属性")
    }

    private func utf8Manifest(rawIndex: Int) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16(v >> 16 & 0xFFFF) }
        let strings = ["manifest", "package", "com.example.utf8"]
        var body: [UInt8] = []
        var offsets: [Int] = []
        for s in strings {
            offsets.append(body.count)
            body += [UInt8(s.utf16.count), UInt8(s.utf8.count)] + Array(s.utf8) + [0]
        }
        while body.count % 4 != 0 { body.append(0) }
        let poolHeader = 28
        let stringsStart = poolHeader + 4 * strings.count
        let pool = le16(0x0001) + le16(poolHeader) + le32(stringsStart + body.count) + le32(strings.count)
            + le32(0) + le32(0x100) + le32(stringsStart) + le32(0) + offsets.flatMap(le32) + body
        let attribute = le32(-1 & 0xFFFF_FFFF) + le32(1) + le32(rawIndex) + le16(8) + [0, 0x03] + le32(2)
        let ext = le32(-1 & 0xFFFF_FFFF) + le32(0) + le16(20) + le16(20) + le16(1) + le16(0) + le16(0) + le16(0)
        let element = le16(0x0102) + le16(16) + le32(16 + ext.count + attribute.count) + le32(1) + le32(-1 & 0xFFFF_FFFF)
            + ext + attribute
        let document = le16(0x0003) + le16(8) + le32(8 + pool.count + element.count) + pool + element
        return Data(document)
    }

    func testBrokenManifestIsNil() throws {
        XCTAssertNil(AndroidPackageInspector.manifestPackage(axml: Data()))
        XCTAssertNil(AndroidPackageInspector.manifestPackage(axml: Data("<manifest package=\"x\"/>".utf8)),
                     "テキストの XML はバイナリ XML ではない")
        let real = try manifest("e2e-cmp")
        XCTAssertNil(AndroidPackageInspector.manifestPackage(axml: real.prefix(real.count / 3)), "途中で切れた")
    }

    // MARK: - 目印の規則

    private func judge(_ files: Set<String>, dex: String = "") -> AppUIFramework {
        AndroidPackageInspector.framework(exists: { files.contains($0) }, dexContains: { dex.contains($0) })
    }

    func testMarkersAndTheirOrder() {
        let compose = "Landroidx/compose/ui/platform/AndroidComposeView;"
        XCTAssertEqual(judge(["lib/arm64-v8a/libflutter.so"], dex: compose), .flutter)
        XCTAssertEqual(judge(["lib/x86_64/libreactnative.so"], dex: compose), .reactNative)
        XCTAssertEqual(judge(["lib/armeabi-v7a/libreactnativejni.so"]), .reactNative)
        XCTAssertEqual(judge(["assets/index.android.bundle"]), .reactNative)
        XCTAssertEqual(judge([], dex: "…" + compose + "…"), .compose)
        XCTAssertEqual(judge(["lib/arm64-v8a/libhermesvm.so"]), .androidView, "Hermes だけでは RN と言わない")
        XCTAssertEqual(judge([]), .androidView)
    }

    /// dex(1 本数 MB)は、ライブラリの目印で決まる回には読まない
    func testDexIsReadOnlyWhenNeeded() {
        var asked = false
        _ = AndroidPackageInspector.framework(exists: { $0 == "lib/arm64-v8a/libflutter.so" },
                                              dexContains: { _ in asked = true; return false })
        XCTAssertFalse(asked)
    }
}
