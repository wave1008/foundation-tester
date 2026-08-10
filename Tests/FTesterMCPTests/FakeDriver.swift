// MCP のツール dispatch を実デバイス無しで検証するための AppDriver スタブ。
// 「どのメソッドがどの引数で呼ばれたか」を記録し、任意のメソッドを失敗させられる。

import Foundation
import FTCore

final class FakeDriver: AppDriver, @unchecked Sendable {

    /// 呼ばれたメソッドを引数込みで記録する(例: `tap(ref:3)`)
    private(set) var calls: [String] = []
    /// ここに入れた名前のメソッドは throw する(エラー整形の検証用)
    var failing: Set<String> = []

    var statusResponse = StatusResponse(
        ready: true, device: "iPhone 17", osVersion: "26.0", sessionBundleID: "com.example.app")
    var snapshotResponse = SnapshotResponse(
        sessionBundleID: "com.example.app",
        screen: FTRect(x: 0, y: 0, width: 390, height: 844),
        elements: [
            ElementInfo(ref: 1, type: "Button", identifier: "login_btn", label: "ログイン",
                        value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 10, y: 20, width: 100, height: 40), depth: 1),
        ],
        truncatedCount: 0)
    var screenshotData = Data([0x89, 0x50, 0x4E, 0x47])

    struct Boom: Error, LocalizedError {
        let what: String
        var errorDescription: String? { "\(what) が失敗しました" }
    }

    private func record(_ call: String, _ name: String) throws {
        calls.append(call)
        if failing.contains(name) { throw Boom(what: name) }
    }

    func status() async throws -> StatusResponse {
        try record("status", "status")
        return statusResponse
    }

    func install(packagePath: String) async throws {
        try record("install(\(packagePath))", "install")
    }

    func uninstall(bundleID: String) async throws {
        try record("uninstall(\(bundleID))", "uninstall")
    }

    var foregroundBundleID: String?

    func isAppForeground(bundleID: String) async throws -> Bool {
        try record("isAppForeground(\(bundleID))", "isAppForeground")
        return foregroundBundleID == bundleID
    }

    func foregroundAppID() async throws -> String? {
        try record("foregroundAppID", "foregroundAppID")
        return foregroundBundleID
    }

    func launch(bundleID: String) async throws {
        try record("launch(\(bundleID))", "launch")
    }

    func snapshot() async throws -> SnapshotResponse {
        try record("snapshot", "snapshot")
        // 待ちの検証用: 台本があれば呼ばれた順に返し、尽きたら最後の1枚を返し続ける
        if !scriptedSnapshots.isEmpty {
            let next = scriptedSnapshots.removeFirst()
            snapshotResponse = next
        }
        return snapshotResponse
    }

    /// Android を模す(既定 false = iOS 相当)。true にすると MCP は必ず
    /// `snapshot(bypassingCache: true)` を撃つはずで、呼び出し記録で区別できる
    var supportsCacheBypass = false

    func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse {
        guard bypassingCache else { return try await snapshot() }
        try record("snapshot(fresh)", "snapshot")
        if !scriptedSnapshots.isEmpty {
            snapshotResponse = scriptedSnapshots.removeFirst()
        }
        return snapshotResponse
    }

    /// snapshot が順に返す台本(空 = snapshotResponse を返し続ける)
    var scriptedSnapshots: [SnapshotResponse] = []

    func clearAppData(bundleID: String) async throws {
        try record("clearAppData(\(bundleID))", "clearAppData")
    }

    func tap(ref: Int) async throws {
        try record("tap(ref:\(ref))", "tap")
    }

    func tap(x: Double, y: Double) async throws {
        try record("tap(x:\(x),y:\(y))", "tap")
    }

    func type(ref: Int?, text: String) async throws {
        try record("type(ref:\(ref.map(String.init) ?? "nil"),text:\(text))", "type")
    }

    func swipe(_ direction: FTSwipeDirection) async throws {
        try record("swipe(\(direction.rawValue))", "swipe")
    }

    func press(ref: Int, duration: Double) async throws {
        try record("press(ref:\(ref),duration:\(duration))", "press")
    }

    func doubleTap(x: Double, y: Double) async throws {
        try record("doubleTap(x:\(x),y:\(y))", "doubleTap")
    }

    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {
        try record("drag(\(fromX),\(fromY)->\(toX),\(toY),duration:\(durationSeconds))", "drag")
    }

    func pinch(frame: FTRect?, identifier: String?, scale: Double,
               durationSeconds: Double) async throws {
        let target = frame.map { "\($0.x),\($0.y),\($0.width)x\($0.height)" } ?? "screen"
        try record("pinch(\(target),id:\(identifier ?? "nil"),scale:\(scale))", "pinch")
    }

    func back() async throws { try record("back", "back") }
    func home() async throws { try record("home", "home") }
    func openAppSwitcher() async throws { try record("appSwitcher", "appSwitcher") }
    func pressEnter() async throws { try record("pressEnter", "pressEnter") }

    func clearInput(ref: Int?) async throws {
        try record("clearInput(ref:\(ref.map(String.init) ?? "nil"))", "clearInput")
    }

    func screenshot() async throws -> Data {
        try record("screenshot", "screenshot")
        // 台本があれば呼ばれた順に返す(ft_screenshot の imageHash×treeFingerprint 判定を
        // 「同じバイト列を2回」「別バイト列」で作り分けるため。空 = screenshotData を返し続ける
        if !scriptedScreenshots.isEmpty {
            return scriptedScreenshots.removeFirst()
        }
        return screenshotData
    }

    /// screenshot が順に返す台本。scriptedSnapshots と対になる(FakeDriver.snapshot 参照)
    var scriptedScreenshots: [Data] = []

    func terminate() async throws {
        try record("terminate", "terminate")
    }
}
