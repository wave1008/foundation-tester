// hybrid で「in-app が原理的に実行できない操作」だけを XCUITest 側へ回すデコレータ。
//
// シナリオ実行では同じ判断を StepExecutor が持っている(driver → 501 なら typeDriver)。
// **StepExecutor を通らない呼び出し口**(MCP の ft_*)にも同じ振る舞いを与えるのがこのクラスで、
// これが無いと in-app エンジンでは home / drag / 座標 press が素の 501 で返る
// (2026-07-28 に live/MCP を xcuitest 固定にした理由そのもの)。
//
// **ref を使う操作は回さない**のが不変条件: ref はブリッジごとに別名前空間で、そのまま渡すと
// **無関係な要素を操作する**。座標・identifier で完結する操作だけが安全に回せる
// (WebViewDelegatingDriver の domInterop が ref を渡さないのと同じ理由)。
// 例外は press(ref:) で、**primary の snapshot で座標へ畳んでから**回す(ref を渡さない形にできる)。

import Foundation
import FTCore

public final class HybridFallbackDriver: AppDriver {
    private let primary: AppDriver
    /// 対象アプリに attach した XCUITest ドライバ。home/appSwitcher もこれが受ける
    /// (AppAttachDriver はセッション不要の操作を素通しする)
    private let fallback: AppDriver
    private var fallbackNote: String?

    public init(primary: AppDriver, fallback: AppDriver) {
        self.primary = primary
        self.fallback = fallback
    }

    /// primary を試し、**このエンジンでは不可(501 / ルート不明 404)のときだけ** fallback へ回す。
    /// 409 は含めない(一時的競合。理由は DriverError.isEngineIncapable)
    private func withFallback<T>(_ operation: (AppDriver) async throws -> T) async throws -> T {
        do {
            let result = try await operation(primary)
            fallbackNote = nil
            return result
        } catch {
            guard DriverError.isEngineIncapable(error) else { throw error }
            let result = try await operation(fallback)
            fallbackNote = "fell back to XCUITest"
            return result
        }
    }

    // MARK: - 座標・フォーカスで完結する操作(回してよい)

    public func tap(x: Double, y: Double) async throws {
        try await withFallback { try await $0.tap(x: x, y: y) }
    }

    public func doubleTap(x: Double, y: Double) async throws {
        try await withFallback { try await $0.doubleTap(x: x, y: y) }
    }

    public func pinch(frame: FTRect?, identifier: String?, scale: Double,
                      durationSeconds: Double) async throws {
        try await withFallback {
            try await $0.pinch(frame: frame, identifier: identifier, scale: scale,
                               durationSeconds: durationSeconds)
        }
    }

    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                     pressSeconds: Double, durationSeconds: Double) async throws {
        try await withFallback {
            try await $0.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                              pressSeconds: pressSeconds, durationSeconds: durationSeconds)
        }
    }

    public func press(x: Double, y: Double, duration: Double) async throws {
        try await withFallback { try await $0.press(x: x, y: y, duration: duration) }
    }

    public func swipe(_ direction: FTSwipeDirection) async throws {
        try await withFallback { try await $0.swipe(direction) }
    }

    public func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent,
                      path: FTSwipePath?) async throws {
        try await withFallback { try await $0.swipe(direction, intent: intent, path: path) }
    }

    public func home() async throws { try await withFallback { try await $0.home() } }
    public func back() async throws { try await withFallback { try await $0.back() } }
    public func openAppSwitcher() async throws {
        try await withFallback { try await $0.openAppSwitcher() }
    }
    public func hideKeyboard() async throws {
        try await withFallback { try await $0.hideKeyboard() }
    }
    public func pressEnter() async throws {
        try await withFallback { try await $0.pressEnter() }
    }

    /// ref なし(フォーカス中の要素)だけ回す。ref ありは primary 限定
    public func type(ref: Int?, text: String) async throws {
        guard ref == nil else { return try await primary.type(ref: ref, text: text) }
        try await withFallback { try await $0.type(ref: nil, text: text) }
    }

    public func clearInput(ref: Int?) async throws {
        guard ref == nil else { return try await primary.clearInput(ref: ref) }
        try await withFallback { try await $0.clearInput(ref: nil) }
    }

    /// **ref を渡さずに回す**: in-app は長押しを持たない(501)ので、primary の snapshot で
    /// 中心座標へ畳んでから XCUITest の座標長押しへ送る。ref をそのまま渡すと別要素を押す
    public func press(ref: Int, duration: Double) async throws {
        do {
            try await primary.press(ref: ref, duration: duration)
            fallbackNote = nil
        } catch {
            guard DriverError.isEngineIncapable(error) else { throw error }
            let snapshot = try await primary.snapshot()
            guard let element = snapshot.elements.first(where: { $0.ref == ref }) else {
                throw error
            }
            try await fallback.press(x: element.frame.centerX, y: element.frame.centerY,
                                     duration: duration)
            fallbackNote = "fell back to XCUITest (by coordinates)"
        }
    }

    // MARK: - primary 限定(ref の名前空間・注入・エンジン identity を跨がせない)

    public func tap(ref: Int) async throws { try await primary.tap(ref: ref) }
    public func snapshot() async throws -> SnapshotResponse { try await primary.snapshot() }
    public func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse {
        try await primary.snapshot(bypassingCache: bypassingCache)
    }
    public var supportsCacheBypass: Bool { primary.supportsCacheBypass }
    public func status() async throws -> StatusResponse { try await primary.status() }
    public func screenshot() async throws -> Data { try await primary.screenshot() }
    public func launch(bundleID: String) async throws { try await primary.launch(bundleID: bundleID) }
    public func activate(bundleID: String) async throws {
        try await primary.activate(bundleID: bundleID)
    }
    public func terminate() async throws { try await primary.terminate() }
    public func install(packagePath: String) async throws {
        try await primary.install(packagePath: packagePath)
    }
    public func uninstall(bundleID: String) async throws {
        try await primary.uninstall(bundleID: bundleID)
    }
    public func clearAppData(bundleID: String) async throws {
        try await primary.clearAppData(bundleID: bundleID)
    }
    public func isAppForeground(bundleID: String) async throws -> Bool {
        try await primary.isAppForeground(bundleID: bundleID)
    }
    public func foregroundAppID() async throws -> String? { try await primary.foregroundAppID() }
    public func captureKeyboardStateOnNextSnapshot() {
        primary.captureKeyboardStateOnNextSnapshot()
    }

    /// フォールバックしたことは注記として見せる(黙って別経路へ回ると挙動差の原因が読めない)。
    /// primary 自身の注記があればそちらを優先する(最内の観測を潰さない)
    public var lastActionNote: String? { primary.lastActionNote ?? fallbackNote }
    public var lastLaunchTiming: LaunchTiming? { primary.lastLaunchTiming }
}
