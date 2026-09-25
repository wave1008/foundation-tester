// BridgeRouter.swift
// HTTPリクエストを XCUITest 操作に変換する。
// スナップショットの圧縮(フィルタ・set-of-mark参照番号付与)はここで行い、
// ホストへ生ツリーを送らない(4Kトークン対策)。

import Foundation
import UIKit
import XCTest

struct BridgeError: Error {
    let status: Int
    let message: String

    init(_ status: Int, _ message: String) {
        self.status = status
        self.message = message
    }
}

final class BridgeRouter {

    // 現在のセッション状態。直近スナップショットの ref→frame 対応表を保持し、
    // tap/press は座標タップとして解決する(要素クエリ再構築より頑健)。
    private var app: XCUIApplication?
    private var sessionBundleID: String?
    private var refFrames: [Int: CGRect] = [:]
    /// `/hittable` が ref から XCUIElement を引き直すための手掛かり(直近の /snapshot 由来)。
    /// **タップ経路では使わない** —— タップは従来どおり座標で撃つ(クエリの往復を払わない)
    private var refIdentity: [Int: (identifier: String?, label: String?, type: String)] = [:]
    /// 直近スナップショットの ref→要素。handleType の読み返しが「対象の identifier」と
    /// 「入力前の値」をここから採る(ライブクエリを撃たずに済ませるため)
    var refElements: [Int: ElementInfo] = [:]
    /// `/systemui/snapshot` が振る ref。**アプリの refFrames と別に持つ**のが要点 ——
    /// 同じ表に書くと、システム UI を1枚撮っただけで直前のアプリの ref が全部無効になる
    /// (engine=xcuitest はブリッジが1本しかなく、主ドライバと共有している)
    private var systemRefFrames: [Int: CGRect] = [:]
    // 直前の要求が画面を変えうる操作(tap/swipe/press/type/drag/session)だったか。
    // XCUITest の tap quiescence は非同期 push 遷移の完了前に返ることがあり、直後 snapshot が
    // 遷移前ツリーを掴む(実測 50% / bridge-8123)。操作直後の snapshot に限り整定確認する。
    // **取得そのものは高コストではない**: ホスト側から HTTP 越しの外形計測で 29〜118ms
    // (要素 5〜22 個・M2 Ultra アイドル・2026-07-30)。以前ここに「~0.45s と高コスト」と
    // 書いていたのは **350ms ガード込みの値を素のコストと取り違えた誤り**だった。
    private var settlePending = false

    /// この snapshot 1回に適用する要素上限(`?max=`)。**要求ごとに handleSnapshot が入れ直す**
    /// ので持ち越しは起きない(接続は1本ずつ順に処理される = 別要求と混ざらない)
    var snapshotElementLimit = BridgeAPI.maxSnapshotElements

    /// /status の idleSeconds 申告用(FleetestBridgeTests がサーバ生成後に配線する。
    /// サーバ⇔ルーターの生成順の都合でコンストラクタ注入にしない)
    var idleSecondsProvider: (() -> TimeInterval)?

    private let decoder = JSONDecoder()

    // 画面を変えうる操作。直後の snapshot だけ整定確認する(handleSnapshot の settlePending)。
    //
    // **/swipe と /drag は入れない**。スクロール慣性は budget 内で収束しないので
    // ここで待っても整定したツリーにはならず、待ち時間だけ捨てることになる(実測: 収束せず
    // budget 打ち切り)。スクロール探索は `for attempt in 0...maxSwipes` で毎周 snapshot を
    // 撮るため、その全てにこの待ちが乗っていた。
    // **スクロール後の静止はホスト側が担う**: 探索終端は StepExecutor.settleAfterScroll、
    // 明示的な swipe/scroll コマンドは同 settledSignature(どちらも「連続2回一致」で待つ)。
    // **/pinch と /doubletap も同じ理由で入れない**: ズーム・展開のアニメーションは budget 内に
    // 収まらないことがあり、ホストの performGesture が末尾で必ず整定を待つ(二重に待たない)。
    private static let mutatingPaths: Set<String> = ["/session", "/systemui/tap", "/tap", "/type", "/clear", "/pressEnter", "/hidekeyboard", "/press", "/appswitcher", "/home"]

    /// 所要内訳ログの on/off(既定 off)。ホストの FT_BRIDGE_TIMING=1 を BridgeLauncher が
    /// xctestrun の環境変数へ注入する(同期相手: Sources/FTBridgeClient/BridgeLauncher.swift)
    private static let timingEnabled =
        ProcessInfo.processInfo.environment["FT_BRIDGE_TIMING"] == "1"
    /// ゲート off でも記録する閾値(ms)。実測の p90 は 439ms・最大 889ms なので、
    /// 通常運転では1行も出ない値にしてある(2026-08-02 実測)
    private static let timingAlwaysLogMs: Double = 1500

    func handle(_ request: BridgeHTTPServer.Request) -> BridgeHTTPServer.Response {
        do {
            let response: BridgeHTTPServer.Response
            switch (request.method, request.path) {
            case ("GET", "/status"): response = handleStatus()
            case ("POST", "/session"): response = try handleLaunch(request.body)
            case ("GET", "/snapshot"): response = try handleSnapshot(request)
            case ("GET", "/hittable"): response = try handleHittable(request)
            case ("GET", "/systemalert"): response = handleSystemAlert()
            case ("GET", "/systemui/covering"): response = handleSystemUICovering()
            case ("GET", "/systemui/snapshot"): response = try handleSystemUISnapshot(request)
            case ("POST", "/systemui/tap"): response = try handleSystemUITap(request.body)
            case ("POST", "/systemui/drag"): response = try handleSystemUIDrag(request.body)
            case ("POST", "/systemui/swipe"): response = try handleSystemUISwipe(request.body)
            case ("POST", "/tap"): response = try handleTap(request.body)
            case ("POST", "/type"): response = try handleType(request.body)
            case ("POST", "/clear"): response = try handleClear(request.body)
            case ("POST", "/pressEnter"): response = try handlePressEnter()
            case ("POST", "/hidekeyboard"): response = try handleHideKeyboard()
            case ("POST", "/swipe"): response = try handleSwipe(request.body)
            case ("POST", "/drag"): response = try handleDrag(request.body)
            case ("POST", "/doubletap"): response = try handleDoubleTap(request.body)
            case ("POST", "/pinch"): response = try handlePinch(request.body)
            case ("POST", "/gesture"): response = try handleGesture(request.body)
            case ("POST", "/rotate"): response = try handleRotate(request.body)
            case ("POST", "/press"): response = try handlePress(request.body)
            case ("GET", "/screenshot"): response = handleScreenshot()
            case ("POST", "/appswitcher"): response = try handleAppSwitcher()
            case ("POST", "/home"): response = try handleHome()
            case ("POST", "/terminate"): response = try handleTerminate()
            case ("POST", "/appstate"): response = try handleAppState(request.body)
            default:
                return .error("not found: \(request.method) \(request.path)", status: 404)
            }
            if request.method == "POST", Self.mutatingPaths.contains(request.path) {
                settlePending = true
            }
            return response
        } catch let error as BridgeError {
            return .error(error.message, status: error.status)
        } catch {
            return .error("\(error)", status: 500)
        }
    }

    // MARK: - Handlers

    private func handleStatus() -> BridgeHTTPServer.Response {
        let device = UIDevice.current
        return .json(StatusResponse(
            ready: true,
            device: device.name,
            osVersion: "\(device.systemName) \(device.systemVersion)",
            sessionBundleID: sessionBundleID,
            engine: "xcuitest",
            protocolVersion: BridgeAPI.bridgeProtocolVersion,
            // 画面が進んでいるかの計器(DisplayHeartbeat 参照)。凍結を絵の一様さではなく直接測る
            displayIdleSeconds: DisplayHeartbeat.shared.idleSeconds,
            fastInputAvailable: FastInput.available,
            // 起動元の自己申告(doctor の刈り取り判定が依存。BridgeDTO の各フィールド参照)
            ownerRepo: ProcessInfo.processInfo.environment["FT_OWNER_REPO"],
            ownerPid: Int(ProcessInfo.processInfo.processIdentifier),
            idleSeconds: idleSecondsProvider.map { $0() },
            // 載っているシミュレータの UDID(H)。ホストが port ではなく udid で宛先を
            // 指せるようにするための申告。実機には SIMULATOR_UDID が無いので nil
            udid: ProcessInfo.processInfo.environment["SIMULATOR_UDID"],
            orientation: XCUIDevice.shared.orientation.ftOrientation))
    }

    private func handleLaunch(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(LaunchRequest.self, body)
        let target = XCUIApplication(bundleIdentifier: req.bundleID)
        // springboard は起動せず参照のみ(launch するとホームに飛びシステムアラートを消す。
        // ハイブリッドのフォールバックで、アプリ上に載ったシステム UI を非破壊で走査/操作するため)。
        if req.bundleID == "com.apple.springboard" {
            app = target
            sessionBundleID = req.bundleID
            refFrames = [:]
            refIdentity = [:]
            refElements = [:]
            return .json(OKResponse())
        }
        if req.attachOnly == true {
            // simctl 等で起動済みのアプリへのプロキシ接続のみ(activate() の約1s を払わない。
            // 前面到達の確認だけ行う=未起動なら即エラーで呼び出し側が診断できる)
            guard target.state == .runningForeground
                || target.wait(for: .runningForeground, timeout: 5) else {
                throw BridgeError(500, "the app to attach to is not in the foreground:"
                    + " \(req.bundleID) (check whether simctl launch succeeded)")
            }
        } else if req.activate == true {
            target.activate()
        } else {
            target.launch()
        }
        guard target.state == .runningForeground || target.wait(for: .runningForeground, timeout: 10) else {
            throw BridgeError(500, "could not launch \(req.bundleID) — check that it is installed")
        }
        app = target
        sessionBundleID = req.bundleID
        refFrames = [:]
        refIdentity = [:]
        refElements = [:]
        return .json(OKResponse())
    }

    struct Captured {
        let elements: [ElementInfo]
        let frames: [Int: CGRect]
        /// `/hittable` が ref から要素を引き直すための手掛かり
        var identities: [Int: (identifier: String?, label: String?, type: String)] = [:]
        let truncated: Int
        /// 捨てた候補の内訳(SnapshotResponse.truncatedTiers)。件数だけでは
        /// 「選べる物が消えたのか、飾りが消えただけか」をホストが区別できない
        var truncatedTiers: [String: Int] = [:]
        /// 要素上限の外で送った bulk の件数(SnapshotResponse.bulkExemptCount)
        var bulkExempt: Int = 0
        let screen: CGRect
        /// SnapshotResponse.keyboardShown/keyboardFrame 用。**Captured に載せる**: 整定ループは
        /// captureOnce を複数回まわして「返す1回」を選ぶので、インスタンス変数だと返却ツリーと
        /// 1回ズレる。nil = 非表示または不明(XCUITest は「非表示」を積極的に確認できない)
        let keyboardFrame: CGRect?
        /// captureSettled が **budget 切れで打ち切った**(= 収束していないツリー)。
        /// 黙って返すと「毎回 350ms 使い切っているのに誰も気付かない」状態が続くので note にする
        var settleCapped: Bool = false
        /// WebView 内の画面外ノード(スクロールヒント)。Android の SnapshotBuilder と同じ契約 =
        /// ref 0・elements に混ぜない(見えない要素へ exist/tap が当たる)・実座標。iOS は
        /// XCUITest が実座標のまま報告するので復元は不要(2026-08-04 実測)。
        /// 読み手は StepExecutor.offscreenJump / offscreenEdgeJump
        let offscreen: [ElementInfo]
    }

    private func handleSnapshot(_ request: BridgeHTTPServer.Request) throws
        -> BridgeHTTPServer.Response {
        // `max=<n>` は呼び手が1回だけ上限を引き上げるためのもの(BridgeAPI.maxSnapshotElementsCeiling)。
        // 解釈は resolvedSnapshotElementLimit の1箇所 = ホスト・3ブリッジで同じ規則
        snapshotElementLimit = BridgeAPI.resolvedSnapshotElementLimit(
            request.queryValue("max").flatMap { Int($0) })
        let app = try requireForegroundApp()
        // 操作直後のみ整定してから取得する(captureSettled)。XCUITest の tap quiescence は
        // 非同期 push 遷移の完了前に返るため、直後の素取得は遷移前ツリーを返す(実測 50%)。
        // 連続 snapshot(settlePending=false)は整定不要なので素取得のまま。
        let cap = try settlePending ? captureSettled(app) : captureOnce(app)
        settlePending = false

        refFrames = cap.frames
        refIdentity = cap.identities
        // ref → 要素(handleType の読み返しが identifier / 直前の値を使う)。frame と同じ寿命
        refElements = Dictionary(uniqueKeysWithValues: zip(cap.elements.map(\.ref), cap.elements))
        return .json(SnapshotResponse(
            sessionBundleID: sessionBundleID,
            screen: FTRect(x: cap.screen.origin.x, y: cap.screen.origin.y,
                           width: cap.screen.width, height: cap.screen.height),
            elements: withFocusedFlag(cap.elements, app: app),
            truncatedCount: cap.truncated,
            note: cap.settleCapped ? "snapshot taken before the screen settled (budget)" : nil,
            offscreen: cap.offscreen.isEmpty ? nil : cap.offscreen,
            keyboardShown: cap.keyboardFrame != nil ? true : nil,
            keyboardFrame: cap.keyboardFrame.map {
                FTRect(x: $0.origin.x, y: $0.origin.y, width: $0.width, height: $0.height)
            },
            truncatedTiers: cap.truncatedTiers.isEmpty ? nil : cap.truncatedTiers,
            bulkExemptCount: cap.bulkExempt > 0 ? cap.bulkExempt : nil))
    }

    /// フォーカス中要素の申告(clearInput 事後検証用。ElementInfo.focused 参照)。
    /// captureOnce の snapshot ツリーは `hasKeyboardFocus` を持たない(値は KVC 専用の
    /// ライブクエリでしか読めない)ため、**要素ごとに追加クエリを撃つのではなく**
    /// フォーカス要素だけ1回引いて frame 一致で突き合わせる(handleClear と同じ経路)。
    /// 見つからなければ全要素 focused なしのまま返す
    private func withFocusedFlag(_ elements: [ElementInfo], app: XCUIApplication) -> [ElementInfo] {
        let focused = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        guard focused.exists else { return elements }
        let frame = focused.frame
        let focusedFrame = FTRect(x: frame.origin.x, y: frame.origin.y,
                                  width: frame.width, height: frame.height)
        guard let index = elements.firstIndex(where: { $0.frame == focusedFrame }) else { return elements }
        var out = elements
        out[index].focused = true
        return out
    }

    /// 整定してから取得する(操作直後の 1 回だけ)。
    ///
    /// **固定 sleep にしない**(2026-07-30 実測): 必要量はマシン性能・並列負荷・アニメーション長に
    /// 依存するため 1 つの定数(一律 350ms を試した)では合わない。
    /// 外形計測では、タブ遷移は 350ms 待たずとも 1 回目から安定していた一方(= 過剰)、
    /// **スワイプ直後は 350ms 後もフレームが動き続けていた**(= 不足。y が 6 回連続で変化)。
    ///
    /// **成立の根拠**: 連続取得でツリーは毎回更新される(同条件で署名 6 回中 6 種)。
    /// XCUITest の snapshot キャッシュは取得をまたいで居座らないため、
    /// 「連続 2 回一致 = 静止」で判定できる。
    ///
    /// 早抜け防止に **minSettle** を置く: 遷移がまだ始まっていない時点で 2 回撮ると
    /// 「遷移前のツリーで一致」して stale を掴む。最初の 1 回はここを待ってから撮る。
    /// 収束しない画面(スピナー・常時アニメーション)のために **budget** で必ず打ち切る。
    ///
    /// **残存リスク**: minSettle だけは固定待ちなので環境依存が残る。遷移の開始が
    /// minSettle より遅い機械では、2 回とも遷移前のツリーを撮って「一致 = 静止」と
    /// 誤判定しうる。「操作前のツリーと違うこと」を条件に足せば消せるが、画面を変えない
    /// 操作(no-op なタップ等)で必ず budget を使い切るので採らない。
    /// アサーション経路は StepExecutor 側が PollBackoff で撮り直すため、この誤判定は
    /// 「1 周ぶん遅くなる」に吸収される。吸収されないのは snapshot の frame を
    /// タップ座標に使う経路(スクロール探索の終端)。
    private func captureSettled(_ app: XCUIApplication) throws -> Captured {
        // budget は**入口からの総経過**の上限。旧実装の固定 350ms と同等に置くことで
        // 「収束しない画面(スクロール慣性・スピナー)でも従来より遅くならない」を担保する。
        // 実測(2026-07-30): Flutter のスクロール慣性は 800ms でも収束しなかったので、
        // 待ち切る設計にはしない。スクロール後の静止は**ホスト側の settleAfterScroll**
        // (frame が連続 2 回同じ・最大 600ms)が担うので、ここで粘る必要はない。
        let minSettle: TimeInterval = 0.12   // 遷移の立ち上がりを待つ床(取得 1 回ぶん相当)
        let budget: TimeInterval = 0.35
        let deadline = Date().addingTimeInterval(budget)

        Thread.sleep(forTimeInterval: minSettle)
        var previous = try captureOnce(app)
        var previousSignature = Self.signature(previous)
        while Date() < deadline {
            let current = try captureOnce(app)
            let signature = Self.signature(current)
            if signature == previousSignature { return current }
            previous = current
            previousSignature = signature
        }
        // budget 切れ。previous は常に直近の取得(収束はしていない)。
        // **打ち切ったことを申告する**(handleSnapshot が note にする)
        previous.settleCapped = true
        return previous
    }

    /// 静止判定の署名。ラベル・型・矩形が全て同じなら「動いていない」とみなす
    /// (スクロール中は y が変わるので frame を必ず含める)。
    private static func signature(_ captured: Captured) -> String {
        var text = ""
        text.reserveCapacity(captured.elements.count * 24)
        for element in captured.elements {
            let frame = element.frame
            text += "\(element.label ?? "")|\(element.type)|"
            text += "\(Int(frame.x)),\(Int(frame.y)),\(Int(frame.width)),\(Int(frame.height));"
        }
        return text
    }

    /// **その ref を撃つと本当にそれに当たるか**を XCUITest 自身に聞く(`XCUIElement.isHittable`)。
    ///
    /// **なぜブリッジ側にしか置けないか**: `isHittable` は `XCUIElement`(生のクエリ)の API で、
    /// 木を作るのに使う `XCUIElementSnapshot` は持たない。ホストは木しか受け取らないので
    /// 原理的に計算できない。
    ///
    /// **なぜ全要素に付けないか**(2026-08-14 実測・iPhone 17 Pro / iOS 27・126ノード):
    /// 木の取得は 102ms なのに、`isHittable` は**要素ごとに往復**して中央 39ms かかる。
    /// 121 要素に付けると約 5.1 秒 = **snapshot の 50 倍**で、常時払える額ではない。
    /// 対象1件だけなら 72〜146ms(引き方による)なので、**呼び手が疑ったときだけ**聞く形にする。
    ///
    /// **タップ経路は変えない**: タップは従来どおり座標で撃つ(`resolvePoint`)。ここはあくまで
    /// 撃つ前の照会で、`isHittable` の評価そのものは何も操作しない。
    ///
    /// 引き当ては identifier → label の順で、**候補が1つに絞れて frame も一致するときだけ**
    /// 答える(`hittable` が nil = 「引き当てられなかった」で、呼び手は黙る)。
    /// 曖昧なまま別要素の可否を返すと、木の限界を別の嘘で置き換えるだけになる
    /// **システム UI(SpringBoard のアラート)が載っているかだけ**を返す軽い口。
    ///
    /// `GET /snapshot` は木を全部歩いて直列化するので約 185ms(実測 2026-08-21・ホーム画面)
    /// かかり、ステップごとに払える値ではない。ここは `alerts.firstMatch.exists` の1問だけで
    /// 済ませる。**ボタンの読み出しは載っているときだけ**行う(名指しが要るのは出たときだけ)。
    ///
    /// **セッションを変えない**のが要点: `POST /session springboard` は refFrames を消すので、
    /// 操作の途中で呼ぶと直前の snapshot の ref が無効になる。ここは springboard を
    /// **その場で参照するだけ**で、`app` / `sessionBundleID` / `refFrames` に一切触らない。
    private func handleSystemAlert() -> BridgeHTTPServer.Response {
        struct Out: Encodable {
            let present: Bool
            let title: String?
            let buttons: [String]
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.exists else { return .json(Out(present: false, title: nil, buttons: [])) }
        let buttons = alert.buttons.allElementsBoundByIndex
            .map { $0.label }
            .filter { !$0.isEmpty }
        let title = alert.label.isEmpty ? nil : alert.label
        return .json(Out(present: true, title: title, buttons: buttons))
    }

    /// SpringBoard(別プロセス)の木を **セッションを触らずに** 撮る。
    ///
    /// `POST /session springboard` + `GET /snapshot` と結果は同じだが、あちらは `app` /
    /// `sessionBundleID` / `refFrames` を差し替える。**engine=xcuitest はブリッジが1本しかなく
    /// 主ドライバと共有している**ため、それを撃つとアプリのセッションと ref が巻き添えになり、
    /// アラートを閉じた次のステップが SpringBoard の木を読んで
    /// `cannot resolve the locator` で落ちる(2026-08-25 に E2E-iOS で実測)。
    ///
    /// 撮る機構(`captureOnce`)は元からアプリを引数で受け取るので、参照した SpringBoard を
    /// 渡して ref を別表へ書くだけでよい。`/systemalert` と同じ「参照するだけ」の規律。
    ///
    /// **アラートの有無で撮る/撮らないを分けない**: この口はホーム画面の走査(tapAppIcon)にも
    /// 使う。SpringBoard は system shell なので背面に回らず、`requireForegroundApp` が
    /// 防いでいる「背面アプリの木を読むとランナーごと落ちる」形には当たらない
    /// **SpringBoard の面(コントロールセンター / 通知センター)がアプリを覆っているか**。
    ///
    /// 覆っていてもアプリ側は何も気付けない —— `/snapshot` は覆う前と同じ木を返し、
    /// `XCUIApplication.state` は `foreground: true`、`/hittable` も `true`(実機で実測)。
    /// **SpringBoard に聞く以外に知る手段が無い**ので専用の口を置く。
    ///
    /// **`/systemui/snapshot` では代用しない**: あちらは木を丸ごと撮る(CC 表示中は 56 要素)。
    /// ここは目印の存在を1問聞くだけ —— `/systemalert` と同じ形。
    /// 目印の集合は `BridgeAPI.systemUICoveringMarkers` が唯一の定義元(実測の根拠もそちら)。
    ///
    /// **述語で1回のクエリにまとめる**(目印ごとに `.exists` を撃つと往復が本数分になる)
    private func handleSystemUICovering() -> BridgeHTTPServer.Response {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // **前方一致**で見る —— 窓の identifier には接尾辞が付く(実測 2026-09-22:
        // アプリスイッチャーは `SBSwitcherWindow:Main`)。完全一致だと取りこぼし、
        // 覆われているのに「覆われていない」と答える
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates:
            BridgeAPI.systemUICoveringMarkers.map { NSPredicate(format: "identifier BEGINSWITH %@", $0) })
        let match = springboard.descendants(matching: .any).matching(predicate).firstMatch
        // **exists だけでは足りない** —— 一度開いた面の窓は閉じてもツリーに残る(実測 2026-09-22:
        // アプリスイッチャーを閉じてホーム画面へ戻っても `SBSwitcherWindow:Main` の exists は
        // true のまま)。**今その面が触れる状態か**で切る
        guard match.exists, match.isHittable else {
            return .json(SystemUICoveringResponse(covering: false))
        }
        let marker = match.identifier
        // **アプリスイッチャーは「触れる窓」だけでは足りない** —— ホームボタン機(実測 2026-09-24:
        // iPhone SE3 / iOS 26)は設定アプリが前面でも `SBSwitcherWindow:Main` を isHittable と答え、
        // 前面アプリのカードが窓いっぱいのまま 1 枚載っている(Face ID 機・シミュレータは窓が
        // hittable でなく、閉じるとカードも消える)。開いているスイッチャーのカードは縮んで並ぶので、
        // **窓より小さいカードがあるときだけ**覆い(BridgeAPI.appSwitcherCardIsShrunken)。
        // 誤って true にするとライブ操作の前面追従が止まり、前面のアプリの木が一度も読めない
        if marker.hasPrefix(BridgeAPI.appSwitcherMarkerPrefix) {
            let window = match.frame
            let cards = match.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", BridgeAPI.appSwitcherCardPrefix))
            // 枚数は開いているアプリの数(数枚〜十数枚)。frame の照会は 1 枚ずつ往復するので上限を置く
            let shrunken = cards.allElementsBoundByIndex.prefix(16).contains { card in
                let f = card.frame
                return BridgeAPI.appSwitcherCardIsShrunken(cardWidth: f.width, cardHeight: f.height,
                                                           windowWidth: window.width, windowHeight: window.height)
            }
            guard shrunken else {
                return .json(SystemUICoveringResponse(covering: false))
            }
        }
        return .json(SystemUICoveringResponse(covering: true, marker: marker))
    }

    private func handleSystemUISnapshot(_ request: BridgeHTTPServer.Request) throws
        -> BridgeHTTPServer.Response {
        snapshotElementLimit = BridgeAPI.resolvedSnapshotElementLimit(
            request.queryValue("max").flatMap { Int($0) })
        let springboard = systemUIAnchor()
        // **`settlePending` は /snapshot と同じように消費する**。置き換え前の経路は
        // `POST /session springboard` が mutatingPaths に居たので、続く /snapshot が必ず
        // captureSettled を通っていた。素取得に落とすと、アラートを閉じた直後・アイコンを叩いた
        // 直後の1枚をアニメーション中に撮り、続く /systemui/tap が座標を外す。
        // **どちらの口が先に来ても1回だけ**待つ(消費するのは最初に撮った方)
        let cap = try settlePending ? captureSettled(springboard) : captureOnce(springboard)
        settlePending = false
        systemRefFrames = cap.frames
        return .json(SnapshotResponse(
            sessionBundleID: "com.apple.springboard",
            screen: FTRect(x: cap.screen.origin.x, y: cap.screen.origin.y,
                           width: cap.screen.width, height: cap.screen.height),
            elements: cap.elements,
            truncatedCount: cap.truncated,
            note: nil))
    }

    /// `/systemui/snapshot` が振った ref を叩く。**アプリの refFrames は読まない**
    /// (別の名前空間。取り違えると座標が1枚前のアプリの木のものになる)
    private func handleSystemUITap(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(TapRequest.self, body)
        guard let ref = req.ref else {
            throw BridgeError(400, "ref is required (GET /systemui/snapshot first)")
        }
        guard let frame = systemRefFrames[ref] else {
            throw BridgeError(404,
                "unknown system-UI reference number [\(ref)] — run GET /systemui/snapshot first")
        }
        coordinate(systemUIAnchor(), CGPoint(x: frame.midX, y: frame.midY)).tap()
        return .json(OKResponse())
    }

    /// `/systemui/*` の座標ジェスチャが原点にするアプリ。
    ///
    /// **セッションのアプリを使わない**のが要点。この口の呼び手(tapAppIcon)は
    /// 直前に `home()` を撃っており、セッションのアプリは**背面**か、まだ**起動していない**。
    /// 前者を `/drag` に流すと背面アプリの座標解決で `Find the Application` を約45秒リトライして
    /// **ランナーごと落ち**、後者は `requireLiveApp` の 503 で弾かれる(旧経路は
    /// `POST /session springboard` がセッションごと差し替えていたので、どちらも起きなかった)。
    ///
    /// 座標は画面座標なので、原点が (0,0) の SpringBoard を基準にすれば
    /// **前面に何が居ても同じ点を叩く**(`/appswitcher` と `/home` が同じ理由で既にこうしている)。
    /// **`/tap` 側を勝手に SpringBoard へ寄せてはいけない** —— あちらの 503 は
    /// 「アプリが死んでいる」の申告で、ホストが復帰に使っている(requireLiveApp の doc)
    private func systemUIAnchor() -> XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }

    /// `/drag` の SpringBoard 版(tapAppIcon のページ送り)
    private func handleSystemUIDrag(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(DragRequest.self, body)
        return try performDrag(req, in: systemUIAnchor())
    }

    /// `/swipe` の SpringBoard 版(tapAppIcon が座標を作れなかったときの退避先)。
    /// **path 付きは受けない** —— 呼び手はページ送りの座標を作れなかったから来ているので、
    /// 向き基準の全画面スワイプだけで足りる
    private func handleSystemUISwipe(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(SwipeRequest.self, body)
        let app = systemUIAnchor()
        switch req.direction {
        case .up: app.swipeUp()
        case .down: app.swipeDown()
        case .left: app.swipeLeft()
        case .right: app.swipeRight()
        }
        return .json(OKResponse())
    }

    private func handleHittable(_ request: BridgeHTTPServer.Request) throws
        -> BridgeHTTPServer.Response {
        let app = try requireForegroundApp()
        guard let ref = request.queryValue("ref").flatMap({ Int($0) }) else {
            throw BridgeError(400, "ref is required")
        }
        guard let frame = refFrames[ref], let identity = refIdentity[ref] else {
            throw BridgeError(404, "unknown reference number [\(ref)] — run GET /snapshot first")
        }
        struct Out: Encodable {
            let ref: Int
            /// nil = 引き当てられなかった(呼び手は何も言わない)
            let hittable: Bool?
            let resolvedBy: String
        }
        func answer(_ hittable: Bool?, _ how: String) -> BridgeHTTPServer.Response {
            .json(Out(ref: ref, hittable: hittable, resolvedBy: how))
        }

        // **frame の一致まで確かめる**: 同じ id/label が複数あるとき、別の個体の可否を
        // 返してしまうのを防ぐ(1pt の丸めは許容)
        func matches(_ element: XCUIElement) -> Bool {
            let f = element.frame
            return abs(f.origin.x - frame.origin.x) <= 1 && abs(f.origin.y - frame.origin.y) <= 1
                && abs(f.width - frame.width) <= 1 && abs(f.height - frame.height) <= 1
        }
        func unique(_ query: XCUIElementQuery, _ how: String) -> BridgeHTTPServer.Response? {
            let all = query.allElementsBoundByAccessibilityElement.filter(matches)
            guard all.count == 1, let element = all.first else { return nil }
            return answer(element.isHittable, how)
        }

        if let id = identity.identifier, !id.isEmpty,
           let hit = unique(app.descendants(matching: .any).matching(identifier: id), "identifier") {
            return hit
        }
        if let label = identity.label, !label.isEmpty,
           let hit = unique(app.descendants(matching: .any)
                                .matching(NSPredicate(format: "label == %@", label)), "label") {
            return hit
        }
        return answer(nil, "unresolved")
    }

    func captureOnce(_ app: XCUIApplication) throws -> Captured {
        let root = try app.snapshot()
        // 別 UIWindow の上部バナー(高さ180)の本体に触れた直後、root.frame が**そのバナー窓の
        // frame** に縮む(402x180)。そのまま使うと下の shouldInclude の `frame.intersects(screen)`
        // がアプリ本体を丸ごと画面外扱いして木から消す(XCUITest 固有。in-app は可視な窓を自分で歩く)
        let screen = Self.screenBounds(root: root)
        var elements: [ElementInfo] = []
        var frames: [Int: CGRect] = [:]
        var identities: [Int: (identifier: String?, label: String?, type: String)] = [:]
        var truncated = 0
        var truncatedTiers: [String: Int] = [:]
        var bulkExempt = 0
        var keyboardFrame: CGRect?
        var offscreenHints: [ElementInfo] = []
        collect(root, depth: 0, screen: screen,
                elements: &elements, frames: &frames, identities: &identities,
                truncated: &truncated,
                truncatedTiers: &truncatedTiers, bulkExempt: &bulkExempt,
                keyboardFrame: &keyboardFrame, offscreenHints: &offscreenHints)
        return Captured(elements: elements, frames: frames, identities: identities,
                        truncated: truncated,
                        truncatedTiers: truncatedTiers, bulkExempt: bulkExempt, screen: screen,
                        keyboardFrame: keyboardFrame, offscreen: offscreenHints)
    }

    /// 「画面」の外接矩形 = root.frame に、**ディスプレイに収まる**子(各 UIWindow)の frame を union
    /// したもの。root.frame は手前の別 UIWindow の frame に縮むことがあるが、アプリ本体の窓の frame は
    /// 歪まない。**収まらない子は足さない** —— SpringBoard の木には画面外の窓が居て、素朴に union すると
    /// 画面が 1206x2622(ディスプレイの3倍)に膨らみ、画面外の要素が木に載る(`/systemui/snapshot` も同じ)。
    /// ディスプレイの寸法が取れないときは root.frame のまま
    private static func screenBounds(root: XCUIElementSnapshot) -> CGRect {
        guard let display = displaySides else { return root.frame }
        return root.children.reduce(root.frame) { acc, child in
            fits(child.frame.size, within: display) ? acc.union(child.frame) : acc
        }
    }

    /// ディスプレイの長辺・短辺(pt)。回転で縦横が入れ替わるので辺の長さだけを持つ。
    /// 採るのはプロセスで最初の1回(`static let` の初期化はスレッド安全)。XCUIScreen の
    /// スクショはアプリに触れない(`/screenshot` と同じ)。`UIImage.size` は pt
    private static let displaySides: (long: CGFloat, short: CGFloat)? = {
        let size = XCUIScreen.main.screenshot().image.size
        guard size.width > 0, size.height > 0 else { return nil }
        return (max(size.width, size.height), min(size.width, size.height))
    }()

    /// frame は 1/scale pt 刻みの端数を持つので、ディスプレイちょうどの窓を落とさないよう 1pt 見逃す
    private static func fits(_ size: CGSize, within display: (long: CGFloat, short: CGFloat)) -> Bool {
        max(size.width, size.height) <= display.long + 1 && min(size.width, size.height) <= display.short + 1
    }

    private func handleTap(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(TapRequest.self, body)
        let app = try requireForegroundAppForGesture()
        let point = try resolvePoint(ref: req.ref, x: req.x, y: req.y)
        // 計測: `tap()` は「イベント合成」と「暗黙の quiescence 待ち」の両方を含む1呼び出しで、
        // ホスト側の actionMs からは分解できない。quiescence 側だけ swizzle 経由で数え、
        // 残り(synth)を引き算で出す(FastInput.quiescenceMs の但し書きも読むこと)
        FastInput.resetTiming()
        let start = DispatchTime.now()
        try FastInput.with(req.fast) {
            coordinate(app, point).tap()
        }
        let totalMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        // 閾値超えは**ゲートに関係なく**残す。FT_BRIDGE_TIMING はランナー起動時にしか効かず
        // (稼働中ランナーを再利用すると届かない)、そのとき 0 行を「待ちが無かった」と
        // 誤読する事故が起きる。異常に遅い tap だけは必ず記録が残るようにしておく
        if Self.timingEnabled || totalMs >= Self.timingAlwaysLogMs {
            NSLog("[fleetest] tapTiming total=%.0f quiesce=%.0f synth=%.0f", totalMs,
                  FastInput.quiescenceMs, totalMs - FastInput.quiescenceMs)
        }
        return .json(OKResponse())
    }

    /// typeText("\n") は XCUITest 内部で Return キー相当に落ちる(ソフトキーボードの改行/送信
    /// アクションを駆動する唯一の経路。fleetest はキーボード要素を snapshot から除外しているため
    /// 実ソフトキー tap はできない)。
    ///
    /// hybrid(ios-inapp)では in-app 側が合成タッチでタップ・入力してフォーカスを立てているため、
    /// app 全体への typeText("\n") はフォーカス中の入力欄に届かないことがある。キーボード
    /// フォーカスを持つ要素を探し、見つかればそこへ typeText する。見つからない場合(engine=xcuitest
    /// 単独等、in-app がフォーカスを立てていないケース)は従来どおり app 全体へ送る。
    private func handlePressEnter() throws -> BridgeHTTPServer.Response {
        let app = try requireForegroundAppForInput()
        let focused = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        if focused.exists {
            focused.typeText("\n")
        } else {
            app.typeText("\n")
        }
        return .json(OKResponse())
    }

    /// **iOS ではキーボードを閉じられない**(docs/design.md に不採用の記録)。Esc は不発で、
    /// app.keyboards は別プロセス扱いでタイムアウトする(handleType のコメント参照)。
    /// **嘘の成功を返さない**ため 501 を返す
    /// アプリの窓の縦横から読む向き(デバイスの向きではない。handleRotate のコメント参照)。
    /// **`snapshot()` ではなく `frame` を読む** —— 回転中の snapshot は高コストで失敗もし、
    /// nil が返り続けると「回っていない」と誤判定して 3 秒待ち切る(2026-08-10 実測)。
    /// セッションが無いときは窓で判定できないのでデバイスの向きに落ちる
    /// (その場合だけは縦専用アプリを見抜けないが、/rotate をセッション無しで撃つ経路は無い)
    /// **前面に居ないアプリの窓は読まない**(落ちた・背面のアプリの `frame` は XCTest を Tear Down させ、
    /// ランナーごとブリッジが消える。待ちの途中でアプリが消える形もここで止める)
    private func appOrientation() -> FTOrientation? {
        guard let app else { return XCUIDevice.shared.orientation.ftOrientation }
        guard app.state == .runningForeground else { return nil }
        let frame = app.frame
        guard frame.width > 0, frame.height > 0 else { return nil }
        return frame.width > frame.height ? .landscape : .portrait
    }

    private func handleHideKeyboard() throws -> BridgeHTTPServer.Response {
        .error("hideKeyboard is Android-only; on iOS use pressEnter to dismiss the keyboard",
               status: 501)
    }

    private func handleSwipe(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(SwipeRequest.self, body)
        let app = try requireForegroundAppForGesture()
        // 所要が長くなりうるのは velocity 指定時だけ(未指定は XCTest の既定速度)。距離は path の
        // 2点間、無ければ画面の長辺(既定の swipe は画面の外へ出ない = 上から見積もる)。
        // **`app.frame` を使わない** —— XCUI の問い合わせになり、scrollToEdge の毎回に往復が1回増える
        if let rawVelocity = req.velocity {
            guard rawVelocity.isFinite, rawVelocity > 0 else {
                throw BridgeError(400, "velocity must be positive and finite (got \(rawVelocity))")
            }
            let distance: Double
            if let path = req.path {
                distance = hypot(path.toX - path.fromX, path.toY - path.fromY)
            } else {
                let screen = UIScreen.main.bounds.size
                distance = Double(max(screen.width, screen.height))
            }
            if let violation = BridgeAPI.gestureDurationViolation("swipe",
                                                                   seconds: 0.05 + distance / rawVelocity,
                                                                   cap: BridgeAPI.gestureSecondsCeiling) {
                throw BridgeError(400, violation)
            }
        }
        // velocity(points/sec)はホストが用途に応じて送る(scrollToEdge だけ。契約は
        // FTCore/BridgeDTO の FTSwipeIntent)。**`?? .default` で4分岐に畳まないこと**:
        // XCUIGestureVelocityDefault の実体は -10 というセンチネル値で、実速度は XCTest 内部が
        // 解決する。`swipeUp(velocity: .default)` が `swipeUp()` と同一である保証は公開されておらず、
        // 未指定側(search / DSL の swipe = スイート内の大半)の挙動を確認なしに変えることになる
        let velocity = req.velocity.map { XCUIGestureVelocity($0) }
        // **スクロール領域を指定された場合は座標ドラッグ**(swipeUp() 系は始点を選べない)。
        // 同じ velocity なら両者の物理は一致する(2026-08-02 実測: 984.3pt 対 985.3pt)。
        // 速度未指定のときは既定速度を模倣せず**素の press-drag** にする —— 指定領域を
        // 動かすことが目的で、未指定側(全画面)の挙動を変えるものではない
        if let path = req.path {
            pressDrag(app, from: CGPoint(x: path.fromX, y: path.fromY),
                      to: CGPoint(x: path.toX, y: path.toY), velocity: velocity, fast: req.fast)
            return .json(OKResponse())
        }
        // 横向きだけ `swipeUp()` 系が不発(2026-08-31・実機 iPhone 13 landscape 844x390 実測:
        // 8方向 switch のどれも画面を動かさない。縦向きは同じ switch のままでよい)。
        // path 指定と同じ press-drag へ落とし、始点・終点は landscapeDefaultSwipe が決める
        if let (from, to) = Self.landscapeDefaultSwipe(req.direction, frame: app.frame) {
            pressDrag(app, from: from, to: to, velocity: velocity, fast: req.fast)
            return .json(OKResponse())
        }
        FastInput.with(req.fast) {
            switch (req.direction, velocity) {
            case (.up, nil): app.swipeUp()
            case (.down, nil): app.swipeDown()
            case (.left, nil): app.swipeLeft()
            case (.right, nil): app.swipeRight()
            case (.up, let v?): app.swipeUp(velocity: v)
            case (.down, let v?): app.swipeDown(velocity: v)
            case (.left, let v?): app.swipeLeft(velocity: v)
            case (.right, let v?): app.swipeRight(velocity: v)
            }
        }
        return .json(OKResponse())
    }

    /// path 指定 swipe と横向き既定 swipe が共有する press-drag(velocity nil = 素の
    /// `press(forDuration:thenDragTo:)`。既定速度を模倣しない理由は handleSwipe のコメント)
    private func pressDrag(_ app: XCUIApplication, from: CGPoint, to: CGPoint,
                           velocity: XCUIGestureVelocity?, fast: Bool?) {
        let fromCoordinate = coordinate(app, from)
        let toCoordinate = coordinate(app, to)
        FastInput.with(fast) {
            if let velocity {
                fromCoordinate.press(forDuration: 0.05, thenDragTo: toCoordinate,
                                      withVelocity: velocity, thenHoldForDuration: 0)
            } else {
                fromCoordinate.press(forDuration: 0.05, thenDragTo: toCoordinate)
            }
        }
    }

    /// 横向き(landscape)専用の既定 swipe の始点・終点。**frame ローカル座標**を返す
    /// (`coordinate(_:_:)` が app frame 原点からのオフセットとして加算するため minX/minY は足さない)。
    /// 縦向きは対象外で nil を返し `swipeUp()` 系のまま —— 全画面を暗黙に座標化する案は
    /// 2度撤回済み(docs/performance-tuning.md §3.19)。
    /// マージンは `BridgeAPI.defaultSwipeMarginRatio`(0.25)だが、**下端からは
    /// `BridgeAPI.bottomChromeClearance` を必ず空ける** —— 比だけだと窓の低い横向きで
    /// 始点がタブバーの内側に落ち、1pt も動かない(定数の doc に実測)。
    /// ランナーは木を持たないので保証できるのは標準的なバーを外すところまでで、
    /// **それより高いバーに乗れば動かない**——そのときは host 側の
    /// 「何も動いていない」判定がそのまま報告する
    private static func landscapeDefaultSwipe(_ direction: FTSwipeDirection, frame: CGRect)
        -> (CGPoint, CGPoint)? {
        guard frame.width > frame.height else { return nil }
        let margin = BridgeAPI.defaultSwipeMarginRatio
        let midX = frame.width / 2
        let midY = frame.height / 2
        switch direction {
        case .up:
            // 床が終点より上へ来る(窓がクリアランス+スパンより低い)ときは比のまま ——
            // 始点と終点が入れ替わって逆向きに振るほうが害が大きい
            let end = frame.height * margin
            let ratioStart = frame.height * (1 - margin)
            let cleared = frame.height - BridgeAPI.bottomChromeClearance
            return (CGPoint(x: midX, y: cleared > end ? min(ratioStart, cleared) : ratioStart),
                    CGPoint(x: midX, y: end))
        case .down:
            return (CGPoint(x: midX, y: frame.height * margin),
                    CGPoint(x: midX, y: frame.height * (1 - margin)))
        case .left:
            return (CGPoint(x: frame.width * (1 - margin), y: midY),
                    CGPoint(x: frame.width * margin, y: midY))
        case .right:
            return (CGPoint(x: frame.width * margin, y: midY),
                    CGPoint(x: frame.width * (1 - margin), y: midY))
        }
    }

    /// 2点間ドラッグ(座標は tap と同じポイント座標)。press=静止時間で長押し→ドラッグを再現し、
    /// velocity=距離÷移動時間で「ゆっくりドラッグ(慣性なし)〜フリック」を再現する
    private func handleDrag(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(DragRequest.self, body)
        return try performDrag(req, in: try requireForegroundAppForGesture())
    }

    /// ドラッグの実体。**`/systemui/drag` と共有する**(原点にするアプリだけが違う)
    private func performDrag(_ req: DragRequest, in app: XCUIApplication) throws
        -> BridgeHTTPServer.Response {
        guard req.fromX.isFinite, req.fromY.isFinite, req.toX.isFinite, req.toY.isFinite else {
            throw BridgeError(400, "drag coordinates must be finite (got fromX=\(req.fromX)"
                + " fromY=\(req.fromY) toX=\(req.toX) toY=\(req.toY))")
        }
        let from = coordinate(app, CGPoint(x: req.fromX, y: req.fromY))
        let to = coordinate(app, CGPoint(x: req.toX, y: req.toY))
        let press = max(req.press ?? 0.05, 0.05)
        if let violation = BridgeAPI.gestureDurationViolation("drag", seconds: press,
                                                               cap: BridgeAPI.gestureSecondsCeiling) {
            throw BridgeError(400, violation)
        }
        guard let requestedDuration = req.duration else {
            from.press(forDuration: press, thenDragTo: to)
            return .json(OKResponse())
        }
        let distance = hypot(req.toX - req.fromX, req.toY - req.fromY)
        let duration = max(requestedDuration, 0.05)
        // velocity の単位は pt/秒。極端値はクランプ(0除算・非現実的な速度の防止)
        let velocity = max(10.0, min(distance / duration, 5000.0))
        // クランプ後の velocity で実際の所要を見積もる(requestedDuration は上限クランプが無いため、
        // これを検査しないと distance が大きいときに velocity 5000 クランプ越しでも長時間になる)
        if let violation = BridgeAPI.gestureDurationViolation("drag", seconds: press + distance / velocity,
                                                               cap: BridgeAPI.gestureSecondsCeiling) {
            throw BridgeError(400, violation)
        }
        // **thenHoldForDuration に正の値を渡しても慣性は消えない**(2026-08-02 実測。
        // 指を保持するだけでイベントが出ず velocity 計算が更新されない)。0 のままにすること
        from.press(forDuration: press, thenDragTo: to,
                   withVelocity: XCUIGestureVelocity(velocity), thenHoldForDuration: 0)
        return .json(OKResponse())
    }

    /// ダブルタップ(座標は tap と同じポイント座標)。**2回の /tap に分けない** ——
    /// ホストとの往復が入ると OS のダブルタップ判定時間を超えて単タップ2回になる。
    ///
    /// **`XCUICoordinate.doubleTap()` は React Native では拾われない**(実測 2026-09-24: XCTest は
    /// 1つのタッチに tapCount=2 を付けて送るだけで、RN の PanResponder はこれを**単タップ**としか
    /// 数えない)。座標ジェスチャの非公開 API があるときは**2本の独立したタッチ**として送る
    /// (`doubleTapTouchDuration` / `doubleTapSecondTouchDelay`。RN・Flutter はこの形を拾う。
    /// **Compose Multiplatform(iOS)はどちらの形も拾わない** —— XCTest 合成タッチはダブルタップとして
    /// 一度も登録されない)。**API が無いときは** `XCUICoordinate.doubleTap()` へ縮退する
    private func handleDoubleTap(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(TapRequest.self, body)
        let app = try requireForegroundAppForGesture()
        let point = try resolvePoint(ref: req.ref, x: req.x, y: req.y)
        if CoordinatePinch.isAvailable {
            try CoordinatePinch.synthesize(
                fingers: [
                    [(point: point, offset: 0), (point: point, offset: Self.doubleTapTouchDuration)],
                    [(point: point, offset: Self.doubleTapSecondTouchDelay),
                     (point: point, offset: Self.doubleTapSecondTouchDelay + Self.doubleTapTouchDuration)],
                ],
                name: "fleetest doubletap",
                orientation: appOrientation() == .landscape ? .landscapeLeft : .portrait)
            return .json(OKResponse())
        }
        try FastInput.with(req.fast) {
            coordinate(app, point).doubleTap()
        }
        return .json(OKResponse())
    }

    /// 各タッチの接触時間[秒]。実測 2026-09-24 でこの長さのときだけ RN の PanResponder が拾った
    private static let doubleTapTouchDuration: TimeInterval = 0.08
    /// 1本目が触れてから2本目が触れるまでの間隔[秒](= OS のダブルタップ判定窓の内側。
    /// 1本目は `doubleTapTouchDuration` で離れているので、2本目の直前には
    /// 0.25 - 0.08 = 0.17 秒の空きができる)
    private static let doubleTapSecondTouchDelay: TimeInterval = 0.25

    /// gesture / pinch が共有する指の検査(本数・点数・時刻の単調性・全体の秒数)。上限は
    /// `BridgeAPI.gestureMaxFingers` / `.gestureMaxPointsPerFinger`(BridgeDTO.swift はこのターゲットの
    /// 入力集合。ホストと MCP の門(`FTCore.TouchGesture.validate`)と同じ値で、ここは古いホスト・
    /// 直叩きから testmanagerd を守る**最後の砦**)
    private func validateFingers(_ fingers: [GestureFinger], what: String) throws {
        guard !fingers.isEmpty, fingers.count <= BridgeAPI.gestureMaxFingers else {
            throw BridgeError(400, "a gesture needs 1 to \(BridgeAPI.gestureMaxFingers) fingers"
                + " (got \(fingers.count))")
        }
        for (index, finger) in fingers.enumerated() {
            guard finger.points.count >= 2, finger.points.count <= BridgeAPI.gestureMaxPointsPerFinger else {
                throw BridgeError(400, "finger \(index + 1) needs 2 to \(BridgeAPI.gestureMaxPointsPerFinger)"
                    + " points (got \(finger.points.count))")
            }
            var previousTime = -Double.infinity
            for point in finger.points {
                guard point.x.isFinite, point.y.isFinite, point.t.isFinite,
                      point.t >= 0, point.t >= previousTime else {
                    throw BridgeError(400, "finger \(index + 1) has a point with non-finite"
                        + " coordinates, or a time that goes backwards")
                }
                previousTime = point.t
            }
        }
        let total = fingers.compactMap { $0.points.last?.t }.max() ?? 0
        if let violation = BridgeAPI.gestureDurationViolation(what, seconds: total,
                                                               cap: BridgeAPI.gestureSecondsCeiling) {
            throw BridgeError(400, violation)
        }
    }

    /// 2本指のピンチ。**指の置き方はホストが決める**(`FTCore.PinchGesture`。1つの規則を OS ごとに
    /// 持つのは `BridgeDTO.PinchRequest.fingers` のドキュメント参照)—— ここは指を組まず、座標ジェスチャの
    /// 非公開 API(`CoordinatePinch`)があればそれをそのまま再生するだけ。**API が無いときだけ**
    /// `XCUIElement.pinch(withScale:velocity:)` へ縮退する(XCUICoordinate は単点のみで座標指定の
    /// 多点ジェスチャを持たないため要素単位になる)。identifier で対象を引き、見つからなければ
    /// アプリ全体をピンチして注記を返す。
    ///
    /// velocity(scale/秒)は**符号が scale と食い違うと XCTest が例外を投げる**ので、要素ピンチの
    /// 経路だけ scale と所要時間から導出する。
    private func handlePinch(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(PinchRequest.self, body)
        let app = try requireForegroundAppForGesture()
        guard req.scale > 0, req.scale != 1, req.scale.isFinite else {
            throw BridgeError(400, "scale must be positive, finite and not 1 (got \(req.scale))")
        }
        let duration = max(req.durationSeconds ?? 0.5, 0.05)
        // requestedDuration 自体は下限クランプしか無い(座標ジェスチャへそのまま渡る)ので、
        // ここで先に断る
        if let violation = BridgeAPI.gestureDurationViolation("pinch", seconds: duration,
                                                               cap: BridgeAPI.gestureSecondsCeiling) {
            throw BridgeError(400, violation)
        }
        // **ホストが組んだ指の経路があり、座標ジェスチャの API が使えるならそちらを再生する**。
        // identifier は要素ピンチ(下)だけが読む——ここでは対象を選ばない
        if let fingers = req.fingers, CoordinatePinch.isAvailable {
            try validateFingers(fingers, what: "pinch")
            try CoordinatePinch.synthesize(
                fingers: fingers.map { finger in
                    finger.points.map { (point: CGPoint(x: $0.x, y: $0.y), offset: $0.t) }
                },
                name: "fleetest pinch",
                orientation: appOrientation() == .landscape ? .landscapeLeft : .portrait)
            return .json(OKResponse())
        }
        var target: XCUIElement = app
        var note: String?
        if let identifier = req.identifier {
            let matched = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
            if matched.exists {
                target = matched
            } else {
                note = "identifier [\(identifier)] not found; pinched the whole app instead"
            }
        }
        if req.fingers != nil {
            // **縮退したことは必ず言う**(黙ると「縮小したのにパンした」の理由が読めない)
            note = [note, "no coordinate pinch in this Xcode (XCPointerEventPath is gone), so the"
                + " fingers came from the element's frame — a zoom out can be taken by whatever"
                + " sits on its edge"].compactMap { $0 }.joined(separator: " / ")
        }
        // 拡大は正・縮小は負の velocity。極端値は避ける(0.1〜10 scale/秒)
        let magnitude = min(max(abs(req.scale - 1) / duration, 0.1), 10)
        // `magnitude` の下限クランプ(0.1)が実際の所要を `duration` から引き離す(scale が
        // 大きいほど `abs(scale-1)/magnitude` が伸びる)ので、渡す velocity から逆算した
        // 見積もりで検査する
        if let violation = BridgeAPI.gestureDurationViolation("pinch", seconds: abs(req.scale - 1) / magnitude,
                                                               cap: BridgeAPI.gestureSecondsCeiling) {
            throw BridgeError(400, violation)
        }
        target.pinch(withScale: CGFloat(req.scale),
                     velocity: req.scale > 1 ? magnitude : -magnitude)
        return .json(OKResponse(note: note))
    }

    /// 指ごとの時刻つき経路をまとめて1本のタッチ列として再生する(DSL `gesture` / MCP `ft_gesture`)。
    /// 座標は他の座標系コマンドと同じ画面座標(pt。snapshot の screen と同じ系)。
    ///
    /// **ホストは `FTCore.TouchGesture.validate` を通した形だけを送る**が、ここでも同じ規則で
    /// 検査する(`validateFingers`。/pinch の座標ピンチ経路と共有)。**フォールバック無し** ——
    /// `/pinch` は要素ピンチへ縮退できるが、多点の時刻つき経路には公開 API の代替が無いので、
    /// 座標ピンチが無い Xcode では 422 を返すだけ
    private func handleGesture(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(GestureRequest.self, body)
        // 前面確認のみ(座標は CoordinatePinch が直接送るので `app` 自体は使わない。/pinch の
        // 座標ピンチ経路と同じ —— coordinate(app, point) を経由しない)
        _ = try requireForegroundAppForGesture()
        try validateFingers(req.fingers, what: "gesture")
        // **501 にしない** —— ホストは 501 を「このエンジンでは無理」と読んで typeDriver へ回すが、
        // XCUITest ランナー自身が回送先なので自分に戻る(501 は hideKeyboard の1箇所だけ)
        guard CoordinatePinch.isAvailable else {
            throw BridgeError(422, "this Xcode has no coordinate gesture support (XCPointerEventPath /"
                + " XCSynthesizedEventRecord are gone), so a multi-finger timed gesture cannot be sent."
                + " There is no fallback for this route on the XCUITest runner")
        }
        try CoordinatePinch.synthesize(
            fingers: req.fingers.map { finger in
                finger.points.map { (point: CGPoint(x: $0.x, y: $0.y), offset: $0.t) }
            },
            name: "fleetest gesture",
            orientation: appOrientation() == .landscape ? .landscapeLeft : .portrait)
        return .json(OKResponse())
    }

    /// POST /rotate. See InAppBridge.handleRotate for why this polls (XCUIDevice's readback is
    /// immediate per PoC, but the shared budget/behavior stays symmetric across both iOS bridges).
    /// **No requireApp()**: rotation is device-level, not app-session-scoped (same as handleAppState).
    /// **セッションがあるときは前面で生きていることを先に確かめる**(`requireForegroundAppForRotation`)——
    /// 判定はアプリの窓を読むので、落ちた・背面のアプリで読むとランナーごと消える
    /// (2026-09-19 負荷テスト: クラッシュ後の ft_rotate でブリッジが消え、以後 881 回「no running bridge」)
    private func handleRotate(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(RotateRequest.self, body)
        if app != nil { _ = try requireForegroundAppForRotation() }
        // 契約は「アプリの UI が横になること」で物理方向は約束しない(FTOrientation の宣言を参照)
        // ので、`UIDeviceOrientation` と `UIInterfaceOrientation` の左右が逆であることは問題に
        // ならない —— どちらの landscape でも成功とする(読み側も左右をまとめている)
        let target: UIDeviceOrientation
        switch req.orientation {
        case .portrait: target = .portrait
        case .landscape: target = .landscapeLeft
        }
        XCUIDevice.shared.orientation = target
        // **アプリの窓で判定する**(デバイスの向きではない)。契約は「アプリの UI がその向きに
        // なること」で、**縦向き専用のアプリはデバイスを回しても縦のまま** —— XCUIDevice の
        // 向きだけを見ると、そういうアプリで**成功を返してしまう**
        // (2026-08-10 実測: 縦専用の React Native SUT が xcuitest では成功・in-app では 422 と
        // 食い違った)。Android の判定(スナップショットの画面サイズ)と同じ基準に揃える
        let deadline = Date().addingTimeInterval(RotationSettle.deadlineSeconds)
        while Date() < deadline {
            if appOrientation() == req.orientation {
                return .json(RotateResponse(orientation: req.orientation))
            }
            Thread.sleep(forTimeInterval: RotationSettle.pollIntervalSeconds)
        }
        if let app, app.state != .runningForeground {
            throw BridgeError(422, "the session's app (\(sessionBundleID ?? "?")) left the foreground or stopped"
                + " while waiting for the rotation to \(req.orientation.rawValue), so it could not be confirmed."
                + " Bring it back first (DSL: launchApp / MCP: ft_launch \(sessionBundleID ?? "<bundleId>"))")
        }
        throw BridgeError(422, "orientation did not settle to \(req.orientation.rawValue) within "
            + "\(RotationSettle.deadlineSeconds)s (the app stayed "
            + "\(appOrientation()?.rawValue ?? "unknown") — an app that does not declare that "
            + "orientation in UISupportedInterfaceOrientations cannot rotate)")
    }

    private func handlePress(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(PressRequest.self, body)
        if let violation = BridgeAPI.gestureDurationViolation("press", seconds: req.duration,
                                                               cap: BridgeAPI.gestureSecondsCeiling) {
            throw BridgeError(400, violation)
        }
        let app = try requireForegroundAppForGesture()
        let point = try resolvePoint(ref: req.ref, x: req.x, y: req.y)
        try FastInput.with(req.fast) {
            coordinate(app, point).press(forDuration: req.duration)
        }
        return .json(OKResponse())
    }

    private func handleScreenshot() -> BridgeHTTPServer.Response {
        .png(XCUIScreen.main.screenshot().pngRepresentation)
    }

    /// **ホームボタン機かどうか**(iPhone に限る)。ホームボタン機では画面下端から上へのスワイプは
    /// **仕様上コントロールセンター**で、アプリスイッチャーはホームボタンの2度押しなので、
    /// Face ID 機のジェスチャをそのまま撃つと**黙って別の面が開く**(2026-08-28・実機
    /// iPhone SE 第3世代で実測。`ft_navigate appSwitcher` がコントロールセンターを開いていた)。
    ///
    /// 判定そのものは **`BridgeAPI.isHomeButtonPhoneScreen` の1箇所**(閾値・実測値・iPad の
    /// 扱いはそちらの doc)。ここは画面寸法を渡すだけ —— 2つ目の閾値を作らない
    private func isHomeButtonPhone(_ sb: XCUIApplication) -> Bool {
        let f = sb.frame
        return BridgeAPI.isHomeButtonPhoneScreen(width: Double(f.width), height: Double(f.height))
    }

    /// 画面下端からのスワイプ上げ+ホールドでアプリスイッチャーを開く(Face ID 機にはホームボタン
    /// APIが無いためジェスチャで行う)。座標は springboard 参照(セッション不要・HID合成なので
    /// 前面アプリに関係なく効く)。velocity/hold はシミュレータ実機で調整済みの値。
    ///
    /// **ホームボタン機では開けないので断る**(2026-08-28・実機 iPhone SE3 で2案とも実測):
    /// ⑴ このジェスチャは**コントロールセンターが開くだけ**(下端スワイプの意味が機種で違う)
    /// ⑵ `XCUIDevice.press(.home)` の2連打も**ホームに戻るだけ**でスイッチャーにならない
    /// (XCUITest の press は同期実行で、ダブルプレスとして解釈される間隔に入らない)。
    /// どちらも **ok を返しながら別の画面になる**ので、呼び手は永久に気付けない。
    /// スイッチャーはハードウェアボタンの2度押しで、送る手段が無い —— **黙って別のことを
    /// するより断る**。**501 にしない**(501 は「このエンジンでは不可 = 他エンジンへ
    /// フォールバックせよ」の意味で、実機には代わりのエンジンが無い。BridgeRouterStatusContractTests)
    private func handleAppSwitcher() throws -> BridgeHTTPServer.Response {
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if isHomeButtonPhone(sb) {
            throw BridgeError(422, "the app switcher cannot be opened on a home-button iPhone:"
                + " the bottom-edge swipe up is Control Center by design, and the switcher is a"
                + " hardware double-press XCUITest cannot send. Switch apps with a launch instead"
                + " (DSL: launchApp / MCP: ft_launch <bundleId>).")
        }
        let start = sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.999))
        let end = sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48))
        start.press(forDuration: 0.1, thenDragTo: end,
                    withVelocity: XCUIGestureVelocity(500), thenHoldForDuration: 1.0)
        return .json(OKResponse())
    }

    /// ホーム画面に戻る(セッション不要)。
    /// **実機では `XCUIDevice.press(.home)` が黙って効かない**(2026-08-05 実測:
    /// iPhone 15 Pro / iOS 26.5.2 で ok を返すのにアプリが前面のまま。同じ端末で
    /// スワイプ系[appswitcher]は効くので、ジェスチャではなく API 側の問題)。
    /// そこで実機だけ springboard の下端スワイプで代替する —— ホールドしなければ
    /// アプリスイッチャーではなくホームに戻る(handleAppSwitcher と同じ座標系)。
    /// シミュレータは press(.home) が確実に効くので変えない(ジェスチャに一本化すると
    /// 既存の全シナリオの前提を実測せずに動かすことになる)
    /// ホームへ戻す。**押しただけで信じない**: セッションのアプリが前面から外れたことを `app.state` で確かめ、
    /// 外れなければ押し直す(最大 `homeAttempts` 回)。物理 iPhone SE3 で `press(.home)` が ok を返しながら
    /// アプリが前面のままの回が 12 回中 8 回あった(2026-09-12。同日の再計測では 12/12 効いた = 間欠)。
    /// `app.state` は物理 iPhone(SE3 / 13)とも押して 1 秒以内に background を返す(12/12 実測)ので、
    /// 待ちの上限 `homeSettleSeconds` はその倍。セッションが無い・SpringBoard 自身のときは確かめようが
    /// 無いので1回だけ送る
    private static let homeAttempts = 3
    private static let homeSettleSeconds = 2.0
    private func handleHome() throws -> BridgeHTTPServer.Response {
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let verifiable = app.map { $0.state == .runningForeground && sessionBundleID != "com.apple.springboard" } ?? false
        for attempt in 1...Self.homeAttempts {
            sendHome(sb)
            guard verifiable, let app else { break }
            let deadline = Date().addingTimeInterval(Self.homeSettleSeconds)
            var left = false
            while Date() < deadline {
                if app.state != .runningForeground { left = true; break }
                // **Thread.sleep にしない**: XCTest は状態の更新を run loop で受けるので、寝ている間は
                // `app.state` が前面のまま止まり、期限まで待ち切ってから押し直す形になる(実測 3.3 秒)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            }
            if left { break }
            if attempt == Self.homeAttempts {
                throw BridgeError(422, "the home gesture was sent \(attempt) times but \(sessionBundleID ?? "the app")"
                    + " is still in the foreground (XCUIDevice.press(.home) can be swallowed on physical devices)."
                    + " Retry, or bring the home screen up by hand")
            }
        }
        return .json(OKResponse())
    }

    private func sendHome(_ sb: XCUIApplication) {
        #if targetEnvironment(simulator)
        XCUIDevice.shared.press(.home)
        #else
        // **速い短フリック**でないとアプリスイッチャーが開く(実測: 下端から画面の 1/4 強を
        // 0.08 秒で駆け上がるとホーム・ゆっくり長く引くとスイッチャー)。
        // 数値は iPhone 15 Pro / iOS 26.5.2 で確認した値
        // **ホームボタン機は下端スワイプがコントロールセンター**なので、ここでもジェスチャを
        // 使わずハードウェアボタンを押す(2026-08-28・iPhone SE3 で appswitcher 側の実害を確認)
        if isHomeButtonPhone(sb) {
            XCUIDevice.shared.press(.home)
            return
        }
        let start = sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995))
        let end = sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.73))
        // press は 0 にしない(タッチダウンが載らず不発になる。handleDrag の下限 0.05 と同じ)
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(2850),
                    thenHoldForDuration: 0.0)
        #endif
    }

    private func handleTerminate() throws -> BridgeHTTPServer.Response {
        let app = try requireApp()
        // 未起動での terminate() は NSException(Code=10001「is not running」)を投げ、
        // BridgeHTTPServer の例外シムで 500 化する。state で回避し、
        // チェック〜呼び出し間のレースで投げられた「is not running」だけは握り潰して冪等にする。
        if app.state != .notRunning && app.state != .unknown {
            if let ex = FTCatchObjCException({ app.terminate() }), !ex.contains("is not running") {
                throw BridgeError(500, "could not terminate the app: \(ex)")
            }
        }
        self.app = nil
        sessionBundleID = nil
        refFrames = [:]
        refIdentity = [:]
        refElements = [:]
        return .json(OKResponse())
    }

    /// フォアグラウンドのアプリが bundleID と一致するか(DSL の appIs)。**requireApp() を使わない**
    /// — このルートはセッション対象アプリに依存しない読み取りで、任意の bundleID を照会できる
    private func handleAppState(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(AppStateRequest.self, body)
        // **セッションのアプリなら、保持しているインスタンスに聞く**。同じアプリでも
        // その場で作った proxy の `.state` は実機で `.runningForeground` を返さないことがある
        // (2026-09-05 実測・iPhone SE3 / iOS 26.6: 画面には出ているのに 15/15 で false。
        // 同時刻に `requireForegroundApp()` の `app.state` は通っていた = 保持側が正しい)。
        // 嘘の側を配ると `ft_snapshot` が毎回「前面に居ない・木は古い」と警告し、
        // **正しい ref を信じるなと言い続ける**(DSL の `appIs` も同じ嘘を受け取る)。
        // セッション外の bundleID は従来どおり新規 proxy —— この口の「任意のアプリを
        // 照会できる」性質(requireApp() を使わない理由)を壊さない
        let target = (req.bundleID == sessionBundleID ? app : nil)
            ?? XCUIApplication(bundleIdentifier: req.bundleID)
        return .json(AppStateResponse(foreground: target.state == .runningForeground))
    }

    // MARK: - Helpers

    /// **操作系(tap/type/pressEnter/swipe/drag/press)専用**の生存確認。
    ///
    /// XCUI の操作が失敗すると `_XCUIFailWithError` が issue を記録するが、ハンドラは
    /// **main queue 上 = テストメソッドのスタックの外**で動く(BridgeHTTPServer.dispatchToMain)。
    /// XCUITest は「現在のテスト」を特定できず `XCTFallbackIssueHandler` へ回し、そこから
    /// Xcode 27 beta の XCTest↔swift-testing 相互運用が**無限再帰してランナーごと落ちる**
    /// (2026-07-28 実測: 950 段超のスタックオーバーフローで SIGSEGV。`Failed to application
    /// ... is not running` が起点)。**`continueAfterFailure` も FTCatchObjCException も効かない**
    /// (issue がテストケースに届かない / ObjC 例外ではない)。
    /// ランナーが死ぬとブリッジが消えて run 全体のワーカーが離脱するため、**XCUI に触れる前**に
    /// 弾いて HTTP エラーで返す。
    ///
    /// - snapshot/screenshot には入れない: `state` は IPC で毎回コストがかかるうえ、
    ///   これらは失敗しても issue を出さない(取得系)
    /// - **503 であることに意味がある**: 409 はセッション消失専用(`SessionRecoveryDriver` が
    ///   activate で復帰を試み、in-app では dylib 無しでアプリが起動してブリッジが戻らなくなる)、
    ///   501/404 は「このエンジンでは不可」= XCUITest へのフォールバック判定に使われている
    private func requireLiveApp() throws -> XCUIApplication {
        let app = try requireApp()
        guard app.state != .notRunning, app.state != .unknown else {
            throw BridgeError(503, "the target app (\(sessionBundleID ?? "?")) is not running, so"
                + " it cannot be driven (it may have exited or crashed in an earlier step; the host"
                + " relaunches it with /session)")
        }
        return app
    }

    /// **取得系(snapshot/hittable)専用**の前面確認。
    ///
    /// セッションのアプリが**前面から外れている**間に木を撮ると、XCUI が対象を引けず
    /// `Find the Application '<bundle>'` を約45秒リトライした末に**ランナーごと落ちる**
    /// (2026-08-15 実測 6/6。ログの最終行は必ずこのリトライで、続いて "Restarting after
    /// unexpected exit, crash, or test timeout" → 建て直されたランナーは 0 tests で
    /// スイート終了 = **ブリッジが永久に消える**)。`requireLiveApp` は `.notRunning`/`.unknown`
    /// しか弾かないので、**背面(`.runningBackground`)は掛けても素通りする**。
    ///
    /// - `/screenshot` 自体は `XCUIScreen` なのでアプリに触れないが、MCP の `ft_screenshot` が
    ///   鮮度判定のため直後に snapshot を撃ち、その失敗を `try?` で握り潰す ——
    ///   **画像を返したままブリッジだけ死ぬ**ので、ここを塞げば両方が塞がる
    /// - **springboard は他アプリが前面でも `.runningForeground` を名乗る**(2026-08-15 実測)。
    ///   システム UI を読む `ft_launch com.apple.springboard` の経路は塞がらない
    /// - **409 でも 503 でもなく 422**: 409 はセッション消失専用、503 は `AppAttachDriver` が
    ///   activate で復帰を試みる = **呼び手に黙ってアプリを前面へ引き戻す**。ここは
    ///   「セッションはあるが今のこの画面では実行できない」なので 422(handleClear と同じ理由)
    /// - `state` の実測コストは 1.5ms 未満(`/appstate` の HTTP 往復込み)。45 秒とブリッジ喪失に
    ///   対して十分安い。**取得系を外していた元の判断はこのコストだけを見ていた**
    /// **入力系(/type /clear /pressEnter)専用**の前面確認。ref 無し・入力欄でない ref の経路は
    /// 焦点のライブクエリ(`focusMark` / `hasKeyboardFocus`)を撃つが、セッションのアプリが背面だと
    /// そのクエリが刺さって XCTest が Tear Down し**ランナーごと落ちる**(2026-09-11 物理 iPhone 13:
    /// `ft_navigate home` → `ft_type` で 8151 が消えた)。`requireLiveApp`(死活だけ)では足りない。
    /// **422** = セッションはあるが今は無理(409 は requireApp 専用。BridgeRouterStatusContractTests)
    func requireForegroundAppForInput() throws -> XCUIApplication {
        let app = try requireLiveApp()
        guard app.state == .runningForeground else {
            throw BridgeError(422, "the session's app (\(sessionBundleID ?? "?")) is not in the foreground,"
                + " so nothing can be typed into it (querying its keyboard focus in this state takes the"
                + " runner down). Bring it back first (DSL: launchApp / MCP: ft_launch \(sessionBundleID ?? "<bundleId>")"
                + " — resume: true keeps its state)")
        }
        return app
    }

    /// **ジェスチャ系(/tap /swipe /drag /doubleTap /pinch /press)専用**の前面確認(§3.1 の残件。
    /// 2026-09-14 物理 SE3: `ft_navigate home` → 座標 `ft_tap` でランナーが落ちた)。座標ジェスチャは
    /// `app.coordinate(...)` が **Find the Application** を撃ち、ref 形は要素のライブクエリを撃つ ——
    /// どちらもセッションのアプリが背面だと刺さって XCTest が Tear Down し**ランナーごと落ちる**。
    /// 入力系(`requireForegroundAppForInput`)と同じ 422(セッションはあるが今は無理)。
    /// **`/systemui/drag` は通らない**(SpringBoard を原点にする = 常に前面)
    private func requireForegroundAppForGesture() throws -> XCUIApplication {
        let app = try requireLiveApp()
        guard app.state == .runningForeground else {
            throw BridgeError(422, "the session's app (\(sessionBundleID ?? "?")) is not in the foreground,"
                + " so the gesture cannot be sent to it (locating its window in this state takes the"
                + " runner down). Bring it back first (DSL: launchApp / MCP: ft_launch \(sessionBundleID ?? "<bundleId>")"
                + " — resume: true keeps its state), or point the session at what IS in front"
                + " (MCP: ft_launch com.apple.springboard for the home screen)")
        }
        return app
    }

    /// **回転(/rotate)専用**の前面確認。判定にアプリの窓(`app.frame`)を読むので、ジェスチャ系と同じく
    /// 落ちたアプリ(503 = requireLiveApp)・背面のアプリ(422)では撃たない
    private func requireForegroundAppForRotation() throws -> XCUIApplication {
        let app = try requireLiveApp()
        guard app.state == .runningForeground else {
            throw BridgeError(422, "the session's app (\(sessionBundleID ?? "?")) is not in the foreground,"
                + " so it cannot be rotated (reading its window in this state takes the runner down)."
                + " Bring it back first (DSL: launchApp / MCP: ft_launch \(sessionBundleID ?? "<bundleId>")"
                + " — resume: true keeps its state)")
        }
        return app
    }

    private func requireForegroundApp() throws -> XCUIApplication {
        let app = try requireApp()
        guard app.state == .runningForeground else {
            throw BridgeError(422, "the session's app (\(sessionBundleID ?? "?")) is not in the"
                + " foreground — another app is. Reading the tree in this state hangs XCUITest and"
                + " takes this runner (and the bridge) down with it, so it is refused. Bring it back"
                + " (DSL: launchApp / MCP: ft_launch \(sessionBundleID ?? "<bundleId>")), or point"
                + " the session at whatever IS in front (MCP: ft_launch with that bundle id;"
                + " com.apple.springboard reads the home screen or a system dialog)")
        }
        return app
    }

    private func requireApp() throws -> XCUIApplication {
        guard let app else {
            // status は 409 のまま変えないこと(ホスト側 SessionRecoveryDriver がこの1箇所の
            // 409 だけを「セッション消失」と断定して判定に使う)
            throw BridgeError(409, "the XCUITest runner has no session (it may have been lost to a"
                + " runner restart); the host re-establishes it with /session")
        }
        return app
    }

    func resolvePoint(ref: Int?, x: Double?, y: Double?) throws -> CGPoint {
        if let ref {
            guard let frame = refFrames[ref] else {
                throw BridgeError(404, "unknown reference number [\(ref)] — run GET /snapshot first")
            }
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        if let x, let y {
            return CGPoint(x: x, y: y)
        }
        throw BridgeError(400, "either ref or x/y is required")
    }

    func coordinate(_ app: XCUIApplication, _ point: CGPoint) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: point.x, dy: point.y))
    }

    func decode<T: Decodable>(_ type: T.Type, _ body: Data) throws -> T {
        do {
            return try decoder.decode(type, from: body)
        } catch {
            throw BridgeError(400, "malformed JSON in the request body: \(error)")
        }
    }
}

private extension UIDeviceOrientation {
    var ftOrientation: FTOrientation? {
        switch self {
        case .portrait: return .portrait
        // 左右どちらも landscape として読む(要求と同じ側かは問わない = 契約どおり)
        case .landscapeLeft, .landscapeRight: return .landscape
        default: return nil   // upsideDown/faceUp/faceDown/unknown — not part of FTOrientation
        }
    }
}
