// アプリ内常駐ブリッジのエントリと HTTP ルータ。dylib は SIMCTL_CHILD_DYLD_INSERT_LIBRARIES で
// 対象アプリに注入され、boot.m の構成子が FTInAppBridgeStart を呼ぶ。ポートは環境変数 FT_PORT
// (既定 8123=BridgeAPI.defaultPort)。エンドポイントは Runner/BridgeRouter と HTTP 互換にし、
// ホスト側(FTBridgeClient)を無改変で使えるようにする(単一実装原則)。
//
// ハンドラは InAppHTTPServer の accept ループ(バックグラウンド)で呼ばれる。UIKit 参照や
// タッチ合成はメインへホップし、アクションは実行後に整定(InAppSettle)を待ってから応答する。
//
// 実装エンドポイント: /status /snapshot /tap /type /clear /pressEnter /hidekeyboard /swipe /press /screenshot。
// /session はアプリ再起動を伴うためホスト側(BridgeProvisioner)が simctl launch+注入で担う。

import Foundation
import UIKit
import WebKit

@_cdecl("FTInAppBridgeStart")
public func FTInAppBridgeStart() {
    FTInAppBridge.shared.start()
}

final class FTInAppBridge {
    static let shared = FTInAppBridge()

    private var server: InAppHTTPServer?
    // 直近スナップショットの ref → window 座標フレーム / AX 要素。tap/press の解決に使う。
    // accept ループは1本ずつ処理するので単純プロパティで足りる(同時アクセスなし)。
    // nodes は弱参照テーブル(画面遷移後に旧ビュー階層を snapshot 更新まで抱え込まないため)。
    private var frames: [Int: CGRect] = [:]
    private let nodes = NSMapTable<NSNumber, AnyObject>(keyOptions: .strongMemory, valueOptions: .weakMemory)
    // compose-resources = Compose Multiplatform のリソースバンドル(2026-07-20 実バンドルで検証済みマーカー)。
    // Frameworks/Flutter.framework = Flutter アプリのマーカー。type ルーティング判定(StepExecutor)に使う
    private lazy var uiFramework: String = {
        let bundle = Bundle.main.bundlePath as NSString
        if FileManager.default.fileExists(atPath: bundle.appendingPathComponent("compose-resources")) {
            return "compose"
        }
        if FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent("Frameworks/Flutter.framework")) {
            return "flutter"
        }
        return "uikit"
    }()

    func start() {
        let port = UInt16(ProcessInfo.processInfo.environment["FT_PORT"] ?? "")
            ?? BridgeAPI.defaultPort
        let server = InAppHTTPServer(port: port) { [weak self] req in
            self?.handle(req) ?? .error("bridge gone", status: 500)
        }
        // AX ツリーを materialize させる(XCUITest 相当。未活性だと label/frame が取れない)
        DispatchQueue.main.async { FTActivateAccessibility() }
        // キーボードの実矩形は通知でしか安定して取れない(TextEffects window は全画面、
        // UIInputSetHostView のクラス名走査は iOS 27 で不発を実測)。ブリッジ起動前に
        // 開いていたキーボードは最初の変化まで不明のまま = keyboardFrame なし
        DispatchQueue.main.async { Self.observeKeyboardFrame() }
        // 画面が進んでいるかの計器(/status の displayIdleSeconds)。
        // **ホストは凍結判定に使わない** —— 理由は DisplayHeartbeat の説明を参照
        DisplayHeartbeat.shared.start()
        do {
            try server.start()
            self.server = server
            NSLog("FTInAppBridge listening on 127.0.0.1:\(port)")
        } catch {
            NSLog("FTInAppBridge failed to start: \(error)")
        }
    }

    /// 直近の performWithSettle が **cap で打ち切られた**か(整定していない)。
    /// handle の冒頭で必ず落とし、ok(_:) が note に載せる。**黙って返さない**ための1本道
    private var lastSettleCapped = false

    /// 応答を作る。整定が打ち切られていたら note に足す(ホストは driverFallback として記録する)。
    /// 打ち切りは失敗ではないので status は 200 のまま
    private func ok(_ note: String? = nil, atEdge: Bool? = nil) -> InAppHTTPServer.Response {
        guard lastSettleCapped else { return .json(OKResponse(note: note, atEdge: atEdge)) }
        let capped = "settle capped (screen kept animating)"
        return .json(OKResponse(note: note.map { "\($0) / \(capped)" } ?? capped, atEdge: atEdge))
    }

    private func handle(_ req: InAppHTTPServer.Request) -> InAppHTTPServer.Response {
        lastSettleCapped = false
        do {
            switch (req.method, req.path) {
            case ("GET", "/status"): return handleStatus()
            case ("GET", "/snapshot"): return try handleSnapshot(req)
            case ("POST", "/tap"): return try handleTap(req.body)
            case ("POST", "/type"): return try handleType(req.body)
            case ("POST", "/clear"): return try handleClear(req.body)
            case ("POST", "/pressEnter"): return try handlePressEnter()
            case ("POST", "/hidekeyboard"): return try handleHideKeyboard()
            case ("POST", "/swipe"): return try handleSwipe(req.body)
            case ("POST", "/doubletap"): return try handleDoubleTap(req.body)
            case ("POST", "/pinch"): return try handlePinch(req.body)
            case ("POST", "/rotate"): return try handleRotate(req.body)
            case ("POST", "/press"): return try handlePress(req.body)
            case ("GET", "/screenshot"): return try handleScreenshot()
            case ("POST", "/session"):
                // in-app ブリッジは注入先アプリそのものに常駐している。ホストの launch(bundleID) は
                // 既に起動済みの当該アプリを指すので OK を返す(状態リセットが要る場合は
                // ホスト側がプロセス再起動+再注入で行う=lifecycle だけホスト責務)。
                let req = try decode(LaunchRequest.self, req.body)
                guard req.bundleID == Bundle.main.bundleIdentifier else {
                    throw InAppError(409, "the in-app bridge serves only its host app (\(Bundle.main.bundleIdentifier ?? "?")) — requested: \(req.bundleID)")
                }
                return ok()
            case ("POST", "/terminate"):
                return .error("/terminate is not supported in-app (the host controls the process)", status: 501)
            case ("POST", "/appstate"): return try handleAppState(req.body)
            default:
                return .error("not found: \(req.method) \(req.path)", status: 404)
            }
        } catch let e as InAppError {
            return .error(e.message, status: e.status)
        } catch {
            return .error("\(error)", status: 500)
        }
    }

    // MARK: - Handlers

    private func handleStatus() -> InAppHTTPServer.Response {
        mainSync {
            let device = UIDevice.current
            let state: String
            switch UIApplication.shared.applicationState {
            case .active: state = "active"
            case .inactive: state = "inactive"
            case .background: state = "background"
            @unknown default: state = "unknown"
            }
            return .json(StatusResponse(
                ready: true,
                device: device.name,
                osVersion: "\(device.systemName) \(device.systemVersion)",
                sessionBundleID: Bundle.main.bundleIdentifier,
                engine: "inapp",
                // 版申告が無いと旧 dylib のままの稼働中ブリッジが再利用され、新エンドポイントが
                // 404 になる(BridgeProvisioner.planBridge が再利用可否をこの版で判定する)
                protocolVersion: BridgeAPI.bridgeProtocolVersion,
                applicationState: state,
                uiFramework: self.uiFramework,
                displayIdleSeconds: DisplayHeartbeat.shared.idleSeconds,
                // 合成タッチは「時間・移動を伴うジェスチャ」を駆動できない。これは Compose 固有ではなく
                // SwiftUI/UIKit でも同じ(2026-07-23 に TestProjects/E2E-iOS で実測)ので press は常に申告する。
                //
                // **swipe は申告しない**(2026-07-31 に取り下げ)。申告は「このアクションは一律不可」の
                // 意味しか持たないが、swipe の可否は**目的と画面によって割れる**ようになった:
                //   スクロール目的 … UIKit=contentOffset / Compose・Flutter=UIAccessibility の scroll で通る
                //   ジェスチャ目的 … どのフレームワークでも不可(handleSwipe が 501 を返す)
                // 申告したままだとスクロールまで XCUITest へ回り、せっかくの in-app 経路が使われない。
                // 可否の判定は handleSwipe に一本化し、不可なら 501 で個別に申告する
                // (ホストは 501 を見て XCUITest へフォールバックする)
                unsupportedActions: ["press"],
                // 起動元の自己申告(InAppLauncher が SIMCTL_CHILD_FT_OWNER_REPO で注入)
                ownerRepo: ProcessInfo.processInfo.environment["FT_OWNER_REPO"],
                // 載っているシミュレータの UDID(H)。ホストが port ではなく udid で宛先を
                // 指せるようにするための申告。実機には SIMULATOR_UDID が無いので nil
                udid: ProcessInfo.processInfo.environment["SIMULATOR_UDID"],
                orientation: self.keyWindow()?.windowScene?.interfaceOrientation.ftOrientation))
        }
    }

    /// フォアグラウンドのアプリが bundleID と一致するか(DSL の appIs)。in-app ブリッジは
    /// 自プロセスしか見えないため、判定は「要求された bundleID が自分自身で、かつ active か」
    /// だけで足りる: 自分が active なら他アプリは前面にいられない。別アプリを問われた場合は、
    /// ブリッジが応答できている(=自分は少なくとも起動している)こと自体からは前面/背面を
    /// 判定できないので false を返す(前面なのは高々1つ、それが自分でない以上 false で正しい)
    private func handleAppState(_ body: Data) throws -> InAppHTTPServer.Response {
        let req = try decode(AppStateRequest.self, body)
        return mainSync {
            let isSelf = req.bundleID == Bundle.main.bundleIdentifier
            let active = UIApplication.shared.applicationState == .active
            return .json(AppStateResponse(foreground: isSelf && active))
        }
    }

    private func handleSnapshot(_ req: InAppHTTPServer.Request) throws -> InAppHTTPServer.Response {
        // `max=<n>`: 呼び手が1回だけ引き上げる要素上限(解釈は resolvedSnapshotElementLimit の
        // 1箇所 = ホスト・3ブリッジで同じ規則)。DOM マージ側の上限にも同じ値を使う
        let limit = BridgeAPI.resolvedSnapshotElementLimit(
            req.queryValue("max").flatMap { Int($0) })
        let base: InAppSnapshot.Result = try mainSync {
            guard let window = self.keyWindow() else {
                throw InAppError(409, "no key window")
            }
            // Flutter は engine.ensureSemanticsEnabled を呼ばないと SemanticsObject が生成されず
            // 0 要素になる(_AXSSetAutomationEnabled は Flutter engine に効かない)。冪等・非 Flutter は no-op。
            // 起動直後は FlutterViewController が未生成のことがあるため boot 時でなく snapshot ごとに呼ぶ
            FTEnsureFlutterSemantics()
            return InAppSnapshot.capture(windows: Self.visibleWindows(keyWindow: window), max: limit)
        }
        // **キーボードはキーウィンドウの外**(UITextEffectsWindow)に載るため、AX ツリー走査
        // (InAppSnapshot の sawKeyboard)では見つからない。表示中かと実矩形を同一時点で読むため
        // 1回の mainSync にまとめる(2回に分けると間でキーボードが閉じ、不整合な組が起こり得る)
        let (keyboardShown, keyboardWindowFrame): (Bool, CGRect?) = mainSync {
            (Self.keyboardIsVisible(), Self.keyboardFrameIfVisible())
        }

        // **mainSync の外で行う**: WKWebView の DOM 読みは evaluateJavaScript の完了を待つが、
        // その完了はメインキューへ配送されるため、メインを保持したまま待つとデッドロックする
        let merged = mergeWebViewDOM(into: base, max: limit)

        mainSync {
            self.frames = merged.frames
            self.nodes.removeAllObjects()
            for (ref, node) in merged.nodes { self.nodes.setObject(node, forKey: NSNumber(value: ref)) }
        }
        return .json(SnapshotResponse(
            sessionBundleID: Bundle.main.bundleIdentifier,
            screen: base.screen,
            elements: merged.elements,
            truncatedCount: merged.truncated,
            note: merged.note,
            webViewPath: merged.webViewPath,
            // in-app は window 一覧から実際に「非表示」を確認できる唯一のエンジン
            // (XCUITest/Android は不明を false 相当で返すしかない)。false を nil に潰すと
            // keyboardIsNotShown() が unknown 扱いになりタイムアウトする(実害・再発させない)
            keyboardShown: keyboardShown,
            keyboardFrame: keyboardWindowFrame.map {
                FTRect(x: $0.origin.x, y: $0.origin.y, width: $0.width, height: $0.height)
            },
            truncatedTiers: merged.truncatedTiers.isEmpty ? nil : merged.truncatedTiers,
            bulkExemptCount: merged.bulkExempt > 0 ? merged.bulkExempt : nil))
    }

    /// keyboardWillChangeFrame の最新値(画面座標)。nil = 非表示または不明。
    /// メインスレッドでのみ読み書きする(observeKeyboardFrame も snapshot も mainSync 内)
    private static var observedKeyboardFrame: CGRect?
    private static var keyboardObserversInstalled = false

    private static func observeKeyboardFrame() {
        guard !keyboardObserversInstalled else { return }
        keyboardObserversInstalled = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification,
                           object: nil, queue: .main) { note in
            guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                as? NSValue)?.cgRectValue else { return }
            // 閉じるときは end frame が画面外(minY >= 画面下端)で来る
            let screen = UIScreen.main.bounds
            observedKeyboardFrame = frame.minY < screen.maxY - 1 ? frame : nil
        }
        center.addObserver(forName: UIResponder.keyboardWillHideNotification,
                           object: nil, queue: .main) { _ in
            observedKeyboardFrame = nil
        }
    }

    /// ソフトキーボードが表示中か。**キーボードは UITextEffectsWindow(キーウィンドウとは別)に
    /// 載る**ので window 一覧から探す。閉じた直後は window が画面外(y >= 画面下端)へ退避する
    /// だけで残るため、可視かつ画面内に張り出しているかで見る
    private static func keyboardIsVisible() -> Bool {
        for window in UIApplication.shared.windows
        where NSStringFromClass(type(of: window)).contains("TextEffects") {
            guard !window.isHidden, window.alpha > 0.01 else { continue }
            if window.frame.minY < window.screen.bounds.maxY - 1 { return true }
        }
        return false
    }

    /// 可視なソフトキーボードの実矩形(画面座標)。通知の最新値から採る ——
    /// **TextEffects window の frame をそのまま使ってはいけない**(開いている間も全画面。
    /// 実測 2026-08-08: (0,0 402x874) が返り、画面上部の要素まで「キーボード下」と誤警告した。
    /// 配下の UIInputSetHostView をクラス名で探す案も iOS 27 で不発を実測)。
    /// 通知値が無ければ frame は申告しない(誤検知側に倒さない。keyboardShown だけ true になる)
    private static func keyboardFrameIfVisible() -> CGRect? {
        guard keyboardIsVisible(), let observed = observedKeyboardFrame,
              observed.height >= 1 else { return nil }
        return observed
    }

    /// 自分自身から window までのクラス名(interop 判定用。UIKit 参照だがメイン外でも
    /// 参照だけなら安全 = superview チェーンは snapshot 取得時点で確定している)
    private static func ancestorClassNames(of view: UIView) -> [String] {
        var names: [String] = []
        var cursor: UIView? = view
        while let current = cursor {
            names.append(NSStringFromClass(type(of: current)))
            cursor = current.superview
        }
        return names
    }

    private struct MergedSnapshot {
        var elements: [ElementInfo]
        var frames: [Int: CGRect]
        var nodes: [Int: NSObject]
        var truncated: Int
        var note: String?
        /// BridgeDTO の SnapshotResponse.webViewPath。"dom" = uikit ホスト等で DOM を読めた /
        /// "dom-interop" = DOM は読めたが interop(Compose/Flutter)配下 = 操作はホスト側
        /// (WebViewDelegatingDriver)が XCUITest 座標へ回す。DOM 自体が読めなければ nil
        var webViewPath: String?
        /// 捨てた候補の内訳(SnapshotResponse.truncatedTiers)。ネイティブ1段目と
        /// DOM マージ2段目の両方を合算する
        var truncatedTiers: [String: Int] = [:]
        /// 要素上限の外で送った bulk の件数(SnapshotResponse.bulkExemptCount)
        var bulkExempt: Int = 0
    }

    /// WebView コンテナの**直後**に DOM 由来の要素を差し込み、ref を採番し直す
    /// (文書順 = a11y 経路と同じ並びにする。並びが変わると `.型[n]` の意味が変わる)。
    ///
    /// DOM 要素には **AX ノードを紐付けない**。tapByRef はノードが無いと座標タップへ落ちるので、
    /// それがそのまま「DOM の矩形へ合成タッチを打つ」動作になる(DOM 側で click させない理由は
    /// InAppWebViewDOM の冒頭コメント参照)。
    ///
    /// interop(Compose/Flutter)配下でも DOM は読む(読み取りは届く、操作だけ interop に
    /// 横取りされる)。操作は合成タッチでは届かないため、interop 配下が1つでも
    /// あれば webViewPath を "dom-interop" と申告する — **ホスト(WebViewDelegatingDriver)が
    /// これを見て ref を座標へ解決し XCUITest の実タッチへ回す**(ここでは判定だけ、実際の
    /// ルーティングはブリッジの責務外)。DOM が全く読めなかった WebView は素通し = 従来どおり
    /// コンテナだけが出て、ホストは画面ごと XCUITest へ委譲する。
    private func mergeWebViewDOM(into base: InAppSnapshot.Result, max limit: Int)
        -> MergedSnapshot {
        let containers = base.elements.filter { $0.type == "webView" }
        guard !containers.isEmpty else {
            return MergedSnapshot(elements: base.elements, frames: base.frames,
                                  nodes: base.nodes, truncated: base.truncated, note: nil,
                                  webViewPath: nil, truncatedTiers: base.truncatedTiers,
                                  bulkExempt: base.bulkExempt)
        }
        let screen = CGRect(x: base.screen.x, y: base.screen.y,
                            width: base.screen.width, height: base.screen.height)
        var domByRef: [Int: InAppWebViewDOM.Captured] = [:]
        var note: String?
        var anyInterop = false
        for container in containers {
            guard let webView = base.nodes[container.ref] as? WKWebView,
                  let captured = InAppWebViewDOM.capture(webView: webView, screen: screen)
            else { continue }
            if WebViewDOM.isInteropHosted(ancestorClassNames: Self.ancestorClassNames(of: webView)) {
                anyInterop = true
            }
            domByRef[container.ref] = captured
            if note == nil { note = captured.note }
        }
        guard !domByRef.isEmpty else {
            // 読めなかった = ホスト側が XCUITest へ委譲する。経路は委譲した側が名乗る
            return MergedSnapshot(elements: base.elements, frames: base.frames,
                                  nodes: base.nodes, truncated: base.truncated, note: nil,
                                  webViewPath: nil, truncatedTiers: base.truncatedTiers,
                                  bulkExempt: base.bulkExempt)
        }

        // **先着順で切らない**(2026-08-08 実測: 密グリッドページで装飾セルが残り、送信・入力欄・
        // リンクが全部押し出された)。捨てる順は BridgeSnapshotThinning.mergedSlots に1箇所
        // (ネイティブ1段目の間引きと同じ優先度規則)
        let domElements = domByRef.mapValues(\.elements)
        let (kept, dropped) = BridgeSnapshotThinning.mergedSlots(
            base: base.elements, dom: domElements, max: limit)
        // 1段目(ネイティブ)と2段目(DOM マージ)は別々に捨てるので**両方を足す**
        var truncatedTiers = base.truncatedTiers
        if dropped > 0 {
            for (key, count) in BridgeSnapshotThinning.mergedDroppedByTier(
                base: base.elements, dom: domElements, max: limit) {
                truncatedTiers[key, default: 0] += count
            }
        }
        var elements: [ElementInfo] = []
        var frames: [Int: CGRect] = [:]
        var nodes: [Int: NSObject] = [:]
        for slot in kept {
            var copy: ElementInfo
            var frame: CGRect?
            var node: NSObject?
            switch slot {
            case .base(let i):
                copy = base.elements[i]
                frame = base.frames[copy.ref]
                node = base.nodes[copy.ref]
            case .dom(let container, let index):
                copy = domByRef[container]!.elements[index]
                frame = domByRef[container]!.frames[index]
            }
            copy.ref = elements.count + 1
            elements.append(copy)
            if let frame { frames[copy.ref] = frame }
            if let node { nodes[copy.ref] = node }
        }
        return MergedSnapshot(elements: elements, frames: frames, nodes: nodes,
                              truncated: base.truncated + dropped, note: note,
                              webViewPath: anyInterop ? "dom-interop" : "dom",
                              truncatedTiers: truncatedTiers, bulkExempt: base.bulkExempt)
    }

    private func handleTap(_ body: Data) throws -> InAppHTTPServer.Response {
        let req = try decode(TapRequest.self, body)
        if let ref = req.ref {
            let note = try tapByRef(ref, req: req)
            return ok(note)
        }
        try performWithSettle { window in
            let p = try self.resolvePoint(ref: nil, x: req.x, y: req.y)
            // 座標指定は直近 snapshot で point を含む最小要素を activate(SwiftUI の活性化要素は
            // 合成 AX ノードで hitTest の view 階層には無いため、snapshot 要素から解決する)。
            // 合成タッチはジェスチャを発火しないので座標タップが無言 no-op になるのを防ぐ。無ければ合成タッチ。
            if self.activateSnapshotNode(containing: p) { return }
            FTSynthTap(window, p)
        }
        return ok()
    }

    /// ref 指定タップ。accessibilityActivate(要素のデフォルトアクション=ボタン発火・セル選択等を
    /// 確実に起こす)を最優先し、不発なら**整定を待って要素を取り直し再 activate**、それでも不発なら
    /// 合成タッチ(従来のフォールバック)。戻り値は観測用 note(通常経路は nil)。
    ///
    /// 再試行を挟む理由(2026-07-27 sut-ec-mobile お気に入り一覧で実測):
    /// Compose iOS は**画面遷移直後、要素が AX ツリーに載っていても activate がまだ配線されておらず
    /// false を返す**ことがある。その瞬間の合成タッチも無反応(成否も検知できない)で、タップが
    /// 黙って空振りする。1〜2 秒後の再操作は成功するため、アニメーション整定を待ってから
    /// 取り直すと救える。待ちはメインをブロックしない(asyncAfter / InAppSettle)。
    /// 再試行は activate が false のときだけ発生するので、通常経路のコストはゼロ。
    private func tapByRef(_ ref: Int, req: TapRequest) throws -> String? {
        let sem = DispatchSemaphore(value: 0)
        var thrown: Error?
        var note: String?
        // 取り直しで判明した現在 frame の中心。activate が不発でも合成タッチはこちらを使う
        // (stored frame はコールドラウンチ直後のレイアウト確定を跨ぐと古く、RN で1要素ぶん
        // 上のナビを叩いた実害。2026-08-08)
        var freshTapPoint: CGPoint?

        func finish(_ window: UIWindow) {
            InAppSettle.waitOnMain { converged in
                if !converged { self.lastSettleCapped = true }
                sem.signal()
            }
        }
        func synthFallback(_ window: UIWindow) {
            // FTSynthTap は成否を返さないため、要素が実際に反応したかは検知できず
            // 無言 no-op になり得る(throw は追加しない: 誤検知で正常系を壊す方が害が大きい)。
            // 反応しない場合は accessibilityIdentifier(testTag)を付けるか engine=xcuitest を検討
            // (hybrid の XCUITest フォールバックは springboard 参照でアプリ要素には効かない)。
            note = "activate 不発 → 合成タッチ(要素が反応しない場合は testTag 付与か engine=xcuitest を検討)"
            do {
                let p = try freshTapPoint ?? self.resolvePoint(ref: ref, x: req.x, y: req.y)
                FTSynthTap(window, p)
            } catch {
                thrown = error
                sem.signal()
                return
            }
            finish(window)
        }
        func retry(_ remaining: Int, stale: NSObject, window: UIWindow) {
            if let fresh = self.refreshedNode(matching: stale, ref: ref, window: window) {
                // 現在 frame を使うのは**近距離の移動だけ**(コールドラウンチ直後のレイアウト確定
                // = 実測 ~60pt)。id 一致は距離無制限なので、画面遷移後の同 id 要素へ飛ぶと
                // ホストの遮蔽・安全判定が別画面の木に対して無効になる。遠距離は従来どおり
                // stored frame へ落とす
                if let orig = self.frames[ref],
                   abs(fresh.frame.midX - orig.midX) + abs(fresh.frame.midY - orig.midY) <= 120 {
                    freshTapPoint = CGPoint(x: fresh.frame.midX, y: fresh.frame.midY)
                }
                if fresh.node.accessibilityActivate() {
                    note = "activate 不発 → 要素を取り直して再実行"
                    finish(window)
                    return
                }
            }
            guard remaining > 1 else {
                synthFallback(window)
                return
            }
            // AX ツリーの配線はアニメ整定より遅れることがあるため、固定の小休止で1回だけ粘る
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) {
                retry(remaining - 1, stale: stale, window: window)
            }
        }

        DispatchQueue.main.async {
            guard let keyWindow = self.keyWindow() else {
                thrown = InAppError(409, "no key window")
                sem.signal()
                return
            }
            guard let node = self.nodes.object(forKey: NSNumber(value: ref)) as? NSObject else {
                // 保持ノードが無い(従来と同じく座標へ)。宛先は**いま指が当たる窓**
                synthFallback(Self.frontmostTouchableWindow(keyWindow: keyWindow))
                return
            }
            // **合成タッチは対象が載っている窓へ撃つ**(別 UIWindow のモーダルを閉じられない
            // 原因がこれだった。Self.window(of:) の宣言参照)
            let window = Self.window(of: node) ?? Self.frontmostTouchableWindow(keyWindow: keyWindow)
            if node.accessibilityActivate() {
                finish(window)
                return
            }
            // 遷移アニメーションが終わるのを待ってから取り直す(イベント駆動・上限 800ms)
            // ここの打ち切りは note にしない: activate 不発の再試行までの繋ぎで、
            // 続く finish() の整定結果が最終的な申告になる
            InAppSettle.waitOnMain(capMs: 800) { _ in
                retry(2, stale: node, window: window)
            }
        }
        // 最悪ケース: 整定 800ms + 再試行2回(+250ms) + アクション後整定 2500ms
        _ = sem.wait(timeout: .now() + .seconds(8))
        if let thrown { throw thrown }
        return note
    }

    /// 不発だった保持ノードの代わりを、取り直したツリーから探す(id 一致 → 無 id なら frame+label 一致)。
    /// 不発ノードでも identifier/label プロパティは読める(参照は生きている)のでキーに使う。
    /// **self.nodes/frames は更新しない** — この tap リクエスト内の座標解決は元の snapshot が前提のため。
    /// frame は取り直したツリーの現在値を返す(activate 不発時の合成タッチがこれを使う)
    private func refreshedNode(matching stale: NSObject, ref: Int, window: UIWindow)
        -> (node: NSObject, frame: CGRect)? {
        guard let originalFrame = frames[ref] else { return nil }
        let fresh = InAppSnapshot.capture(window: window)
        func distance(_ frame: FTRect) -> CGFloat {
            abs(frame.x - originalFrame.origin.x) + abs(frame.y - originalFrame.origin.y)
        }
        func pack(_ element: ElementInfo) -> (node: NSObject, frame: CGRect)? {
            fresh.nodes[element.ref].map {
                ($0, CGRect(x: element.frame.x, y: element.frame.y,
                            width: element.frame.width, height: element.frame.height))
            }
        }
        if let id = FTAccessibilityIdentifier(stale), !id.isEmpty {
            // 同 id が複数あるときだけ frame で近い方に絞る(通常 testTag は一意)
            let best = fresh.elements.filter { $0.identifier == id }
                .min { distance($0.frame) < distance($1.frame) }
            return best.flatMap { pack($0) }
        }
        // id 無しは frame(±2pt)と label の一致で同定する
        let label = stale.accessibilityLabel
        let candidate = fresh.elements.first {
            $0.label == label && distance($0.frame) <= 2
        }
        return candidate.flatMap { pack($0) }
    }

    /// point を含む最小フレームの snapshot 要素を accessibilityActivate する(座標→要素解決)。
    private func activateSnapshotNode(containing point: CGPoint) -> Bool {
        var bestRef: Int?
        var bestArea = CGFloat.greatestFiniteMagnitude
        for (ref, frame) in frames where frame.contains(point) {
            let area = frame.width * frame.height
            if area < bestArea { bestArea = area; bestRef = ref }
        }
        guard let ref = bestRef,
              let node = nodes.object(forKey: NSNumber(value: ref)) as? NSObject else { return false }
        return node.accessibilityActivate()
    }

    private func handleType(_ body: Data) throws -> InAppHTTPServer.Response {
        let req = try decode(TypeRequest.self, body)
        if req.ref != nil {
            try performWithSettle { window in
                let p = try self.resolvePoint(ref: req.ref, x: nil, y: nil)
                FTSynthTap(window, p)
            }
        }
        // 末尾の改行1つは本文と分けて **pressEnter と同じ経路**へ流す(「type の末尾改行 = pressEnter」が
        // 契約。Compose は "\n" 完全一致の insertText でだけ IME アクションに変換し、UITextField は
        // insertText では発火せず delegate 経由が要る ―― その差の吸収は
        // FTPressEnterOnComposeFirstResponder に1箇所だけ置く)。文中の改行は本文側にそのまま残る
        let (main, hasTrailingNewline) = Self.splitTrailingNewline(req.text)
        var inserted = false
        try performWithSettle { _ in
            if hasTrailingNewline {
                inserted = FTInsertTextIntoFirstResponder(main)
                let enterFired = FTPressEnterOnComposeFirstResponder()
                inserted = inserted || enterFired
            } else {
                inserted = FTInsertTextIntoFirstResponder(req.text)
            }
        }
        guard inserted else {
            // hybrid の XCUITest フォールバック(SystemUIDriver)は springboard 参照のシステム UI 専用で
            // アプリの入力欄を解決できない(2026-07-20 実証)。ここで hybrid を案内しないこと。
            throw InAppError(409, "no focused input field — tap the target field first."
                + " If it still fails on a focused field, the input is not UIKit-backed"
                + " (Compose Multiplatform / Flutter) and the in-app engine cannot attach a"
                + " first responder to type into it: run with an engine=xcuitest run profile"
                + " (iosInappEngine: false). If the field never appears in the AX tree"
                + " (no accessibilityIdentifier/testTag), add a testTag in the app."
                + " Diagnostics: \(FTFirstResponderDiagnostics())")
        }
        return ok()
    }

    private func handleClear(_ body: Data) throws -> InAppHTTPServer.Response {
        let req = try decode(ClearRequest.self, body)
        if req.ref != nil {
            try performWithSettle { window in
                let p = try self.resolvePoint(ref: req.ref, x: nil, y: nil)
                FTSynthTap(window, p)
            }
        }
        var cleared = false
        try performWithSettle { _ in cleared = FTClearTextInFirstResponder() }
        guard cleared else {
            throw InAppError(409, "no focused input field — tap the target field first."
                + " If it still fails on a focused field, the input is not UIKit-backed"
                + " (Compose Multiplatform / Flutter) and the in-app engine cannot attach a"
                + " first responder to clear it: run with an engine=xcuitest run profile"
                + " (iosInappEngine: false). If the field never appears in the AX tree"
                + " (no accessibilityIdentifier/testTag), add a testTag in the app."
                + " Diagnostics: \(FTFirstResponderDiagnostics())")
        }
        return ok()
    }

    /// 末尾の改行1つだけを分離する(text 全体が "\n" のときは分離しない。AndroidDriver の
    /// 同名ヘルパと同じ規則)。戻り値: (本文, 末尾に改行があったか)
    private static func splitTrailingNewline(_ text: String) -> (String, Bool) {
        guard text != "\n", text.hasSuffix("\n") else { return (text, false) }
        return (String(text.dropLast()), true)
    }

    private func handlePressEnter() throws -> InAppHTTPServer.Response {
        var inserted = false
        try performWithSettle { _ in inserted = FTPressEnterOnComposeFirstResponder() }
        guard inserted else {
            // 受け口ごとに機構が違い、吸収は FTPressEnterOnComposeFirstResponder の1箇所にある
            // (Compose = insertText("\n") / UITextField = Return の再現 / Flutter = engine への
            // アクション配送)。ここへ来るのはフォーカスが無いか、Flutter の私有 API が
            // 版差で欠けた場合。xcuitest 経路は in-app が立てたフォーカスに届かないため、
            // hybrid では救済されない(engine=xcuitest 単独プロファイルを案内する)。
            // **エンジン切替を最初に勧めない**(2026-08-08 の監査): 実際に多いのは
            // 「フォーカスが無いだけ」で、それはどのエンジンでも Enter が意味を持たない ——
            // 先に「欄を tap/type しろ」を言い、切替は「フォーカス済みでも失敗する」場合に限る
            throw InAppError(409, "could not fire Enter via the in-app engine."
                + " Most likely no input field is focused — tap or type into the field first"
                + " (Enter needs focus on every engine, so switching engines will not fix that)."
                + " If a field is focused and this still fails, the input implementation is"
                + " unsupported here: run with an engine=xcuitest run profile"
                + " (iosInappEngine: false). Diagnostics: \(FTFirstResponderDiagnostics())")
        }
        return ok()
    }

    /// **iOS ではキーボードを閉じられない**(docs/design.md に不採用の記録)。resignFirstResponder は
    /// 直接送っても nil ターゲットの sendAction でも閉じず(Compose の受け口が自前でフォーカスを
    /// 保持する)、xcuitest の Esc も不発。**嘘の成功を返さない**ため 501 を返す
    private func handleHideKeyboard() throws -> InAppHTTPServer.Response {
        .error("hideKeyboard is Android-only (iOS cannot close the soft keyboard — use pressEnter)", status: 501)
    }

    private func handleSwipe(_ body: Data) throws -> InAppHTTPServer.Response {
        let req = try decode(SwipeRequest.self, body)
        // 端送りで動かせなかった(= もう端)ことをホストへ返すための箱
        var atEdge: Bool?
        // **スクロール領域の指定(SwipeRequest.path)は「座標を撃つ指示」ではなく
        // 「どこを・どれだけ動かすか」の指示として読む**。合成タッチの drag は受理されないので
        // 座標そのものは注入できないが、
        //   - 始点(fromX/fromY)は**必ず対象領域の中**にある(ホストがマージンを内側に取るため)
        //     → 動かすスクロールビュー/AX 要素を選ぶのに使える
        //   - 始点と終点の差 = ホストが意図した移動量 → contentOffset をその量だけ動かせる
        // これで in-app でもマージン指定が効く(ページ送り 0.85 固定ではなくなる)。
        // 座標を無視して画面全体を動かしてはいけない —— **指定と違う領域が黙って動く**
        // Compose / Flutter は自前描画で UIScrollView を持たない(Compose の画面には**本体の
        // スクロールとは無関係な UIScrollView が存在する**ので、contentOffset を動かしても
        // 見た目は変わらず黙った空振りになる)。合成タッチの drag も受理されない
        // (tap のみ通る。2026-07-22 実測)。**UIAccessibility の scroll アクションだけが通る** ——
        // VoiceOver が使う経路なので両フレームワークとも実装している(2026-07-31 実測。
        // Compose = AccessibilityElement / Flutter = SemanticsObjectContainer が受理)。
        //
        // 受理されなければ従来どおり 501 でホストに XCUITest へ回させる。
        //
        // **スクロール目的(req.scroll)のときだけ通す**。DSL の `swipe`(ジェスチャ自体が目的)を
        // ここへ流してはいけない —— ジェスチャ検出パッドの上でも**画面のスクロール可能な親が
        // 受理してしまい**、パッドにジェスチャが届かないまま 200 を返す
        // (2026-07-31 実測: E2E-Flutter のジェスチャ画面が 2/2 で黙って空振りした)。
        //
        // **WebView 画面だけは AX 経路より先に contentOffset を試す**: WKWebView の中の
        // WKScrollView は本物の UIScrollView で、interop が横取りするのはタッチだけなので
        // contentOffset は効く。AX 経路は Web コンテンツを動かせず 501 → ホストが画面ごと
        // XCUITest へ委譲したままスワイプするため、1スクロールが実スワイプ + 委譲 snapshot に
        // なる(2026-08-01 実測 scrollTo 9.5s / scrollToTop 14.2s。同じ画面が SwiftUI ホスト
        // では 1.1s / 1.5s)。
        if ["compose", "flutter"].contains(uiFramework), req.scroll == true {
            // **領域指定つきは受けない**(2026-08-02 実測で確定)。自前描画のフレームワークでは
            // hitTest も AX ツリーも「画面のどこか」までしか絞れず、指定領域の外を指しても
            // 画面本体のスクロールが受理してしまう —— E2E-Flutter で「固定ヘッダを指定したのに
            // リストが動く」を実際に踏んだ。**黙って別の領域を動かすより 501 で XCUITest へ回す**
            // (あちらは座標を実際に撃てるので領域どおりに動く)。
            // UIKit/SwiftUI 側(下の contentOffset 経路)は矩形で対象を選べるので受ける
            if req.path != nil {
                throw InAppError(501, "the in-app engine cannot confine a scroll to a region on"
                    + " \(uiFramework) (self-rendered: neither hitTest nor AX can narrow the"
                    + " area). hybrid falls back to XCUITest")
            }
            var scrolled = false
            try performSettlingIfMoved { window -> Bool in
                if let webScroll = Self.webContentScrollView(in: window, at: req.path) {
                    // 端に達しているだけなら no-op で 200(UIKit 経路と同じ理由。501 を返すと
                    // XCUITest の実スワイプへ切り替わり、以降のジェスチャがラッチで全部 XCUITest 化する)。
                    // **動かしていないので整定も待たない**(performWithSettle の Bool 版)
                    scrolled = true
                    guard Self.hasRoom(webScroll, req.direction) else { return false }
                    Self.scroll(webScroll, direction: req.direction, path: req.path,
                                toEdge: req.edge == true)
                    return req.edge != true   // 端送りは待たない(下の UIKit 経路と同じ理由)
                }
                // AX 経路は端でも true を返すフレームワークがある(Compose)ので「動いた」と扱う
                scrolled = Self.scrollViaAccessibility(window, finger: req.direction)
                return scrolled
            }
            guard scrolled else {
                // 501 = このエンジンでは未対応(/terminate と同じ慣習)。409(Conflict)はキーウィンドウ
                // 不在等の一時的競合と同じコードのため、フォールバック判定に使うと取り違える。
                throw InAppError(501, "nothing on this screen scrolls via the in-app engine"
                    + " (no element accepts the UIAccessibility scroll action, and synthetic"
                    + " drags are not accepted). hybrid falls back to XCUITest")
            }
            return ok()
        }
        if ["compose", "flutter"].contains(uiFramework) {
            // ジェスチャ目的の swipe。自前描画で合成タッチの drag を受理しないので従来どおり
            // XCUITest へ回す(上の AX 経路はスクロールしか代行できない)
            throw InAppError(501, "gesture swipes do not work via the in-app engine on \(uiFramework)"
                + " (self-rendered without UIScrollView, and synthetic drags are not accepted)."
                + " hybrid falls back to XCUITest")
        }
        try performSettlingIfMoved { window -> Bool in
            // UIKit/SwiftUI のスクロールは合成タッチでは駆動できない(ジェスチャ認識器が受理しない)ため、
            // contentOffset を直接動かす(accessibilityScroll は SwiftUI List で片方向しか効かず不安定
            // だった。setContentOffset は決定的・双方向)。
            //
            // 「スクロールビューが無い」と「あるが端に達した」は**区別する**:
            // - 無い = ジェスチャ検出用パッド等。FTSynthSwipe を撃っても DragGesture /
            //   UIPanGestureRecognizer は受理されず 200 で黙って空振りするため、501 で申告して
            //   ホストに XCUITest へ回させる(2026-07-23 に TestProjects/E2E-iOS で実測)
            // - 端に達した = scrollTo の探索が終端に来ただけの**正常な状態**。ここで 501 を返すと
            //   XCUITest の実スワイプ(バウンス)へ切り替わり、さらにラッチで以降のジェスチャ全部が
            //   XCUITest 化して、下端でのタップが不安定になる(実測: scrollTo 直後の行タップが
            //   空振りする flake)。従来どおり無害な no-op にする(次の snapshot が解決を判定する)
            let scrollViews = Self.visibleScrollViews(in: window)
            guard !scrollViews.isEmpty else {
                throw InAppError(501, "no scroll view on this screen can be driven by the in-app engine"
                    + " (synthetic drags are not accepted by gesture recognizers)."
                    + " hybrid falls back to XCUITest")
            }
            // 余地なし = 端。no-op で 200 を返し、**動かしていないので整定も待たない**。
            // **端送りならその事実を返す**(ホストが署名の2回不変を待たずに切り上げられる)
            guard let scrollView = Self.target(scrollViews, direction: req.direction,
                                               path: req.path) else {
                atEdge = req.edge == true
                return false
            }
            Self.scroll(scrollView, direction: req.direction, path: req.path,
                        toEdge: req.edge == true)
            // **端送りは動かした後も待たない**: 端送りの後にホストは必ず
            // `settledSignature`(署名が2回続けて一致)で整定を待つので、ここで待つのは二重。
            // 常にアニメーションし続ける画面ではこの cap(2.5s)がそのまま所要になり、
            // 受け手の実文書で端送りが 3.0s 固定になっていた残りがこれ。
            // **探索や単発の swipe では従来どおり待つ** —— あちらは待たないと次の解決が
            // 動いている木を掴む(XCUITest ブリッジが `/swipe` を整定対象から外したのと同じ線引き)
            return req.edge != true
        }
        return ok(atEdge: atEdge)
    }

    /// UIAccessibility の scroll アクションでスクロールする(Compose / Flutter 専用)。
    /// 受理した要素が1つでもあれば true。
    ///
    /// **UIKit/SwiftUI には使わない**: SwiftUI List では片方向しか効かず不安定で、
    /// `setContentOffset` の方が決定的・双方向(下の contentOffset 経路)。
    ///
    /// **1回 = 1ページ**(API がページ単位なので刻み幅は選べない)。contentOffset 経路の ~85% より
    /// 粗く、スクロール探索が要素を跨ぐ余地はあるが、**この2フレームワークの従来の経路は
    /// XCUITest の実スワイプ(慣性つき = 1ページ以上動く)**だったので、粗さは悪化しない。
    ///
    /// 走査は深さ優先で**最初に受理した要素**を採る。横カルーセルと縦リストが同居する画面でも、
    /// 向きの合わない要素は false を返すので実質的に選り分けられる。
    /// 端に達したときの挙動はフレームワークで割れる(Compose = true のまま動かない /
    /// Flutter = false)。**false を「スクロール不能」と区別できない**ので、呼び出し側は
    /// 501 を返しホストの XCUITest フォールバックに委ねる(端での 1 回ぶんは無駄になるが、
    /// 「スクロールできない画面で黙って成功する」より安全)
    private static func scrollViaAccessibility(_ root: NSObject, finger: FTSwipeDirection) -> Bool {
        // 指の向き = コンテンツと逆(指を上へ = 次のページへ送る)
        let direction: UIAccessibilityScrollDirection
        switch finger {
        case .up: direction = .down
        case .down: direction = .up
        case .left: direction = .right
        case .right: direction = .left
        }
        var visited = 0
        return scrollWalk(root, direction, visited: &visited)
    }

    /// 走査上限。AX ツリーは深いことがあるので暴走を止める(実測の受理は 20〜100 要素目)
    private static let axScrollMaxVisits = 2000

    private static func scrollWalk(_ node: NSObject, _ direction: UIAccessibilityScrollDirection,
                                   visited: inout Int) -> Bool {
        if visited >= axScrollMaxVisits { return false }
        visited += 1
        if node.accessibilityScroll(direction) { return true }
        if let elements = node.accessibilityElements as? [NSObject] {
            for element in elements where scrollWalk(element, direction, visited: &visited) { return true }
        }
        // Flutter の SemanticsObjectContainer は accessibilityElements を実装せず、旧式の
        // indexed API だけを実装する(InAppSnapshot.axChildren と同じ事情)
        let count = node.accessibilityElementCount()
        if count != NSNotFound && count > 0 {
            for i in 0..<count {
                guard let element = node.accessibilityElement(at: i) as? NSObject else { continue }
                if scrollWalk(element, direction, visited: &visited) { return true }
            }
        }
        if let view = node as? UIView {
            for sub in view.subviews where scrollWalk(sub, direction, visited: &visited) { return true }
        }
        return false
    }

    /// スワイプ1回 = 可視領域の ~85% 分だけ contentOffset を動かす(実機スワイプの体感に合わせる)。
    /// 指の向き=コンテンツと逆(上スワイプ=下方向へスクロール=offset.y 増)。範囲外はクランプ。
    /// 1回ぶんのスクロール。**領域指定(path)があればホストが意図した移動量をそのまま使う**
    /// (= マージン指定が in-app でも効く)。無ければ従来どおりビューポートの 85%。
    /// 移動の向きは指の向きと逆。
    ///
    /// **`toEdge`(= SwipeRequest.edge)のときは刻まずに端まで寄せる**: この経路にジェスチャは
    /// 無いので「1回ぶん」を刻む理由は実機の体感に合わせること以外に無く、scrollToEdge の
    /// 目的は端そのもの。長文(利用規約等)では往復回数がページ数に比例していた
    private static func scroll(_ sv: UIScrollView, direction: FTSwipeDirection,
                               path: FTSwipePath?, toEdge: Bool = false) {
        if toEdge { scrollToEdge(sv, direction: direction); return }
        guard let path else { scrollByPage(sv, direction: direction); return }
        var offset = sv.contentOffset
        offset.x += path.fromX - path.toX
        offset.y += path.fromY - path.toY
        clampAndApply(sv, offset)
    }

    /// 指の向きに対応するコンテンツの端まで一度に寄せる(clampAndApply が実際の限界へ丸める =
    /// 端の値をここで持たない)。**領域指定(path)は対象の選択にだけ使われ、移動量は無視される**
    /// —— 端まで送るのだから途中の量に意味が無い
    private static func scrollToEdge(_ sv: UIScrollView, direction: FTSwipeDirection) {
        var offset = sv.contentOffset
        switch direction {
        case .up:    offset.y = .greatestFiniteMagnitude
        case .down:  offset.y = -.greatestFiniteMagnitude
        case .left:  offset.x = .greatestFiniteMagnitude
        case .right: offset.x = -.greatestFiniteMagnitude
        }
        clampAndApply(sv, offset)
    }

    private static func scrollByPage(_ sv: UIScrollView, direction: FTSwipeDirection) {
        let inset = sv.adjustedContentInset
        let stepY = (sv.bounds.height - inset.top - inset.bottom) * 0.85
        let stepX = (sv.bounds.width - inset.left - inset.right) * 0.85
        var offset = sv.contentOffset
        switch direction {
        case .up:    offset.y += stepY
        case .down:  offset.y -= stepY
        case .left:  offset.x += stepX
        case .right: offset.x -= stepX
        }
        clampAndApply(sv, offset)
    }

    /// コンテンツ範囲へ丸めてから適用する(はみ出すとバウンスして戻る = 動かないのと同じ)
    private static func clampAndApply(_ sv: UIScrollView, _ offset: CGPoint) {
        let inset = sv.adjustedContentInset
        let minY = -inset.top, maxY = max(-inset.top, sv.contentSize.height + inset.bottom - sv.bounds.height)
        let minX = -inset.left, maxX = max(-inset.left, sv.contentSize.width + inset.right - sv.bounds.width)
        var clamped = offset
        clamped.y = min(max(offset.y, minY), maxY)
        clamped.x = min(max(offset.x, minX), maxX)
        sv.setContentOffset(clamped, animated: false)
    }

    private static func visibleScrollViews(in window: UIWindow) -> [UIScrollView] {
        var found: [UIScrollView] = []
        var stack: [UIView] = [window]
        while let v = stack.popLast() {
            if let sv = v as? UIScrollView, !sv.isHidden, sv.alpha > 0.01 {
                found.append(sv)
            }
            stack.append(contentsOf: v.subviews)
        }
        return found
    }

    /// **指定点(領域指定が無ければ画面中央)を覆う WKWebView 自身のスクロールビュー**
    /// (WKScrollView)。無ければ nil。
    ///
    /// 点で絞るのは、小さな埋め込み WebView のために画面本体のスクロールを奪わないため
    /// (XCUITest の実スワイプが駆動するのも画面中央の下にあるものだけ = 従来と同じ対象に揃う)。
    /// 面積で選ぶ判定は使えない: Compose の画面には本体と無関係な UIScrollView が居るので、
    /// 「WebView 由来か」を先に効かせる必要がある。
    private static func webContentScrollView(in window: UIWindow, at path: FTSwipePath?) -> UIScrollView? {
        let center = path.map { CGPoint(x: $0.fromX, y: $0.fromY) }
            ?? CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        var best: UIScrollView?
        var bestArea: CGFloat = 0
        for sv in visibleScrollViews(in: window) where sv.superview is WKWebView {
            let frame = sv.convert(sv.bounds, to: window)
            guard frame.contains(center) else { continue }
            let area = frame.width * frame.height
            if area > bestArea { best = sv; bestArea = area }
        }
        return best
    }

    /// 動かすスクロールビューを選ぶ。**領域指定(path)があれば始点を含むものを優先する** ——
    /// 始点はホストが対象領域の内側に取っているので、これで「指定と違う領域が動く」ことがなくなる。
    /// 入れ子(リストの中の横カルーセル等)では**内側 = 面積が小さい方**を採る:
    /// 指定された領域そのものを動かしたいのであって、その親ではない。
    /// 含むものが無ければ従来どおり面積最大へ落ちる(領域が UIScrollView でない画面もあるため)
    private static func target(_ scrollViews: [UIScrollView], direction: FTSwipeDirection,
                               path: FTSwipePath?) -> UIScrollView? {
        guard let path else { return largestWithRoom(scrollViews, direction: direction) }
        let point = CGPoint(x: path.fromX, y: path.fromY)
        let containing = scrollViews.filter { sv in
            guard hasRoom(sv, direction), let window = sv.window else { return false }
            return sv.convert(sv.bounds, to: window).contains(point)
        }
        if let innermost = containing.min(by: { $0.bounds.width * $0.bounds.height
                                                < $1.bounds.width * $1.bounds.height }) {
            return innermost
        }
        return largestWithRoom(scrollViews, direction: direction)
    }

    /// 面積最大の、**その向きに実際にスクロール余地がある**スクロールビュー。
    /// 余地の判定を入れているのは、画面上に本体のスクロールとは無関係な(コンテンツが収まりきっている)
    /// UIScrollView が居ることがあり、それを動かすと「offset は変わったが見た目は不変」= 黙った空振りに
    /// なるため。全て余地なし = 端に達している(呼び出し側が no-op にする)。
    private static func largestWithRoom(_ scrollViews: [UIScrollView],
                                        direction: FTSwipeDirection) -> UIScrollView? {
        var best: UIScrollView?
        var bestArea: CGFloat = 0
        for sv in scrollViews where hasRoom(sv, direction) {
            let area = sv.bounds.width * sv.bounds.height
            if area > bestArea { best = sv; bestArea = area }
        }
        return best
    }

    /// 指定方向へまだ動かせるか(1pt でも余地があれば真)。指の向きとスクロール方向は逆。
    private static func hasRoom(_ sv: UIScrollView, _ direction: FTSwipeDirection) -> Bool {
        let inset = sv.adjustedContentInset
        let maxY = max(-inset.top, sv.contentSize.height + inset.bottom - sv.bounds.height)
        let maxX = max(-inset.left, sv.contentSize.width + inset.right - sv.bounds.width)
        switch direction {
        case .up:    return sv.contentOffset.y < maxY - 1
        case .down:  return sv.contentOffset.y > -inset.top + 1
        case .left:  return sv.contentOffset.x < maxX - 1
        case .right: return sv.contentOffset.x > -inset.left + 1
        }
    }

    // 合成タッチの押下保持はどのフレームワークでも長押しとして受理されない
    // (Compose だけでなく SwiftUI の onLongPressGesture でも発火しないことを 2026-07-23 に
    // TestProjects/E2E-iOS で実測。tap だけが通る)。黙って空振りさせず xcuitest へ誘導するため、
    // 実装(FTSynthPress 経路)は持たず常に 501 を返す。
    // 501 = このエンジンでは未対応(/terminate と同じ慣習。409 は一時的競合なので取り違えない)。
    /// 合成タッチの多点・連打を受理するのは**自前描画のフレームワークだけ**(2026-08-04 実測):
    /// Compose / Flutter は生タッチを自前のアリーナで捌くので通るが、UIKit/SwiftUI の
    /// UIGestureRecognizer は受理しない(press / drag が in-app で 501 なのと同じ機構)。
    /// **受理しない側で 200 を返すと黙って無反応になる**ので、ここで 501 を返して
    /// ホストに XCUITest へ回させる(あちらは UIKit/SwiftUI では正しく動く)
    private func requireSelfRenderedFramework(_ action: String) throws {
        guard ["compose", "flutter"].contains(uiFramework) else {
            throw InAppError(501, "\(action) does not work via the in-app engine on \(uiFramework)"
                + " (UIGestureRecognizer does not accept synthetic touches)."
                + " hybrid falls back to XCUITest")
        }
    }

    /// ダブルタップ。**in-app の方が正確な場面がある**: 離してから次に押すまでの間隔を
    /// こちらで決められるので、XCTest の doubleTap(この間隔が 0ms)では単タップに落ちる
    /// Compose(iOS)でも成立する(2026-08-04 実測)
    private func handleDoubleTap(_ body: Data) throws -> InAppHTTPServer.Response {
        let req = try decode(TapRequest.self, body)
        try requireSelfRenderedFramework("doubleTap")
        try performWithSettle { window in
            let p = try self.resolvePoint(ref: req.ref, x: req.x, y: req.y)
            FTSynthDoubleTap(window, p, 0.08)
        }
        return ok()
    }

    /// 2本指ピンチ。対象領域(PinchRequest.frame。nil = 画面全体)の中心で開閉する。
    /// **XCUITest より指を大きく動かせる**のが効く場面がある: XCTest のピンチは指の間隔を
    /// 8px 程度からしか開かず、Flutter のスケール判定のしきい値に届かない(2026-08-04 実測)。
    /// こちらは対象領域の短辺 90% まで開くので届く
    private func handlePinch(_ body: Data) throws -> InAppHTTPServer.Response {
        let req = try decode(PinchRequest.self, body)
        try requireSelfRenderedFramework("pinch")
        guard req.scale > 0, req.scale != 1, req.scale.isFinite else {
            throw InAppError(400, "scale must be positive and not 1 (got: \(req.scale))")
        }
        try performWithSettle { window in
            let bounds = window.bounds
            let frame = req.frame.map {
                CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            } ?? bounds
            // 指の間隔は**倍率が正確に出る側から決める**(Android ブリッジの handlePinch と同じ規律)
            let maxSpan = min(frame.width, frame.height) * 0.9
            let startSpan: Double
            let endSpan: Double
            if req.scale > 1 {
                endSpan = maxSpan
                startSpan = max(maxSpan / req.scale, 16)
            } else {
                startSpan = maxSpan
                endSpan = max(maxSpan * req.scale, 16)
            }
            FTSynthPinch(window, CGPoint(x: frame.midX, y: frame.midY),
                         startSpan, endSpan, req.durationSeconds ?? 0.5, 20)
        }
        return ok()
    }

    /// POST /rotate. `requestGeometryUpdate` is async — the readback right after the request can
    /// still be the pre-rotation value — so poll until it matches or the deadline passes; never
    /// answer 200 with a value that isn't what was requested (RotationSettle.deadlineSeconds).
    private func handleRotate(_ body: Data) throws -> InAppHTTPServer.Response {
        let req = try decode(RotateRequest.self, body)
        let mask: UIInterfaceOrientationMask
        switch req.orientation {
        case .portrait: mask = .portrait
        // **どちらの landscape でもよい**(契約は「アプリの UI が横になること」で、物理方向は
        // テストから観測できないので約束しない。FTOrientation の宣言を参照)
        case .landscape: mask = .landscapeLeft
        }
        try mainSync {
            guard let scene = self.keyWindow()?.windowScene else {
                throw InAppError(409, "no window scene")
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
        let deadline = Date().addingTimeInterval(RotationSettle.deadlineSeconds)
        while Date() < deadline {
            let current: FTOrientation? = mainSync { self.keyWindow()?.windowScene?.interfaceOrientation.ftOrientation }
            if current == req.orientation { return .json(RotateResponse(orientation: req.orientation)) }
            Thread.sleep(forTimeInterval: RotationSettle.pollIntervalSeconds)
        }
        let observed: FTOrientation? = mainSync { self.keyWindow()?.windowScene?.interfaceOrientation.ftOrientation }
        throw InAppError(422, "orientation did not settle to \(req.orientation.rawValue) within "
            + "\(RotationSettle.deadlineSeconds)s (observed: \(observed?.rawValue ?? "unknown"))")
    }

    private func handlePress(_ body: Data) throws -> InAppHTTPServer.Response {
        throw InAppError(501, "press (long-press) does not work via the in-app engine"
            + " (gesture recognizers do not accept a held synthetic touch)."
            + " hybrid falls back to XCUITest; with engine=inapp alone, set"
            + " iosInappEngine: false (xcuitest) in the run profile")
    }

    private func handleScreenshot() throws -> InAppHTTPServer.Response {
        try mainSync {
            guard let key = self.keyWindow() else {
                throw InAppError(409, "no key window")
            }
            // **可視な窓を奥から手前へ重ねて描く**。キーウィンドウ1枚だけ描くと、
            // 別 UIWindow のモーダルが**写らない**画像を証跡として残すことになる
            // (木は載せるようになったのに画像だけ食い違う)
            let windows = Self.visibleWindows(keyWindow: key)
                .sorted { $0.windowLevel < $1.windowLevel }
            let renderer = UIGraphicsImageRenderer(bounds: key.bounds)
            let image = renderer.image { _ in
                for window in windows {
                    window.drawHierarchy(in: window.frame, afterScreenUpdates: false)
                }
            }
            guard let png = image.pngData() else {
                throw InAppError(500, "PNG encoding failed")
            }
            return .png(png)
        }
    }

    // MARK: - 実行ヘルパ

    /// バックグラウンドのハンドラからメインで同期実行する。UIKit 参照用。
    private func mainSync<T>(_ block: @escaping () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try block() }
        return try DispatchQueue.main.sync { try block() }
    }

    /// メインでアクションを実行し、整定(または cap)まで待ってから返る。
    /// block 内の throw はバックグラウンド側へ伝播する。
    /// blockBudgetMs = block 自体がメインを保持する見込み時間(press の押下保持等)。
    /// semaphore タイムアウト = blockBudgetMs + capMs + 余裕 とし、settle 完了前の早期打ち切りを防ぐ。
    private func performWithSettle(capMs: Int = 2500, blockBudgetMs: Int = 0,
                                   _ block: @escaping (UIWindow) throws -> Void) throws {
        try performSettlingIfMoved(capMs: capMs, blockBudgetMs: blockBudgetMs) { window -> Bool in
            try block(window)
            return true
        }
    }

    /// **block が「何も動かしていない」と申告したら整定を待たない**版。
    /// 端に達した後のスクロール要求(余地が無い = no-op)がこれを使う。
    ///
    /// 自分が動かしていない画面の整定を待っても**収束は自分とは無関係**で、
    /// 常にアニメーションしている画面では毎回 cap(2,500ms)を丸ごと捨てる ——
    /// 端送りは「動かす1回 + 端を確認する数回」なので、確認のぶんがそのまま所要になる
    /// (受け手の実アプリで `scrollToBottom`/`scrollToTop` が距離にも画面にも依存せず
    /// 8.0s 固定になっていた。2026-08-20 報告)。
    private func performSettlingIfMoved(capMs: Int = 2500, blockBudgetMs: Int = 0,
                                        _ block: @escaping (UIWindow) throws -> Bool) throws {
        let sem = DispatchSemaphore(value: 0)
        var thrown: Error?
        DispatchQueue.main.async {
            guard let key = self.keyWindow() else {
                thrown = InAppError(409, "no key window")
                sem.signal()
                return
            }
            // **操作の宛先は「いま指が当たる窓」**。keyWindow 固定だと、
            // 別 UIWindow のモーダルが出ている間にスクロールや座標タップが**背面へ抜ける**
            let window = Self.frontmostTouchableWindow(keyWindow: key)
            let moved: Bool
            do {
                moved = try block(window)
            } catch {
                thrown = error
                sem.signal()
                return
            }
            guard moved else { sem.signal(); return }
            InAppSettle.waitOnMain(capMs: capMs) { converged in
                if !converged { self.lastSettleCapped = true }
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + .milliseconds(blockBudgetMs + capMs + 1500))
        if let thrown { throw thrown }
    }

    private func resolvePoint(ref: Int?, x: Double?, y: Double?) throws -> CGPoint {
        if let ref {
            guard let frame = frames[ref] else {
                throw InAppError(404, "unknown ref [\(ref)] — run GET /snapshot first")
            }
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        if let x, let y { return CGPoint(x: x, y: y) }
        throw InAppError(400, "ref or x/y is required")
    }

    private func decode<T: Decodable>(_ type: T.Type, _ body: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: body)
        } catch {
            throw InAppError(400, "invalid JSON in the request body: \(error)")
        }
    }


    /// 木に載せる窓 = **キーウィンドウ + その上に重なっている可視の窓**。
    /// **覆われた要素を落とすのは `InAppSnapshot.isCovered`**(理由はそちらの宣言)。
    /// **キーボードの窓は常に除く**(キーは大量に写り込み、表示判定と実矩形は
    /// keyboardIsVisible / keyboardFrameIfVisible が別に申告する既存の設計)
    static func visibleWindows(keyWindow: UIWindow) -> [UIWindow] {
        var result = [keyWindow]
        for window in UIApplication.shared.windows where window !== keyWindow {
            let name = NSStringFromClass(type(of: window))
            guard !name.contains("TextEffects"), !name.contains("RemoteKeyboard") else { continue }
            guard !window.isHidden, window.alpha > 0.01,
                  window.bounds.width > 0, window.bounds.height > 0 else { continue }
            result.append(window)
        }
        return result
    }

    /// **その要素が載っている窓**。合成タッチはこの窓へ撃つ(2026-08-20 の受け手報告)。
    ///
    /// 木は可視な窓を歩くようになったのに(bridgeProtocolVersion 75)、**タップは keyWindow
    /// 固定のまま**だった。別 UIWindow のモーダル(SDK のカード)では、activate が不発で
    /// 合成タッチへ落ちた瞬間に**背面のアプリ側へ撃つ**ことになり、「見えているのに閉じられない」。
    /// a11y 要素は `UIView` とは限らないので `accessibilityContainer` も辿る
    static func window(of node: NSObject) -> UIWindow? {
        // **`value(forKey:)` は使わない** —— 未定義キーで NSUnknownKeyException が飛び、
        // Swift では捕まえられないので**テスト対象アプリを落とす**。
        // セレクタの有無を確かめてから呼ぶ(親を辿れない型はそこで打ち切る)
        let containerSelector = NSSelectorFromString("accessibilityContainer")
        var current: NSObject? = node
        var hops = 0
        while let object = current, hops < 20 {
            if let window = object as? UIWindow { return window }
            if let view = object as? UIView, let window = view.window { return window }
            guard object.responds(to: containerSelector),
                  let next = object.perform(containerSelector)?.takeUnretainedValue() as? NSObject
            else { return nil }
            current = next
            hops += 1
        }
        return nil
    }

    /// 座標だけで撃つ操作の宛先 = **一番手前の、タッチを受ける窓**。
    /// ref が無い操作(座標タップ・向き指定のスワイプ)は対象ノードを持たないので、
    /// 「いま指が当たる窓」を選ぶ(木が覆いを落とす規則と揃う)
    static func frontmostTouchableWindow(keyWindow: UIWindow) -> UIWindow {
        let center = CGPoint(x: keyWindow.bounds.midX, y: keyWindow.bounds.midY)
        var best = keyWindow
        for window in UIApplication.shared.windows where window !== keyWindow {
            let name = NSStringFromClass(type(of: window))
            guard !name.contains("TextEffects"), !name.contains("RemoteKeyboard") else { continue }
            guard !window.isHidden, window.alpha > 0.01,
                  window.windowLevel > best.windowLevel else { continue }
            let local = window.convert(center, from: nil)
            guard window.bounds.contains(local),
                  window.hitTest(local, with: nil) != nil else { continue }
            best = window
        }
        return best
    }

    private func keyWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let key = windowScene.windows.first(where: { $0.isKeyWindow }) { return key }
            if let first = windowScene.windows.first { return first }
        }
        return nil
    }
}

struct InAppError: Error {
    let status: Int
    let message: String
    init(_ status: Int, _ message: String) {
        self.status = status
        self.message = message
    }
}

private extension UIInterfaceOrientation {
    var ftOrientation: FTOrientation? {
        switch self {
        case .portrait: return .portrait
        // 左右どちらも landscape として読む(要求と同じ側かは問わない = 契約どおり)
        case .landscapeLeft, .landscapeRight: return .landscape
        default: return nil   // portraitUpsideDown/unknown — not part of FTOrientation
        }
    }
}
