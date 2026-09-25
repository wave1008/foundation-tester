// BridgeDTO.swift
// ホスト(macOS CLI)とXCUITestランナー(iOSシミュレータ)の間で共有するAPI型。
// このファイルは Runner/FleetestRunnerUITests ターゲットにも直接コンパイルされるため、
// Foundation 以外に依存してはならない。

import Foundation

public enum BridgeAPI {
    public static let defaultPort: UInt16 = 8123
    /// in-app ブリッジが**メインスレッドの実行を待つ上限**(ms)。尽きたら 504(未実行の 200 を
    /// 返さない)。根拠: ホストの操作系 HTTP 上限 `BridgeClient.Timeout.interaction`(20 秒)より
    /// 短く、往復と応答の組み立てに 5 秒残す。「整定の cap + 余裕」のような小さい見積りにすると、
    /// 8 台並列で main が遅いだけの回(操作は実際に完了する)を 504 にしてしまう
    /// (E2E-CMP で 4,000ms が実際に尽きた実測がある)。`BridgeMainThreadBudgetTests` が上限の順序を守る
    public static let inAppMainThreadWaitMs = 15_000
    /// 1回のスナップショットで返す要素数の上限(4Kトークン対策の第一段)
    public static let maxSnapshotElements = 120

    /// `GET /snapshot?max=<n>` で引き上げられる上限の天井。
    ///
    /// **既定を上げるのではなく、呼び手が1回だけ上げる**(ブラウザ監査): web ページは
    /// 広告リンクだけで tier0 が枠を埋め、間引きは tier1(ラベル付きの本文)から捨てるので、
    /// **画面に写っている表の行が丸ごと消える**。実測(tenki.jp の2週間天気)では 299 候補中
    /// 179 件が脱落し、その **全部が labelled** —— 落ちた行を `ft_scroll_to` が探し続けて
    /// 2回で 101 秒を捨てた。間引きの優先度を変える案は採らない(同じ規則がネイティブの
    /// リスト行にも当たる。BridgeSnapshotThinning の却下履歴と同型)。
    /// 天井の根拠: 出力は要素あたり約1行なので、これ以上は読み手側が読み切れない
    public static let maxSnapshotElementsCeiling = 400

    /// `max=` クエリの唯一の解釈者(ホスト・3ブリッジで同じ規則)。
    /// nil・0以下・非整数 = 既定、天井超え = 天井へ丸める。**呼び手の指定を黙って捨てない**
    /// ためにホスト側でも同じ関数を通す(丸めた事実は MCP が応答で名乗る)
    public static func resolvedSnapshotElementLimit(_ raw: Int?) -> Int {
        guard let raw, raw > 0 else { return maxSnapshotElements }
        return min(raw, maxSnapshotElementsCeiling)
    }
    /// ブリッジ HTTP API のプロトコルバージョン(in-app dylib と XCUITest ランナーの共通定数)。
    /// /status で返り、ホストは不一致のブリッジを再利用せず入れ替える(nil = この定数導入前のビルド = 旧版扱い)。
    /// **上げる条件**: エンドポイント・リクエスト/レスポンスの形・**ハンドラの挙動**のどれかを変えたとき
    /// (`BridgeContractTests` がルート表とソース指紋で検出する)。上げないと稼働中の旧ブリッジが再利用され、
    /// **変更が効いていないのに緑になる**(旧ブリッジは未知のフィールドを黙って無視する・新ルートに 404 を返す)。
    /// - optional フィールドの追加だけでも、それで**挙動が変わるなら上げる**(黙って縮退する経路を残さない)。
    ///   純粋な追加で旧ブリッジの無視が安全なときだけ据え置いてよい(該当フィールドの doc にそう書く)
    /// - ソースの分割・コメントだけの変更は指紋の貼り替えだけでよい(版は据え置き)
    /// - **撤去した版の番号は再利用しない**(37・48 は欠番): その版が稼働中の環境を確実に入れ替えるため
    /// 各版で何を変えたかは `git log -L '/bridgeProtocolVersion =/,+1:Sources/FTCore/BridgeDTO.swift'` で引く
    public static let bridgeProtocolVersion = 130

    /// **ホームボタンの iPhone か**(画面の寸法だけで決まる純粋判定)。
    ///
    /// なぜ要るか: ホームボタン機では画面下端から上へのスワイプが**仕様上コントロールセンター**で、
    /// アプリスイッチャーはハードウェアボタンの2度押し。Face ID 機のジェスチャをそのまま撃つと
    /// **黙って別の面が開いたまま ok を返す**(実機 iPhone SE 第3世代で実測。
    /// `ft_navigate appSwitcher` がコントロールセンターを開いていた)。
    ///
    /// 実測値: iPhone SE3 = 375x667(1.78)/ iPhone 15 Pro = 393x852(2.17)/
    /// iPhone 17 Pro = 402x874(2.17)。**2.0 で綺麗に割れる**。
    /// **iPad は対象外**(短辺 500pt 以上で false)—— Face ID iPad は下端スワイプでスイッチャーが
    /// 開くのでそのままでよく、ホームボタン iPad は未実測なので勝手に挙動を変えない。
    ///
    /// **XCUITest ランナーもこの定義を使う**(BridgeDTO.swift はランナーの入力集合に入っている)。
    /// 2つ目の閾値を作らないこと
    public static let homeButtonAspectThreshold = 2.0
    /// iPhone とみなす短辺の上限(pt)。これ以上は iPad 扱いで挙動は変えない
    public static let phoneShortSideLimit = 500.0

    /// 横向き既定 swipe(XCUITest ランナーの `landscapeDefaultSwipe`)のマージン比。
    /// `Sources/FTCore/ScrollGeometry.swift` の `FTScrollDefaults` の `.search` と同じ値
    /// (スパン0.5・重なり50%)を写したもの——ScrollGeometry.swift はランナーの入力集合に
    /// 無いため定数はここに置く。
    /// 0.25(0.2 でなく)である理由: 横向きの高さは実測 ~390pt で下部バー+セーフエリアが
    /// ~y=341 から始まる。0.2 の始点(y≈312)はそこを ~30pt しかクリアしない
    /// (docs/performance-tuning.md:798-801 に、全画面 swipe がタブバー上で始まり 0pt しか
    /// 動かなかった実測が残る)。それでもバーに乗れば動かない——そのときは
    /// host 側の「何も動いていない」判定がそのまま報告する
    public static let defaultSwipeMarginRatio = 0.25

    /// **下部 chrome(タブバー・ツールバー)の上に指を置かないための、画面下端からの最小距離**
    /// (pt/dp)。比だけで決めると窓が低いほど始点が下端へ寄るので、**絶対距離の床**を併せる。
    /// ランナーの `landscapeDefaultSwipe` と host の `ScrollGeometry` が共有する
    /// (ScrollGeometry.swift はランナーの入力集合に無いため定数はここに置く)。
    ///
    /// 根拠: iOS のタブバー 49pt + home indicator のセーフエリア 34pt = 83pt が標準だが、
    /// **アイコン+ラベルのタブバーは実測 80pt** で、下端 20pt のインセットと合わせて
    /// **下端から 100pt** を占める(実機 iPhone 13 横向き 844x390 の実測。
    /// `defaultSwipeMarginRatio` の始点 0.75×390=292.5pt はバーの上端 290pt の内側に落ち、
    /// scrollTo / swipe / scrollFrame 指定のすべてが「nothing moved」で終わった。
    /// 座標ドラッグを 250→60 に変えると同じ画面が 137pt 動く)。
    /// 120 はその 100pt を超える最小の切りのよい値。
    ///
    /// **尽きたとき**(これより高い下部 chrome を持つ画面で動かない)は数字を上げるのではなく、
    /// 木を持っている host 側で実際のバーを測って `scrollFrame` を絞ること —— ランナーは
    /// 木を持たないので、ここは「標準的なバーを外す」以上の約束をしない
    public static let bottomChromeClearance: Double = 120

    /// **SpringBoard の面がアプリを覆っていることの目印**(`GET /systemui/covering`)。
    ///
    /// 実測(実機 iPhone SE3 / iOS 26.6。SpringBoard の木の要素数):
    /// **素の状態 6 件 → コントロールセンター 56 件 → 通知センター 9 件**。
    /// 素の状態にはここに挙げた識別子が**1つも無い**ので、存在そのものが信号になる。
    ///
    /// - `cc-brightness-slider` / `cc-volume-slider`: コントロールセンター。`cc-` 接頭辞は
    ///   CC 固有で**ローカライズされない**(同時に出る `mode-おやすみモード` のような
    ///   ローカライズされる名前は使わない)
    /// - `SBCoverSheetWindow`: 通知センター(カバーシート)。ロック画面もこれなので、
    ///   **ロック中もアプリは覆われている**という意味で正しい
    /// - `SBSwitcherWindow`: アプリスイッチャー(タスク一覧)。**アプリは前面と答え続ける**
    ///   (実測: スイッチャー表示中に Safari が foreground:true、木もページのまま)
    ///   ので、ここに無いとライブ操作の前面追従がアプリへ activate を撃ち、
    ///   **開いたスイッチャーが閉じてアプリに戻る**
    ///
    /// **iOS の版が変わると識別子は変わりうる**。増減させるときは実機で
    /// 「素の状態に出ないこと」と「その面で出ること」の両方を測ること
    public static let systemUICoveringMarkers: [String] = [
        "cc-brightness-slider", "cc-volume-slider", "SBCoverSheetWindow", "SBSwitcherWindow",
    ]
    /// `systemUICoveringMarkers` のうちアプリスイッチャーの窓。**この窓だけは「触れる」では足りず、
    /// 中にカード(`appSwitcherCardPrefix`)が載っているときだけ覆いと見る**(BridgeRouter.handleSystemUICovering。
    /// ホームボタン機はアプリが前面でも窓を isHittable と答える。実測 iPhone SE3)
    public static let appSwitcherMarkerPrefix = "SBSwitcherWindow"
    /// スイッチャーのアプリのカードの identifier(`card:<bundle>:sceneID:<bundle>-default`)。
    /// 実測: 開いているとき(iPhone 17 Pro / iOS 27.0 シミュレータ)は縮んだカードが並ぶ
    /// (281×612 が 5 枚)。閉じたあと、Face ID 機・シミュレータの窓には 1 枚も残らないが、
    /// **ホームボタン機(iPhone SE3 / iOS 26)は前面アプリのカードが窓いっぱい(375×667)のまま 1 枚残り、
    /// isHittable も true** —— だから有無では切れず、`appSwitcherCardIsShrunken` で切る
    public static let appSwitcherCardPrefix = "card:"

    /// スイッチャーの窓が**本当に開いている**ことの判定(BridgeRouter.handleSystemUICovering):
    /// カードが窓より縮んでいるときだけ true。窓いっぱいのカードは「前面アプリの面をスイッチャーの窓が
    /// 抱えている」形(ホームボタン機の平常時)で、覆いではない。1pt の許容は端数(SE3 は整数、
    /// シミュレータは 1/3pt 刻み)のため
    public static func appSwitcherCardIsShrunken(cardWidth: Double, cardHeight: Double,
                                                 windowWidth: Double, windowHeight: Double) -> Bool {
        guard cardWidth > 0, cardHeight > 0 else { return false }
        return cardWidth < windowWidth - 1 || cardHeight < windowHeight - 1
    }

    public static func isHomeButtonPhoneScreen(width: Double, height: Double) -> Bool {
        guard width > 0, height > 0 else { return false }
        let shortSide = min(width, height)
        let longSide = max(width, height)
        guard shortSide < phoneShortSideLimit else { return false }
        return longSide / shortSide < homeButtonAspectThreshold
    }

    /// 無通信 TTL の既定値(秒)。この時間リクエストが無いブリッジは自主終了する。
    /// 同期相手: AndroidRunner/src/com/example/ftbridge/BridgeInstrumentation.java の
    /// TTL_DEFAULT_SECONDS(AndroidBridgeVersionSyncTests が不一致を検出)
    public static let bridgeTTLSecondsDefault = 7200

    /// FT_BRIDGE_TTL(秒)の唯一の解釈者。0 = 無効(無期限)、未設定・空・非整数・負 = 既定値。
    /// Java 側 BridgeInstrumentation.parseTTL も同じ規則
    public static func resolvedBridgeTTLSeconds(_ raw: String?) -> Int {
        guard let raw, let value = Int(raw), value >= 0 else { return bridgeTTLSecondsDefault }
        return value
    }

    // MARK: - LAN トークン認証(実機バインド時のみ要求)
    //
    // 不変条件: 「.fleetest/bridge-<port>.endpoint が在る」⟺「非ループバック(実機 LAN)」⟺
    // 「FT_BIND_ALL=1」⟺「トークンが要る」。この一致を壊さないこと。
    // 同期相手: Runner/FleetestRunnerUITests/BridgeHTTPServer.swift(要求側)⇄
    // Sources/FTBridgeClient/BridgeLauncher.swift(注入)⇄
    // Sources/FTBridgeClient/BridgeClient.swift・Sources/fleetest-devicepoll/main.swift(送信側)

    /// xctestrun へ注入する env の鍵。ランナーはこれを読んで要求トークンとする
    public static let bridgeTokenEnvKey = "FT_BRIDGE_TOKEN"
    /// トークンを運ぶ HTTP ヘッダ名
    public static let bridgeTokenHeader = "X-FT-Token"

    /// 暗号論的乱数 32 バイトを16進(64文字)にしたもの
    public static func makeBridgeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &generator) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// トークンを要求するか。判定を1箇所に置くための薄いラッパー(現状は bindAll と同義 ——
    /// 「非ループバック ⟺ トークン要」の不変条件そのもの)
    public static func bridgeTokenRequired(bindAll: Bool) -> Bool { bindAll }

    /// **定数時間比較**。長さの違いを含め早期 return せず、タイミングでトークンの手掛かりを
    /// 与えない(LAN 上の総当たりが唯一の攻撃経路であるヘッダ照合のため)
    public static func bridgeTokenMatches(expected: String, provided: String?) -> Bool {
        // 空の expected は「未設定」であって「何もかも一致」ではない。start() は空トークンでの
        // 起動そのものを拒む(fail closed)が、ここでも二重に塞ぐ
        guard let provided, !expected.isEmpty else { return false }
        let expectedBytes = Array(expected.utf8)
        let providedBytes = Array(provided.utf8)
        var diff: UInt8 = expectedBytes.count == providedBytes.count ? 0 : 1
        let length = max(expectedBytes.count, providedBytes.count)
        for i in 0..<length {
            let a = i < expectedBytes.count ? expectedBytes[i] : 0
            let b = i < providedBytes.count ? providedBytes[i] : 0
            diff |= a ^ b
        }
        return diff == 0
    }

    /// press/drag/swipe/pinch が iOS で XCTest に合成させる時間の**既定**上限(秒)。Android の
    /// 注入丸め(10 秒)と同じ値。**唯一の定義元**(`ArgumentBounds.numeric` の
    /// holdSeconds/durationSeconds/duration/press はこれを既定として参照する)。
    /// コマンドの `maxGestureSeconds:` 引数で1コマンドだけ `gestureSecondsCeiling` まで上書きできる
    /// (ユーザー決定)。根拠は `gestureSecondsCeiling` のコメント参照
    public static let defaultMaxGestureSeconds: Double = 10

    /// `maxGestureSeconds:` で上書きできる**絶対上限**(秒)。ランナー(iOS)と Android の注入層が
    /// 最後の砦として断るのもこの値 —— ホスト側(StepExecutor / ArgumentBounds)の門をどちらも
    /// 通らない経路(DSL からランナーへ直接・ライブ操作)が残っていても、ここで必ず止まる。
    /// 根拠: これを超えて素通しすると、シミュレータ内の testmanagerd が合成タッチ列
    /// (RCPSyntheticEventStream)を作り続けて約15MB/秒で肥大化する(実測: press
    /// duration=1e9 でランナーは3秒で ok を返すが testmanagerd は残り続け、数時間で170〜280GB。
    /// 止めるには testmanagerd 自体を kill するしかない。→ maintainer-notes §49.1)
    public static let gestureSecondsCeiling: Double = 60

    /// `/gesture` の指の本数の上限。**装置の上限ではなく操作の意味から決めた値**(片手の指の本数。
    /// 6本以上を要する UI は無い)。ホストの門(`TouchGesture.validate`)と XCUITest ランナーの
    /// 最後の砦が共有する。Android(Java)は写しを持ち、`GestureLimitsSyncTests` が一致を固定する
    public static let gestureMaxFingers = 5

    /// `/gesture` の1本の指に置ける点の上限。根拠: Android の注入器は 16ms 刻みで再生するので、
    /// 既定の上限 10 秒では 10 / 0.016 = 625 刻み。これより細かい点は再生で間引かれて意味を持たない
    /// (`maxGestureSeconds:` で延ばしたときも点の数はこの値で縛る = 要求の大きさを抑える)
    public static let gestureMaxPointsPerFinger = 625

    /// ジェスチャの見積もり所要(秒)が `cap` を超えるか、非有限・負か。
    /// **XCUITest ランナーが合成タッチを送る前に呼ぶ**(BridgeRouter の press/drag/swipe/pinch。
    /// `cap` は常に `gestureSecondsCeiling` を渡す —— ランナーは要求ごとの上書き値を受け取らず、
    /// 方針の判定(既定 10 秒・上書き上限 60 秒)はホスト側(StepExecutor / ArgumentBounds)が持つ。
    /// ランナー自身が断るのは、DSL からランナーへ直接届く経路がホストの門を通らないため)。
    /// **cap が `gestureSecondsCeiling` 未満のときだけ**「`maxGestureSeconds:` で上書きできる」と
    /// 案内する(ちょうど絶対上限のときはもう上げようが無い)。違反なら英語の文言、OK なら nil
    public static func gestureDurationViolation(_ what: String, seconds: Double, cap: Double) -> String? {
        gestureSecondsViolation(subject: "\(what) duration", seconds: seconds, cap: cap)
    }

    /// 同じ判定を**利用者が渡した引数の名前**で言う版(MCP・ライブ操作・DSL = ホスト側の門)。
    /// `subject` は文言の主語そのもの(`holdSeconds` / `holdSeconds of tap` 等)。
    /// 引数名に " duration" を足すと「holdSeconds duration」になるので `gestureDurationViolation` と分ける
    public static func gestureSecondsViolation(subject: String, seconds: Double, cap: Double) -> String? {
        guard seconds.isFinite, seconds >= 0 else {
            return "\(subject) must be a finite, non-negative number of seconds"
                + " (got \(gestureSecondsFormat(seconds)))"
        }
        guard seconds <= cap else {
            let base = "\(subject) must be \(gestureSecondsFormat(cap)) seconds or"
                + " less (got \(gestureSecondsFormat(seconds)))"
            guard cap < gestureSecondsCeiling else { return base }
            return base + "; pass maxGestureSeconds: (up to \(gestureSecondsFormat(gestureSecondsCeiling)))"
                + " to allow longer"
        }
        return nil
    }

    /// `maxGestureSeconds:` の上書き値そのものの検査(非有限・0以下・`gestureSecondsCeiling` 超を断る)。
    /// **唯一の定義元**(`ArgumentBounds` の入口・DSL の StepExecutor 入口が両方これを呼ぶ)
    public static func maxGestureSecondsViolation(_ value: Double) -> String? {
        guard value.isFinite, value > 0 else {
            return "maxGestureSeconds must be a finite, positive number of seconds"
                + " (got \(gestureSecondsFormat(value)))"
        }
        guard value <= gestureSecondsCeiling else {
            return "maxGestureSeconds must be \(gestureSecondsFormat(gestureSecondsCeiling))"
                + " seconds or less (got \(gestureSecondsFormat(value)))"
        }
        return nil
    }

    /// "got 10" であって "got 10.0" ではなく、桁外れの値でも `Int` へ変換して trap しない
    /// (`ArgumentBounds.format` と同種だが独立: あちらは値域違反、こちらは秒数の見積もり)
    private static func gestureSecondsFormat(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

/// ref 指定の type / clear で、タップ後の受け口(first responder)が**叩いた要素のもの**か。
/// **ブリッジと共有する純粋関数**(in-app ブリッジの `requireFocusMoved` が使う)。
/// - **面積のある受け口**(UIKit・Compose): 叩いた点を含むか。枠で見ないのは、大きい容器を叩いたときに
///   中の前の欄を「叩いた先」と取り違えるため
/// - **面積の無い受け口**(Flutter の 1×1pt。欄の編集領域の左上に置かれ、叩いた点を含むことが原理的に無い。
///   実測: 受け口 (16,310 1x1)・欄 (16,298 370x48)・叩いた中心 (201,322)): 叩いた要素の枠の中にあるか。
///   **叩いたのが入力欄でない(容器)なら、タップの前後で受け口が動いたか、容器の中の入力欄がちょうど1つで
///   受け口がその欄の中にあることが要る** —— 前の欄を内側に含む容器(欄が2つ以上)を叩いて焦点が動かなかった形を
///   通すと、前の欄へ打って 200 を返す。欄が1つだけの包み(id を持つのが包み側)は、焦点のある欄を叩き直した形でも
///   叩いた先はその欄なので通す(`TapTargetGeometry.nonInputTypeTargetNote` と同じ「ちょうど1つ」の考え方)。
///   入力欄そのものなら叩き直し(受け口は動かない)も通す
public enum FocusLanding {
    /// `movedSinceTap` = タップの前後で受け口が別の view になったか位置が変わったか(タップ前に受け口が
    /// 無ければ true)。`target` = 叩いた要素の今の枠(取れなければ nil = 面積の無い受け口は通さない)。
    /// `soleInnerInput` = 叩いた要素の中の入力欄がちょうど1つならその枠(0個・2個以上は nil)
    public static func landed(receiver: CGRect, tapped: CGPoint, target: CGRect?, targetIsInput: Bool,
                              movedSinceTap: Bool, soleInnerInput: CGRect?) -> Bool {
        guard receiver.width <= 1 || receiver.height <= 1 else { return receiver.contains(tapped) }
        let centre = CGPoint(x: receiver.midX, y: receiver.midY)
        guard target.map({ $0.contains(centre) }) ?? false else { return false }
        return targetIsInput || movedSinceTap || (soleInnerInput?.contains(centre) ?? false)
    }
}

/// 座標タップ(in-app)でどの snapshot 要素を activate するか。**ブリッジと共有する純粋関数**
/// (in-app ブリッジはこのファイルをそのままコンパイルする)。
/// 候補は **frame が点を含み、かつ見えている範囲(`clips` = 祖先のスクロール容器で切った後)にも
/// 点が入る要素**で、その中の最小面積を選ぶ。容器で切れた行は frame 上は点を含んでも描かれていない
/// (SwiftUI では行の AX ノードがホスティング view にしか辿れず、hitTest では見分けられない)ので、
/// 候補から外さないと見えない要素を撃ち抜く。clips に無い要素(祖先に容器が無い)は frame だけで判定する
public enum BridgeCoordinateTapTarget {
    public struct Choice: Equatable {
        /// activate する要素(無ければ呼び手は点へ合成タッチ)
        public let ref: Int?
        /// 点を frame に含むが容器で切れていたため外した要素のうち、**選んだ要素より小さい**もの
        /// (= 見えていれば撃たれたはずの要素。呼び手が注記で名指しする)。無ければ nil
        public let clippedRef: Int?
    }

    /// 端の端数(1/scale pt)で見えている行を落とさないための見逃し幅(pt)
    static let clipTolerance: CGFloat = 0.5

    public static func choose(point: CGPoint, frames: [Int: CGRect], clips: [Int: CGRect]) -> Choice {
        var best: (ref: Int, area: CGFloat)?
        var clipped: (ref: Int, area: CGFloat)?
        // 同じ面積なら ref の小さい方(辞書の走査順に結果を依存させない)
        func smaller(_ ref: Int, _ area: CGFloat, than current: (ref: Int, area: CGFloat)?) -> Bool {
            guard let current else { return true }
            return area < current.area || (area == current.area && ref < current.ref)
        }
        for (ref, frame) in frames where frame.contains(point) {
            let area = frame.width * frame.height
            if let clip = clips[ref],
               !clip.insetBy(dx: -clipTolerance, dy: -clipTolerance).contains(point) {
                if smaller(ref, area, than: clipped) { clipped = (ref, area) }
                continue
            }
            if smaller(ref, area, than: best) { best = (ref, area) }
        }
        let named = clipped.flatMap { c in smaller(c.ref, c.area, than: best) ? c.ref : nil }
        return Choice(ref: best?.ref, clippedRef: named)
    }
}

/// GET /snapshot が maxSnapshotElements を超えたときに何を先に捨てるかの判定。
/// **in-app dylib と XCUITest ランナーの共通実装**(BridgeSourceSet 参照。両方コンパイルする)。
/// Android は Java で書けないため `AndroidRunner/.../SnapshotBuilder.java` の `priorityTier` に
/// 個別実装している —— **こちらを正とする。tier0〜2 を変えたら Java 側も直すこと**。
/// **tier3(bulk)は iOS だけ**: コーパス14本の実測で Android は1画面も発火しなかった
/// (Google マップを含む)ため移植していない。Android で bulk 群が出る画面を見つけたら、
/// ここを写して VERSION_CODE を上げる。
///
/// 捨てる順序は tier2(それ以外) → tier3(bulk) → tier1(ラベル/identifier を持つ) →
/// tier0(操作可能 or scrollable な容器)。tier2 から全部捨ててもまだ超過するなら tier3、
/// それでも超過するなら tier1 → tier0 と捨てる。ラベル/id 付きの同一id反復群(tier3)は
/// ラベル無し装飾(tier2)より本物のコンテンツである可能性が高いため、装飾を先に落とす。
/// 同一 tier 内は preorder の後ろから捨てる(先頭寄りの要素を優先して残す)。
///
/// bulk tier の根拠(コーパス14本・iOS/Android・2種の地図アプリ・4 SUT で確認):
/// 装飾ピン(同一 identifier ×90・非操作)は地図画面の枠の大半を占めて本物のコンテンツ
/// (リスト・詳細シート)を押し出す。**当初は scrollable な祖先を持つ群を bulk から除外**していたが、
/// 地図 POI 自体がスクロール容器(地図)の中に居るため素通りしてラベル付き tier1 になり、
/// preorder 前方(地図は木の先頭)に居るため同 tier 内では最後まで残って、後方のカード内容から
/// 先に落ちる +84 切り詰めを起こした(実測、Apple マップ)。
/// **免除は「自身がスクロール容器か」だけに縮小**(祖先ベースの免除は撤去)。リスト行の
/// ラベル群(同一id×20+)も bulk 対象になるが、捨て順は tier2(無ラベル装飾)が先
/// (indicesToKeep)なので、装飾より先に本物の行が消えることはない。
/// 容器そのものは indicesToKeep が tier に関係なく cap 免除する。
public enum BridgeSnapshotThinning {

    /// 同一 identifier の出現数がこの数以上なら bulk tier の対象候補。
    ///
    /// **「畳める群は枠も1つぶんにする」案は却下**(実装して撤回): 地図の POI が
    /// 上限の 64% を占めるのは事実だが、**同じ述語はリストの行にも当たる**(同一 id ×20 以上の
    /// 行は普通にある)。群の尾を先に落とすと、30 行のリストの 21 行目以降が
    /// **無ラベル装飾より先に**消える —— tier2 → tier3 の順序はまさにそれを防ぐために
    /// 選ばれている(下の「捨てる順序」参照)。地図 POI とリスト行を木から見分ける手掛かりは
    /// 無く、祖先ベースの区別は 58 で一度失敗している。**代わりに MCP 側が
    /// 「どの id 群が枠を食っているか」を打ち切り注記で名指しする**(MCPServer.truncationNote)
    public static let bulkGroupMinimum = 20

    /// 操作可能とみなす正規化型名(ElementInfo.normalizedType 後の綴り = ElementInfo.init が
    /// 自動で適用するので、makeInfo が返す ElementInfo.type は既にこの形)。bulk tier からは
    /// 常に除外する
    public static let operableTypes: Set<String> = [
        "button", "cell", "textField", "secureTextField", "searchField", "switch",
        "checkBox", "link", "slider", "tab", "menuItem", "clickable", "textView",
    ]

    /// 間引き判定の入力。tier/bulk 判定は info(自身のプロパティ)だけで決まる
    /// (祖先由来の情報は 58 で撤去。ElementInfo.scrollable は自身が容器かどうかの申告)
    public struct Candidate {
        public var info: ElementInfo

        public init(info: ElementInfo) {
            self.info = info
        }
    }

    /// bulk 群を予算外で送るときの安全弁。木が壊れたアプリで応答が無制限に膨らむのを防ぐ
    /// だけの値で、通常は当たらない(実測の最大は Apple マップの 87)
    public static let bulkExemptCeiling = 400

    /// 超過時に残す候補の添字を、元の配列と同じ順序(preorder)で返す。max 以下ならそのまま全添字。
    /// **並べ替えない**: RefGuard.lineage が preorder+depth からツリーを復元し、ref の大小を
    /// z-order の代理に使う。
    ///
    /// **bulk 群(tier3)は要素上限の勘定に入れない**(61): 上限は「読み手が選ぶ
    /// 対象」に使い切らせるためのもので、同一 id の飾りがその枠を食うのは上限の目的に反する。
    /// 実測(Apple マップの経路手順)では `#VKPointFeature` が保持 119 件中 87 件 = 73% を占め、
    /// 操作可能要素とラベル持ち要素がその分だけ押し出されていた。
    /// **捨てるのではなく予算から外す**ので、ref タップも SelectorInventory への記録も
    /// expandBulk の展開もそのまま効く(捨てる案は却下済み。bulkGroupMinimum のコメント参照)。
    /// 予算外にした分だけ `elements.count` は max を超え得る —— スクロール容器の cap 免除と同じ扱い
    public static func indicesToKeep(_ candidates: [Candidate], max: Int) -> [Int] {
        let n = candidates.count

        var identifierCounts: [String: Int] = [:]
        for candidate in candidates {
            guard let id = candidate.info.identifier, !id.isEmpty else { continue }
            identifierCounts[id, default: 0] += 1
        }

        var keep = [Bool](repeating: true, count: n)
        // ① bulk は予算外。天井を超えた分だけは落とす(内訳では "bulk" として申告される)
        var exempt = [Bool](repeating: false, count: n)
        var exemptCount = 0
        for index in 0..<n where isBulk(candidates[index], identifierCounts: identifierCounts) {
            if exemptCount < bulkExemptCeiling {
                exempt[index] = true
                exemptCount += 1
            } else {
                keep[index] = false
            }
        }

        // ② 上限が掛かるのは bulk 以外だけ
        var remaining = (0..<n).filter { keep[$0] && !exempt[$0] }.count
        guard remaining > max else { return (0..<n).filter { keep[$0] } }
        // tier3 は予算外になったので掃き出しの順序から外れる
        for currentTier in [2, 1, 0] {
            guard remaining > max else { break }
            for index in stride(from: n - 1, through: 0, by: -1) {
                guard remaining > max else { break }
                // スクロール容器自身は tier に関係なく cap 免除(容器が落ちると scrollFrame
                // 解決が退化する。数個しかないので実害なし)。max を僅かに超えて返ることを許容する
                guard keep[index], !exempt[index], candidates[index].info.scrollable != true,
                      tier(candidates[index], identifierCounts: identifierCounts) == currentTier
                else { continue }
                keep[index] = false
                remaining -= 1
            }
        }
        return (0..<n).filter { keep[$0] }
    }

    /// 予算外で送った bulk 要素の数(ホストが「上限の外で何件届いたか」を言うために使う)。
    /// `indicesToKeep` と**同じ判定**で数える
    public static func bulkExemptCount(_ candidates: [Candidate]) -> Int {
        var identifierCounts: [String: Int] = [:]
        for candidate in candidates {
            guard let id = candidate.info.identifier, !id.isEmpty else { continue }
            identifierCounts[id, default: 0] += 1
        }
        let bulk = candidates.filter { isBulk($0, identifierCounts: identifierCounts) }.count
        return Swift.min(bulk, bulkExemptCeiling)
    }

    /// WebView DOM マージ用の間引き。ネイティブ(間引き済み)の直後に各 webView コンテナの
    /// DOM 要素を差し込んだ合算列を作り、max 超過なら indicesToKeep と同じ優先度で捨てる。
    ///
    /// なぜ要るか(E2E-iOS の密グリッドページで実測): 従来の先着順カットは
    /// 装飾セル 115 個を残して**ページ上の操作可能要素(送信・入力欄・リンク・状態 echo)を
    /// 全部**押し出した —— iOS ネイティブ側が版54で直した形がマージ側に残っていた。
    ///
    /// bulk 判定は info.scrollable(自身のプロパティ)だけを見るので、祖先情報が失われる
    /// マージ後の flat な列でも1段目と矛盾なく再適用できる(58 より前は祖先ベースの判定で
    /// ここだけ bulk を無効化する必要があったが、その回避は不要になった)。
    public enum MergeSlot: Equatable, Sendable {
        /// base[i](ネイティブ要素)
        case base(Int)
        /// dom[container]![j](container = ネイティブ側 webView コンテナの ref)
        case dom(container: Int, index: Int)
    }

    public static func mergedSlots(base: [ElementInfo], dom: [Int: [ElementInfo]],
                                   max: Int) -> (kept: [MergeSlot], dropped: Int) {
        let (slots, candidates) = mergedCandidates(base: base, dom: dom)
        let kept = indicesToKeep(candidates, max: max)
        return (kept.map { slots[$0] }, slots.count - kept.count)
    }

    /// マージ側で捨てた分の内訳。**`mergedSlots` の戻り値は増やさない** —— 位置分解で
    /// 受けている呼び出し側とテストを巻き込むだけで、得るものが無い。組み立ては
    /// `mergedCandidates` に寄せてあるので二重定義にはならない。
    /// 呼ぶのは `dropped > 0` のときだけ(捨てていないなら走らせる意味が無い)
    public static func mergedDroppedByTier(base: [ElementInfo], dom: [Int: [ElementInfo]],
                                           max: Int) -> [String: Int] {
        let (_, candidates) = mergedCandidates(base: base, dom: dom)
        return droppedByTier(candidates, kept: indicesToKeep(candidates, max: max))
    }

    /// ネイティブ(間引き済み)の直後に各 webView コンテナの DOM 要素を差し込んだ合算列
    static func mergedCandidates(base: [ElementInfo],
                                 dom: [Int: [ElementInfo]]) -> ([MergeSlot], [Candidate]) {
        var slots: [MergeSlot] = []
        var candidates: [Candidate] = []
        for (i, info) in base.enumerated() {
            slots.append(.base(i))
            candidates.append(Candidate(info: info))
            guard let elements = dom[info.ref] else { continue }
            for (j, element) in elements.enumerated() {
                slots.append(.dom(container: info.ref, index: j))
                candidates.append(Candidate(info: element))
            }
        }
        return (slots, candidates)
    }

    /// 捨てた候補の内訳(`SnapshotResponse.truncatedTiers`)。**間引きの方針を実データで
    /// 議論するために要る** —— 件数だけでは「選べる物が消えたのか、飾りが消えただけか」を
    /// 区別できない(Apple マップの経路プランナーで 211 → 120 の 91 件脱落を
    /// 観測したが、内訳が無く原因を断定できなかった)。
    /// `kept` は indicesToKeep の戻り値(元配列の添字)
    public static func droppedByTier(_ candidates: [Candidate], kept: [Int]) -> [String: Int] {
        let keptSet = Set(kept)
        guard candidates.count > keptSet.count else { return [:] }
        var identifierCounts: [String: Int] = [:]
        for candidate in candidates {
            guard let id = candidate.info.identifier, !id.isEmpty else { continue }
            identifierCounts[id, default: 0] += 1
        }
        var result: [String: Int] = [:]
        for index in candidates.indices where !keptSet.contains(index) {
            let key = tierKey(tier(candidates[index], identifierCounts: identifierCounts))
            result[key, default: 0] += 1
        }
        return result
    }

    /// tier 番号 → `SnapshotResponse.truncatedTiers` のキー。**番号をそのまま外へ出さない**
    /// (ホストが tier の並び順を知っている必要が生まれ、順序を変えた瞬間に嘘になる)
    public static func tierKey(_ tier: Int) -> String {
        switch tier {
        case 0: return "operable"
        case 1: return "labelled"
        case 3: return "bulk"
        default: return "decoration"
        }
    }

    /// 0(高優先・最後まで残す) … 3(bulk・最初に捨てる)
    static func tier(_ candidate: Candidate, identifierCounts: [String: Int]) -> Int {
        if isBulk(candidate, identifierCounts: identifierCounts) { return 3 }
        if operableTypes.contains(candidate.info.type) || candidate.info.scrollable == true { return 0 }
        let hasText = !(candidate.info.label ?? "").isEmpty || !(candidate.info.identifier ?? "").isEmpty
        return hasText ? 1 : 2
    }

    /// bulk 判定の3条件(すべて満たすときだけ true): 同一 identifier の群が bulkGroupMinimum 以上・
    /// **自身が**スクロール容器でない(祖先ベースにしない —— 地図 POI はスクロール容器[地図]の
    /// 中に居るので素通りする)・操作可能な型でない
    private static func isBulk(_ candidate: Candidate, identifierCounts: [String: Int]) -> Bool {
        guard candidate.info.scrollable != true else { return false }
        guard let id = candidate.info.identifier, let count = identifierCounts[id],
              count >= bulkGroupMinimum else { return false }
        return !operableTypes.contains(candidate.info.type)
    }
}

/// CGRect の代わりに使うプラットフォーム非依存の矩形(エンコード形式を固定する)
public struct FTRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }

    /// inner の中心がこの矩形の内側にあるか(1px の丸めに強い中心点判定)。
    /// システムアラートの「そのアラートに属するボタンか」の絞り込みに使う
    public func contains(_ inner: FTRect) -> Bool {
        inner.centerX >= x && inner.centerX <= x + width
            && inner.centerY >= y && inner.centerY <= y + height
    }
}

public struct StatusResponse: Codable, Sendable {
    public var ready: Bool
    public var device: String
    public var osVersion: String
    public var sessionBundleID: String?
    /// 駆動エンジン種別("inapp" / "xcuitest")。同一シミュレータ(UDID)に複数ブリッジが
    /// 共存するハイブリッド時、ホストがどのブリッジかを /status で区別するために使う。
    /// 旧ブリッジは返さない → decodeIfPresent で nil 許容(=不明)。
    public var engine: String?
    /// BridgeAPI.bridgeProtocolVersion。旧ブリッジは返さない → nil 許容(=旧版扱い)。
    public var protocolVersion: Int?
    /// このブリッジが載っているシミュレータの UDID(`SIMULATOR_UDID` 環境変数)。
    /// **iOS のツールをポートではなく udid で指すために要る**(H): ft_list_devices は
    /// udid と port を両方出すのに、操作系が受けるのは port だけで、ホストは port から udid を
    /// 確定できなかった。**実機とシミュレータ以外では nil**(実機のランナーにこの環境変数は無い)。
    /// 追加 optional フィールドのみなので単独なら版を上げる必要は無いが、61 に相乗りさせている
    public var udid: String?
    /// UIApplication.applicationState の文字列化("active"/"inactive"/"background")。
    /// inapp 専用診断(背面 suspend でハングしていないかの申告)。xcuitest ブリッジは返さない → nil 許容。
    public var applicationState: String?
    /// inapp ブリッジが自己申告する UI フレームワーク(AppUIFramework の rawValue。規則は UIFrameworkMarkers)。
    /// xcuitest/Android ブリッジは返さない → nil 許容。**直接読まない** —— AppUIFrameworkQuery.bridgeReport(_:about:)
    /// を通す(申告は注入先アプリのもの)
    public var uiFramework: String?
    /// **最後に画面が進んでからの秒数**(iOS=CADisplayLink / Android=Choreographer の tick)。
    /// **ホストは凍結判定に使わない。採り直さないこと** —— 本物の wedge でも拍動は回り続ける
    /// (測っているのは「vsync を要求しているか」で「表示が進んだか」ではない。反証の実測は
    /// docs/verification.md)。計器の撤去は版上げを伴うため次のブリッジ変更に便乗する。
    /// 計器を持たないブリッジ・旧ブリッジは返さない → nil 許容。
    /// 通信の `idleSeconds`(下)とは別物 —— あちらは「無通信秒数」で画面とは無関係
    public var displayIdleSeconds: Double?
    /// Android ブリッジ APK の versionCode(BridgeRouter.java handleStatus)。稼働中の旧ブリッジを
    /// probe 時に検知して自動更新するために使う。iOS ブリッジ・旧 Android ブリッジは返さない → nil 許容。
    public var bridgeVersionCode: Int?
    /// xcuitest ランナーが高速入力(quiescence スキップ)swizzle の導入に成功したか(FastInput.swift)。
    /// 旧ランナー・他ブリッジは返さない → nil 許容(=非対応)
    public var fastInputAvailable: Bool?
    /// このブリッジが**この対象アプリでは実行できない**アクション名(FlowStep.action と同じ語:
    /// "swipe" / "press" 等)。ホストはこれを見て代替ドライバへ回す/明示的に失敗させる。
    /// 「compose なら swipe 不可」のような知識をホストへ散らかさず、事情を知っている
    /// ブリッジ側に集約するための申告。返さない実装は nil(=制約なしとみなす)。
    public var unsupportedActions: [String]?
    /// 起動元リポジトリのルートパス(iOS=FT_OWNER_REPO 環境変数 / Android=-e owner)。
    /// doctor の刈り取り判定が依存: パスが実在しなければ確定ゾンビとして自動停止できる。
    /// 旧ブリッジは返さない → nil 許容(=起動元不明・報告のみ)
    public var ownerRepo: String?
    /// ランナープロセスの pid(iOS のみ。ホスト上のプロセスなので doctor が直接停止できる)。
    /// Android は device 内 pid になり意味が違うため返さない
    public var ownerPid: Int?
    /// このリクエストの直前の無通信秒数(「いつから放置されていたか」の診断用)
    public var idleSeconds: Double?
    /// 所要内訳ログ(tapTiming/settleTiming/reqTiming)が有効な状態で起動しているか。
    /// **起動時にしか切り替わらない**ので、ホストは希望状態と食い違うときブリッジを起動し直す
    /// (Android: AndroidBridge.startBridge)。返さない実装は nil(=off とみなす)
    public var timingEnabled: Bool?
    /// Current device orientation. **Only the 2 iOS bridges populate this** (used by the host to
    /// capture the pre-rotation orientation before the first rotate, for scenario-end restore).
    /// Android's orientation is read via adb host-side (AndroidDriver), not through this field.
    /// Omitted by old bridges and by bridges that can't currently determine it → nil = unknown.
    public var orientation: FTOrientation?

    public init(ready: Bool, device: String, osVersion: String, sessionBundleID: String?,
                engine: String? = nil, protocolVersion: Int? = nil, applicationState: String? = nil,
                uiFramework: String? = nil, displayIdleSeconds: Double? = nil,
                bridgeVersionCode: Int? = nil,
                fastInputAvailable: Bool? = nil, unsupportedActions: [String]? = nil,
                ownerRepo: String? = nil, ownerPid: Int? = nil, idleSeconds: Double? = nil,
                timingEnabled: Bool? = nil, udid: String? = nil,
                orientation: FTOrientation? = nil) {
        self.ready = ready
        self.device = device
        self.osVersion = osVersion
        self.sessionBundleID = sessionBundleID
        self.engine = engine
        self.protocolVersion = protocolVersion
        self.applicationState = applicationState
        self.uiFramework = uiFramework
        self.displayIdleSeconds = displayIdleSeconds
        self.bridgeVersionCode = bridgeVersionCode
        self.fastInputAvailable = fastInputAvailable
        self.unsupportedActions = unsupportedActions
        self.ownerRepo = ownerRepo
        self.ownerPid = ownerPid
        self.idleSeconds = idleSeconds
        self.timingEnabled = timingEnabled
        self.udid = udid
        self.orientation = orientation
    }
}

public struct LaunchRequest: Codable {
    public var bundleID: String
    /// true なら XCUIApplication.activate()(起動中は状態保持で前面化、未起動なら起動)。
    /// nil/false は launch(再起動)する。旧ランナーは本フィールドを無視して launch する。
    public var activate: Bool?
    /// true ならプロキシ接続のみ(XCUIApplication を生成・保持するだけで launch/activate を呼ばない。
    /// simctl で起動済みのアプリに使う=FastLaunchDriver)。activate より優先。
    /// 旧ランナーは無視して launch する(TapRequest.fast と同じ互換方針で版は据え置き)
    public var attachOnly: Bool?
    public init(bundleID: String, activate: Bool? = nil, attachOnly: Bool? = nil) {
        self.bundleID = bundleID
        self.activate = activate
        self.attachOnly = attachOnly
    }
}

/// アクセシビリティツリーの1要素(ランナー側でフィルタ済み)
public struct ElementInfo: Codable, Sendable {
    /// set-of-mark 参照番号(スナップショット毎に振り直す)
    public var ref: Int
    /// 型名。**ホスト側では常に先頭小文字**(`button` / `staticText`)。
    /// ブリッジは歴史的経緯で `Button` を送ってくるので、デコード時に normalizedType で畳む。
    /// セレクタ記法 `.button` と、スナップショット表示・生成コードの型名を一致させるための唯一の変換点
    /// (3ブリッジの wire 形式は変えない = APK versionCode もプロトコル版も上げなくてよい)。
    public var type: String
    public var identifier: String?
    public var label: String?
    public var value: String?
    public var placeholder: String?
    public var enabled: Bool
    /// チェック状態の生の申告(true のときだけ送る = 省略は「オフ、または状態を持たない要素」)。
    /// 取得元は iOS=`isSelected` / Android=`isChecked || isSelected`。**直接読まない** ——
    /// value に載ったオフ/mixed と合わせて判定する `CheckStateReading` を通す
    public var checked: Bool?
    public var frame: FTRect
    public var depth: Int
    /// **DOM から読んだ Web コンテンツか**(true のときだけ送る)。in-app ブリッジが WKWebView の
    /// 中身を読めたときに立てる。ホストは「in-app で中身が読めているか」をこれで判定する
    /// (幾何で判定すると WebView と同じ矩形を持つ interop 容器を中身と誤認する実害があった)
    public var web: Bool?
    /// **スクロールできる容器か**(true のときだけ送る = checked/web と同じ省略規約)。
    /// 取得元: Android=`AccessibilityNodeInfo.isScrollable` / iOS xcuitest=要素の型
    /// (scrollView / table / collectionView)/ iOS in-app=`UIScrollView` かどうか。
    /// **Compose/Flutter の in-app では申告できない**(自前描画で UIScrollView を持たず、
    /// AX の scroll 可否は**呼ぶと実際にスクロールしてしまう**ので非破壊に判定できない)。
    /// だから「false = スクロールできない」と読んではいけない —— 使ってよいのは
    /// **true を見つけたときだけ**(scrollFrame の指定が空振りかの判定に使う)
    public var scrollable: Bool?
    /// **入力フォーカスを持つか**(true のときだけ送る = checked/web と同じ省略規約)。
    /// clearInput(ref なし)の事後検証(StepExecutor)が、クリア前後のスナップショットで
    /// 同一要素を突き合わせるための唯一の手がかり。取得元: iOS xcuitest=`hasKeyboardFocus` /
    /// iOS in-app=`isFirstResponder` / Android=`AccessibilityNodeInfo.isFocused`
    public var focused: Bool?
    /// **塗り順**(0 起点の通し番号。大きいほど手前)。nil = ブリッジが申告しない
    /// (iOS の XCUITest / in-app には描画順を読む API が無い)。
    ///
    /// **preorder は描画順ではない**ので、遮蔽の判定にツリー順を代理で使うと裏返る ——
    /// Google マップは地図の FAB をシートより後に出すが、描画はシートが手前で、
    /// 「シートの裏の要素」を無警告でタップして別アプリを起動していた(実測)。
    ///
    /// **ホストでは合成できないのでブリッジが1本の整数にして送る**: 出力ツリーは中間ノードを
    /// 間引くため、2要素の共通祖先が木に残っておらず、段ごとの `getDrawingOrder` を
    /// 突き合わせられない(実測: `#mylocation_button` の祖先鎖は3段で、シート側と1つも共有が無い)。
    /// 生成は SnapshotBuilder.assignPaintOrder。**nil のときは ref 順へ落ちる**
    public var z: Int?

    /// スライダー/プログレスの**取り得る範囲**(`"0-100"`)。nil = 範囲を持たない要素、
    /// またはブリッジが申告しない。現在値は `value` に入る。
    ///
    /// **パーセントへ正規化しない**のが決定: 0..10 のスライダーで current=3 を
    /// "30%" と言うのは、生値を読みたい側には嘘に近い。範囲を別に添えて割合は読み手に任せる。
    /// 取得元: Android=`AccessibilityNodeInfo.getRangeInfo`。
    /// **iOS はまだ出さない**(XCUIElement.value が `"50%"` を返すので value 側だけは読める)
    public var range: String?

    /// **その要素を実装しているクラス名**(XCUITest ランナーだけが出す。in-app / Android は nil)。
    /// 取得元は XCTest の非公開辞書 `XCElementSnapshot.additionalAttributes` の属性番号 5004
    /// (反射で確認。根の snapshot から children を辿るだけで全要素に付き、追加の往復は無い)。
    /// 値はフレームワーク名ではない —— Compose / Flutter の要素は `UIAccessibilityElement`(自前描画の上の
    /// a11y 要素)、React Native は `UIView`、SwiftUI は `NSObject`、UIKit は実クラス名。読み手は
    /// `AccessibilityClassHint`(空打ちの第3段)だけ。**非公開属性なので取れなければ nil = 不明**。
    /// 追加 optional フィールドのみなので bridgeProtocolVersion は据え置き(webViewPath と同じ方針)
    public var axClass: String?

    public init(ref: Int, type: String, identifier: String?, label: String?, value: String?,
                placeholder: String?, enabled: Bool, frame: FTRect, depth: Int,
                checked: Bool? = nil, web: Bool? = nil, focused: Bool? = nil,
                scrollable: Bool? = nil, z: Int? = nil, range: String? = nil,
                axClass: String? = nil) {
        self.range = range
        self.axClass = axClass
        self.scrollable = scrollable
        self.z = z
        self.ref = ref
        self.type = Self.normalizedType(type)
        self.identifier = identifier
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.enabled = enabled
        self.checked = checked
        self.frame = frame
        self.depth = depth
        self.web = web
        self.focused = focused
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ref = try container.decode(Int.self, forKey: .ref)
        type = Self.normalizedType(try container.decode(String.self, forKey: .type))
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        checked = try container.decodeIfPresent(Bool.self, forKey: .checked)
        frame = try container.decode(FTRect.self, forKey: .frame)
        depth = try container.decode(Int.self, forKey: .depth)
        web = try container.decodeIfPresent(Bool.self, forKey: .web)
        focused = try container.decodeIfPresent(Bool.self, forKey: .focused)
        scrollable = try container.decodeIfPresent(Bool.self, forKey: .scrollable)
        z = try container.decodeIfPresent(Int.self, forKey: .z)
        range = try container.decodeIfPresent(String.self, forKey: .range)
        axClass = try container.decodeIfPresent(String.self, forKey: .axClass)
    }

    /// 先頭 1 文字だけ小文字化する(`StaticText` → `staticText`)。冪等なので二重適用しても安全
    public static func normalizedType(_ type: String) -> String {
        guard let first = type.first, first.isUppercase else { return type }
        return first.lowercased() + type.dropFirst()
    }
}

public struct SnapshotResponse: Codable, Sendable {
    public var sessionBundleID: String?
    public var screen: FTRect
    public var elements: [ElementInfo]
    /// 上限超過で切り捨てた要素数(FMへのプロンプトにも明記する)
    public var truncatedCount: Int
    /// このスナップショットで**取りこぼしがある**ことの申告(例: クロスオリジン iframe は
    /// main frame の JS から読めない)。旧ブリッジは返さない → nil 許容。
    /// 黙って要素ゼロにしないための経路で、ホストは lastActionNote として記録に載せる
    public var note: String?
    /// WebView 内の**画面外**ノード(スクロールヒント)。frame はクランプ前の実座標
    /// (Chromium は全ドキュメントをツリーに載せる。Android ブリッジ v18 以降のみ・他は nil)。
    /// スクロール探索が「目的の要素がどの方向・何 px 先か」を知り、盲目的スワイプを
    /// 長距離ドラッグへ置き換えるために使う(StepExecutor.offscreenJump)。
    /// **要素解決には決して使わない**(見えない要素へ exist/tap が当たる)。ref は全て 0
    public var offscreen: [ElementInfo]?
    /// WebView の中身を**どの経路で読んだか**の申告。`"dom"` = in-app が DOM を JS で走査 /
    /// `"dom-interop"` = DOM は読めたが interop(Compose/Flutter)ホスト配下 = 操作はホスト側
    /// (WebViewDelegatingDriver)が座標へ解決して XCUITest の実タッチへ回す /
    /// `"delegated"` = XCUITest へ画面ごと委譲(ホスト側の WebViewDelegatingDriver が入れる)。
    /// **要素の形から推測してはいけない**: Android は webView 型を出すが web フラグを持たないため、
    /// 推測すると「XCUITest へ委譲」と名乗って Android のデバッグを誤誘導する実害がある。
    /// 経路を知っているのは snapshot を返した本人だけなので、そこに申告させる。
    /// 追加 optional フィールドのみなので bridgeProtocolVersion は据え置き(TapRequest.fast と同じ方針。
    /// 旧ブリッジは返さず nil = 申告なし = 注記も出ない、で安全に縮退する)
    public var webViewPath: String?
    /// **ソフトキーボードが表示中か**(true のときだけ送る = checked/web/focused と同じ省略規約。
    /// 省略は「非表示、または不明」)。要素単位ではなくスナップショット全体の状態。
    /// 取得元は iOS xcuitest=ツリー走査中に `.keyboard` ノードを見たか / iOS in-app=同走査中に
    /// `.keyboardKey` ノードを見たか / Android=オンデバイスのブリッジではなくホスト側の
    /// `AndroidDriver.snapshot()` が `dumpsys window windows` から算出(dumpsys の固定費を避けるため
    /// `captureKeyboardStateOnNextSnapshot()` で立てた回だけ。それ以外は nil)。
    public var keyboardShown: Bool?
    /// ソフトキーボードが覆っている矩形(画面座標)。省略は「非表示、または旧ブリッジ」。
    /// 取得元は iOS xcuitest=走査中に見た `.keyboard` ノードの frame /
    /// iOS in-app=`keyboardWillChangeFrame` 通知の最新値(**TextEffects window の frame は
    /// 使わない** — 開いていても全画面で、画面上部の要素まで誤警告する。実測)/
    /// Android=UiAutomation.getWindows() の TYPE_INPUT_METHOD ウィンドウ bounds。
    /// 読み手はホストの遮蔽警告(TapTargetGeometry)。
    public var keyboardFrame: FTRect?
    /// **木に出ないオーバーレイ・ウィンドウ**が覆っている矩形(画面座標)。省略は「無し、
    /// または旧ブリッジ」。読み手はホストの遮蔽警告(`OverlayWindowOcclusion`)。
    ///
    /// **Android だけが申告する**。Android の木は `getRootInActiveWindow()` = アクティブ
    /// ウィンドウ1枚だけなので、その手前に居るポップアップ(メニュー・ツールチップ・
    /// テキスト選択のフローティングツールバー)は木に1要素も載らず、木由来の遮蔽判定では
    /// 原理的に拾えない —— `keyboardFrame` と同じ理由・同じ形の申告。
    /// iOS は in-app が可視な窓を全部歩き、xcuitest も同様に載せるので申告しない(nil)。
    ///
    /// 何を数えるかの境界は `SnapshotBuilder.hiddenWindowRects` が唯一の定義元
    /// (ステータス/ナビゲーションバーは常設なので数えない、等)
    public var overlayWindowFrames: [FTRect]?
    /// **何を捨てたか**の内訳(`BridgeSnapshotThinning.tierKey` の値 → 件数)。
    /// `truncatedCount` は「何件落ちたか」しか言わないので、ホストは
    /// 「選べる物が消えたのか、飾りが消えただけなのか」を区別できなかった ——
    /// 実測(Apple マップの経路プランナー): 候補 211 件中 91 件が落ちたが、
    /// **内訳が分からないと間引きの方針が妥当かを議論できない**。
    /// 落とした本人にしか分からないのでブリッジが申告する。
    /// 追加 optional フィールドのみ = 旧ブリッジは返さず nil(件数だけ出す)で安全に縮退する
    /// (webViewPath / TapRequest.fast と同じ方針)。**iOS の2ブリッジだけが申告する** ——
    /// Android の SnapshotBuilder は tier3 を持たず、内訳の語彙が揃わない
    public var truncatedTiers: [String: Int]?

    /// **要素上限の外で送った bulk 要素の数**(61。`BridgeSnapshotThinning.bulkExemptCount`)。
    /// これが非 0 なら「`elements.count` が上限を超えているのは異常ではない」ことを意味し、
    /// ホストはそれを読み手へ言える。**申告が無い(nil)= 旧ブリッジ or Android** ——
    /// Android の SnapshotBuilder は tier3 を持たないので常に nil で、件数だけの報告に縮退する
    public var bulkExemptCount: Int?

    /// `truncatedTiers` を出すときの並びと表示名。**ホストの表示順を固定する**ため、
    /// 辞書の列挙順に頼らない
    public static let truncatedTierOrder: [(key: String, label: String)] = [
        ("operable", "operable"),
        ("labelled", "labelled"),
        ("decoration", "unlabelled decorations"),
        ("bulk", "repeated same-id elements"),
    ]

    public init(sessionBundleID: String?, screen: FTRect, elements: [ElementInfo],
                truncatedCount: Int, note: String? = nil, webViewPath: String? = nil,
                offscreen: [ElementInfo]? = nil, keyboardShown: Bool? = nil,
                keyboardFrame: FTRect? = nil, overlayWindowFrames: [FTRect]? = nil,
                truncatedTiers: [String: Int]? = nil,
                bulkExemptCount: Int? = nil) {
        self.sessionBundleID = sessionBundleID
        self.screen = screen
        self.elements = elements
        self.truncatedCount = truncatedCount
        self.note = note
        self.webViewPath = webViewPath
        self.offscreen = offscreen
        self.keyboardShown = keyboardShown
        self.keyboardFrame = keyboardFrame
        self.overlayWindowFrames = overlayWindowFrames
        self.truncatedTiers = truncatedTiers
        self.bulkExemptCount = bulkExemptCount
    }
}

/// `GET /systemalert`(XCUITest ランナーのみ)。**SpringBoard のアラートが載っているか**と、
/// 載っているならその題名とボタン。
///
/// なぜ専用の口があるか: in-app の木は自プロセスしか見えず、SpringBoard の木を丸ごと撮ると
/// 約 185ms かかる(実測)。この口は `alerts.firstMatch.exists` の1問だけなので
/// **アラート無しで約 73ms・表示中で約 146ms**(題名とボタンの読み出し込み)。
/// **セッションを変えない**ので、操作の途中で呼んでも直前の snapshot の ref が生き残る。
public struct SystemAlertProbeResponse: Codable, Sendable {
    public var present: Bool
    public var title: String?
    public var buttons: [String]
    public init(present: Bool, title: String? = nil, buttons: [String] = []) {
        self.present = present
        self.title = title
        self.buttons = buttons
    }
}

/// `GET /systemui/covering`(XCUITest ランナーのみ)。**SpringBoard の面がアプリを覆っているか**。
///
/// なぜ専用の口が要るか(実機 iPhone SE3 で実測): コントロールセンター /
/// 通知センターがアプリを全画面で覆っても、**アプリ側からは何も分からない** ——
/// `/snapshot` は覆う前と1バイト同じ木を返し、`XCUIApplication.state` は `foreground: true`、
/// `/hittable` も `hittable: true` のまま。覆っているのは別プロセス(SpringBoard)の窓なので、
/// アプリのクエリには原理的に現れない。**SpringBoard に聞く以外に知る手段が無い**。
public struct SystemUICoveringResponse: Codable, Sendable {
    public var covering: Bool
    /// 当たった目印(`BridgeAPI.systemUICoveringMarkers`)。呼び手が面を名指しするために使う
    public var marker: String?
    public init(covering: Bool, marker: String? = nil) {
        self.covering = covering
        self.marker = marker
    }
}

public struct TapRequest: Codable {
    public var ref: Int?
    public var x: Double?
    public var y: Double?
    /// true = quiescence 待ちスキップの高速入力(PoC・FastInput.swift)。省略可能な追加
    /// フィールドのみのため bridgeProtocolVersion は据え置き(旧ランナーは無視して通常タップ・
    /// 旧ホストは未指定。bump すると稼働中の旧ホスト常駐プロセスが新ランナーを stale 判定して
    /// 再起動ループに入るため、追加フィールドでは上げない)
    public var fast: Bool?
    public init(ref: Int? = nil, x: Double? = nil, y: Double? = nil, fast: Bool? = nil) {
        self.ref = ref
        self.x = x
        self.y = y
        self.fast = fast
    }
}

public struct DragRequest: Codable {
    public var fromX: Double
    public var fromY: Double
    public var toX: Double
    public var toY: Double
    /// 押下から移動開始までの静止時間(秒)。nil は最小値(0.05)扱い
    public var press: Double?
    /// 移動開始から離すまでの時間(秒)。nil は既定速度。
    /// **終端ドウェル(`thenHoldForDuration`)のフィールドは持たない** —— 実測して
    /// **iOS では慣性を止められない**ことが分かったため(v1500 + hold 0.2s で 2.85→2.82 倍。
    /// 所要だけ +200ms)。XCUITest の hold は指を保持するだけでイベントを出さず、
    /// `UIPanGestureRecognizer` の速度計算が更新されない。詳細は docs/performance-tuning.md §6
    public var duration: Double?
    public init(fromX: Double, fromY: Double, toX: Double, toY: Double,
                press: Double? = nil, duration: Double? = nil) {
        self.fromX = fromX
        self.fromY = fromY
        self.toX = toX
        self.toY = toY
        self.press = press
        self.duration = duration
    }
}

public struct TypeRequest: Codable {
    public var ref: Int?
    public var text: String
    public init(ref: Int? = nil, text: String) {
        self.ref = ref
        self.text = text
    }
}

/// POST /clear(入力欄のクリア。DSL の clearInput)。3ブリッジ共通。
/// ref あり = その要素へフォーカスを立ててからクリア(/type の ref 経路と同じ点解決)。
/// ref なし = フォーカス中の入力欄をクリア。対象が無ければ 409(/type の 409 と同じ扱い)。
/// **409 でフォールバックできるのは typeDriver を持つ iOS の hybrid だけ** ——
/// Android は ScenarioRunnerMain が typeDriver を渡さないので、409 はそのまま失敗になる
public struct ClearRequest: Codable {
    public var ref: Int?
    public init(ref: Int? = nil) {
        self.ref = ref
    }
}

/// swipe の**用途**。同じ「上へ払う」でも要求される性質が違うので、ホストが用途を伝えて
/// ブリッジ側がジェスチャを選ぶ。
/// - `gesture`: DSL の `swipe`。**ジェスチャ自体が目的**(向きの検出をアプリに見せたい)
/// - `search`: `scrollTo` / `scrollDown` 等。**飛距離がビューポート高を超えると要素を飛び越す**
///   ので、1回の移動量を欲張らない
/// - `edge`: `scrollToEdge`。行き過ぎても無害なので**最速で端まで**送ってよい
public enum FTSwipeIntent: String, Codable, CaseIterable {
    case gesture, search, edge
}

/// **ジェスチャの向き**(指の動き)。ブリッジの /swipe はこれを受ける
public enum FTSwipeDirection: String, Codable, CaseIterable {
    case up, down, left, right
}

/// Device orientation for the `rotateTo` DSL command / `ft_rotate` MCP tool / POST /rotate.
/// The contract is **the orientation the app's UI ends up in** — not how the device is tilted.
/// Everything a test can observe (frames, screen size) is already in the app's coordinate space,
/// so that is the only definition that means the same thing on iOS and Android and across
/// Compose / SwiftUI / View-XML / Flutter / React Native (all verified to relayout identically).
///
/// **Two values on purpose** (decision). landscapeLeft/Right were dropped:
/// the physical direction they name is *not observable from a test* (both platforms report the
/// tree in the app's frame either way), so no definition of them could be verified — and the
/// Android side was in fact accepting either landscape as success while iOS enforced the exact
/// one. A distinction that cannot be checked does not belong in the vocabulary.
public enum FTOrientation: String, Codable, CaseIterable, Sendable {
    case portrait, landscape

    /// Parses a user-facing orientation string (MCP tool args / ft_batch).
    /// Swift DSL callers pass `FTOrientation` directly and never come through here
    public static func parse(_ raw: String) -> FTOrientation? {
        FTOrientation(rawValue: raw)
    }
}

public struct RotateRequest: Codable {
    public var orientation: FTOrientation
    public init(orientation: FTOrientation) { self.orientation = orientation }
}

/// Response to POST /rotate. Only sent on success (settled within budget) — `orientation` always
/// equals the requested one. Timeout is a 422 ErrorResponse instead (never a silent partial success).
public struct RotateResponse: Codable {
    public var orientation: FTOrientation
    public init(orientation: FTOrientation) { self.orientation = orientation }
}

/// Settle-poll budget shared by the in-app and XCUITest bridges' POST /rotate (Android is
/// host-side adb, see AndroidDriver — no bridge route, so no shared constant needed there).
public enum RotationSettle {
    public static let deadlineSeconds: Double = 3.0
    public static let pollIntervalSeconds: Double = 0.1
}

/// 焦点待ちの上限と刻み。**唯一の定義元**: MCP の awaitFocus・DSL の pressEnter
/// (StepExecutor+Actions)・in-app ブリッジの ref 指定 type/clear(タップ後に受け口が動くのを待つ)。
/// ブリッジのソース集合に入るのでここに置く。
/// **上限が短い**のは、焦点を報告しないフレームワークで毎回これを丸ごと待つため
public enum FocusWait {
    public static let waitSeconds: Double = 1.5
    public static let pollSeconds: Double = 0.15
}

/// **スクロールの向き**(コンテンツ基準。標準用語どおり `.down` = 下に読み進める)。
/// Shirates の `ScrollDirection` と同じ構成(`None` は fleetest では Optional が担うため持たない)。
/// **指の動きとは逆**なので、ジェスチャへの写像はここに1箇所だけ置く
public enum FTScrollDirection: String, Codable, CaseIterable, Sendable {
    case down, up, right, left

    /// このスクロールを起こすための指の動き(`.down` に読み進めるには指を上へ動かす)
    public var swipe: FTSwipeDirection {
        switch self {
        case .down: return .up
        case .up: return .down
        case .right: return .left
        case .left: return .right
        }
    }
}

/// スワイプの実座標(snapshot の screen と同じ座標系。iOS = pt / Android = px)。
/// 作るのはホストの `ScrollGeometry`(FTCore)だが、**型はここに置く** ——
/// このファイルはランナーのターゲットにも直接コンパイルされるため
public struct FTSwipePath: Codable, Equatable, Sendable {
    public var fromX: Double
    public var fromY: Double
    public var toX: Double
    public var toY: Double
    /// scrollFrame で指定した要素の矩形(`ScrollGeometry.path` の container)。**in-app の自前描画
    /// (Compose / Flutter)だけが読む**: 2 点からは「どの容器か」が絞れない(hitTest も AX の走査も
    /// 画面のどこかまでしか絞れず、固定ヘッダを指定してもリストが動いた)ので、枠がこれと一致する
    /// スクロール可能な AX 要素だけを動かす。nil = 領域の指定なし(in-app の自前描画は 501 で XCUITest へ)
    public var region: FTRect?

    public init(fromX: Double, fromY: Double, toX: Double, toY: Double, region: FTRect? = nil) {
        self.fromX = fromX
        self.fromY = fromY
        self.toX = toX
        self.toY = toY
        self.region = region
    }

    /// 始点から終点までの距離(velocity の算出に使う。縦横どちらかしか動かさないので単純和でよい)
    public var distance: Double { (toX - fromX).magnitude + (toY - fromY).magnitude }
}

/// `FTSwipePath.region` と枠が一致するスクロール可能な要素を選ぶ(in-app の自前描画が使う純粋な判定)。
public enum ScrollRegionMatch {
    /// 一致とみなす重なり(IoU)の下限。region はホストが**同じスナップショットの要素の枠**から作るので、
    /// レイアウトが動いていなければ完全一致(1.0)になる。0.9 は送るまでの間の小さなずれだけを許す値で、
    /// 固定ヘッダの帯(リストの 1 割未満の高さ)がリストの枠と一致することは無い
    public static let minimumOverlap = 0.9

    /// 一致する要素の ref を**内側から**(木の後ろから)返す。同じ枠で入れ子になった容器は内側が実体
    public static func candidates(in elements: [ElementInfo], region: FTRect) -> [Int] {
        elements.filter { $0.scrollable == true && overlap($0.frame, region) >= minimumOverlap }
            .map(\.ref).reversed()
    }

    /// 重なり(交差の面積 ÷ 和集合の面積)。どちらかの面積が 0 なら 0
    public static func overlap(_ a: FTRect, _ b: FTRect) -> Double {
        let w = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
        let h = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
        guard w > 0, h > 0 else { return 0 }
        let inter = w * h
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }
}

/// scrollFrame 無しのスクロールで、指を置く点(画面中央)に触れうる要素だけを対象にする判定
/// (in-app の自前描画の AX 走査が使う)。XCUITest / Android は画面中央を実際に払うので、in-app も
/// 同じ容器だけを動かす —— 「余地のある最大の容器」や「木の順で最初に受理した要素」を動かすと、
/// 同じシナリオが iOS の既定エンジンでだけ別の容器(画面下のカルーセル等)を動かした。
public enum ScrollPointReach {
    /// 枠が点を含むか。**枠の大きさが 0 の要素は通す**(枠を申告しない入れ物。ここで刈ると
    /// その下の容器まで届かず、ふだんの縦スクロールまで XCUITest へ落ちる)
    public static func mayReach(frame: FTRect, x: Double, y: Double) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return true }
        return x >= frame.x && x <= frame.x + frame.width && y >= frame.y && y <= frame.y + frame.height
    }
}

public struct SwipeRequest: Codable {
    public var direction: FTSwipeDirection
    /// TapRequest.fast と同じ(互換性の注記もそちらを参照)
    public var fast: Bool?
    /// **スクロールが目的**の swipe か(scrollTo / scrollToEdge / scrollDown が立てる)。
    /// DSL の `swipe` はジェスチャそのものが目的なので立てない。
    ///
    /// in-app の Compose/Flutter だけがこれを見る: スクロールは UIAccessibility の scroll
    /// アクションで代行できるが、**ジェスチャ目的の swipe を同じ経路へ流すと、画面内の
    /// スクロール可能な親が受理してしまい、ジェスチャ検出パッドに届かないまま 200 を返す**
    /// (実測: E2E-Flutter のジェスチャ画面が黙って空振りした)。
    /// 旧ブリッジは無視して従来動作(TapRequest.fast と同じ互換方針で版は据え置かない —
    /// 挙動が変わるので handleSwipe 側の変更とセットで上げる)
    public var scroll: Bool?
    /// 指の移動距離(画面比)。**Android ブリッジだけが読む**。未指定はブリッジの軸別既定
    /// (縦 0.4・横 0.6 = 従来の固定座標と同一)。ホストは送らない(計測・将来の override 用の口。
    /// 広げると始点がスクロール領域の外に出る罠は BridgeClient.edgeSwipeDurationMs のコメント)
    public var distance: Double?
    /// ストローク時間(ms)。短いほど離す瞬間の速度が上がりフリングが伸びる
    public var durationMs: Int?
    /// ACTION_UP の eventTime を MOVE と同じ合成時刻にするか。**Android の View/Compose では
    /// これが false(= 実時計)だとフリングが出ない**(実測: 276px → 1,156px)。
    /// 既定 false(挙動は変えない)。Flutter は影響を受けない(独自の速度計算)
    public var fling: Bool?
    /// スワイプ速度(points/sec)。**XCUITest ランナーだけが読む**(`XCUIGestureVelocity`)。
    /// nil = `swipeUp()` 等の既定速度。Android は距離とストローク時間で速度を決めるので読まない
    public var velocity: Double?
    /// **スクロール領域を指定したときの実座標**(snapshot の screen と同じ座標系)。
    /// ホストが `ScrollGeometry` で計算して送る。**nil = 全画面固定**(ブリッジ側の
    /// 軸別既定で計算する)。両 OS のブリッジがこれを読む —— 経路を分けると
    /// 「どこをスクロールするか」の決定がエンジンごとに割れるため。
    /// **in-app ブリッジは座標を撃たずに「対象と移動量」として読む**: 始点は必ず対象領域の
    /// 内側にある(ホストがマージンを内側に取る)ので動かすスクロールビュー/AX 要素の特定に使い、
    /// 始点と終点の差を contentOffset の移動量に使う。これで in-app でもマージンが効く
    public var path: FTSwipePath?
    /// **端まで送るのが目的**の swipe か(scrollToEdge が立てる。`scroll` と必ず同時に立つ)。
    /// **contentOffset を直接動かすエンジンだけが読む** = in-app の UIKit/SwiftUI と WKScrollView。
    /// あの経路にジェスチャは無く慣性も無いので「1回 = ビューポートの 85%」を刻む理由が無く、
    /// 長文(利用規約等)では**ページ数ぶんの往復**をホストに払わせていた。立っていれば
    /// コンテンツの端まで1回で寄せる。
    ///
    /// 実ジェスチャを撃つエンジン(XCUITest・Android)は**読まない** —— あちらは指を動かす以上の
    /// ことはできないので、端の判定はホストのループが持つ(`velocity`/`fling` が
    /// 速さのノブ)。旧ブリッジは無視して従来どおりページ送りする(正しいが遅いまま)
    public var edge: Bool?
    public init(direction: FTSwipeDirection, fast: Bool? = nil, scroll: Bool? = nil,
                distance: Double? = nil, durationMs: Int? = nil, fling: Bool? = nil,
                velocity: Double? = nil, path: FTSwipePath? = nil, edge: Bool? = nil) {
        self.path = path
        self.direction = direction
        self.fast = fast
        self.scroll = scroll
        self.distance = distance
        self.durationMs = durationMs
        self.fling = fling
        self.velocity = velocity
        self.edge = edge
    }
}

/// POST /pinch(2本指のズーム。DSL の pinchOut / pinchIn)。**指の置き方はホスト(`PinchGesture`)が
/// `fingers` に組んで送り、ブリッジは再生するだけ**。`identifier` は XCUITest ランナーが非公開の
/// ポインタイベント API を持たないときの縮退先(`XCUIElement.pinch` = 要素単位)のためだけに運ぶ
/// (同期相手: Runner / InAppBridge / AndroidRunner の handlePinch)
public struct PinchRequest: Codable {
    /// 拡大率。> 1 = 拡大(指を開く) / 0 < scale < 1 = 縮小(指を閉じる)。
    /// **XCUITest は scale と velocity の符号が食い違うと例外を投げる**ので、velocity は
    /// ランナー側が scale から導出する(ホストからは送らない)
    public var scale: Double
    /// ジェスチャの所要時間(秒)。Android のストローク時間・iOS の velocity 算出に使う
    public var durationSeconds: Double?
    /// 対象領域(snapshot の screen と同じ座標系)。nil = 画面全体。**ブリッジは読まない**
    /// (`fingers` を組んだ元。XCUITest の縮退時の注記の有無にだけ使う)
    public var frame: FTRect?
    /// 対象の accessibility identifier。nil / 解決不能 = アプリ全体。**XCUITest だけが読む**
    public var identifier: String?
    /// 指2本の経路(ホストの `PinchGesture` が OS ごとの規則で組む = 指の置き方の唯一の定義元)。
    /// **ブリッジは指を自分で置かず、これを再生する**(in-app・Android は必須)。XCUITest は非公開 API が
    /// 無いときだけ読まずに `identifier` の要素ピンチへ縮退する。nil は iOS の「対象なし = アプリ全体の
    /// 要素ピンチ」だけ
    public var fingers: [GestureFinger]?
    public init(scale: Double, durationSeconds: Double? = nil,
                frame: FTRect? = nil, identifier: String? = nil, fingers: [GestureFinger]? = nil) {
        self.fingers = fingers
        self.scale = scale
        self.durationSeconds = durationSeconds
        self.frame = frame
        self.identifier = identifier
    }
}

/// POST /gesture(指ごとの時刻つき経路を1回で再生する。DSL の gesture / MCP の ft_gesture)。
/// 座標は snapshot の screen と同じ座標系(iOS = pt / Android = px)・`t` はジェスチャ開始からの秒。
/// 各指の**最初の点で押し、最後の点で離す**(同じ座標の点が続く区間 = 静止)。
/// **ホストは `TouchGesture.validate` を通した形だけを送る**(本数・時刻の単調性・画面内・上限)が、
/// ブリッジも同じ上限で断る(古いホスト・直叩きから testmanagerd を守る。v125 の秒数の門と同じ理由)。
/// 点の間はブリッジが自分の刻みで補間する(同期相手: Runner の handleGesture /
/// AndroidRunner BridgeRouter.handleGesture / InputInjector.gesture)
public struct GestureRequest: Codable, Equatable, Sendable {
    public var fingers: [GestureFinger]
    public init(fingers: [GestureFinger]) { self.fingers = fingers }
    /// 最後の指が離れる時刻(秒)
    public var totalSeconds: Double {
        fingers.compactMap { $0.points.last?.t }.max() ?? 0
    }
}

public struct GestureFinger: Codable, Equatable, Sendable {
    public var points: [GesturePoint]
    public init(points: [GesturePoint]) { self.points = points }
}

public struct GesturePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var t: Double
    public init(x: Double, y: Double, t: Double) {
        self.x = x
        self.y = y
        self.t = t
    }
}

public struct PressRequest: Codable {
    public var ref: Int?
    public var x: Double?
    public var y: Double?
    public var duration: Double
    /// TapRequest.fast と同じ(互換性の注記もそちらを参照)
    public var fast: Bool?
    public init(ref: Int? = nil, x: Double? = nil, y: Double? = nil, duration: Double,
                fast: Bool? = nil) {
        self.ref = ref
        self.x = x
        self.y = y
        self.duration = duration
        self.fast = fast
    }
}

public struct OKResponse: Codable {
    public var ok: Bool
    /// 通常と違う経路を通ったときの短い説明(既定 nil)。失敗ではなく観測用(例: InAppBridge.handleTap の
    /// activate 不発→合成タッチ)。throw にしない代わりに StepExecutor.driverFallback へ載せて可視化する。
    public var note: String?
    /// **端送り(`SwipeRequest.edge`)で「もう端に着いていた」**(= 動かせなかった)なら true、
    /// **確かに動かした**なら false(v116〜。contentOffset を動かした経路だけ。AX の受理は端でも起きるので含めない)。位置を直接動かすエンジンだけが答えられる事実で、
    /// ホストは true で「署名が2回続けて不変」を待たずに切り上げ、false で「動いた」と数える
    /// (`AppDriver.reachedEdgeOnLastSwipe`)。旧ブリッジ・答えられない経路は nil = 従来どおりの判定
    public var atEdge: Bool?
    public init(ok: Bool = true, note: String? = nil, atEdge: Bool? = nil) {
        self.ok = ok
        self.note = note
        self.atEdge = atEdge
    }
}

/// POST /appstate(DSL の appIs)。読み取り専用でセッション不要
/// (両ブリッジとも requireApp() を経由しない。同期相手: Runner/FleetestRunnerUITests/BridgeRouter.swift handleAppState /
/// InAppBridge/Sources/InAppBridge.swift handleAppState)。
public struct AppStateRequest: Codable {
    public var bundleID: String
    public init(bundleID: String) { self.bundleID = bundleID }
}

public struct AppStateResponse: Codable {
    public var foreground: Bool
    public init(foreground: Bool) { self.foreground = foreground }
}

public struct ErrorResponse: Codable {
    public var error: String
    public init(error: String) { self.error = error }
}
