// canonicalAVDID の照合順序(id 完全一致 → 正規化 id → displayName)の検証。
// 特に「正規化 id が displayName より先」を退行させないこと — displayName は ini を失った
// 孤児 .avd ディレクトリ(起動不能)にも一致するため(AndroidDeviceCatalog.swift 参照)。

import XCTest
@testable import FTAndroid

final class CanonicalAVDIDTests: XCTestCase {
    /// 実環境の再現: 表示名スタイルの指定が、孤児 .avd(Pixel_9_Android_15__1)の
    /// displayName に一致するより先に、正規化 id(Pixel_9_Android_15_)へ解決される
    func testSanitizedIDWinsOverOrphanDisplayName() {
        let installed: [(id: String, displayName: String?)] = [
            ("Pixel_9_Android_15_", "Pixel 9(Android 15)-01"),
            ("Pixel_9_Android_15__1", "Pixel 9(Android 15)"),
        ]
        XCTAssertEqual(
            AndroidDeviceCatalog.canonicalAVDID("Pixel 9(Android 15)", installed: installed),
            "Pixel_9_Android_15_")
    }

    func testExactIDMatchWinsFirst() {
        let installed: [(id: String, displayName: String?)] = [
            ("Pixel_9_Android_15_", "Pixel 9(Android 15)"),
        ]
        XCTAssertEqual(
            AndroidDeviceCatalog.canonicalAVDID("Pixel_9_Android_15_", installed: installed),
            "Pixel_9_Android_15_")
    }

    /// 正規化はハイフン・ドット・アンダースコアを保持する("…-01" の枝番が壊れないこと)
    func testSanitizationKeepsHyphenSuffix() {
        let installed: [(id: String, displayName: String?)] = [
            ("Pixel_9_Android_15_-01", nil),
        ]
        XCTAssertEqual(
            AndroidDeviceCatalog.canonicalAVDID("Pixel 9(Android 15)-01", installed: installed),
            "Pixel_9_Android_15_-01")
    }

    /// 正規化 id が実在しないときは従来どおり displayName 照合へフォールバックする
    func testDisplayNameFallback() {
        let installed: [(id: String, displayName: String?)] = [
            ("Pixel_9_Android_16", "Pixel 9(Android 16)"),
        ]
        XCTAssertEqual(
            AndroidDeviceCatalog.canonicalAVDID("Pixel 9(Android 16)", installed: installed),
            "Pixel_9_Android_16")
    }

    /// どれにも一致しなければ入力をそのまま返す(エラーメッセージで内容が分かるようにする契約)
    func testUnknownReturnsInput() {
        XCTAssertEqual(
            AndroidDeviceCatalog.canonicalAVDID("Nexus 1(Android 4)", installed: []),
            "Nexus 1(Android 4)")
    }
}
