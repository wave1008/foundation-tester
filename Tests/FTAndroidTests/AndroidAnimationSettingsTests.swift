import XCTest
import FTCore
@testable import FTAndroid

final class AndroidAnimationSettingsTests: XCTestCase {

    func testPutArguments() {
        XCTAssertEqual(
            AndroidAnimationSettings.putArguments(key: "window_animation_scale", animationsEnabled: false),
            ["settings", "put", "global", "window_animation_scale", "0"])
        XCTAssertEqual(
            AndroidAnimationSettings.putArguments(key: "window_animation_scale", animationsEnabled: true),
            ["settings", "put", "global", "window_animation_scale", "1"])
    }

    func testApplyWritesEveryScaleKey() {
        var written: [[String]] = []
        let failed = AndroidAnimationSettings.apply(animationsEnabled: false) {
            written.append($0)
            return true
        }
        XCTAssertTrue(failed.isEmpty)
        XCTAssertEqual(written.count, AnimationPolicy.androidScaleKeys.count)
        XCTAssertEqual(Set(written.map { $0[3] }), Set(AnimationPolicy.androidScaleKeys))
        XCTAssertEqual(Set(written.map { $0[4] }), ["0"])
    }

    /// 失敗した key だけを返す(呼び出し側が警告文へ並べる)
    func testApplyReportsOnlyFailedKeys() {
        let failed = AndroidAnimationSettings.apply(animationsEnabled: true) { args in
            args[3] != "animator_duration_scale"
        }
        XCTAssertEqual(failed, ["animator_duration_scale"])
    }

    func testMatchesTreatsUnsetAsOSDefaultOne() {
        // 未設定は Android 既定の 1.0 = アニメーション有効側
        for raw in ["null", "", "  \n"] {
            XCTAssertTrue(AndroidAnimationSettings.matches(rawValue: raw, animationsEnabled: true))
            XCTAssertFalse(AndroidAnimationSettings.matches(rawValue: raw, animationsEnabled: false))
        }
        XCTAssertTrue(AndroidAnimationSettings.matches(rawValue: nil, animationsEnabled: true))
    }

    func testMatchesReadsNumericValues() {
        XCTAssertTrue(AndroidAnimationSettings.matches(rawValue: "0.0", animationsEnabled: false))
        XCTAssertFalse(AndroidAnimationSettings.matches(rawValue: "0.0", animationsEnabled: true))
        // 0 以外は倍率が何であれ「アニメーションが出る」側
        XCTAssertTrue(AndroidAnimationSettings.matches(rawValue: "0.5", animationsEnabled: true))
        XCTAssertTrue(AndroidAnimationSettings.matches(rawValue: "1", animationsEnabled: true))
    }

    /// 読めない値は「一致しない」= 書きに行かせる(黙って諦めない)
    func testMatchesRejectsUnparsableValue() {
        XCTAssertFalse(AndroidAnimationSettings.matches(rawValue: "error", animationsEnabled: true))
        XCTAssertFalse(AndroidAnimationSettings.matches(rawValue: "error", animationsEnabled: false))
    }

    /// run 開始の同期は台ごとに並行に撃つ(順に撃つと台数ぶんの adb の往復が供給の後の待ちに積み上がる)
    func testSyncAnimationSettingsRunsDevicesConcurrently() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTAndroid/ProfileWorkerFactory.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let entry = try XCTUnwrap(text.range(of: "public static func syncAnimationSettings("))
        let body = text[entry.upperBound...].prefix(900)
        XCTAssertTrue(body.contains("DispatchQueue.concurrentPerform(iterations: devices.count)"), "台ごとに並行に撃っていない")
        XCTAssertFalse(body.contains("for device in resolved.androidDevices"), "台を順に回している")
    }
}
