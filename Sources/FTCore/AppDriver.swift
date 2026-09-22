// AppDriver.swift
// プラットフォーム境界となる唯一の抽象。iOS は FTBridgeClient が実装し、
// Android フェーズでは adb/UIAutomator2 ベースの実装を追加する(FTFoundationModels/FTCore は無変更)。

import Foundation

/// launch(bundleID:) の所要時間内訳(ミリ秒)。AppDriver.lastLaunchTiming が返す型。
/// actionMs = プロセスを起動させる外部呼び出し自体(simctl launch 等の往復)。
/// waitMs = 起動後、操作可能になるまで待った時間(readiness ポーリング等)。
/// FTDSL の launchApp/restartApp が ScenarioEvent(kind:"step").actionMs/waitMs へ
/// そのまま渡す(StepExecutor 経由のステップと同じフィールドに相乗り。新フィールドは足さない)。
public struct LaunchTiming: Sendable {
    public let actionMs: Int
    public let waitMs: Int
    /// 起動させた後、**XCUITest ランナーがアプリを前面と見ないまま activate を頼んだ**
    /// (FastLaunchDriver。注記 `StepNote.launchActivatedBeforeForeground` の材料)
    public let activatedBeforeForeground: Bool
    public init(actionMs: Int, waitMs: Int, activatedBeforeForeground: Bool = false) {
        self.actionMs = actionMs
        self.waitMs = waitMs
        self.activatedBeforeForeground = activatedBeforeForeground
    }
}

/// `GET /hittable` の答え。**3つを混ぜない** —— 混ぜると「撃てない」と「聞けなかった」が
/// 同じ nil になり、呼び手はどちらとも断定できずに黙るしかなくなる(実際にそうなっていた)。
///
/// - `hittable(false)`: プラットフォームが**その位置では当たらない**と答えた
///   (上のクロムの下へ潜った等)
/// - `unresolvable`: **木が今まさに載せている要素を、ライブのクエリが引き当てられない**。
///   iOS で SpringBoard の面(アプリスイッチャー・コントロールセンター)がアプリを覆うと
///   これになる —— そのとき `/snapshot` は覆う前と1バイト同じ木を返し続けるので、
///   **木と食い違うこの答えだけが「木が画面を代表していない」ことを知っている**
///   (2026-08-28 実測: 覆い無し 0/12 → 覆い有り 12/12。判定は
///   `TapTargetGeometry.platformShouldResolve` で「引き当てられて当然の要素」に絞る)
/// - `unavailable`: 旧ブリッジ・in-app・Android・通信失敗。**何も言えない**
public enum HitTestAnswer: Sendable, Equatable {
    case hittable(Bool)
    case unresolvable
    case unavailable

    /// `GET /hittable` の本文から組み立てる。**`hittable` 欠落 = 引き当て不能**
    /// (ランナーは `resolvedBy: "unresolved"` を添える)。
    /// **ここを `.unavailable` へ畳むと検知が丸ごと死ぬ** —— 木が画面を代表していないことを
    /// 知っている唯一の答えが「聞けなかった」と同じ扱いになる。
    /// 呼び出しの失敗(旧ブリッジの 404・通信断)は呼び手が `.unavailable` にする
    public static func fromBridge(hittable: Bool?) -> HitTestAnswer {
        guard let hittable else { return .unresolvable }
        return .hittable(hittable)
    }
}

public protocol AppDriver {
    func status() async throws -> StatusResponse
    /// パッケージファイル(iOS: .app バンドル / Android: .apk / .apks)からアプリをインストールする
    func install(packagePath: String) async throws
    /// アプリをアンインストールする(DSL の removeApp)。**プロトコル要件として宣言すること**
    /// (install(packagePath:) と同じ理由。extension だけに置くと存在型越しの呼び出しが
    /// 静的ディスパッチで既定実装に落ち、ドライバ側の実装が呼ばれないまま黙って無視される)
    func uninstall(bundleID: String) async throws
    func launch(bundleID: String) async throws
    /// 状態を保持したまま前面へ切り替える(未起動なら起動)。
    func activate(bundleID: String) async throws
    /// **既に前面にあると確かめたアプリ**へ、画面を動かさずにセッションを向け直す。
    /// 前面化も起動も撃たないのが activate / launch との違い。前面でなければ失敗する。
    ///
    /// **利用者が見ているものが必ずしも「アプリ」ではない**ので要る —— Spotlight を開くと
    /// `com.apple.Spotlight` が前面と答えるが、これは SpringBoard の拡張で、activate すると
    /// **ホーム画面が描画を失い画面が真っ黒になる**(実測 2026-09-22。陽性対照:
    /// activate でスクリーンショット 2.2MB→68KB・木が 28→6 要素)。自アプリでも同じで、
    /// in-app ドライバの activate は既定実装から launch = dylib 注入の再起動へ落ちる。
    ///
    /// **プロトコル要件として宣言すること**(既定実装へ静的ディスパッチで落ちる)
    func attach(bundleID: String) async throws
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
    /// **その ref を撃つと本当にそれに当たるか**をプラットフォームに聞く(iOS の XCUITest だけが
    /// 答えられる。`XCUIElement.isHittable` はヒットテストそのもの)。
    /// nil = 「答えられない」(未対応のドライバ・引き当て不能)で、呼び手は何も言わない。
    ///
    /// **木では原理的に答えられない問い**への逃げ道。iOS は塗り順(z)を出さないので、
    /// 木の順序では「上のクロムの下へスクロールで潜った要素」を見分けられない
    /// (実測: カレンダーのセルを撃つと警告ゼロで戻るボタンが押される)。
    ///
    /// **全要素に付けてはいけない**(実測 121 要素で 5.1 秒 = snapshot の 50 倍)。
    /// 呼び手が疑ったときだけ1件聞く。**プロトコル要件として宣言すること**(理由は上と同じ)
    func hitTest(ref: Int) async throws -> HitTestAnswer
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
    /// 次の snapshot() 1回だけ要素上限を引き上げる(nil = 既定へ戻す)。
    /// **一発限りにする理由**: 上げたままだと以後の応答が全部膨らみ、上げた当人以外
    /// (整定ループ・探索の各周回)が黙って重い木を引く。`captureKeyboardStateOnNextSnapshot`
    /// と同じ形。**プロトコル要件として宣言すること**(既定実装だけに置くと存在型越しの
    /// 呼び出しが静的ディスパッチで no-op に落ち、ブリッジまで届かない)
    func raiseElementLimitOnNextSnapshot(_ max: Int?)
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
    /// 直前の**端送り**(`intent: .edge`)で「もう端に着いている」とドライバが**確信できた**か。
    /// 既定 nil = 分からない(ホストは従来どおり木の署名が2回続けて不変になるまで読む)。
    ///
    /// 端送りの所要は、スクロールそのものではなく**この判定のための読み**が支配する
    /// (ページを1回で飛ばせる画面では 2.3s のほぼ全部。docs/performance-tuning.md §3.27)。
    /// 位置を直接動かせるドライバは「余地が無い」を**事実として**知っているので、
    /// 推測(署名の比較)より強い。**プロトコル要件として宣言すること**(既定実装だけだと
    /// 存在型越しの呼び出しが静的ディスパッチで既定へ落ち、ドライバの答えが捨てられる)
    var reachedEdgeOnLastSwipe: Bool? { get }
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
    /// **OS のシステム UI(SpringBoard のアラート)が載っているか**。分からないドライバは nil。
    /// **プロトコル要件として宣言すること**(install(packagePath:) と同じ理由 ——
    /// 要件でないと存在型越しの呼び出しが静的ディスパッチで既定実装に落ち、黙って nil になる)
    func systemAlert() async throws -> SystemAlertProbeResponse?
    /// **SpringBoard の面がアプリを覆っているか**(iOS xcuitest だけが答えられる)。
    /// nil = 答えられない(in-app / Android / 旧ブリッジ)。**プロトコル要件として宣言すること**
    /// (存在型越しの呼び出しは要件でなければ既定実装へ静的ディスパッチされる)
    func systemUICovering() async throws -> SystemUICoveringResponse?
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
    /// **木の座標1単位あたり何 px か**(iOS = 1: 木は pt / Android = 表示密度: 木は px)。
    /// 幾何の床(`StepExecutor.minimumVisibleTapExtent`)を木の単位へ換算するために使う。
    ///
    /// iOS の pt(1/163 inch)と Android の dp(1/160 inch)は**物理的にほぼ同じ**なので、
    /// pt で測った床は dp としてそのまま通用する —— 足りないのは px への換算だけ。
    /// 換算しないと 3倍密度の端末で床が約3倍緩くなり、**わずかな重なりを「見えている部分」と
    /// 信じて叩く**(2026-08-15。コメントが pt と書いてある値を px の木へ当てていた)。
    /// **プロトコル要件として宣言すること**(install(packagePath:) と同じ理由)。
    /// **ラッパードライバは base の値を透過すること**(1 に落とすと最内の Android へ届かない)
    var pointScale: Double { get }
    /// type(ref:text:) を自前で読み返して検証済みか(xcuitest ランナー・Android 注入器は内部で
    /// 読み返す。iOS in-app ブリッジは読み返さない=false)。false のときだけ StepExecutor が
    /// 読み返しを行う(TypeReadback.swift 参照)。**プロトコル要件として宣言すること**
    /// (install(packagePath:) と同じ理由。存在型越しの呼び出しは要件でなければ静的ディスパッチで
    /// 既定実装に落ち、実装したドライバが無視される)。
    /// **ラッパードライバは実際に type を実行する側の値へ転送すること**(既定 false に落とすと
    /// 無害だが、既に検証済みの経路にも二重読み返しの固定費が乗る)
    var verifiesTypedText: Bool { get }
}

extension DriverError: StepFailureKindProviding {
    /// 到達できなかった(接続拒否・応答なし・アプリのプロセス死・別デバイスへの奪取)/
    /// 到達したがエラー応答、の2つ
    public var stepFailureKind: StepFailureKind? {
        switch self {
        case .bridgeUnreachable, .bridgeConnectionRefused, .bridgeIdentityMismatch: return .driverUnreachable
        case .badResponse: return .driverError
        }
    }
}

/// この失敗が起きた構成(プラットフォーム込みのエンジン・実機か)。`DriverError.bridgeUnreachable`/
/// `.bridgeConnectionRefused` の必須の同伴データにする(**既定値を置かない** —— 新しい throw
/// サイトが文脈を渡し忘れたらコンパイルで止める。`OverlayWindowOcclusion` と同じ規律)。
///
/// **`BridgeClient`(iOS xcuitest 用クライアント)は in-app・Android にも使い回されるため、
/// 自分の宛先が3つのどれかを知らない**(BridgeClient.send 参照)。in-app は `InAppDriver`、
/// Android は `AndroidDriver.withBridge` が、境界で正しい context へ付け替えて再 throw する。
public struct DriverErrorContext: Sendable, Equatable {
    public enum Engine: Sendable, Equatable {
        case iosInApp
        case iosXCUITest
        case android
    }
    public let engine: Engine
    public let physicalDevice: Bool
    public init(engine: Engine, physicalDevice: Bool) {
        self.engine = engine
        self.physicalDevice = physicalDevice
    }
}

/// `DriverError.errorDescription` の文言組み立て(純粋関数。`DriverErrorMessageTests` が
/// 構成ごとの文面を等号固定する)。**構成ごとに、その構成で実際に起こりうる原因だけを並べる**
/// —— 2026-09-16 の負荷テストで、Android の一時的な adb 断に iOS inapp/hybrid 向けの案内
/// (「シミュレータ専用」)が付き、iOS xcuitest ランナーを外から殺した接続拒否で
/// 「アプリが落ちた」が第一容疑にされていた(xcuitest はアプリと別プロセスなので的外れ)
public enum DriverErrorMessage {
    public static func unreachable(context: DriverErrorContext, detail: String) -> String {
        let base = "Cannot reach the driver (not running, or slow to respond)."
        let hint: String
        switch context.engine {
        case .iosInApp:
            // in-app は常にシミュレータ上で走る(InAppDriver.context 参照)ので、この文言の
            // 読み手の構成では「実機では不可」の案内は起こりえない
            hint = " In hybrid/mixed runs the backgrounded app can be suspended, so TCP is accepted"
                + " but no HTTP response comes back. Check: fleetest bridge up."
        case .iosXCUITest:
            hint = " Check: fleetest bridge up."
        case .android:
            hint = " Check: adb devices, `fleetest doctor`, or try `fleetest bridge up --platform android`."
        }
        return detail.isEmpty ? "\(base)\(hint)" : "\(base)\(hint) \(detail)"
    }

    public static func connectionRefused(context: DriverErrorContext, detail: String) -> String {
        let base = "Connection to the driver was refused (nothing listening on the port)."
        let suspect: String
        switch context.engine {
        case .iosInApp:
            suspect = " If this happened mid-run, the app under test most likely exited or crashed"
                + " (on iOS inapp the bridge lives inside the app, so it becomes unreachable the"
                + " moment the app dies)."
        case .iosXCUITest:
            suspect = context.physicalDevice
                ? " If this happened mid-run, the XCUITest runner most likely stopped, or the"
                    + " physical device disconnected (USB/Wi-Fi) — on xcuitest the bridge runs in a"
                    + " separate process from the app under test, so a crashed app alone would not"
                    + " explain this."
                : " If this happened mid-run, the XCUITest runner most likely stopped (on xcuitest"
                    + " the bridge runs in a separate process from the app under test, so a crashed"
                    + " app alone would not explain this)."
        case .android:
            suspect = " If this happened mid-run, the Android bridge (a separate instrumentation"
                + " process) most likely stopped — it does not live inside the app under test."
        }
        let checkHint = context.engine == .android
            ? " If the app has not been started yet, check: adb devices."
            : " If the app has not been started yet, check: fleetest bridge up."
        return "\(base)\(suspect)\(checkHint) Detail: \(detail)"
    }
}

/// Android の `/snapshot` が「アクティブウィンドウの a11y 根が無い」で断るときの本文接頭辞(422)。
/// 同期相手は `AndroidRunner/src/com/example/ftbridge/BridgeRouter.java` の
/// `NO_ACTIVE_WINDOW_ROOT`(片方だけ変えない。`AndroidNoReadableWindowSyncTests` が固定)。
/// **`BridgeDTO.swift` へ置かない** —— あちらはブリッジのソース集合に入っており、ホストしか
/// 読まない定数を足すと dylib/ランナーの指紋が無意味に動く(`WebViewDOMSnapshot.swift` と同じ規律)
public enum AndroidBridgeErrorPrefix {
    public static let noActiveWindowRoot = "no-active-window-root:"
}

public enum DriverError: Error, LocalizedError {
    case bridgeUnreachable(context: DriverErrorContext, detail: String)
    /// URLSession レベルで「リクエストがサーバに届いていないことが確実」なエラー
    /// (接続拒否・接続断など)。Android ブリッジの自動再プロビジョン判定に使う
    case bridgeConnectionRefused(context: DriverErrorContext, detail: String)
    case badResponse(status: Int, body: String)
    /// F8b: 事前確認の /status がドライバ自体には届いたが、接続先が期待したデバイスと違った
    /// (ポートが別デバイスのブリッジに奪われた)。detail は BridgeIdentityCheck.verdict が
    /// 組み立てる、事実だけの完成文(呼び出し元で追加の前置きをしない)
    case bridgeIdentityMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .bridgeUnreachable(let context, let detail):
            return DriverErrorMessage.unreachable(context: context, detail: detail)
        case .bridgeConnectionRefused(let context, let detail):
            return DriverErrorMessage.connectionRefused(context: context, detail: detail)
        case .badResponse(let status, let body):
            return "The driver returned an error (\(status)): \(body)"
        case .bridgeIdentityMismatch(let detail):
            return detail
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

    /// ブリッジが「アクティブウィンドウの a11y 根が無い」と申告した応答か。
    /// **status と宣言した本文接頭辞で見る**(自由文の一致ではない。接頭辞は
    /// AndroidRunner/src/com/example/ftbridge/BridgeRouter.java の NO_ACTIVE_WINDOW_ROOT と同期
    /// = AndroidBridgeErrorPrefix.noActiveWindowRoot)。**`isEngineIncapable` の「404 は
    /// "not found:" 前置でだけ拾う」と同じ立場** —— 422 は他の一時的競合にも使われるため
    public static func isNoReadableWindow(_ error: Error) -> Bool {
        guard let driverError = error as? DriverError,
              case .badResponse(let status, let body) = driverError else { return false }
        return status == 422 && body.hasPrefix(AndroidBridgeErrorPrefix.noActiveWindowRoot)
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
    /// 既定は nil(= 判定しない)。**答えられるのは XCUITest ランナーを包むドライバだけ**で、
    /// in-app は自プロセスしか見えず、Android は木の根が active window なので判定自体が要らない
    func systemAlert() async throws -> SystemAlertProbeResponse? { nil }
    /// 既定は「答えられない」。答えられるのは XCUITest ブリッジを話す BridgeClient だけ
    func systemUICovering() async throws -> SystemUICoveringResponse? { nil }

    var lastActionNote: String? { nil }
    /// 既定は「分からない」。答えられるのは**位置を直接動かせる**ドライバ(AndroidDriver の
    /// CDP 経路・in-app の contentOffset 経路)だけ。**包むドライバは中のドライバの答えを
    /// 素通しすること**(捨てると端送りが毎回ホストの署名判定まで回る)
    var reachedEdgeOnLastSwipe: Bool? { nil }
    /// 既定は「答えられない」。答えられるのは XCUITest ブリッジを話す BridgeClient だけ
    func hitTest(ref: Int) async throws -> HitTestAnswer { .unavailable }
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

    /// 既定は未検証(false)= StepExecutor 側の読み返しが働く安全側。検証済みドライバだけが true を宣言する
    var verifiesTypedText: Bool { false }

    /// 既定は 1(木が pt = iOS 系)。px で木を返す Android だけが密度を申告する
    var pointScale: Double { 1 }

    func activate(bundleID: String) async throws {
        try await launch(bundleID: bundleID)
    }

    /// **activate へ倒さない** —— 向け直せないことより、画面を壊すほうが害が大きい
    /// (要件の doc 参照)。呼び手は失敗を「向け直せなかった」として扱う
    func attach(bundleID: String) async throws {
        throw DriverError.badResponse(
            status: 501, body: "This driver cannot point its session at an app without activating it")
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

    /// 既定は no-op(上限を持たないドライバ = 上げようがない)。ブリッジ接続を持つ
    /// ドライバとラッパーだけが実装する
    func raiseElementLimitOnNextSnapshot(_ max: Int?) {}

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
