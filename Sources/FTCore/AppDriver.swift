// AppDriver.swift
// プラットフォーム境界となる唯一の抽象。iOS は FTBridgeClient が実装し、
// Android フェーズでは adb/UIAutomator2 ベースの実装を追加する(FTAgent/FTCore は無変更)。

import Foundation

public protocol AppDriver {
    func status() async throws -> StatusResponse
    /// パッケージファイル(iOS: .app バンドル / Android: .apk)からアプリをインストールする
    func install(packagePath: String) async throws
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
    /// URLSession レベルで「リクエストがサーバに届いていないことが確実」なエラー
    /// (接続拒否・接続断など)。Android ブリッジの自動再プロビジョン判定に使う
    case bridgeConnectionRefused(String)
    case badResponse(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .bridgeUnreachable(let detail), .bridgeConnectionRefused(let detail):
            return "ドライバに接続できません(iOS: ftester bridge up を先に実行 / Android: adb devices を確認): \(detail)"
        case .badResponse(let status, let body):
            return "ドライバがエラーを返しました (\(status)): \(body)"
        }
    }

    /// URLError のうち、接続そのものが成立しなかったことが確実なものだけを true とする
    /// (タイムアウト・キャンセル等、届いた可能性が残るものは false = 安全のためリトライしない)
    public static func isDefiniteDeliveryFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost:
            return true
        default:
            return false
        }
    }
}
