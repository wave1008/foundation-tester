// `adb shell` へ埋めるパッケージ名は `AndroidPackageName` を通す。`adb shell` は引数を空白で結合して
// 端末側の sh に解釈し直させるので、MCP の bundleId に `x;reboot` を渡すと端末上で別コマンドになっていた。

import Foundation
import XCTest
@testable import FTAndroid
import FTCore

final class AndroidPackageNameTests: XCTestCase {

    func testAcceptsRealPackageNames() {
        for name in ["com.ftester.e2e", "android", "com.google.android.webview", "jp.co.Example_App2"] {
            XCTAssertTrue(AndroidPackageName.isShellSafe(name), name)
            XCTAssertNoThrow(try AndroidPackageName.require(name), name)
        }
    }

    func testRejectsAnythingTheDeviceShellWouldReinterpret() {
        for name in ["x;reboot", "com.x && id", "com.x $(id)", "com.x`id`", "com.x|sh", "com.x\nreboot",
                     "a b", "com.x'", "com.x\"", "com.x>/sdcard/f", "-p", ".com.x", "1com.x", "com.x-y", ""] {
            XCTAssertFalse(AndroidPackageName.isShellSafe(name), name.debugDescription)
            XCTAssertThrowsError(try AndroidPackageName.require(name), name.debugDescription) {
                guard case DriverError.badResponse(let status, let body) = $0 else {
                    return XCTFail("unexpected error: \($0)")
                }
                XCTAssertEqual(status, 400)
                XCTAssertTrue(body.contains("not a valid Android package name"), body)
            }
        }
    }

    func testEveryShellBuilderRefusesAnUnsafeName() {
        XCTAssertThrowsError(try AndroidDriver.amStartArgs(url: "fte2e://x", package: "com.x;reboot"))
        XCTAssertNil(ApksBundle.installedFilesScript(packageID: "com.x;reboot"))
        XCTAssertNotNil(ApksBundle.installedFilesScript(packageID: "com.ftester.e2e"))
        XCTAssertNil(AndroidWebViewDOM.probeCommand(packageID: "com.x;reboot"))
    }

    /// 端末に何もせず断ること(adb を撃つ前に throw する)。adb は常に失敗する偽物なので、
    /// 門が無ければ adb の失敗(400 以外)になる
    func testDriverEntryPointsRefuseBeforeTouchingTheDevice() async {
        let driver = AndroidDriver(serial: "ft-no-such-serial-\(UUID().uuidString)", adbPath: "/usr/bin/false")
        let calls: [(String, () async throws -> Void)] = [
            ("clearAppData", { try await driver.clearAppData(bundleID: "x;reboot") }),
            ("launch", { try await driver.launch(bundleID: "x;reboot") }),
            ("activate", { try await driver.activate(bundleID: "x;reboot") }),
        ]
        for (name, call) in calls {
            do {
                try await call()
                XCTFail("\(name) accepted an unsafe package name")
            } catch DriverError.badResponse(let status, let body) {
                XCTAssertEqual(status, 400, "\(name): \(body)")
                XCTAssertTrue(body.contains("not a valid Android package name"), "\(name): \(body)")
            } catch {
                XCTFail("\(name): the guard did not run before adb: \(error)")
            }
        }
        XCTAssertNil(driver.isInstalled(bundleID: "x;reboot"))
        XCTAssertFalse(driver.installedPackageIsCurrent(packageID: "x;reboot", apkPath: "/nonexistent.apk"))
    }

    /// Android ブリッジの POST /session も同じ文法で断る(attemptLaunch が shell へ連結する)。
    /// Java の正規表現を取り出し、Swift の判定と同じ答えを返すことを標本で確かめる
    func testBridgeLaunchUsesTheSameGrammar() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let java = try String(contentsOf: root.appendingPathComponent(
            "AndroidRunner/src/com/example/ftbridge/BridgeRouter.java"), encoding: .utf8)
        let marker = "return name.matches(\""
        let start = try XCTUnwrap(java.range(of: marker), "isShellSafePackageName の形が変わった")
        let pattern = String(java[start.upperBound...].prefix { $0 != "\"" })
        let regex = try NSRegularExpression(pattern: "^(?:\(pattern))\\z")
        for name in ["com.ftester.e2e", "android", "jp.Co_2.x", "x;reboot", "com.x y", "-p", ".x", "1x", "a-b", "",
                     "com.x$(id)", "Ünicode", "com.x\n"] {
            let javaAccepts = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
            XCTAssertEqual(javaAccepts, AndroidPackageName.isShellSafe(name), name.debugDescription)
        }
        let launch = try XCTUnwrap(java.range(of: "private BridgeHttpServer.Response handleLaunch("))
        let body = java[launch.upperBound...]
        let guardAt = try XCTUnwrap(body.range(of: "isShellSafePackageName(bundleID)"), "handleLaunch が検めていない")
        let firstShell = try XCTUnwrap(body.range(of: "attemptLaunch(bundleID)"))
        XCTAssertLessThan(guardAt.lowerBound, firstShell.lowerBound, "検める前に attemptLaunch を呼んでいる")
    }

    /// 同型の再発を落とす: Sources/FTAndroid でパッケージ名の変数を `adb shell` の引数・端末側の
    /// スクリプト文字列へ埋める行は、同じ関数の手前(直前 15 行以内)で `AndroidPackageName` を通す
    func testShellSitesEmbeddingPackageNamesAreGuarded() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTAndroid")
        // 引用符に挟まれた語(`"dumpsys", "package"` の文字列リテラル)は変数ではないので除く
        let identifier = try NSRegularExpression(pattern: #"(?<!")\b(bundleID|packageID|package|packageName)\b(?!")"#)
        let deviceCommands = ["pidof", "pm path", "pm clear", "pm list", "am force-stop", "monkey"]
        var sites = 0
        var offenders: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift")
            && name != "AndroidPackageName.swift" {
            let lines = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                .components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//")[0]
                let range = NSRange(code.startIndex..., in: code)
                guard identifier.firstMatch(in: code, range: range) != nil else { continue }
                let isShellArgument = code.contains("\"shell\"")
                let isScript = code.contains("\\(") && deviceCommands.contains { code.contains($0) }
                guard isShellArgument || isScript else { continue }
                sites += 1
                let window = lines[max(0, index - 15)...index].joined(separator: "\n")
                if !window.contains("AndroidPackageName.") {
                    offenders.append("\(name):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(offenders, [], "パッケージ名を adb shell へ埋める前に AndroidPackageName.isShellSafe / require を通す")
        // 走査が届いていることの確認(0 件なら正規表現かパスが壊れている)
        XCTAssertGreaterThanOrEqual(sites, 9)
    }
}
