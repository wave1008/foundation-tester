// AppDriver.swift
// プラットフォーム境界となる唯一の抽象。iOS は FTBridgeClient が実装し、
// Android フェーズでは adb/UIAutomator2 ベースの実装を追加する(FTAgent/FTCore は無変更)。

import Foundation

public protocol AppDriver {
    func status() async throws -> StatusResponse
    /// パッケージファイル(iOS: .app バンドル / Android: .apk)からアプリをインストールする
    func install(packagePath: String) async throws
    func launch(bundleID: String) async throws
    /// 状態を保持したまま前面へ切り替える(未起動なら起動)。
    func activate(bundleID: String) async throws
    /// アプリスイッチャー(タスク一覧)を開く。
    func openAppSwitcher() async throws
    /// ホーム画面に戻る。
    func home() async throws
    func snapshot() async throws -> SnapshotResponse
    func tap(ref: Int) async throws
    func tap(x: Double, y: Double) async throws
    func type(ref: Int?, text: String) async throws
    func swipe(_ direction: FTSwipeDirection) async throws
    /// 2点間ドラッグ(座標は snapshot の screen と同じ座標系)。pressSeconds=押下静止時間、
    /// durationSeconds=移動時間(実機ジェスチャの速度・長押しに反映される)。
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws
    func press(ref: Int, duration: Double) async throws
    /// 座標指定のロングプレス(座標は snapshot の screen と同じ座標系)。
    func press(x: Double, y: Double, duration: Double) async throws
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

/// activate 未対応ドライバ(InAppDriver/SystemUIDriver 等)は launch(再起動)にフォールバックする。
public extension AppDriver {
    func activate(bundleID: String) async throws {
        try await launch(bundleID: bundleID)
    }

    func openAppSwitcher() async throws {
        throw DriverError.badResponse(status: 501, body: "このドライバはアプリスイッチャーに対応していません")
    }

    func home() async throws {
        throw DriverError.badResponse(status: 501, body: "このドライバはホームボタンに対応していません")
    }

    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {
        throw DriverError.badResponse(status: 501, body: "このドライバは2点間ドラッグに対応していません")
    }

    func press(x: Double, y: Double, duration: Double) async throws {
        throw DriverError.badResponse(status: 501, body: "このドライバは座標ロングプレスに対応していません")
    }
}
