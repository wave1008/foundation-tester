// サンドボックスの中の adb は親が `AdbPolicy`(FTCore)の許す形だけ代行する。FTAndroid が組み立てる引数が
// 表から外れると、サンドボックスの中でだけその操作が断られる(枠の外の単体テストは緑のまま)。
// ここで組み立て側の出力を表に当てて、片方だけの変更を落とす。

import Foundation
import XCTest
@testable import FTAndroid
import FTCore

private extension SimctlPolicy.Context {
    var withBundletool: SimctlPolicy.Context {
        var copy = self
        copy.bundletool = ["/parent/bundletool"]
        return copy
    }
}

final class AdbPolicyBuilderSyncTests: XCTestCase {

    private let context = SimctlPolicy.Context(udid: nil, deviceName: nil, toolRoots: [], childWritableRoots: [],
                                               serial: "emulator-5554", adbPath: "/parent/adb")

    private func assertAllowed(_ args: [String], file: StaticString = #filePath, line: UInt = #line) {
        let refusal = AdbPolicy.check(["-s", "emulator-5554"] + args, context: context)
        XCTAssertNil(refusal, "\(args) — \(refusal?.reason ?? "")", file: file, line: line)
    }

    func testBuildersProduceShapesThePolicyAllows() throws {
        assertAllowed(try AndroidDriver.amStartArgs(url: "fte2e://screen/detail?x=1&y=2", package: nil))
        assertAllowed(try AndroidDriver.amStartArgs(url: "https://example.com/a b", package: "com.ftester.e2e"))
        assertAllowed(try XCTUnwrap(AndroidWebViewDOM.probeCommand(packageID: "com.ftester.e2e")))
        assertAllowed(try XCTUnwrap(WebViewDOMFallback.probeCommand(packageID: "com.ftester.e2e")))
        assertAllowed(["shell", AndroidPhysicalDevice.screenCheckCommand])
        assertAllowed(["shell", "pm path \(AndroidDriver.bridgePackage) 2>/dev/null; echo \(AndroidDriver.pmPathMarker)"])
        for ttl in [60, 3600] {
            for owner in [nil, "/Users/me/my repo"] as [String?] {
                for timing in [false, true] {
                    assertAllowed(["shell", AndroidDriver.instrumentCommand(ttl: ttl, ownerPath: owner, timing: timing)])
                }
            }
        }
        for key in AnimationPolicy.androidScaleKeys {
            assertAllowed(["shell"] + AndroidAnimationSettings.getArguments(key: key))
            for enabled in [false, true] {
                assertAllowed(["shell"] + AndroidAnimationSettings.putArguments(key: key, animationsEnabled: enabled))
            }
        }
        assertAllowed(AdbInstallVerifier.readArguments)
        assertAllowed(AdbInstallVerifier.disableArguments)
        assertAllowed(AdbInstallVerifier.restoreArguments(original: "1"))
        assertAllowed(AdbInstallVerifier.restoreArguments(original: "null"))
    }

    /// `.apks` のインストール(bundletool)の組み立ても親の表に通ること
    func testSplitBundleInstallArgumentsArePassedByTheBroker() {
        let argv = ApksBundle.installArgs(bundletool: ["/opt/homebrew/bin/bundletool"], apksPath: "/apps/App.apks",
                                          serial: "emulator-5554", adb: "/sdk/platform-tools/adb")
        XCTAssertNil(BrokerPolicy.check(argv, context: context.withBundletool))
        let jarArgv = ApksBundle.installArgs(bundletool: ["java", "-jar", "/tools/bundletool.jar"],
                                             apksPath: "/apps/App.apks", serial: "emulator-5554", adb: "/sdk/adb")
        XCTAssertNil(BrokerPolicy.check(jarArgv, context: context.withBundletool))
    }

    /// owner のパスに `'` があると端末の sh のクォートが壊れる(表にも断られる)ので付けない
    func testInstrumentCommandDropsAnOwnerPathItCannotQuote() {
        let command = AndroidDriver.instrumentCommand(ttl: 60, ownerPath: "/Users/o'neil/repo", timing: false)
        XCTAssertFalse(command.contains("-e owner"), command)
        assertAllowed(["shell", command])
    }

    /// 定数だけで書いた adb の呼び出し(`adb([...])` 等。`["shell"] + x` のように続くものは除く)を走査し、表に通ることを見る。
    /// 新しい呼び出しを足して表に足し忘れると落ちる(値が入る呼び出しは上の組み立ての検査で見る)
    func testLiteralAdbCallsInTheDriverAreAllowed() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTAndroid")
        let call = try NSRegularExpression(pattern: #"\b(?:adb|adbAnswering|adbProbe|rawAdb)\(\[((?:"[^"\\]*"(?:,\s*)?)+)\]\s*[,)]"#)
        let literal = try NSRegularExpression(pattern: #""([^"\\]*)""#)
        var checked = 0
        for name in ["AndroidDriver.swift", "AndroidBridge.swift"] {
            let source = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            for match in call.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let list = String(source[Range(match.range(at: 1), in: source)!])
                let args = literal.matches(in: list, range: NSRange(list.startIndex..., in: list)).map {
                    String(list[Range($0.range(at: 1), in: list)!])
                }
                checked += 1
                assertAllowed(args)
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 20, "走査が呼び出しに届いていない")
    }
}
