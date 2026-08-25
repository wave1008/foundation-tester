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
    private var refElements: [Int: ElementInfo] = [:]
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
    private var snapshotElementLimit = BridgeAPI.maxSnapshotElements

    /// /status の idleSeconds 申告用(FTesterBridgeTests がサーバ生成後に配線する。
    /// サーバ⇔ルーターの生成順の都合でコンストラクタ注入にしない)
    var idleSecondsProvider: (() -> TimeInterval)?

    private let decoder = JSONDecoder()

    // 画面を変えうる操作。直後の snapshot だけ整定確認する(handleSnapshot の settlePending)。
    //
    // **/swipe と /drag は入れない**(2026-07-30)。スクロール慣性は budget 内で収束しないので
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
            case ("GET", "/systemui/snapshot"): response = try handleSystemUISnapshot(request)
            case ("POST", "/systemui/tap"): response = try handleSystemUITap(request.body)
            case ("POST", "/tap"): response = try handleTap(request.body)
            case ("POST", "/type"): response = try handleType(request.body)
            case ("POST", "/clear"): response = try handleClear(request.body)
            case ("POST", "/pressEnter"): response = try handlePressEnter()
            case ("POST", "/hidekeyboard"): response = try handleHideKeyboard()
            case ("POST", "/swipe"): response = try handleSwipe(request.body)
            case ("POST", "/drag"): response = try handleDrag(request.body)
            case ("POST", "/doubletap"): response = try handleDoubleTap(request.body)
            case ("POST", "/pinch"): response = try handlePinch(request.body)
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

    private struct Captured {
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
    /// **固定 sleep をやめた理由**(2026-07-30 実測): 旧実装は一律 350ms 待っていたが、
    /// 必要量はマシン性能・並列負荷・アニメーション長に依存するため 1 つの定数では合わない。
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
    private func handleSystemUISnapshot(_ request: BridgeHTTPServer.Request) throws
        -> BridgeHTTPServer.Response {
        snapshotElementLimit = BridgeAPI.resolvedSnapshotElementLimit(
            request.queryValue("max").flatMap { Int($0) })
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let cap = try captureOnce(springboard)
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
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        coordinate(springboard, CGPoint(x: frame.midX, y: frame.midY)).tap()
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

    private func captureOnce(_ app: XCUIApplication) throws -> Captured {
        let root = try app.snapshot()
        let screen = root.frame
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

    private func handleTap(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(TapRequest.self, body)
        let app = try requireLiveApp()
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
            NSLog("[ftester] tapTiming total=%.0f quiesce=%.0f synth=%.0f", totalMs,
                  FastInput.quiescenceMs, totalMs - FastInput.quiescenceMs)
        }
        return .json(OKResponse())
    }

    /// **`typeText` が返ったことを完了の根拠にしない**(handleClear と同じ規律。2026-08-01)。
    /// 打鍵はキーボード(別プロセス)経由で**非同期に**アプリへ届くため、200 を返した時点では
    /// アプリの状態に入っていない。高負荷ではさらに取りこぼしも起きる。
    ///
    /// **実害**(フル E2E・2026-08-01): `type "#field_single" "persist99"` の直後の送信タップが
    /// **空の値で処理された**(失敗時の画面は `single=persist99` / `len=9` なのに `submitted=`)。
    /// タッチは直接アプリへ届くのに文字はキーボード経由で遅れるので、順序が入れ替わる。
    /// つまり「入っていない」ではなく「まだ入っていない」を 200 で隠していた。
    ///
    /// 対策は読み返し: 期待値(入力前の値 + 送る本文)になるまで待ち、
    ///   - 期待値の**前方一致で止まった**(= 打鍵の取りこぼし)→ 足りないぶんだけ追送
    ///   - 期待値を**含んで長い**(= 追送が二重に入った)→ 余分を delete で削る
    ///   - どちらでもない(自動修正・書式付け・マスク欄の `•••`)→ **検証を諦めて受理**
    ///     (嘘の成功は潰したいが、加工された入力を失敗にはしない)
    /// 上限は周回数ではなく deadline と進捗なし回数(handleClear と同じ設計)。
    ///
    /// **「値が変わらなくなる」まで待ってから追送する**のが肝。まだ届いていないだけの欄へ
    /// 追送すると同じ文字を2回入れる(Android の `InputInjector` で実害。
    /// docs/design.md §Android のテキスト注入の規律)。
    ///
    /// 検証できない経路(ref なし・テキスト欄でない対象・文中の改行)は従来どおり
    /// `app.typeText` を1回だけ送る。
    ///
    /// **読み返しはスナップショットで行い、ライブクエリ(`descendants` + `hasKeyboardFocus`)は
    /// 使わない**。ライブクエリは1回 0.5s 級で、happy path が倍以上遅くなる(実測: /type の
    /// p50 が 842ms → 2,166ms)。**打鍵も `app.typeText` のまま**にする —— 要素に対する
    /// `typeText` はイベント合成の失敗が XCTest の失敗になり**ランナーごと落ちる**
    /// (実測1件: 高負荷で `Type '...' into "field_single" TextView` の Synthesize event を
    /// 最後にランナーが死んだ)。
    private func handleType(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(TypeRequest.self, body)
        let app = try requireLiveApp()
        if let ref = req.ref {
            // tap() が quiescence まで待つため追加待ちは不要(旧: 固定400ms・keyboards クエリは
            // キーボードが別プロセス扱いのため常にタイムアウトし逆効果だった。2026-07-12実測)
            coordinate(app, try resolvePoint(ref: ref, x: nil, y: nil)).tap()
        }
        // 末尾の改行1つは本文と分けて送る(改行は Return キー相当で、値には残らない=検証対象外)。
        // 本文を入れ切ってから発火するので「空のまま送信された」も同時に塞げる
        let (main, hasTrailingNewline) = Self.splitTrailingNewline(req.text)
        // 入力前の値は**直近スナップショットの値をそのまま使う**(ホストは /type の直前に必ず
        // snapshot を撮っている)。ここで撮り直すと happy path に取得1回ぶん乗る
        guard !main.contains("\n"),
              let target = req.ref.flatMap({ refElements[$0] }),
              TypeReadback.isTextInput(target) else {
            app.typeText(req.text)
            return .json(OKResponse())
        }
        let expected = TypeReadback.normalizedValue(of: target) + main
        var pending = main
        var previous: String?
        var stagnantRounds = 0
        var rounds = 0
        let deadline = Date().addingTimeInterval(Self.typeBudgetSeconds)
        loop: while true {
            app.typeText(pending)
            rounds += 1
            // 読めない・曖昧 = 検証不能なので受理する(TypeReadback.value 参照)
            guard let actual = try awaitCommit(app, target: target,
                                               expected: expected, deadline: deadline) else { break }
            switch TypeReadback.plan(expected: expected, actual: actual) {
            case .done, .unverifiable:
                break loop
            case .resend(let missing):
                pending = missing
            case .deleteExcess(let count):
                pending = String(repeating: XCUIKeyboardKey.delete.rawValue, count: count)
            }
            stagnantRounds = (actual == previous) ? stagnantRounds + 1 : 0
            previous = actual
            if stagnantRounds >= Self.typeMaxStagnantRounds || Date() >= deadline {
                // 残った値そのものは出さない(パスワード欄も通る経路)。長さと周回数だけ出す。
                // **409 ではなく 422**(理由は handleClear のコメント)
                throw BridgeError(422, "the field did not end up holding the expected text"
                    + " (\(rounds) round(s) of keystrokes left \(actual.count) character(s)"
                    + " against the expected \(expected.count))")
            }
        }
        // 本文を入れ切ってから発火する(app 全体へ送るのは従来どおり。要素への typeText は
        // ランナーごと落ちうる)
        if hasTrailingNewline { app.typeText("\n") }
        return .json(OKResponse())
    }

    /// 入力の打ち切り時間(秒)と、値が変わらない周回の許容数。handleClear と同じ設計・同じ値
    /// (どちらも「1周まるごと打鍵が落ちる」ことがあるので 1 では早すぎる)
    private static let typeBudgetSeconds: TimeInterval = 8
    private static let typeMaxStagnantRounds = 4
    /// 追送に踏み切る前に「値が動かないこと」を確認する時間。**実測の反映遅れより十分長く取る**
    /// (6シミュレータ並列 + Android スイート並走で、打鍵が値に載るまでの実測は 0.7s 以下)。
    /// 短くすると、まだ届いていないだけの欄へ追送して二重入力になる
    private static let typeStableSeconds: TimeInterval = 1.5
    /// 読み返しの間隔。1回ごとにツリー取得(数十〜数百 ms)が乗るので、これ以上細かくしない
    private static let typePollSeconds: TimeInterval = 0.05

    /// 期待値になるまで待ち、最後に読めた値を返す(nil = 検証不能。TypeReadback.value 参照)。
    /// 抜ける条件は3つ: **期待値に一致** / **値が typeStableSeconds のあいだ変わらない** / deadline。
    /// 「変わらなくなるまで待つ」のが肝 —— 打鍵はキーボード(別プロセス)経由で非同期に届くので、
    /// まだ届いていない欄へ追送すると二重入力になる。
    /// 一致していれば最初の1取得で返るので、happy path に待ちは乗らない
    private func awaitCommit(_ app: XCUIApplication, target: ElementInfo,
                             expected: String, deadline: Date) throws -> String? {
        var lastValue = TypeReadback.value(of: target, in: try captureOnce(app).elements)
        var lastChange = Date()
        while true {
            guard let value = lastValue else { return nil }
            if value == expected { return value }
            if Date() >= deadline { return value }
            if Date().timeIntervalSince(lastChange) >= Self.typeStableSeconds { return value }
            Thread.sleep(forTimeInterval: Self.typePollSeconds)
            let current = TypeReadback.value(of: target, in: try captureOnce(app).elements)
            if current != lastValue {
                lastChange = Date()
                lastValue = current
            }
        }
    }

    /// 末尾の改行1つだけを本文から切り離す(text 全体が "\n" のときは分離しない)。
    /// InAppBridge / AndroidDriver の同名ヘルパと同じ規則 —— 「type の末尾改行 = pressEnter」が
    /// 3ブリッジ共通の契約
    private static func splitTrailingNewline(_ text: String) -> (main: String, hasTrailingNewline: Bool) {
        guard text != "\n", text.hasSuffix("\n") else { return (text, false) }
        return (String(text.dropLast()), true)
    }

    /// hasKeyboardFocus な要素を探して末尾へカーソルを送ってから delete を打つ。**文中をタップして
    /// delete すると左側の一部しか消えない**ため、必ず frame の右端近くをタップしてカーソルを
    /// 末尾に揃える。
    ///
    /// **周回数を固定しないこと**(2026-07-31 実測)。高負荷では `typeText` が打鍵を取りこぼし、
    /// 送った delete が全部は入らない —— 実測の失敗3件はいずれも
    /// `"hello123"(8打鍵)→"hel"`、`"hel"(3打鍵)→"h"` と、**毎周 6 割前後しか入らない**。
    /// 2周固定だった頃はここで打ち切られ「値が残っています」で落ちていた(高負荷で約 2%)。
    /// 残り文字数は単調に減るので、**空になるまで回せば収束する**。
    /// 上限は周回数ではなく deadline と「進捗なし」で持つ:
    /// 進捗なしを数えるのは、delete では消えない欄(入力を書き戻すバリデーション等)で
    /// deadline いっぱい叩き続けないため。通常は1周で終わるので速度は変わらない。
    ///
    /// **失敗は 409 ではなく 422**(2026-07-31 修正)。ここは「セッションはあるが今のこの画面では
    /// クリアできない」であって、`requireApp` のセッション消失とは別物。409 で返していた頃は
    /// `SessionRecoveryDriver` が**一律にセッション消失と断定**し、無用な activate を撃ったうえで
    /// 「ランナーが再起動した可能性」という誤った理由でステップを落としていた(実害: E2E の
    /// clearInput 失敗の原因が読めなかった)。**この経路で 409 を返さないこと** —
    /// XCUITest ランナーの 409 は `requireApp` の1箇所だけという不変条件を
    /// `BridgeRouterStatusContractTests` が守っている。
    /// 422 を選ぶ理由: 501/404 は「このエンジンでは不可」(XCUITest へのフォールバック判定)、
    /// 503 は「アプリが起動していない」に取られているため。
    /// ホスト側の `isClearInputFallback` は 409 と同じく 422 でもフォールバックを許すので、
    /// hybrid の in-app→XCUITest の再試行はこれまでどおり効く
    private func handleClear(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(ClearRequest.self, body)
        let app = try requireLiveApp()
        if let ref = req.ref {
            coordinate(app, try resolvePoint(ref: ref, x: nil, y: nil)).tap()
        }
        let focused = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        guard focused.exists else {
            // **原因を名指しする**(2026-08-12 のブラウザ監査): 「ref を指定してください」だけだと
            // ref を渡した呼び手が読む先を失う —— 実際に起きるのは「渡した ref が入力欄ではなく、
            // タップしても焦点が立たない容器だった」形(Safari の畳んだアドレスバー等)
            throw BridgeError(422, "nothing has keyboard focus, so there is no field to clear."
                + " If you passed a ref, it is probably not the input element itself — tapping a"
                + " container does not move focus. Tap the field (or pass the ref of the element"
                + " whose type is a text field) and try again")
        }
        let deadline = Date().addingTimeInterval(Self.clearBudgetSeconds)
        var previous: String?
        var stagnantRounds = 0
        var rounds = 0
        while let text = Self.remainingText(of: focused), !text.isEmpty {
            // 「打っても減らない」が続いたら delete では消せない欄。deadline まで叩かず抜ける
            stagnantRounds = (text == previous) ? stagnantRounds + 1 : 0
            if stagnantRounds >= Self.clearMaxStagnantRounds || Date() >= deadline { break }
            previous = text
            rounds += 1
            let frame = focused.frame
            coordinate(app, CGPoint(x: frame.maxX - 4, y: frame.midY)).tap()
            focused.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
        }
        if let residual = Self.remainingText(of: focused) {
            // 残った値そのものは出さない(パスワード欄も通る経路)。長さと周回数だけ出す
            throw BridgeError(422, "could not empty the field"
                + " (\(residual.count) character(s) still there after \(rounds) round(s))")
        }
        return .json(OKResponse())
    }

    /// クリアの打ち切り時間(秒)。実測では 8 文字が 3 周で空になるので、
    /// 長文でも収まるだけの余裕を持たせた上限
    private static let clearBudgetSeconds: TimeInterval = 8
    /// 残り文字数が変わらない周回の許容数。1周まるごと打鍵が落ちることがあるので 1 では早すぎる
    private static let clearMaxStagnantRounds = 4

    /// value が placeholder と一致/空なら nil(クリア済み扱い)を返す
    private static func remainingText(of element: XCUIElement) -> String? {
        guard let value = element.value as? String, !value.isEmpty else { return nil }
        if let placeholder = element.placeholderValue, value == placeholder { return nil }
        return value
    }

    /// typeText("\n") は XCUITest 内部で Return キー相当に落ちる(ソフトキーボードの改行/送信
    /// アクションを駆動する唯一の経路。ftester はキーボード要素を snapshot から除外しているため
    /// 実ソフトキー tap はできない)。
    ///
    /// hybrid(ios-inapp)では in-app 側が合成タッチでタップ・入力してフォーカスを立てているため、
    /// app 全体への typeText("\n") はフォーカス中の入力欄に届かないことがある。キーボード
    /// フォーカスを持つ要素を探し、見つかればそこへ typeText する。見つからない場合(engine=xcuitest
    /// 単独等、in-app がフォーカスを立てていないケース)は従来どおり app 全体へ送る。
    private func handlePressEnter() throws -> BridgeHTTPServer.Response {
        let app = try requireLiveApp()
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
    private func appOrientation() -> FTOrientation? {
        guard let app else { return XCUIDevice.shared.orientation.ftOrientation }
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
        let app = try requireLiveApp()
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
            let from = coordinate(app, CGPoint(x: path.fromX, y: path.fromY))
            let to = coordinate(app, CGPoint(x: path.toX, y: path.toY))
            FastInput.with(req.fast) {
                if let velocity {
                    from.press(forDuration: 0.05, thenDragTo: to,
                               withVelocity: velocity, thenHoldForDuration: 0)
                } else {
                    from.press(forDuration: 0.05, thenDragTo: to)
                }
            }
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

    /// 2点間ドラッグ(座標は tap と同じポイント座標)。press=静止時間で長押し→ドラッグを再現し、
    /// velocity=距離÷移動時間で「ゆっくりドラッグ(慣性なし)〜フリック」を再現する
    private func handleDrag(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(DragRequest.self, body)
        let app = try requireLiveApp()
        let from = coordinate(app, CGPoint(x: req.fromX, y: req.fromY))
        let to = coordinate(app, CGPoint(x: req.toX, y: req.toY))
        let press = max(req.press ?? 0.05, 0.05)
        guard let requestedDuration = req.duration else {
            from.press(forDuration: press, thenDragTo: to)
            return .json(OKResponse())
        }
        let distance = hypot(req.toX - req.fromX, req.toY - req.fromY)
        let duration = max(requestedDuration, 0.05)
        // velocity の単位は pt/秒。極端値はクランプ(0除算・非現実的な速度の防止)
        let velocity = max(10.0, min(distance / duration, 5000.0))
        // **thenHoldForDuration に正の値を渡しても慣性は消えない**(2026-08-02 実測。
        // 指を保持するだけでイベントが出ず velocity 計算が更新されない)。0 のままにすること
        from.press(forDuration: press, thenDragTo: to,
                   withVelocity: XCUIGestureVelocity(velocity), thenHoldForDuration: 0)
        return .json(OKResponse())
    }

    /// ダブルタップ(座標は tap と同じポイント座標)。**2回の /tap に分けない** ——
    /// ホストとの往復が入ると OS のダブルタップ判定時間を超えて単タップ2回になる。
    ///
    /// **ランナー内で2打に分けるのも不可**(2026-08-04 実測): `XCUICoordinate.tap()` は
    /// FastInput(quiescence スキップ)込みでも**1打 335ms** かかり、間隔を 60ms に詰めても
    /// 実際の2打間隔は約 400ms = 判定窓(約 300ms)を外れて単タップ2回になる。
    /// よって XCTest の `doubleTap()` に任せるしかない。
    /// **既知の穴**: この2打は間隔が詰まりすぎていて **Compose Multiplatform の iOS だけ拾えない**
    /// (`detectTapGestures` は最初の UP から `doubleTapMinTimeMillis` = 40ms 以内の DOWN を捨てる)。
    /// SwiftUI/UIKit・Flutter・Android は問題ない。詳細と回避策は docs/commands.md
    private func handleDoubleTap(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(TapRequest.self, body)
        let app = try requireLiveApp()
        let point = try resolvePoint(ref: req.ref, x: req.x, y: req.y)
        try FastInput.with(req.fast) {
            coordinate(app, point).doubleTap()
        }
        return .json(OKResponse())
    }

    /// 2本指のピンチ。**XCUITest には座標指定の多点ジェスチャが無い**(XCUICoordinate は単点のみ)ため、
    /// `XCUIElement.pinch(withScale:velocity:)` に落とすしかない = **要素単位**になる。
    /// identifier で対象を引き、見つからなければアプリ全体をピンチして注記を返す
    /// (ホストは PinchRequest.frame も送ってくるが、こちらでは使えない。Android 側が使う)。
    ///
    /// velocity(scale/秒)は**符号が scale と食い違うと XCTest が例外を投げる**ので、ここで
    /// scale と所要時間から導出する(ホストからは受け取らない = 不整合を作れなくする)。
    private func handlePinch(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(PinchRequest.self, body)
        let app = try requireLiveApp()
        guard req.scale > 0, req.scale != 1, req.scale.isFinite else {
            throw BridgeError(400, "scale must be positive, finite and not 1 (got \(req.scale))")
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
        let duration = max(req.durationSeconds ?? 0.5, 0.05)
        // 拡大は正・縮小は負の velocity。極端値は避ける(0.1〜10 scale/秒)
        let magnitude = min(max(abs(req.scale - 1) / duration, 0.1), 10)
        target.pinch(withScale: CGFloat(req.scale),
                     velocity: req.scale > 1 ? magnitude : -magnitude)
        return .json(OKResponse(note: note))
    }

    /// POST /rotate. See InAppBridge.handleRotate for why this polls (XCUIDevice's readback is
    /// immediate per PoC, but the shared budget/behavior stays symmetric across both iOS bridges).
    /// **No requireApp()**: rotation is device-level, not app-session-scoped (same as handleAppState).
    private func handleRotate(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(RotateRequest.self, body)
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
        throw BridgeError(422, "orientation did not settle to \(req.orientation.rawValue) within "
            + "\(RotationSettle.deadlineSeconds)s (the app stayed "
            + "\(appOrientation()?.rawValue ?? "unknown") — an app that does not declare that "
            + "orientation in UISupportedInterfaceOrientations cannot rotate)")
    }

    private func handlePress(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(PressRequest.self, body)
        let app = try requireLiveApp()
        let point = try resolvePoint(ref: req.ref, x: req.x, y: req.y)
        try FastInput.with(req.fast) {
            coordinate(app, point).press(forDuration: req.duration)
        }
        return .json(OKResponse())
    }

    private func handleScreenshot() -> BridgeHTTPServer.Response {
        .png(XCUIScreen.main.screenshot().pngRepresentation)
    }

    /// 画面下端からのスワイプ上げ+ホールドでアプリスイッチャーを開く(Face ID 機にはホームボタン
    /// APIが無いためジェスチャで行う)。座標は springboard 参照(セッション不要・HID合成なので
    /// 前面アプリに関係なく効く)。velocity/hold はシミュレータ実機で調整済みの値。
    private func handleAppSwitcher() throws -> BridgeHTTPServer.Response {
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
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
    private func handleHome() throws -> BridgeHTTPServer.Response {
        #if targetEnvironment(simulator)
        XCUIDevice.shared.press(.home)
        #else
        // **速い短フリック**でないとアプリスイッチャーが開く(実測: 下端から画面の 1/4 強を
        // 0.08 秒で駆け上がるとホーム・ゆっくり長く引くとスイッチャー)。
        // 数値は iPhone 15 Pro / iOS 26.5.2 で確認した値
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let start = sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995))
        let end = sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.73))
        // press は 0 にしない(タッチダウンが載らず不発になる。handleDrag の下限 0.05 と同じ)
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(2850),
                    thenHoldForDuration: 0.0)
        #endif
        return .json(OKResponse())
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
        let target = XCUIApplication(bundleIdentifier: req.bundleID)
        return .json(AppStateResponse(foreground: target.state == .runningForeground))
    }

    // MARK: - スナップショット収集・フィルタ

    /// 1パス目(gather)で拾った要素。ref はまだ未採番(0)
    private struct Gathered {
        var info: ElementInfo
        var frame: CGRect
    }

    /// **2パス化**: 1パス目(gather)は上限で打ち切らずに全件 preorder で集め、2パス目で
    /// dedupe → 間引き(超過時のみ)→ ref 採番を行う。
    /// **順序が要る**: SnapshotDedupe.isRedundant は「既に出したもの」基準なので、間引きより
    /// 先に全件へ通す(先に間引くと、落とした要素を基準にしていた冗長判定が変わる)。
    private func collect(_ node: XCUIElementSnapshot, depth: Int, screen: CGRect,
                         elements: inout [ElementInfo], frames: inout [Int: CGRect],
                         identities: inout [Int: (identifier: String?, label: String?, type: String)],
                         truncated: inout Int,
                         truncatedTiers: inout [String: Int],
                         bulkExempt: inout Int,
                         keyboardFrame: inout CGRect?,
                         offscreenHints: inout [ElementInfo],
                         insideWebView: Bool = false) {
        var gathered: [Gathered] = []
        gather(node, depth: depth, screen: screen, insideWebView: insideWebView,
               gathered: &gathered,
               keyboardFrame: &keyboardFrame, offscreenHints: &offscreenHints)

        // isRedundant は [ElementInfo] を取るので**同じ列を2本持つ**。`deduped.map(\.info)` を
        // 毎回作ると、全件走査になった分そのまま要素ごとの配列確保になる(木が大きいほど効く)
        var deduped: [Gathered] = []
        var dedupedInfos: [ElementInfo] = []
        deduped.reserveCapacity(gathered.count)
        dedupedInfos.reserveCapacity(gathered.count)
        for item in gathered where !SnapshotDedupe.isRedundant(item.info, alreadyEmitted: dedupedInfos) {
            deduped.append(item)
            dedupedInfos.append(item.info)
        }

        let keptIndices: [Int]
        if deduped.count <= snapshotElementLimit {
            keptIndices = Array(deduped.indices)
        } else {
            let candidates = deduped.map { BridgeSnapshotThinning.Candidate(info: $0.info) }
            keptIndices = BridgeSnapshotThinning.indicesToKeep(candidates, max: snapshotElementLimit)
            // **落とした本人しか内訳を知らない**(ホストへ届くのは残った側だけ)
            for (key, count) in BridgeSnapshotThinning.droppedByTier(candidates, kept: keptIndices) {
                truncatedTiers[key, default: 0] += count
            }
            // 上限の外で送った bulk の件数(61)
            bulkExempt += BridgeSnapshotThinning.bulkExemptCount(candidates)
        }
        truncated += deduped.count - keptIndices.count

        for index in keptIndices {
            let ref = elements.count + 1
            var info = deduped[index].info
            info.ref = ref
            frames[ref] = deduped[index].frame
            identities[ref] = (info.identifier, info.label, info.type)
            elements.append(info)
        }
    }

    /// preorder 走査。不可視ノードはサブツリーごと除外。**上限で打ち切らない**(collect の2パス目が
    /// dedupe・間引きをまとめて行う)
    private func gather(_ node: XCUIElementSnapshot, depth: Int, screen: CGRect,
                        insideWebView: Bool,
                        gathered: inout [Gathered],
                        keyboardFrame: inout CGRect?,
                        offscreenHints: inout [ElementInfo]) {
        // キーボードはキー1つ1つが Button として大量に写り込むため、サブツリーごと除外
        // (4Kトークン対策。入力は /type がキーイベント合成で行うので情報として不要)。
        // 除外前に frame だけ記録する(SnapshotResponse.keyboardShown/keyboardFrame。
        // keyboardShown は keyboardFrame != nil から導く)
        if node.elementType == .keyboard {
            keyboardFrame = node.frame
        }
        if node.elementType == .keyboard || node.elementType == .key { return }
        // WebView は入れ子で複数出る(Compose iOS の interop ラッパで実測3重)。外側だけ残さないと
        // `.webView[1]` がどれを指すか読めない。Android ブリッジの nestedWebView と同じ規則
        let isWebView = node.elementType == .webView
        if isWebView && insideWebView {
            for child in node.children {
                gather(child, depth: depth, screen: screen, insideWebView: true,
                       gathered: &gathered,
                       keyboardFrame: &keyboardFrame,
                       offscreenHints: &offscreenHints)
            }
            return
        }
        if shouldInclude(node, screen: screen) {
            let info = makeInfo(node, ref: 0, depth: depth)
            gathered.append(Gathered(info: info, frame: node.frame))
        } else if insideWebView, offscreenHints.count < BridgeAPI.maxSnapshotElements,
                  isOffscreenHintCandidate(node, screen: screen) {
            // ref 0(座標表に入れない・タップ対象にしない)。Captured.offscreen 参照。
            // **この別枠上限は間引きと無関係**(hint は elements に混ざらない)
            offscreenHints.append(makeInfo(node, ref: 0, depth: depth))
        }
        for child in node.children {
            gather(child, depth: depth + 1, screen: screen,
                   insideWebView: insideWebView || isWebView,
                   gathered: &gathered, keyboardFrame: &keyboardFrame,
                   offscreenHints: &offscreenHints)
        }
    }

    private func shouldInclude(_ node: XCUIElementSnapshot, screen: CGRect) -> Bool {
        let frame = node.frame
        guard frame.width >= 2, frame.height >= 2 else { return false }
        guard screen.isEmpty || frame.intersects(screen) else { return false }
        return isEligible(node, screen: screen)
    }

    /// 画面外ヒント(offscreenHints)の候補判定。サイズガードは shouldInclude と共有、
    /// 画面交差ガードだけ反転する(「画面と交わらない」ときだけヒント化する。screen が空だと
    /// 交差判定ができないので対象にしない)
    private func isOffscreenHintCandidate(_ node: XCUIElementSnapshot, screen: CGRect) -> Bool {
        let frame = node.frame
        guard frame.width >= 2, frame.height >= 2 else { return false }
        guard !screen.isEmpty, !frame.intersects(screen) else { return false }
        return isEligible(node, screen: screen)
    }

    /// 型・テキストによる採用資格(画面内/外は問わない)。shouldInclude(可視要素)と
    /// isOffscreenHintCandidate(WebView 配下の画面外ノード)が共有する
    private func isEligible(_ node: XCUIElementSnapshot, screen: CGRect) -> Bool {
        // 画面の大半を覆う Other コンテナは identifier があっても除外する。
        // タップ対象になり得ず、id が「タブ」等に見えると FM の誤タップを誘発する
        // (SwiftUI の .accessibilityIdentifier がコンテナに付くケース)。
        if node.elementType == .other {
            let frame = node.frame
            let screenArea = screen.width * screen.height
            if screenArea > 0, (frame.width * frame.height) / screenArea > 0.85 {
                return false
            }
        }

        let hasText = !node.identifier.isEmpty || !node.label.isEmpty || valueString(node) != nil

        switch node.elementType {
        // 操作可能な要素はテキストがなくても含める(アイコンだけのボタン等)。
        // .icon は springboard のホーム画面アイコン(tapAppIcon 用。label のみで identifier を持たない)
        case .button, .textField, .secureTextField, .textView, .`switch`, .toggle,
             .slider, .cell, .link, .searchField, .segmentedControl, .pickerWheel,
             .stepper, .datePicker, .checkBox, .menuItem, .icon:
            return true
        // 表示要素はテキストを持つ場合のみ
        case .staticText, .image:
            return hasText
        // 画面構造の手がかり。webView は `.webView >> ...` のスコープ起点になるため
        // identifier が無くても残す(Web コンテンツは id を一切持たない = 唯一の絞り込み手段)
        case .navigationBar, .tabBar, .alert, .sheet, .webView:
            return true
        // スクロール容器は identifier が無くても残す(2026-08-08。in-app 側
        // InAppSnapshot.shouldInclude と同じ規律)。落とすと scrollFrame の候補も scroll マークも
        // 出ないまま木から消える(自前描画の容器は Other 型で id を持たないのが普通)
        case .scrollView, .table, .collectionView:
            return true
        // その他(Other/Group 等)は identifier 付きのみ
        default:
            return !node.identifier.isEmpty
        }
    }

    /// スクロールできる容器とみなす型(`ElementInfo.scrollable`)
    private static let scrollableTypes: Set<XCUIElement.ElementType> = [
        .scrollView, .table, .collectionView,
    ]

    private func makeInfo(_ node: XCUIElementSnapshot, ref: Int, depth: Int) -> ElementInfo {
        let frame = node.frame
        return ElementInfo(
            ref: ref,
            type: Self.typeName(node.elementType),
            identifier: node.identifier.isEmpty ? nil : node.identifier,
            label: node.label.isEmpty ? nil : node.label,
            value: valueString(node),
            placeholder: node.placeholderValue,
            enabled: node.isEnabled,
            frame: FTRect(x: frame.origin.x, y: frame.origin.y,
                          width: frame.width, height: frame.height),
            depth: depth,
            // Compose iOS は Switch の value を出さないため isSelected が唯一の checked 経路
            // (SwiftUI/Flutter も同じ trait が立つ。2026-07-26 実測)。false は送らない
            checked: node.isSelected ? true : nil,
            // スクロールできる容器か(scrollFrame の空振り検出用)。XCUITest は Android の
            // isScrollable に当たる属性を持たないので**型で判定する**(Shirates の iOS 側と同じ規則)。
            // 自前描画(Compose/Flutter)の容器は Other として出るため申告できない = false は送らない
            scrollable: Self.scrollableTypes.contains(node.elementType) ? true : nil)
    }

    private func valueString(_ node: XCUIElementSnapshot) -> String? {
        guard let value = node.value else { return nil }
        let string = (value as? String) ?? String(describing: value)
        guard !string.isEmpty else { return nil }
        // **placeholder がそのまま value で来る欄は「空」**。WebKit は空の `<input>` の
        // AXValue に placeholder を入れて返すので(UIKit の入力欄は入れない)、正規化しないと
        // iOS の WebView だけ `value="WebView 入力"` になり `valueIs("")` が通らない。
        // Android のブリッジは同じ欄を empty で返す = ここが揃っていなかった
        // (2026-08-06 に E2E-iOS / E2E-CMP の WebView 画面で実測)。
        // 判定は clearInput の `remainingText` と同じ規則(同じ知見の2つ目の定義を作らない)
        if let placeholder = node.placeholderValue, string == placeholder { return nil }
        return string
    }

    static func typeName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .button: return "Button"
        case .staticText: return "StaticText"
        case .textField: return "TextField"
        case .secureTextField: return "SecureTextField"
        case .textView: return "TextView"
        case .`switch`: return "Switch"
        case .toggle: return "Toggle"
        case .slider: return "Slider"
        // UITableView/UICollectionView のセル。Android の「役割不明の clickable 容器」と
        // 同じバケツに入れるため名前を揃える(型語彙の唯一の正は E2EAppCMP/docs/ui-contract.md)
        case .cell: return "Clickable"
        case .link: return "Link"
        case .image: return "Image"
        case .icon: return "Icon"
        case .searchField: return "SearchField"
        case .segmentedControl: return "SegmentedControl"
        case .picker: return "Picker"
        case .pickerWheel: return "PickerWheel"
        case .stepper: return "Stepper"
        case .datePicker: return "DatePicker"
        case .checkBox: return "CheckBox"
        case .menuItem: return "MenuItem"
        case .pageIndicator: return "PageIndicator"
        case .navigationBar: return "NavigationBar"
        case .tabBar: return "TabBar"
        case .toolbar: return "Toolbar"
        case .alert: return "Alert"
        case .sheet: return "Sheet"
        case .scrollView: return "ScrollView"
        case .webView: return "WebView"
        case .table: return "Table"
        case .collectionView: return "CollectionView"
        case .window: return "Window"
        case .other: return "Other"
        default: return "Type\(type.rawValue)"
        }
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

    private func resolvePoint(ref: Int?, x: Double?, y: Double?) throws -> CGPoint {
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

    private func coordinate(_ app: XCUIApplication, _ point: CGPoint) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: point.x, dy: point.y))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ body: Data) throws -> T {
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
