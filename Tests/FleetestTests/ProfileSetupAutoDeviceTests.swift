// `fleetest profile setup` の**配線**を固定する。
//
// 2026-08-19 の実害: 受け手のマシンプロファイルに、機種も OS も UDID も無い
// simulator1 / emulator1 だけが登録された。原因は判定ロジックではなく配線で、
// 2026-08-17 に「host は手元でも必ず書く」を入れた時点で
// `var device = ["host": …, "name": …]` の要素数が常に2になり、
// `if device.count == 1, autoDevice` という自動選定の番兵が**恒真で false** になっていた。
// 同じ番兵を使う `if device.count > 1`(= 実体を書く分岐)は逆に恒真で true になり、
// 「実体が無いなら既に登録済みのデバイスを使う」分岐ごと死んで、
// **実体付きで登録済みの同名デバイスを実体なしで上書き**していた。
//
// ここで固定するのは「組み立てた1件が実体を持つか」= 自動選定に入る条件そのもの
// (選定の中身は simctl / emulator を叩くので E2E 側。ここは I/O 抜きの判定だけ)。

import XCTest
@testable import fleetest
@testable import FTCore

final class ProfileSetupAutoDeviceTests: XCTestCase {

    private func entry(platform: String, simulator: String? = nil, os: String? = nil,
                       udid: String? = nil, avd: String? = nil, serial: String? = nil)
        -> [String: Any] {
        ProfileSetupCommand.deviceEntry(
            platform: platform, name: ProfileWriter.defaultDeviceName(platform: platform),
            simulator: simulator, os: os, udid: udid, avd: avd, serial: serial)
    }

    /// **本丸**: 何も指定しなければ実体は空 = `--auto-device` が発火する
    func testNoOptionsLeavesTheEntryWithoutABody() {
        for platform in ["ios", "android"] {
            let device = entry(platform: platform)
            XCTAssertFalse(ProfileWriter.hasDeviceBody(device),
                           "\(platform): 実体なしと判定されないと --auto-device が一度も発火しない")
            XCTAssertEqual(device["host"] as? String, DeviceHostGrouping.localDisplayName)
            XCTAssertEqual(device.count, 2, "実体を書かない限り host と name だけ")
        }
    }

    /// 実体を明示したら自動選定に入らない(利用者の指定を上書きしない)
    func testExplicitDeviceIsABody() {
        XCTAssertTrue(ProfileWriter.hasDeviceBody(entry(platform: "ios", simulator: "iPhone 17 Pro")))
        XCTAssertTrue(ProfileWriter.hasDeviceBody(entry(platform: "ios", udid: "XXXX-XXXX")))
        XCTAssertTrue(ProfileWriter.hasDeviceBody(entry(platform: "android", avd: "Pixel_9")))
        XCTAssertTrue(ProfileWriter.hasDeviceBody(entry(platform: "android", serial: "emulator-5554")))
    }

    /// プラットフォーム違いのオプションは無視する(iOS に --avd を渡しても実体にはならない)
    func testOptionsOfTheOtherPlatformAreIgnored() {
        XCTAssertFalse(ProfileWriter.hasDeviceBody(entry(platform: "ios", avd: "Pixel_9")))
        XCTAssertFalse(ProfileWriter.hasDeviceBody(entry(platform: "android", simulator: "iPhone 17 Pro")))
    }

    /// 番兵をキー数へ戻させない。判定ロジックは変異で守れるが、**恒真の番兵**は
    /// 「判定を呼ばない」形の欠陥なので、呼び出し側の書き方そのものを固定する
    func testSetupDoesNotGateOnTheNumberOfKeys() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ProfileSetupCommand.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("device.count"),
                       "実体の有無は ProfileWriter.hasDeviceBody で判定する"
                       + "(host/name が常に入るのでキー数の比較は恒真になる)")
        // プロファイルの os は接頭辞なし("27.0")が規約。SimDeviceInfo.os("iOS 27.0")を
        // 生のまま書くと表示側が「iOS iOS 27.0」と二重に出す(2026-08-19 の実害)
        XCTAssertTrue(code.contains("normalizeOS(picked.os)"),
                      "auto-pick の os は ApiInstalledDevicesCommand.normalizeOS を通して書く")
    }

    /// 自動選定の結果を入れた後は実体あり = マシンプロファイルへ書く分岐に入る
    func testAutoPickedValuesBecomeABody() {
        var device = entry(platform: "ios")
        device["simulator"] = "iPhone 17 Pro"
        device["os"] = "27.0"
        device["udid"] = "AAAA-BBBB"
        XCTAssertTrue(ProfileWriter.hasDeviceBody(device))
    }
}
