// アプリ内常駐ブリッジのエントリと HTTP ルータ。dylib は SIMCTL_CHILD_DYLD_INSERT_LIBRARIES で
// 対象アプリに注入され、boot.m の構成子が FTInAppBridgeStart を呼ぶ。ポートは環境変数 FT_PORT
// (既定 8123=BridgeAPI.defaultPort)。エンドポイントは Runner/BridgeRouter と HTTP 互換にし、
// ホスト側(FTBridgeClient)を無改変で使えるようにする(単一実装原則)。
//
// ハンドラは InAppHTTPServer の accept ループ(バックグラウンド)で呼ばれる。UIKit 参照や
// タッチ合成はメインへホップし、アクションは実行後に整定(InAppSettle)を待ってから応答する。
//
// 実装エンドポイント: /status /snapshot /tap /type /clear /pressEnter /swipe /press /screenshot。
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
        do {
            try server.start()
            self.server = server
            NSLog("FTInAppBridge listening on 127.0.0.1:\(port)")
        } catch {
            NSLog("FTInAppBridge failed to start: \(error)")
        }
    }

    private func handle(_ req: InAppHTTPServer.Request) -> InAppHTTPServer.Response {
        do {
            switch (req.method, req.path) {
            case ("GET", "/status"): return handleStatus()
            case ("GET", "/snapshot"): return try handleSnapshot()
            case ("POST", "/tap"): return try handleTap(req.body)
            case ("POST", "/type"): return try handleType(req.body)
            case ("POST", "/clear"): return try handleClear(req.body)
            case ("POST", "/pressEnter"): return try handlePressEnter()
            case ("POST", "/swipe"): return try handleSwipe(req.body)
            case ("POST", "/press"): return try handlePress(req.body)
            case ("GET", "/screenshot"): return try handleScreenshot()
            case ("POST", "/session"):
                // in-app ブリッジは注入先アプリそのものに常駐している。ホストの launch(bundleID) は
                // 既に起動済みの当該アプリを指すので OK を返す(状態リセットが要る場合は
                // ホスト側がプロセス再起動+再注入で行う=lifecycle だけホスト責務)。
                let req = try decode(LaunchRequest.self, req.body)
                guard req.bundleID == Bundle.main.bundleIdentifier else {
                    throw InAppError(409, "in-app ブリッジは注入先アプリ(\(Bundle.main.bundleIdentifier ?? "?"))専用です(要求: \(req.bundleID))")
                }
                return .json(OKResponse())
            case ("POST", "/terminate"):
                return .error("/terminate は in-app では未対応(ホスト側でプロセス制御)", status: 501)
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
                // 合成タッチは「時間・移動を伴うジェスチャ」を駆動できない。これは Compose 固有ではなく
                // SwiftUI/UIKit でも同じ(2026-07-23 に Projects/E2E-iOS で実測)。
                // - press は全フレームワークで駆動不能 → 常に申告する
                // - swipe は UIScrollView の contentOffset を直接動かす経路があるので UIKit では通ることが
                //   多い。ただし Compose はその経路が無関係な UIScrollView を動かして空振りするため申告する
                //   (UIKit で対象スクロールビューが無い場合は handleSwipe が個別に 501 を返す)
                // ホストはこの申告を見てジェスチャを XCUITest へ回す。撃たれた場合は 501 で拒否する
                // (申告と拒否の二重化。申告を見ないホスト・旧ホストでも黙って空振りしない)。
                // flutter も swipe を申告する: UIScrollView が存在しないため in-app の
                // contentOffset 経路が無く、常に 501 になる(往復を省くため最初から XCUITest へ)
                unsupportedActions: ["compose", "flutter"].contains(self.uiFramework)
                    ? ["swipe", "press"] : ["press"],
                // 起動元の自己申告(InAppLauncher が SIMCTL_CHILD_FT_OWNER_REPO で注入)
                ownerRepo: ProcessInfo.processInfo.environment["FT_OWNER_REPO"]))
        }
    }

    private func handleSnapshot() throws -> InAppHTTPServer.Response {
        let base: InAppSnapshot.Result = try mainSync {
            guard let window = self.keyWindow() else {
                throw InAppError(409, "キーウィンドウがありません")
            }
            // Flutter は engine.ensureSemanticsEnabled を呼ばないと SemanticsObject が生成されず
            // 0 要素になる(_AXSSetAutomationEnabled は Flutter engine に効かない)。冪等・非 Flutter は no-op。
            // 起動直後は FlutterViewController が未生成のことがあるため boot 時でなく snapshot ごとに呼ぶ
            FTEnsureFlutterSemantics()
            return InAppSnapshot.capture(window: window)
        }

        // **mainSync の外で行う**: WKWebView の DOM 読みは evaluateJavaScript の完了を待つが、
        // その完了はメインキューへ配送されるため、メインを保持したまま待つとデッドロックする
        let merged = mergeWebViewDOM(into: base)

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
            webViewPath: merged.webViewPath))
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
        /// BridgeDTO の SnapshotResponse.webViewPath。DOM を読めたときだけ "dom"
        var webViewPath: String?
    }

    /// WebView コンテナの**直後**に DOM 由来の要素を差し込み、ref を採番し直す
    /// (文書順 = a11y 経路と同じ並びにする。並びが変わると `.型[n]` の意味が変わる)。
    ///
    /// DOM 要素には **AX ノードを紐付けない**。tapByRef はノードが無いと座標タップへ落ちるので、
    /// それがそのまま「DOM の矩形へ合成タッチを打つ」動作になる(DOM 側で click させない理由は
    /// InAppWebViewDOM の冒頭コメント参照)。
    ///
    /// DOM が読めなかった WebView は素通し = 従来どおりコンテナだけが出る。
    /// ホスト側(WebViewDelegatingDriver)はそれを見て XCUITest へ委譲する。
    private func mergeWebViewDOM(into base: InAppSnapshot.Result) -> MergedSnapshot {
        // interop 配下かどうかの選別はコンテナごとに下のループで行う(アプリ単位にしない理由も
        // そちらのコメント参照)。ここでは全コンテナを候補にするだけ
        let containers = base.elements.filter { $0.type == "webView" }
        guard !containers.isEmpty else {
            return MergedSnapshot(elements: base.elements, frames: base.frames,
                                  nodes: base.nodes, truncated: base.truncated, note: nil,
                                  webViewPath: nil)
        }
        let screen = CGRect(x: base.screen.x, y: base.screen.y,
                            width: base.screen.width, height: base.screen.height)
        var domByRef: [Int: InAppWebViewDOM.Captured] = [:]
        var note: String?
        for container in containers {
            guard let webView = base.nodes[container.ref] as? WKWebView,
                  // interop(Compose / Flutter)配下の WebView は DOM を読んでも操作が届かない
                  // ため読まない = 従来どおり画面ごと XCUITest へ委譲される。
                  // **アプリ単位ではなく WebView 単位で見る**(isInteropHosted のコメント参照)
                  !WebViewDOM.isInteropHosted(ancestorClassNames: Self.ancestorClassNames(of: webView)),
                  let captured = InAppWebViewDOM.capture(webView: webView, screen: screen)
            else { continue }
            domByRef[container.ref] = captured
            if note == nil { note = captured.note }
        }
        guard !domByRef.isEmpty else {
            // 読めなかった = ホスト側が XCUITest へ委譲する。経路は委譲した側が名乗る
            return MergedSnapshot(elements: base.elements, frames: base.frames,
                                  nodes: base.nodes, truncated: base.truncated, note: nil,
                                  webViewPath: nil)
        }

        var elements: [ElementInfo] = []
        var frames: [Int: CGRect] = [:]
        var nodes: [Int: NSObject] = [:]
        var truncated = base.truncated
        func append(_ info: ElementInfo, frame: CGRect?, node: NSObject?) {
            guard elements.count < BridgeAPI.maxSnapshotElements else {
                truncated += 1
                return
            }
            var copy = info
            copy.ref = elements.count + 1
            elements.append(copy)
            if let frame { frames[copy.ref] = frame }
            if let node { nodes[copy.ref] = node }
        }
        for info in base.elements {
            append(info, frame: base.frames[info.ref], node: base.nodes[info.ref])
            guard let dom = domByRef[info.ref] else { continue }
            for (index, element) in dom.elements.enumerated() {
                append(element, frame: dom.frames[index], node: nil)
            }
        }
        return MergedSnapshot(elements: elements, frames: frames, nodes: nodes,
                              truncated: truncated, note: note, webViewPath: "dom")
    }

    private func handleTap(_ body: Data) throws -> InAppHTTPServer.Response {
        let req = try decode(TapRequest.self, body)
        if let ref = req.ref {
            let note = try tapByRef(ref, req: req)
            return .json(OKResponse(note: note))
        }
        try performWithSettle { window in
            let p = try self.resolvePoint(ref: nil, x: req.x, y: req.y)
            // 座標指定は直近 snapshot で point を含む最小要素を activate(SwiftUI の活性化要素は
            // 合成 AX ノードで hitTest の view 階層には無いため、snapshot 要素から解決する)。
            // 合成タッチはジェスチャを発火しないので座標タップが無言 no-op になるのを防ぐ。無ければ合成タッチ。
            if self.activateSnapshotNode(containing: p) { return }
            FTSynthTap(window, p)
        }
        return .json(OKResponse())
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

        func finish(_ window: UIWindow) {
            InAppSettle.waitOnMain { sem.signal() }
        }
        func synthFallback(_ window: UIWindow) {
            // FTSynthTap は成否を返さないため、要素が実際に反応したかは検知できず
            // 無言 no-op になり得る(throw は追加しない: 誤検知で正常系を壊す方が害が大きい)。
            // 反応しない場合は accessibilityIdentifier(testTag)を付けるか engine=xcuitest を検討
            // (hybrid の XCUITest フォールバックは springboard 参照でアプリ要素には効かない)。
            note = "activate 不発 → 合成タッチ(要素が反応しない場合は testTag 付与か engine=xcuitest を検討)"
            do {
                let p = try self.resolvePoint(ref: ref, x: req.x, y: req.y)
                FTSynthTap(window, p)
            } catch {
                thrown = error
                sem.signal()
                return
            }
            finish(window)
        }
        func retry(_ remaining: Int, stale: NSObject, window: UIWindow) {
            if let fresh = self.refreshedNode(matching: stale, ref: ref, window: window),
               fresh.accessibilityActivate() {
                note = "activate 不発 → 要素を取り直して再実行"
                finish(window)
                return
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
            guard let window = self.keyWindow() else {
                thrown = InAppError(409, "キーウィンドウがありません")
                sem.signal()
                return
            }
            guard let node = self.nodes.object(forKey: NSNumber(value: ref)) as? NSObject else {
                synthFallback(window)   // 保持ノードが無い(従来と同じく座標へ)
                return
            }
            if node.accessibilityActivate() {
                finish(window)
                return
            }
            // 遷移アニメーションが終わるのを待ってから取り直す(イベント駆動・上限 800ms)
            InAppSettle.waitOnMain(capMs: 800) {
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
    /// **self.nodes/frames は更新しない** — この tap リクエスト内の座標解決は元の snapshot が前提のため
    private func refreshedNode(matching stale: NSObject, ref: Int, window: UIWindow) -> NSObject? {
        guard let originalFrame = frames[ref] else { return nil }
        let fresh = InAppSnapshot.capture(window: window)
        func distance(_ frame: FTRect) -> CGFloat {
            abs(frame.x - originalFrame.origin.x) + abs(frame.y - originalFrame.origin.y)
        }
        if let id = FTAccessibilityIdentifier(stale), !id.isEmpty {
            // 同 id が複数あるときだけ frame で近い方に絞る(通常 testTag は一意)
            let best = fresh.elements.filter { $0.identifier == id }
                .min { distance($0.frame) < distance($1.frame) }
            return best.flatMap { fresh.nodes[$0.ref] }
        }
        // id 無しは frame(±2pt)と label の一致で同定する
        let label = stale.accessibilityLabel
        let candidate = fresh.elements.first {
            $0.label == label && distance($0.frame) <= 2
        }
        return candidate.flatMap { fresh.nodes[$0.ref] }
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
            throw InAppError(409, "フォーカスされた入力欄がありません。対象を先に tap してください。"
                + "tap 済みでも発生する場合、入力欄が UIKit 非依存(Compose Multiplatform/Flutter 等)の"
                + "アプリは inapp では first responder を張れず type できません。"
                + "engine=xcuitest の実行プロファイル(iosInappEngine: false)で実行してください。"
                + "入力欄が AX ツリーに現れない(accessibilityIdentifier/testTag 未設定)場合は"
                + "アプリ側で testTag を付けてください。診断: \(FTFirstResponderDiagnostics())")
        }
        return .json(OKResponse())
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
            throw InAppError(409, "フォーカスされた入力欄がありません。対象を先に tap してください。"
                + "tap 済みでも発生する場合、入力欄が UIKit 非依存(Compose Multiplatform/Flutter 等)の"
                + "アプリは inapp では first responder を張れずクリアできません。"
                + "engine=xcuitest の実行プロファイル(iosInappEngine: false)で実行してください。"
                + "入力欄が AX ツリーに現れない(accessibilityIdentifier/testTag 未設定)場合は"
                + "アプリ側で testTag を付けてください。診断: \(FTFirstResponderDiagnostics())")
        }
        return .json(OKResponse())
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
            // hybrid では救済されない(engine=xcuitest 単独プロファイルを案内する)
            throw InAppError(409, "in-app エンジンで Enter を発火できませんでした。"
                + "フォーカスされた入力欄が無いか、対応していない入力実装です。"
                + "engine=xcuitest の実行プロファイル(iosInappEngine: false)で実行してください。"
                + "診断: \(FTFirstResponderDiagnostics())")
        }
        return .json(OKResponse())
    }

    private func handleSwipe(_ body: Data) throws -> InAppHTTPServer.Response {
        let req = try decode(SwipeRequest.self, body)
        // Compose Multiplatform は自前描画で、スクロールも長押しも UIKit を経由しない。
        // この経路は「画面内の UIScrollView の contentOffset を動かす」ものだが、Compose の
        // 画面にも**本体のスクロールとは無関係な UIScrollView が存在する**ため、動かしても
        // 見た目は一切変わらず、エラーも出ない = 黙った空振りになる。合成タッチへ迂回しても
        // Compose は drag を受理しない(tap のみ通る。2026-07-22 に Projects/E2E で実測)。
        // よってここで明示的に失敗させ、xcuitest プロファイルへ誘導する。
        if uiFramework == "compose" {
            // 501 = このエンジンでは未対応(/terminate と同じ慣習)。409(Conflict)はキーウィンドウ
            // 不在等の一時的競合と同じコードのため、フォールバック判定に使うと取り違える。
            throw InAppError(501, "Compose Multiplatform では in-app エンジンの swipe/scrollTo が効きません"
                + "(UIScrollView を介さない自前描画で、合成タッチの drag も受理されない)。"
                + "実行プロファイルで iosInappEngine: false(xcuitest)にしてください")
        }
        try performWithSettle { window in
            // UIKit/SwiftUI のスクロールは合成タッチでは駆動できない(ジェスチャ認識器が受理しない)ため、
            // contentOffset を直接動かす(accessibilityScroll は SwiftUI List で片方向しか効かず不安定
            // だった。setContentOffset は決定的・双方向)。
            //
            // 「スクロールビューが無い」と「あるが端に達した」は**区別する**:
            // - 無い = ジェスチャ検出用パッド等。FTSynthSwipe を撃っても DragGesture /
            //   UIPanGestureRecognizer は受理されず 200 で黙って空振りするため、501 で申告して
            //   ホストに XCUITest へ回させる(2026-07-23 に Projects/E2E-iOS で実測)
            // - 端に達した = scrollTo の探索が終端に来ただけの**正常な状態**。ここで 501 を返すと
            //   XCUITest の実スワイプ(バウンス)へ切り替わり、さらにラッチで以降のジェスチャ全部が
            //   XCUITest 化して、下端でのタップが不安定になる(実測: scrollTo 直後の行タップが
            //   空振りする flake)。従来どおり無害な no-op にする(次の snapshot が解決を判定する)
            let scrollViews = Self.visibleScrollViews(in: window)
            guard !scrollViews.isEmpty else {
                throw InAppError(501, "この画面には in-app エンジンで動かせるスクロールビューがありません"
                    + "(合成タッチの drag はジェスチャ認識器に受理されません)。"
                    + "hybrid なら XCUITest へフォールバックします")
            }
            if let scrollView = Self.largestWithRoom(scrollViews, direction: req.direction) {
                Self.scrollByPage(scrollView, direction: req.direction)
            }
            // 余地なし = 端。no-op で 200 を返す
        }
        return .json(OKResponse())
    }

    /// スワイプ1回 = 可視領域の ~85% 分だけ contentOffset を動かす(実機スワイプの体感に合わせる)。
    /// 指の向き=コンテンツと逆(上スワイプ=下方向へスクロール=offset.y 増)。範囲外はクランプ。
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
        let minY = -inset.top, maxY = max(-inset.top, sv.contentSize.height + inset.bottom - sv.bounds.height)
        let minX = -inset.left, maxX = max(-inset.left, sv.contentSize.width + inset.right - sv.bounds.width)
        offset.y = min(max(offset.y, minY), maxY)
        offset.x = min(max(offset.x, minX), maxX)
        sv.setContentOffset(offset, animated: false)
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
    // Projects/E2E-iOS で実測。tap だけが通る)。黙って空振りさせず xcuitest へ誘導するため、
    // 実装(FTSynthPress 経路)は持たず常に 501 を返す。
    // 501 = このエンジンでは未対応(/terminate と同じ慣習。409 は一時的競合なので取り違えない)。
    private func handlePress(_ body: Data) throws -> InAppHTTPServer.Response {
        throw InAppError(501, "in-app エンジンでは press(長押し)が効きません"
            + "(合成タッチの押下保持がジェスチャ認識器に受理されない)。"
            + "hybrid なら XCUITest へフォールバックします。engine=inapp 単独なら"
            + "実行プロファイルで iosInappEngine: false(xcuitest)にしてください")
    }

    private func handleScreenshot() throws -> InAppHTTPServer.Response {
        try mainSync {
            guard let window = self.keyWindow() else {
                throw InAppError(409, "キーウィンドウがありません")
            }
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            guard let png = image.pngData() else {
                throw InAppError(500, "PNG エンコードに失敗しました")
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
        let sem = DispatchSemaphore(value: 0)
        var thrown: Error?
        DispatchQueue.main.async {
            guard let window = self.keyWindow() else {
                thrown = InAppError(409, "キーウィンドウがありません")
                sem.signal()
                return
            }
            do {
                try block(window)
            } catch {
                thrown = error
                sem.signal()
                return
            }
            InAppSettle.waitOnMain(capMs: capMs) { sem.signal() }
        }
        _ = sem.wait(timeout: .now() + .milliseconds(blockBudgetMs + capMs + 1500))
        if let thrown { throw thrown }
    }

    private func resolvePoint(ref: Int?, x: Double?, y: Double?) throws -> CGPoint {
        if let ref {
            guard let frame = frames[ref] else {
                throw InAppError(404, "参照番号 [\(ref)] は未知です。先に GET /snapshot を実行してください")
            }
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        if let x, let y { return CGPoint(x: x, y: y) }
        throw InAppError(400, "ref または x/y が必要です")
    }

    private func decode<T: Decodable>(_ type: T.Type, _ body: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: body)
        } catch {
            throw InAppError(400, "リクエストボディの JSON が不正です: \(error)")
        }
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
