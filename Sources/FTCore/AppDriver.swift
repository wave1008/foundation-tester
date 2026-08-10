// AppDriver.swift
// プラットフォーム境界となる唯一の抽象。iOS は FTBridgeClient が実装し、
// Android フェーズでは adb/UIAutomator2 ベースの実装を追加する(FTAgent/FTCore は無変更)。

import Foundation

/// launch(bundleID:) の所要時間内訳(ミリ秒)。AppDriver.lastLaunchTiming が返す型。
/// actionMs = プロセスを起動させる外部呼び出し自体(simctl launch 等の往復)。
/// waitMs = 起動後、操作可能になるまで待った時間(readiness ポーリング等)。
/// FTDSL の launchApp/restartApp が ScenarioEvent(kind:"step").actionMs/waitMs へ
/// そのまま渡す(StepExecutor 経由のステップと同じフィールドに相乗り。新フィールドは足さない)。
public struct LaunchTiming: Sendable {
    public let actionMs: Int
    public let waitMs: Int
    public init(actionMs: Int, waitMs: Int) {
        self.actionMs = actionMs
        self.waitMs = waitMs
    }
}

public protocol AppDriver {
    func status() async throws -> StatusResponse
    /// パッケージファイル(iOS: .app バンドル / Android: .apk)からアプリをインストールする
    func install(packagePath: String) async throws
    /// アプリをアンインストールする(DSL の removeApp)。**プロトコル要件として宣言すること**
    /// (install(packagePath:) と同じ理由。extension だけに置くと存在型越しの呼び出しが
    /// 静的ディスパッチで既定実装に落ち、ドライバ側の実装が呼ばれないまま黙って無視される)
    func uninstall(bundleID: String) async throws
    func launch(bundleID: String) async throws
    /// 状態を保持したまま前面へ切り替える(未起動なら起動)。
    func activate(bundleID: String) async throws
    /// アプリスイッチャー(タスク一覧)を開く。
    func openAppSwitcher() async throws
    /// ホーム画面に戻る。
    func home() async throws
    /// 前の画面へ戻る。Android は戻るキー、iOS は左端エッジスワイプ(pop ジェスチャ)と、
    /// ドライバごとに機構が違う。
    func back() async throws
    func snapshot() async throws -> SnapshotResponse
    /// キャッシュを捨てて撮り直す。**プロトコル要件として宣言すること**(extension だけに置くと
    /// 存在型越しの呼び出しが静的ディスパッチで既定実装に落ち、実装したドライバが無視される)
    func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse
    func tap(ref: Int) async throws
    func tap(x: Double, y: Double) async throws
    func type(ref: Int?, text: String) async throws
    /// 入力欄をクリアする(ref なし = フォーカス中の欄)。DSL の clearInput
    func clearInput(ref: Int?) async throws
    /// フォーカス中の入力欄のファーストレスポンダを解除しソフトキーボードを閉じる(ref なし。DSL の hideKeyboard)。
    func hideKeyboard() async throws
    /// **アプリは残したままデータだけ消す**(DSL の clearAppData)。初回起動・オンボーディング・
    /// 権限ダイアログを何度でも再現するためのもので、再インストールは伴わない。
    /// 実行前にアプリを終了する(起動中に消すとプロセスが持っている状態が書き戻る)
    func clearAppData(bundleID: String) async throws
    /// アプリへ URL(ディープリンク)を配送する。**起動済みのアプリへ投げる**のが本来の用途。
    /// bundleID は Android の intent 宛先指定と、iOS in-app の再注入起動にだけ使う
    func openURL(_ url: String, bundleID: String?) async throws
    /// openURL 直後に OS(iOS: SpringBoard)が出す初回確認アラートを、可能なら自動了承する
    /// (ベストエフォート。同意は端末+アプリの組で永続するため以後の openURL では不要になる)。
    /// springboard を見られない接続(in-app ブリッジ等)では何もしない。
    /// **プロトコル要件として宣言すること**(install(packagePath:) と同じ理由。存在型越しの呼び出しは
    /// 要件でなければ静的ディスパッチで既定実装に落ち、実装したドライバが無視される)
    func acknowledgeOpenURLConsentIfPresent(bundleID: String) async
    /// 次の snapshot() 呼び出しでだけキーボード表示状態(SnapshotResponse.keyboardShown)を採る。
    /// StepExecutor が keyboardShown/keyboardNotShown アサートの直前に呼ぶ。既定は no-op
    /// (iOS はツリー走査中に常に判定できるため不要)。Android は dumpsys 呼び出しが固定費なので、
    /// 必要な snapshot でだけ払うためのフラグ(AndroidDriver 参照)
    func captureKeyboardStateOnNextSnapshot()
    /// フォーカス中の入力欄で Enter を押す(ref なし。Shirates pressEnter 相当)。
    /// iOS はソフトキー tap ができない(キーボード要素を snapshot から除外しているため)代替経路を
    /// ドライバごとに持つ: xcuitest は typeText("\n")、inapp は Compose 入力欄への insertText("\n")
    /// (design.md 承認済み差分)。inapp が 409(UIKit 入力欄・フォーカス無し)を返したときの
    /// xcuitest フォールバックは StepExecutor が担う
    func pressEnter() async throws
    func swipe(_ direction: FTSwipeDirection) async throws
    /// 用途つきの swipe。既定は通常 swipe と同じで、ブリッジ実装だけが用途を送る。
    /// path 非 nil = **スクロール領域を指定した座標スワイプ**(ホストの ScrollGeometry が計算)。
    /// **包むドライバは必ず素通しすること**(既定実装は自分の swipe(_:) を呼ぶので、受けないと
    /// 最初のラッパーで用途と座標が落ちる)
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws
    /// 2点間ドラッグ(座標は snapshot の screen と同じ座標系)。pressSeconds=押下静止時間、
    /// durationSeconds=移動時間(実機ジェスチャの速度・長押しに反映される)。
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws
    /// ダブルタップ(座標は snapshot の screen と同じ座標系)。**ref を取らない**のは、
    /// ref がブリッジごとに別名前空間で、501 で別ドライバへ回すときに取り直しが要るため
    /// (swipeElementToElement が中心座標へ畳んでから drag するのと同じ方針)。
    /// **プロトコル要件として宣言すること**(install(packagePath:) と同じ理由)
    func doubleTap(x: Double, y: Double) async throws
    /// 2本指のピンチ(DSL の pinchOut / pinchIn)。対象指定が frame と identifier の2本立てな
    /// 理由は BridgeDTO の PinchRequest 参照。**プロトコル要件として宣言すること**
    func pinch(frame: FTRect?, identifier: String?, scale: Double,
               durationSeconds: Double) async throws
    /// Rotates the device and waits for it to settle, returning the actual settled orientation
    /// (always equals the request — the driver throws instead of returning a mismatch; see
    /// DriverError 422 usage). **Protocol requirement** (same reasoning as doubleTap/pinch above:
    /// existential calls fall back to static dispatch on the default otherwise).
    func rotate(to orientation: FTOrientation) async throws -> FTOrientation
    /// Restores the orientation captured by this driver's first `rotate(to:)` call in the current
    /// scenario, if any (no-op — no round trip — if rotate was never called). Called unconditionally
    /// at scenario end. **Protocol requirement** (same reasoning as above).
    func restoreOrientationIfNeeded() async throws
    func press(ref: Int, duration: Double) async throws
    /// 座標指定のロングプレス(座標は snapshot の screen と同じ座標系)。
    func press(x: Double, y: Double, duration: Double) async throws
    func screenshot() async throws -> Data
    func terminate() async throws
    /// フォアグラウンドのアプリが bundleID(iOS)/ package(Android)と一致しているか(DSL の appIs)。
    /// **プロトコル要件として宣言すること**(install(packagePath:) と同じ理由)
    func isAppForeground(bundleID: String) async throws -> Bool
    /// 現在フォアグラウンドのアプリの bundleID/package(分かるプラットフォームだけ実値。
    /// 分からなければ nil。DSL の appIs の失敗メッセージが actual として使う)。
    /// **プロトコル要件として宣言すること**(install(packagePath:) と同じ理由)
    func foregroundAppID() async throws -> String?
    /// 直前のアクションで通常と違う経路を通ったときの説明(既定 nil)。失敗ではなく観測用。
    /// 「次のアクション呼び出しで上書き/クリアする」実装が前提(1シナリオ=1ドライバの逐次実行なので、
    /// クリアしないと前回の注記が別ステップに誤って付く)。デコレータ実装は base の値を透過すること
    /// (透過しないと最外のドライバから見えない)。
    var lastActionNote: String? { get }
    /// 直近の launch(bundleID:) の内訳。lastActionNote と同じ「次の launch 呼び出しで
    /// 上書き/クリアする」規約(1シナリオ=1ドライバの逐次実行が前提)。計測できないドライバ・
    /// 失敗した呼び出しは既定 nil(嘘の内訳を返さない)。デコレータ実装は base の値を透過すること
    /// (透過しないと最外のドライバから見えない。lastActionNote と同じ理由)。
    var lastLaunchTiming: LaunchTiming? { get }
    /// キャッシュを捨てた snapshot(`snapshot(bypassingCache: true)`)が意味を持つか。
    /// **ラッパードライバは base の値を透過すること**(false 固定にすると最内の Android へ届かない)
    var supportsCacheBypass: Bool { get }
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
    var lastLaunchTiming: LaunchTiming? { nil }

    /// 既定は用途を落として通常 swipe に委譲する(ラッパードライバはこれで素通しになる)。
    /// 用途を実際に送るのは HTTP を話す BridgeClient / AndroidDriver だけ
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        try await swipe(direction)
    }

    /// キャッシュを捨てて撮り直す snapshot。**Android だけが実装を持つ**(a11y ノードは
    /// キャッシュ供給で、IME 等が前面のとき数秒古いツリーを返し続ける)。コストが高い
    /// (1 snapshot あたり約 +65ms)ので、検証が期限切れで失敗と決まる直前の1回にだけ使う。
    /// iOS 系は鮮度問題を持たないので既定の素通しでよい。
    /// **ラッパードライバを足すときは転送すること**(素通しのままだと最内の Android へ届かない)
    func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse {
        try await snapshot()
    }

    /// false のドライバでは検証側が取り直しの周回そのものを行わない(無駄な1周を増やさない)
    var supportsCacheBypass: Bool { false }

    func activate(bundleID: String) async throws {
        try await launch(bundleID: bundleID)
    }

    func openAppSwitcher() async throws {
        throw DriverError.badResponse(status: 501, body: "This driver does not support the app switcher")
    }

    func home() async throws {
        throw DriverError.badResponse(status: 501, body: "This driver does not support the home button")
    }

    func back() async throws {
        throw DriverError.badResponse(status: 501, body: "This driver does not support going back")
    }

    func clearInput(ref: Int?) async throws {
        throw DriverError.badResponse(status: 501, body: "This driver does not support clearing input")
    }

    func hideKeyboard() async throws {
        throw DriverError.badResponse(status: 501, body: "This driver does not support hiding the keyboard")
    }

    func clearAppData(bundleID: String) async throws {
        throw DriverError.badResponse(status: 501, body: "This driver does not support clearing app data")
    }

    func openURL(_ url: String, bundleID: String?) async throws {
        throw DriverError.badResponse(status: 501, body: "This driver does not support opening a URL")
    }

    /// 既定は no-op: 実装を持つのは springboard の /session を張れる接続(BridgeClient=XCUITest
    /// 接続)だけ。他のドライバは黙って通す(取りこぼしより誤爆を避ける側に倒す)
    func acknowledgeOpenURLConsentIfPresent(bundleID: String) async {}

    func captureKeyboardStateOnNextSnapshot() {}

    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {
        throw DriverError.badResponse(status: 501, body: "This driver does not support point-to-point drag")
    }

    func press(x: Double, y: Double, duration: Double) async throws {
        throw DriverError.badResponse(status: 501, body: "This driver does not support long-press by coordinates")
    }

    /// 実装を持たないドライバの既定。501 = ホストが typeDriver(XCUITest)へ回す合図
    /// (in-app は 2026-08-04 から自前描画フレームワーク向けに実装を持つ。UIKit/SwiftUI は
    /// 合成タッチを受理しないので、あちらが 501 を返して XCUITest へ回る)
    func doubleTap(x: Double, y: Double) async throws {
        throw DriverError.badResponse(status: 501, body: "This driver does not support double tap")
    }

    func pinch(frame: FTRect?, identifier: String?, scale: Double,
               durationSeconds: Double) async throws {
        throw DriverError.badResponse(status: 501, body: "This driver does not support pinch")
    }

    func rotate(to orientation: FTOrientation) async throws -> FTOrientation {
        throw DriverError.badResponse(status: 501, body: "This driver does not support rotation")
    }

    func restoreOrientationIfNeeded() async throws {}

    func pressEnter() async throws {
        throw DriverError.badResponse(status: 501, body: "This driver does not support pressing the Enter key")
    }
}
