// AppDriver.swift
// プラットフォーム境界となる唯一の抽象。iOS は FTBridgeClient が実装し、
// Android フェーズでは adb/UIAutomator2 ベースの実装を追加する(FTAgent/FTCore は無変更)。

import Foundation

public protocol AppDriver {
    func status() async throws -> StatusResponse
    func launch(bundleID: String) async throws
    func snapshot() async throws -> SnapshotResponse
    func tap(ref: Int) async throws
    func tap(x: Double, y: Double) async throws
    func type(ref: Int?, text: String) async throws
    func swipe(_ direction: FTSwipeDirection) async throws
    func press(ref: Int, duration: Double) async throws
    func screenshot() async throws -> Data
    func terminate() async throws
}

public enum DriverError: Error, LocalizedError {
    case bridgeUnreachable(String)
    case badResponse(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .bridgeUnreachable(let detail):
            return "ドライバに接続できません(iOS: ftester bridge up を先に実行 / Android: adb devices を確認): \(detail)"
        case .badResponse(let status, let body):
            return "ドライバがエラーを返しました (\(status)): \(body)"
        }
    }
}
