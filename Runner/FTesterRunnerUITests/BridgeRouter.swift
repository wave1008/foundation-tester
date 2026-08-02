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
    /// 直近スナップショットの ref→要素。handleType の読み返しが「対象の identifier」と
    /// 「入力前の値」をここから採る(ライブクエリを撃たずに済ませるため)
    private var refElements: [Int: ElementInfo] = [:]
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
    private static let mutatingPaths: Set<String> = ["/session", "/tap", "/type", "/clear", "/pressEnter", "/hidekeyboard", "/press", "/appswitcher", "/home"]

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
            case ("GET", "/snapshot"): response = try handleSnapshot()
            case ("POST", "/tap"): response = try handleTap(request.body)
            case ("POST", "/type"): response = try handleType(request.body)
            case ("POST", "/clear"): response = try handleClear(request.body)
            case ("POST", "/pressEnter"): response = try handlePressEnter()
            case ("POST", "/hidekeyboard"): response = try handleHideKeyboard()
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
            refElements = [:]
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
        refElements = [:]
        return .json(OKResponse())
    }

    private struct Captured {
        let elements: [ElementInfo]
        let frames: [Int: CGRect]
        let truncated: Int
        let screen: CGRect
        /// SnapshotResponse.keyboardShown 用。**Captured に載せる**: 整定ループは captureOnce を
        /// 複数回まわして「返す1回」を選ぶので、インスタンス変数だと返却ツリーと1回ズレる
        let sawKeyboard: Bool
        /// captureSettled が **budget 切れで打ち切った**(= 収束していないツリー)。
        /// 黙って返すと「毎回 350ms 使い切っているのに誰も気付かない」状態が続くので note にする
        var settleCapped: Bool = false
    }

    private func handleSnapshot() throws -> BridgeHTTPServer.Response {
        let app = try requireApp()
        // 操作直後のみ整定してから取得する(captureSettled)。XCUITest の tap quiescence は
        // 非同期 push 遷移の完了前に返るため、直後の素取得は遷移前ツリーを返す(実測 50%)。
        // 連続 snapshot(settlePending=false)は整定不要なので素取得のまま。
        let cap = try settlePending ? captureSettled(app) : captureOnce(app)
        settlePending = false

        refFrames = cap.frames
        // ref → 要素(handleType の読み返しが identifier / 直前の値を使う)。frame と同じ寿命
        refElements = Dictionary(uniqueKeysWithValues: zip(cap.elements.map(\.ref), cap.elements))
        return .json(SnapshotResponse(
            sessionBundleID: sessionBundleID,
            screen: FTRect(x: cap.screen.origin.x, y: cap.screen.origin.y,
                           width: cap.screen.width, height: cap.screen.height),
            elements: withFocusedFlag(cap.elements, app: app),
            truncatedCount: cap.truncated,
            note: cap.settleCapped ? "snapshot taken before the screen settled (budget)" : nil,
            keyboardShown: cap.sawKeyboard ? true : nil))
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

    private func captureOnce(_ app: XCUIApplication) throws -> Captured {
        let root = try app.snapshot()
        let screen = root.frame
        var elements: [ElementInfo] = []
        var frames: [Int: CGRect] = [:]
        var truncated = 0
        var sawKeyboard = false
        collect(root, depth: 0, screen: screen,
                elements: &elements, frames: &frames, truncated: &truncated,
                sawKeyboard: &sawKeyboard)
        return Captured(elements: elements, frames: frames, truncated: truncated, screen: screen,
                        sawKeyboard: sawKeyboard)
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
                throw BridgeError(422, "入力が期待した値になりませんでした"
                    + "(\(rounds) 周打っても \(expected.count) 文字に対して \(actual.count) 文字)")
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
            throw BridgeError(422, "フォーカスされた入力欄がありません(hasKeyboardFocus な要素が"
                + "見つかりません)。対象を先に tap するか ref を指定してください")
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
            throw BridgeError(422, "入力欄をクリアしきれませんでした"
                + "(\(rounds) 周叩いても \(residual.count) 文字残っています)")
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
    private func handleHideKeyboard() throws -> BridgeHTTPServer.Response {
        .error("hideKeyboard は iOS では未対応(Android のみ)。閉じたい場合は pressEnter を使う", status: 501)
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
        refElements = [:]
        return .json(OKResponse())
    }

    // MARK: - スナップショット収集・フィルタ

    private func collect(_ node: XCUIElementSnapshot, depth: Int, screen: CGRect,
                         elements: inout [ElementInfo], frames: inout [Int: CGRect],
                         truncated: inout Int, sawKeyboard: inout Bool,
                         insideWebView: Bool = false) {
        // キーボードはキー1つ1つが Button として大量に写り込むため、サブツリーごと除外
        // (4Kトークン対策。入力は /type がキーイベント合成で行うので情報として不要)。
        // 除外前に検知だけ記録する(SnapshotResponse.keyboardShown)
        if node.elementType == .keyboard { sawKeyboard = true }
        if node.elementType == .keyboard || node.elementType == .key { return }
        // WebView は入れ子で複数出る(Compose iOS の interop ラッパで実測3重)。外側だけ残さないと
        // `.webView[1]` がどれを指すか読めない。Android ブリッジの nestedWebView と同じ規則
        let isWebView = node.elementType == .webView
        if isWebView && insideWebView {
            for child in node.children {
                collect(child, depth: depth, screen: screen,
                        elements: &elements, frames: &frames, truncated: &truncated,
                        sawKeyboard: &sawKeyboard, insideWebView: true)
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
                    sawKeyboard: &sawKeyboard, insideWebView: insideWebView || isWebView)
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
