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
    // 直前の要求が画面を変えうる操作(tap/swipe/press/type/drag/session)だったか。
    // XCUITest の tap quiescence は非同期 push 遷移の完了前に返ることがあり、直後 snapshot が
    // 遷移前ツリーを掴む(実測 50% / bridge-8123)。操作直後の snapshot に限り整定確認する。
    // **取得そのものは高コストではない**: ホスト側から HTTP 越しの外形計測で 29〜118ms
    // (要素 5〜22 個・M2 Ultra アイドル・2026-07-30)。以前ここに「~0.45s と高コスト」と
    // 書いていたのは **350ms ガード込みの値を素のコストと取り違えた誤り**だった。
    private var settlePending = false

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
    private static let mutatingPaths: Set<String> = ["/session", "/tap", "/type", "/pressEnter", "/press", "/appswitcher", "/home"]

    func handle(_ request: BridgeHTTPServer.Request) -> BridgeHTTPServer.Response {
        do {
            let response: BridgeHTTPServer.Response
            switch (request.method, request.path) {
            case ("GET", "/status"): response = handleStatus()
            case ("POST", "/session"): response = try handleLaunch(request.body)
            case ("GET", "/snapshot"): response = try handleSnapshot()
            case ("POST", "/tap"): response = try handleTap(request.body)
            case ("POST", "/type"): response = try handleType(request.body)
            case ("POST", "/pressEnter"): response = try handlePressEnter()
            case ("POST", "/swipe"): response = try handleSwipe(request.body)
            case ("POST", "/drag"): response = try handleDrag(request.body)
            case ("POST", "/press"): response = try handlePress(request.body)
            case ("GET", "/screenshot"): response = handleScreenshot()
            case ("POST", "/appswitcher"): response = try handleAppSwitcher()
            case ("POST", "/home"): response = try handleHome()
            case ("POST", "/terminate"): response = try handleTerminate()
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
            fastInputAvailable: FastInput.available,
            // 起動元の自己申告(doctor の刈り取り判定が依存。BridgeDTO の各フィールド参照)
            ownerRepo: ProcessInfo.processInfo.environment["FT_OWNER_REPO"],
            ownerPid: Int(ProcessInfo.processInfo.processIdentifier),
            idleSeconds: idleSecondsProvider.map { $0() }))
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
            return .json(OKResponse())
        }
        if req.attachOnly == true {
            // simctl 等で起動済みのアプリへのプロキシ接続のみ(activate() の約1s を払わない。
            // 前面到達の確認だけ行う=未起動なら即エラーで呼び出し側が診断できる)
            guard target.state == .runningForeground
                || target.wait(for: .runningForeground, timeout: 5) else {
                throw BridgeError(500, "attach 対象アプリが前面にありません: \(req.bundleID)"
                    + "(simctl launch の成否を確認してください)")
            }
        } else if req.activate == true {
            target.activate()
        } else {
            target.launch()
        }
        guard target.state == .runningForeground || target.wait(for: .runningForeground, timeout: 10) else {
            throw BridgeError(500, "アプリを起動できませんでした: \(req.bundleID)(インストール済みか確認してください)")
        }
        app = target
        sessionBundleID = req.bundleID
        refFrames = [:]
        return .json(OKResponse())
    }

    private struct Captured {
        let elements: [ElementInfo]
        let frames: [Int: CGRect]
        let truncated: Int
        let screen: CGRect
    }

    private func handleSnapshot() throws -> BridgeHTTPServer.Response {
        let app = try requireApp()
        // 操作直後のみ整定してから取得する(captureSettled)。XCUITest の tap quiescence は
        // 非同期 push 遷移の完了前に返るため、直後の素取得は遷移前ツリーを返す(実測 50%)。
        // 連続 snapshot(settlePending=false)は整定不要なので素取得のまま。
        let cap = try settlePending ? captureSettled(app) : captureOnce(app)
        settlePending = false

        refFrames = cap.frames
        return .json(SnapshotResponse(
            sessionBundleID: sessionBundleID,
            screen: FTRect(x: cap.screen.origin.x, y: cap.screen.origin.y,
                           width: cap.screen.width, height: cap.screen.height),
            elements: cap.elements,
            truncatedCount: cap.truncated))
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
        return previous   // budget 切れ。previous は常に直近の取得(収束はしていない)
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

    private func captureOnce(_ app: XCUIApplication) throws -> Captured {
        let root = try app.snapshot()
        let screen = root.frame
        var elements: [ElementInfo] = []
        var frames: [Int: CGRect] = [:]
        var truncated = 0
        collect(root, depth: 0, screen: screen,
                elements: &elements, frames: &frames, truncated: &truncated)
        return Captured(elements: elements, frames: frames, truncated: truncated, screen: screen)
    }

    private func handleTap(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(TapRequest.self, body)
        let app = try requireLiveApp()
        let point = try resolvePoint(ref: req.ref, x: req.x, y: req.y)
        try FastInput.with(req.fast) {
            coordinate(app, point).tap()
        }
        return .json(OKResponse())
    }

    private func handleType(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(TypeRequest.self, body)
        let app = try requireLiveApp()
        if let ref = req.ref {
            // tap() が quiescence まで待つため追加待ちは不要(旧: 固定400ms・keyboards クエリは
            // キーボードが別プロセス扱いのため常にタイムアウトし逆効果だった。2026-07-12実測)
            coordinate(app, try resolvePoint(ref: ref, x: nil, y: nil)).tap()
        }
        app.typeText(req.text)
        return .json(OKResponse())
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

    private func handleSwipe(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(SwipeRequest.self, body)
        let app = try requireLiveApp()
        FastInput.with(req.fast) {
            switch req.direction {
            case .up: app.swipeUp()
            case .down: app.swipeDown()
            case .left: app.swipeLeft()
            case .right: app.swipeRight()
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
        from.press(forDuration: press, thenDragTo: to,
                   withVelocity: XCUIGestureVelocity(velocity), thenHoldForDuration: 0)
        return .json(OKResponse())
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

    /// ホーム画面に戻る(セッション不要。XCUIDevice のホームボタン押下=前面アプリに関係なく効く)
    private func handleHome() throws -> BridgeHTTPServer.Response {
        XCUIDevice.shared.press(.home)
        return .json(OKResponse())
    }

    private func handleTerminate() throws -> BridgeHTTPServer.Response {
        let app = try requireApp()
        // 未起動での terminate() は NSException(Code=10001「is not running」)を投げ、
        // BridgeHTTPServer の例外シムで 500 化する。state で回避し、
        // チェック〜呼び出し間のレースで投げられた「is not running」だけは握り潰して冪等にする。
        if app.state != .notRunning && app.state != .unknown {
            if let ex = FTCatchObjCException({ app.terminate() }), !ex.contains("is not running") {
                throw BridgeError(500, "アプリの終了に失敗しました: \(ex)")
            }
        }
        self.app = nil
        sessionBundleID = nil
        refFrames = [:]
        return .json(OKResponse())
    }

    // MARK: - スナップショット収集・フィルタ

    private func collect(_ node: XCUIElementSnapshot, depth: Int, screen: CGRect,
                         elements: inout [ElementInfo], frames: inout [Int: CGRect],
                         truncated: inout Int, insideWebView: Bool = false) {
        // キーボードはキー1つ1つが Button として大量に写り込むため、サブツリーごと除外
        // (4Kトークン対策。入力は /type がキーイベント合成で行うので情報として不要)
        if node.elementType == .keyboard || node.elementType == .key { return }
        // WebView は入れ子で複数出る(Compose iOS の interop ラッパで実測3重)。外側だけ残さないと
        // `.webView[1]` がどれを指すか読めない。Android ブリッジの nestedWebView と同じ規則
        let isWebView = node.elementType == .webView
        if isWebView && insideWebView {
            for child in node.children {
                collect(child, depth: depth, screen: screen,
                        elements: &elements, frames: &frames, truncated: &truncated,
                        insideWebView: true)
            }
            return
        }
        if shouldInclude(node, screen: screen) {
            if elements.count < BridgeAPI.maxSnapshotElements {
                let ref = elements.count + 1
                frames[ref] = node.frame
                elements.append(makeInfo(node, ref: ref, depth: depth))
            } else {
                truncated += 1
            }
        }
        for child in node.children {
            collect(child, depth: depth + 1, screen: screen,
                    elements: &elements, frames: &frames, truncated: &truncated,
                    insideWebView: insideWebView || isWebView)
        }
    }

    private func shouldInclude(_ node: XCUIElementSnapshot, screen: CGRect) -> Bool {
        let frame = node.frame
        guard frame.width >= 2, frame.height >= 2 else { return false }
        guard screen.isEmpty || frame.intersects(screen) else { return false }

        // 画面の大半を覆う Other コンテナは identifier があっても除外する。
        // タップ対象になり得ず、id が「タブ」等に見えると FM の誤タップを誘発する
        // (SwiftUI の .accessibilityIdentifier がコンテナに付くケース)。
        if node.elementType == .other {
            let screenArea = screen.width * screen.height
            if screenArea > 0, (frame.width * frame.height) / screenArea > 0.85 {
                return false
            }
        }

        let hasText = !node.identifier.isEmpty || !node.label.isEmpty || valueString(node) != nil

        switch node.elementType {
        // 操作可能な要素はテキストがなくても含める(アイコンだけのボタン等)
        case .button, .textField, .secureTextField, .textView, .`switch`, .toggle,
             .slider, .cell, .link, .searchField, .segmentedControl, .pickerWheel,
             .stepper, .datePicker, .checkBox, .menuItem:
            return true
        // 表示要素はテキストを持つ場合のみ
        case .staticText, .image:
            return hasText
        // 画面構造の手がかり。webView は `.webView >> ...` のスコープ起点になるため
        // identifier が無くても残す(Web コンテンツは id を一切持たない = 唯一の絞り込み手段)
        case .navigationBar, .tabBar, .alert, .sheet, .webView:
            return true
        // その他(Other/Group/ScrollView 等)は identifier 付きのみ
        default:
            return !node.identifier.isEmpty
        }
    }

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
            checked: node.isSelected ? true : nil)
    }

    private func valueString(_ node: XCUIElementSnapshot) -> String? {
        guard let value = node.value else { return nil }
        let string = (value as? String) ?? String(describing: value)
        return string.isEmpty ? nil : string
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
        // 同じバケツに入れるため名前を揃える(型語彙の唯一の正は E2EApp/docs/ui-contract.md)
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
            throw BridgeError(503, "対象アプリ(\(sessionBundleID ?? "?"))が起動していないため操作できません"
                + "(前のステップで終了/クラッシュした可能性。ホストは /session で起動し直してください)")
        }
        return app
    }

    private func requireApp() throws -> XCUIApplication {
        guard let app else {
            // status は 409 のまま変えないこと(ホスト側 SessionRecoveryDriver がこの1箇所の
            // 409 だけを「セッション消失」と断定して判定に使う)
            throw BridgeError(409, "XCUITest ランナーにセッションがありません"
                + "(ランナー再起動でセッションが失われた可能性)。ホストが /session で張り直します")
        }
        return app
    }

    private func resolvePoint(ref: Int?, x: Double?, y: Double?) throws -> CGPoint {
        if let ref {
            guard let frame = refFrames[ref] else {
                throw BridgeError(404, "参照番号 [\(ref)] は未知です。先に GET /snapshot を実行してください")
            }
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        if let x, let y {
            return CGPoint(x: x, y: y)
        }
        throw BridgeError(400, "ref または x/y が必要です")
    }

    private func coordinate(_ app: XCUIApplication, _ point: CGPoint) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: point.x, dy: point.y))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ body: Data) throws -> T {
        do {
            return try decoder.decode(type, from: body)
        } catch {
            throw BridgeError(400, "リクエストボディの JSON が不正です: \(error)")
        }
    }
}
