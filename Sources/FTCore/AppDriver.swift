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
    /// フォーカス中の入力欄で Enter を押す(ref なし。Shirates pressEnter 相当)。
    /// iOS はソフトキー tap ができない(キーボード要素を snapshot から除外しているため)代替経路を
    /// ドライバごとに持つ: xcuitest は typeText("\n")、inapp は Compose 入力欄への insertText("\n")
    /// (design.md 承認済み差分)。inapp が 409(UIKit 入力欄・フォーカス無し)を返したときの
    /// xcuitest フォールバックは StepExecutor が担う
    func pressEnter() async throws
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
    /// 直前のアクションで通常と違う経路を通ったときの説明(既定 nil)。失敗ではなく観測用。
    /// 「次のアクション呼び出しで上書き/クリアする」実装が前提(1シナリオ=1ドライバの逐次実行なので、
    /// クリアしないと前回の注記が別ステップに誤って付く)。デコレータ実装は base の値を透過すること
    /// (透過しないと最外のドライバから見えない)。
    var lastActionNote: String? { get }
}

public enum DriverError: Error, LocalizedError {
    case bridgeUnreachable(String)
    /// URLSession レベルで「リクエストがサーバに届いていないことが確実」なエラー
    /// (接続拒否・接続断など)。Android ブリッジの自動再プロビジョン判定に使う
    case bridgeConnectionRefused(String)
    case badResponse(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .bridgeUnreachable(let detail):
            // ハイブリッド/混在実行では背面アプリが suspend され、TCP は受理されても
            // HTTP 応答が返らずタイムアウトになることがある(この case で観測される)。
            return "Cannot reach the driver (bridge not running, slow response, or — in hybrid/mixed runs — the backgrounded app is suspended so TCP is accepted but no HTTP response comes back. Check iOS: ftester bridge up / Android: adb devices). The inapp/hybrid engines are simulator-only (injection is impossible on physical devices — use an xcuitest profile): \(detail)"
        case .bridgeConnectionRefused(let detail):
            // 接続拒否=ポートで誰も待受していない。実行途中なら対象アプリのプロセス死が最有力
            // (iOS inapp はブリッジがアプリ内常駐のため、アプリが落ちると即接続不能になる)。
            return "Connection to the driver was refused (nothing listening on the port). If this happened mid-run, the app under test most likely exited or crashed (on iOS inapp the bridge lives inside the app, so it becomes unreachable the moment the app dies). If the app has not been started yet, check iOS: ftester bridge up / Android: adb devices. Detail: \(detail)"
        case .badResponse(let status, let body):
            return "The driver returned an error (\(status)): \(body)"
        }
    }

    /// 「このエンジンでは原理的に実行できない」応答か = XCUITest へ回してよいか。
    /// **501 と「ルート不明の 404」だけ**。
    /// - 409 は含めない: キーウィンドウ不在・セッション消失といった一時的競合にも使われ、
    ///   フォールバック判定に使うと「アプリが前面に無い」状況を隠して別画面を操作しかねない
    /// - 404 は in-app では ref 不明(スナップショット取り直しが要る本物の失敗)にも使われるため、
    ///   ルート不明を表す本文前置でだけ拾う(両ブリッジとも "not found: METHOD PATH" 書式。
    ///   InAppBridge.handle / Runner の BridgeRouter.handle と同期が必要)
    public static func isEngineIncapable(_ error: Error) -> Bool {
        guard let driverError = error as? DriverError,
              case .badResponse(let status, let body) = driverError else { return false }
        return status == 501 || (status == 404 && body.hasPrefix("not found:"))
    }

    /// URLError のうち、接続そのものが成立しなかったことが確実なものだけを true とする
    /// (タイムアウト・キャンセル等、届いた可能性が残るものは false = 安全のためリトライしない)。
    /// .networkConnectionLost は接続確立後の切断でも出る=届いて処理された可能性が残るため含めない
    /// (Android withBridge が true 時に operation を再実行するので、含めると tap 等が二重実行されうる)
    public static func isDefiniteDeliveryFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotConnectToHost, .notConnectedToInternet, .cannotFindHost:
            return true
        default:
            return false
        }
    }
}

/// activate 未対応ドライバ(InAppDriver/SystemUIDriver 等)は launch(再起動)にフォールバックする。
public extension AppDriver {
    var lastActionNote: String? { nil }

    func activate(bundleID: String) async throws {
        try await launch(bundleID: bundleID)
    }

    func openAppSwitcher() async throws {
        throw DriverError.badResponse(status: 501, body: "This driver does not support the app switcher")
    }

    func home() async throws {
        throw DriverError.badResponse(status: 501, body: "This driver does not support the home button")
    }

    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {
        throw DriverError.badResponse(status: 501, body: "This driver does not support point-to-point drag")
    }

    func press(x: Double, y: Double, duration: Double) async throws {
        throw DriverError.badResponse(status: 501, body: "This driver does not support long-press by coordinates")
    }

    func pressEnter() async throws {
        throw DriverError.badResponse(status: 501, body: "This driver does not support pressing the Enter key")
    }
}
