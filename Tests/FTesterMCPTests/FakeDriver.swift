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
        return snapshotResponse
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

    func screenshot() async throws -> Data {
        try record("screenshot", "screenshot")
        return screenshotData
    }

    func terminate() async throws {
        try record("terminate", "terminate")
    }
}
