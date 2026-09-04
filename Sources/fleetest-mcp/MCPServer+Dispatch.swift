// MCPServer+Dispatch.swift
// ツールの入口(call/dispatch)と各ツールの実装。本体は MCPServer.swift(instance 状態はそちらに置く)

import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore

extension MCPServer {

    /// `tap(ref:)` の直後、pressEnter を撃つ前に**その欄へフォーカスが立つまで**待つ。
    ///
    /// **フォーカスを報告しないフレームワークで待ち続けない**のが要点: Compose iOS の a11y 要素は
    /// UIResponder ではないので in-app ブリッジは focused を一度も返さない(InAppSnapshot の
    /// makeInfo)。そこで「木の中に focused=true の要素が1つも無い」= 報告しない経路と読み、
    /// 即座に諦める。誰かが focused を名乗っているのに対象でないときだけが**本当の待ち**
    /// (= 前の欄にフォーカスが残っている状態)。
    func awaitFocus(ref: Int, driver: AppDriver, args: [String: Any]) async -> String {
        guard let target = resolveSessionRef(ref, args: args)?.element else { return "" }
        let deadline = Date().addingTimeInterval(Self.focusWaitSeconds)
        while true {
            // **生読み**: この polling read は tap の後に走り、この直後 ft_type は
            // pressEnter → snapshotAfterBody を呼ぶ。freshSnapshot(adoptSnapshot 経由)だと
            // lastSnapshots[key] を tap 後の状態で上書きし、settle-lite の基準が
            // pressEnter 前の状態にずれる(typedIntoNote と同じ理由。2026-08-10)
            guard let fresh = try? await driver.snapshot(bypassingCache: driver.supportsCacheBypass)
            else { return "" }
            if case .found(let found, _) = RefGuard.relocate(target, in: fresh.elements, screen: fresh.screen),
               found.focused == true { return "" }
            // 誰も focused を名乗らない = 報告しない経路。待っても永遠に立たない
            guard fresh.elements.contains(where: { $0.focused == true }) else { return "" }
            guard Date() < deadline else {
                return " (warning: \(RefGuard.describe(target)) never took focus within"
                    + " \(Self.focusWaitSeconds)s — the Enter/IME action may have gone to"
                    + " whichever field still had it)"
            }
            try? await Task.sleep(for: .seconds(Self.focusPollSeconds))
        }
    }

    /// ref を撃つ直前に照合したうえで**要素そのもの**を返す(ft_double_tap / ft_pinch / ft_drag
    /// fromRef 用。いずれも ref ではなく座標・identifier で撃つため要素が要る)。
    ///
    /// **isStale の警告は呼び手に返していない**(座標系のジェスチャは verifiedRef ほど頻繁に
    /// 古い ref を渡される想定がなく、対象が消えていれば下の `.gone` が捕まえる)。
    /// **ラベル変化だけは note で返す** —— これは double_tap/drag/pinch が
    /// 再ターゲットした要素へ実際に操作を撃つ経路なので、verifiedRef と同じ危険がある
    /// (RefGuard.labelChangeNote 参照。.found のときだけ = verifiedRef と条件を揃える)
    func verifiedElement(_ ref: Int, driver: AppDriver,
                                 args: [String: Any]) async throws -> (element: ElementInfo, note: String) {
        let resolved = resolveSessionRef(ref, args: args)
        // stderr のみ・応答には何も足さない。警告を付けるかは実運用の頻度を見て決める
        // (2026-08-10・依頼側と合意した観測)
        if resolved?.isStale == true {
            Self.logStderr("verifiedElement: stale ref [\(ref)] passed to a"
                + " double_tap/pinch/drag path — no warning is attached here; counting"
                + " occurrences to decide whether to add one")
        }
        // **fresh を撮る前に世代の有無を固定する**: freshSnapshot は内部で adoptSnapshot を通し、
        // 世代が無ければその場で最初の世代を作ってしまう。後から見ると常に「世代あり」に見えて
        // 「そもそも撮っていない」と「見つからない」を区別できなくなる
        let hadGenerations = !(refGenerations[Self.engineKey(args)]?.isEmpty ?? true)
        let takenFrom = generationSnapshot(containing: ref, args: args)
        let fresh = try await freshSnapshot(driver, args: args)
        // **ref の出自がアプリを跨いでいないか**(verifiedRef と同じガード。理由はあちらの doc)
        if resolved != nil, let message = Self.refFromAnotherAppMessage(
            ref: ref, takenFrom: takenFrom, fresh: fresh) { throw MCPError(message) }
        guard let target = resolved?.element else {
            // 世代が無かった(ft_snapshot を挟まずに撃たれた)= 撮ったばかりの木から素直に引く。
            // 世代があったのに見つからない(= 直近5世代のどれにも無い番号)なら unknown ref
            guard !hadGenerations else {
                throw MCPError("unknown ref [\(ref)] — it is not from any recent snapshot"
                    + " (refs are per-snapshot; the last 5 snapshots were checked)."
                    + " Take a fresh ft_snapshot")
            }
            guard let element = fresh.elements.first(where: { $0.ref == ref }) else {
                throw MCPError("unknown ref [\(ref)]. Take an ft_snapshot first")
            }
            return (element, "")
        }
        switch RefGuard.relocate(target, in: fresh.elements, screen: fresh.screen) {
        case .gone:
            throw MCPError(RefGuard.goneMessage(ref: ref, target: target,
                                                truncatedCount: fresh.truncatedCount))
        case .ghost(let found):
            return (found, "")
        case .found(let found, _):
            return (found, RefGuard.labelChangeNote(old: target.label, new: found.label) ?? "")
        }
    }

    /// driver(_:) が使うキャッシュキーと同じ引き当て(エンジンの記録先)
    static func engineKey(_ args: [String: Any]) -> String {
        if let profileName = args["profile"] as? String {
            return driverCacheKey(profile: profileName, project: args["project"] as? String,
                                  platform: args["platform"] as? String)
        }
        return driverCacheKey(platform: platformName(args), port: args["port"] as? Int,
                              serial: args["serial"] as? String)
    }

    /// 引数から見た宛先プラットフォーム。**既定は iOS**(FLEETEST_PLATFORM で上書き)
    static func platformName(_ args: [String: Any]) -> String {
        if let explicit = args["platform"] as? String { return explicit }
        // **宛先そのものが platform を名乗っている**(2026-08-12 に実機で踏んだ):
        // `serial` は Android のもの・`udid`/`port` は iOS のものなので、platform を省いた
        // `{"serial": "emulator-5554"}` が既定の "ios" に落ちて**黙って iOS の画面を返していた**
        // (エラーにもならず、返ってくる木が別プラットフォームというだけ)。記憶の適用
        // (foldInRememberedDevice)は既にこの推論をしているのに、**ドライバ選択だけが
        // していなかった** —— 判定はここ1箇所に寄せて両者を必ず揃える。
        // 述語は明示ターゲットの唯一の定義元(argsGaveIOSTarget/argsGaveAndroidTarget)
        if argsGaveAndroidTarget(args) { return "android" }
        if argsGaveIOSTarget(args) { return "ios" }
        return ProcessInfo.processInfo.environment["FLEETEST_PLATFORM"] ?? "ios"
    }

    /// ft_logs の bundleId 既定。ログはブリッジを通らないので engineKey が launch 時と
    /// 揃わない(profile で起動し serial 直指定で読む等)。覚えている起動が1つだけならそれを使う
    func lastLaunchedBundleID(_ args: [String: Any]) -> String? {
        if let exact = launchedBundleIDs[Self.engineKey(args)] { return exact }
        let known = Set(launchedBundleIDs.values)
        return known.count == 1 ? known.first : nil
    }

    /// drivers キャッシュのキー生成。profile / project / port / serial の違いを別ドライバとして扱う
    static func driverCacheKey(profile: String, project: String?, platform: String?) -> String {
        "profile:\(project ?? ""):\(profile):\(platform ?? "")"
    }

    static func driverCacheKey(platform: String, port: Int?, serial: String?) -> String {
        "direct:\(platform):\(port ?? 0):\(serial ?? "")"
    }

    enum ResolvedDriverTarget {
        case ios(ProvisionedIOSDevice, iosApp: ResolvedAppTarget?)
        case android(serial: String, deviceName: String)
    }

    /// profile からデバイスを解決する(ft_run_scenario と直接操作系で共通)。iOS は
    /// BridgeProvisioner.provision を伴うため、初回コールドスタートは分単位かかりうる
    func resolveProfileTarget(
        project: TestProject, profileName: String, platformArg: String?, prologue: inout [String]
    ) async throws -> (platform: String, resolved: ResolvedProfile, target: ResolvedDriverTarget) {
        let machine = try ProfileResolver.determineMachine(
            project: project,
            runProfileName: profileName)
        let resolved = try ProfileResolver.resolve(
            project: project, runName: profileName, machineName: machine.name)
        prologue.append(contentsOf: resolved.warnings.map { "⚠️ \($0)" })
        let platform = platformArg ?? resolved.devices.first?.platform ?? "ios"
        guard let device = resolved.devices.first(where: { $0.platform == platform }) else {
            throw MCPError("profile \(profileName) has no \(platform) device")
        }
        if platform == "ios" {
            // ブリッジ資産(InAppBridge/・Runner/)を持つ**ツール本体**のルート。受け手パッケージの
            // ルート(root(of:))を渡してはいけない — 外部パッケージ構成では別ディレクトリで、
            // InAppBridge/build.sh が無く provision が必ず落ちる(.fleetest の状態も CLI と食い違う)
            let provisioner = BridgeProvisioner(repoRoot: try RepoRoot.find())
            // bundleID/preinstallAppPath は inapp ブリッジのコールドスタートに必須。
            // 稼働中ブリッジ再利用時は使われないため、欠落しても露見しにくい(実際に欠落バグが起きた)
            let iosApp = resolved.apps["ios"]
            // provision の進捗クロージャは @escaping のため inout の prologue を直接キャプチャできない
            var provisionLog: [String] = []
            let provisioned = try await provisioner.provision(
                devices: [(device.name, device.spec)],
                bundleID: iosApp?.bundleID,
                preinstallAppPath: iosApp?.autoInstall == true ? iosApp?.appPath : nil) { provisionLog.append($0) }
            prologue.append(contentsOf: provisionLog)
            return (platform, resolved, .ios(provisioned[0], iosApp: iosApp))
        } else {
            let serial = try AndroidDeviceCatalog.resolveSerial(spec: device.spec)
            return (platform, resolved, .android(serial: serial, deviceName: device.name))
        }
    }

    // MARK: - ツール実装

    /// **接続が消えた失敗には「今どこに何が居るか」を添える**(2026-08-06 フィードバック #7)。
    /// ポートで誰も待受していない = XCUITest ランナーのプロセス死で、原因の筆頭は
    /// **同一シミュレータに2本目のランナーが立った**こと(全ポート共通 bundle id のため
    /// 先代が蹴り出される。Fleetest.swift の bridge up 参照)。素のメッセージからは追えない
    func call(tool: String, args: [String: Any]) async throws -> [[String: Any]] {
        let clock = ContinuousClock()
        let start = clock.now
        // **udid は入口で port へ畳む**。`driver(_:)` は解決後のポートで
        // ドライバを引くのに、`engineKey` は生の引数しか見ないので、udid で指した機は
        // すべて port=nil の同じキーに落ちていた。engineKey が引く記憶は
        // lastSnapshots / launchedBundleIDs / uiFrameworkHints / connections /
        // pendingWarnings / udids / engines / rememberedSnapshotFilters の8つで、
        // **2台を udid で操作すると混ざる**
        // (実測: 機A に Preferences・機B に Maps を launch した後、機A への
        //  ft_open_url が com.apple.Maps へ配ると申告した。Android では intent の
        //  宛先そのものなので、同じ機の中で別アプリへ実際に配送される)。
        // 入口で畳めば 35 箇所の呼び出しを触らずに全部が揃う
        let folded: [String: Any]
        do {
            folded = Self.strippingSelectorQuotes(try await Self.foldingUDIDIntoPort(args))
        } catch {
            let hint = await connectionLostHint(error, args: args)
            throw hint.isEmpty ? error : MCPError(error.localizedDescription + hint)
        }
        // **セッション記憶の適用も同じ入口で畳む**: driver(_:) の内部(キャッシュ参照・
        // engineKey 計算より後)で適用すると、省略呼び出しは常に `direct:ios:0:` の生キーで
        // キャッシュ/ref 世代/engineKey を引き、明示切替後も旧デバイスのキャッシュ済み
        // ドライバや ref 世代が返る。ここで args へ埋めてしまえば、明示指定と省略呼び出しが
        // 完全に同じキーへ揃う。
        // **拒否はこの do/catch の外で投げる**: connectionLostHint はデバイスを走査するので、
        // 「宛先が決まらない」という引数だけで決まる失敗に数秒とブリッジ一覧を足してしまう
        let resolved: [String: Any]
        let rememberedNote: String
        switch Self.toolAcceptsDeviceTarget(tool) ? foldInRememberedDevice(folded) : .unchanged {
        case .unchanged:
            (resolved, rememberedNote) = (folded, "")
        case .applied(let foldedArgs, let note):
            (resolved, rememberedNote) = (foldedArgs, note)
        case .ambiguous(let message):
            throw MCPError(message)
        }
        do {
            var content = try await dispatch(tool: tool, args: resolved)
            if !rememberedNote.isEmpty {
                content = [["type": "text", "text": rememberedNote]] + content
            }
            return Self.withElapsed(content, since: start, clock: clock)
        } catch {
            let hint = await connectionLostHint(error, args: resolved)
                + Self.setTextRefusedHint(tool: tool, args: resolved,
                                          message: error.localizedDescription)
            guard !hint.isEmpty else { throw error }
            throw MCPError(error.localizedDescription + hint)
        }
    }

    /// ios/android 分岐の共通尾部(2026-08-12 の掃討・2026-08-12 曖昧化対応で拡張):
    /// マーカーを立て、注記を組む(rememberedDeviceNote 参照)。
    /// `firstTime` はキー消費(explainedNotes への insert)を伴うので呼び手のクロージャで渡す
    /// (このメソッドを static のままにするため — instance メソッド化すると呼び出し側で
    /// `Self.` と裸の呼び出しが混在して読みにくくなる)。
    /// **曖昧なときは鍵を消費しない**: 消費してしまうと、後で forgetConnection が候補を
    /// 1件まで減らして非曖昧に戻ったとき、この宛先はまだ一度も「初回の満額注記」を
    /// 受け取っていないのに firstTime が false になり黙ってしまう
    static func finishingFold(
        _ args: [String: Any], chosen: String, allSeenLabels: [String], deviceNoun: String,
        unitNoun: String, otherPlatform: String?, noteKey: String, firstTime: (String) -> Bool
    ) -> RememberedDeviceFold {
        guard !isAmbiguousMemory(allSeenLabels: allSeenLabels, otherPlatform: otherPlatform) else {
            return .ambiguous(message: rememberedDeviceRefusal(
                allSeenLabels: allSeenLabels, deviceNoun: deviceNoun, unitNoun: unitNoun,
                otherPlatform: otherPlatform))
        }
        var out = args
        out[deviceFromMemoryKey] = true
        return .applied(args: out,
                        note: rememberedDeviceNote(chosen: chosen, firstTime: firstTime(noteKey)))
    }

    /// `ft_type(ref:)` が Android の注入器に断られたときの助言。**この 500 が返る時点で
    /// ブリッジは既に tap を撃ち終えている**(BridgeRouter.handleType が tap → type の順で動き、
    /// tap 後に断られる)ので、「まず tap しろ」と言うと二度撃ちになるうえ、擬似検索ボックスが
    /// 実入力欄へ差し替わる画面(ブラウザの新規タブなど)では**渡した ref がもう木に無い**ため
    /// 再タップ自体が別の失敗を返す(2026-08-12 実測)。正解は ref なしで撃ち直すこと
    /// (フォーカス済みの欄へキーで撃つ経路は通る)。
    /// 走査から切り離した純粋関数(デバイスが要ると、この枝はテストで一度も実行されない)
    static func setTextRefusedHint(tool: String, args: [String: Any], message: String) -> String {
        guard tool == "ft_type", args["ref"] != nil,
              message.contains(setTextRefusalMarker) else { return "" }
        return " This call already tapped the field before typing into it — that tap may have"
            + " switched focus to a different field (a search box that hands off to a real input,"
            + " common in browsers). Do not re-tap the ref you passed (it is likely no longer in"
            + " the tree); retry ft_type WITHOUT ref first (it types into whichever field is now"
            + " focused, through the keyboard). If that still fails, take a fresh ft_snapshot."
            + " Some widgets refuse ACTION_SET_TEXT outright (Android's NumberPicker among them)."
    }

    /// InputInjector.java(AndroidRunner/src/com/example/ftbridge/)がこの文言を変えると、
    /// 上のガードが二度と当たらなくなる。`SetTextRefusedHintJavaSyncTests` がこの定数の値が
    /// Java 側のソースに実在するかを機械確認する(Java 側は編集しない)
    static let setTextRefusalMarker = "cannot type into the field that was tapped"

    /// セレクタ引数の両端の引用符を入口で剥がす(2026-08-12 の実アプリ監査)。
    /// DSL は Swift の文字列リテラルが引用符を剥がすが、MCP は生文字列で受けるので、
    /// `"*立川*"` は**引用符ごと完全一致ラベル**になり黙って一致しない(先頭が `"` なので
    /// `*` 記法も展開されない)。ft_batch は逆に引用符必須なので、跨いで使うと必ず混入する。
    /// 両端が同じ引用符で**中にその引用符が無い**ときだけ剥がす(`"a"||"b"` を壊さない)。
    /// 引用符そのものを含むラベルは `=` エスケープ(`="…"`)で従来どおり書ける
    /// 引用符剥がしの対象キー。**ToolDefs のスキーマ記述と同期を取る**
    /// (`MCPServerToolDefinitionsTests.testSelectorSyntaxMarkedPropertiesAreAllQuoteStripped`) ——
    /// セレクタ構文を受ける引数を新設したら、ここへ足し忘れないとテストが落ちる
    static let selectorQuoteStrippedKeys = ["selector", "waitFor", "scrollFrame"]

    static func strippingSelectorQuotes(_ args: [String: Any]) -> [String: Any] {
        var out = args
        for key in selectorQuoteStrippedKeys {
            guard let text = args[key] as? String else { continue }
            out[key] = strippedQuotes(text)
        }
        return out
    }

    static func strippedQuotes(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, let first = trimmed.first, first == "\"" || first == "'",
              trimmed.last == first else { return text }
        let inner = String(trimmed.dropFirst().dropLast())
        guard !inner.contains(first) else { return text }
        return inner
    }

    /// `udid` を解決して `port` として畳んだ引数。**udid が無いときは触らない**
    /// (Android や profile 指定はブリッジ走査を1回も払わない)。
    /// 解決と食い違い検査は `portForIOS` に委ねる = 宛先の決め方は1箇所のまま
    static func foldingUDIDIntoPort(_ args: [String: Any]) async throws -> [String: Any] {
        guard (args["udid"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) != nil else { return args }
        return injectingPort(args, port: try await portForIOS(args))
    }

    /// 解決したポートを引数へ載せる。**純粋関数**(走査を伴う解決と切り離してあるので、
    /// 「載せ忘れ」の枝をテストで直接踏める)
    static func injectingPort(_ args: [String: Any], port: UInt16?) -> [String: Any] {
        guard let port else { return args }
        var out = args
        out["port"] = Int(port)
        return out
    }

    /// **デバイス側に何秒かかったかを毎回返す**。読み手はこれが無いと、自分の
    /// 思考時間まで含んだ壁時計しか測れない —— 実測を頼まれたときに `date` をシェルで撃つ
    /// 往復が発生していた。
    ///
    /// **末尾に独立した content ブロックとして足す**(本文へ混ぜない): 本文を読む側は
    /// `content[0].text` を見るので、混ぜると所要時間が結果の文字列の一部になって
    /// 照合や引用を汚す。画像を返す ft_screenshot でも同じ形で足せる
    static func withElapsed(_ content: [[String: Any]], since start: ContinuousClock.Instant,
                            clock: ContinuousClock) -> [[String: Any]] {
        let ms = (clock.now - start) / .milliseconds(1)
        return content + [["type": "text", "text": "⏱ \(Self.elapsedText(milliseconds: ms))"]]
    }

    /// 1秒未満はミリ秒・以上は小数1桁の秒(読み手が桁を数えなくて済む形)
    static func elapsedText(milliseconds: Double) -> String {
        milliseconds < 1000 ? "\(Int(milliseconds.rounded()))ms"
            : String(format: "%.1fs", milliseconds / 1000)
    }

    /// bridgeUnreachable の3択。**走査から切り離した純粋関数**(reconcilePort/bridgeVanished と
    /// 同じ理由: 実ブリッジが要るとこの判定はテストで一度も両方向を通らず、壊しても素通しする)。
    /// bound(誰かが listen している)は vanished より優先する —— busy なブリッジは scan にも
    /// 載らない(bridgeVanished は true になる)ので、bound を見ずに vanished だけで決めると
    /// busy を死と誤判定する。**ただし bound は無条件に信じない**(trustBound 参照。欠陥④:
    /// 実機は listen を iproxy が引き継ぐため、ランナー死後も bound は true のまま残る)
    enum BridgeUnreachableVerdict: Equatable { case busy, vanished, stillUnclear }

    func dispatch(tool: String, args: [String: Any]) async throws -> [[String: Any]] {
        switch tool {
        case "ft_status":
            // **読み取り専用のここだけは、複数台でも失敗させない**(外部フィードバック 2026-08-06)。
            // 操作系(tap/type/…)は従来どおりエラーにする —— 曖昧なまま「どれか」を操作させない
            // 規律([[BridgeDiscovery]] と同じ)を崩さないため。status は状態を見るだけなので、
            // 全台を並べて返すほうが次の一手(serial: を選ぶ)に直結する
            if args["profile"] == nil, args["serial"] == nil,
               (args["platform"] as? String) == "android",
               case .ambiguous(let devices) = AndroidSerialResolver.decide(
                   explicit: nil, connected: AndroidSerialResolver.connectedSerials()) {
                return text(await Self.androidFleetStatus(devices.map(\.serial)))
            }
            let status = try await driver(args).status()
            // **宛先とセッションの意味まで出す**: 「どこに繋がっているか」が見えないと、
            // 既定ポートの死・はぐれデバイスの誤掴み・ブリッジ再起動によるセッション消失が
            // どれも「応答はしているのに操作できない」に見える(2026-08-06 フィードバック #2/#8)
            let statusKey = Self.engineKey(args)
            // **同じシミュレータに in-app / XCUITest が同時に立つのが常態**(2026-08-12 の実アプリ
            // 監査: 10台に対し稼働ブリッジ17本)。どちらに繋がっているかで scrollable 検知・
            // キーボード遮蔽・型語彙・読み返しの有無が変わるので、宛先と一緒に出す。
            // **走査は増やさない** — driver(args) が解決時に埋めた engines[key] を読むだけ
            // (android は platform で既に分かっているので冗長・出さない)
            let engineSuffix = engines[statusKey].flatMap { $0 == "android" ? nil : " engine: \($0)" } ?? ""
            let endpoint = connections[statusKey].map { " @ \($0)\(engineSuffix)" } ?? ""
            let session = status.sessionBundleID
                ?? "none (no app attached — ft_launch <bundleId> first;"
                    + " a bridge restart clears the session)"
            // **session と「いま前面にあるもの」は別物**(外部フィードバック 2026-08-06)。
            // session はブリッジが掴んでいるアプリで、ft_navigate home の後も変わらない。
            // 前面の照会は 1 往復で済むので、シナリオ冒頭の appIs 相当をここで賄えるようにする
            let foreground = await Self.foregroundNote(status.sessionBundleID,
                                                       driver: try await driver(args))
            return text(withPendingWarnings(
                "ready: \(status.ready) / \(status.device) (\(status.osVersion))\(endpoint)"
                + " / session: \(session)\(foreground)\(await Self.fmLivenessNote())", args: args))

        case "ft_list_devices":
            let listProject = args["project"] as? String
            let listProfile = args["profile"] as? String
            let listPlatform = args["platform"] as? String
            // **鍵は見出しが実際に組まれる回だけ消費する**(onceNonEmpty と同じ理由)。
            // devicesText 側の `abbreviated` クロージャに遅延評価させる — ここで同じ判定を
            // 先読みすると、once 系の鍵をここでも消費する二重実装になる。
            // **鍵は理由込み**(欠陥⑥): 理由に依存しない鍵だと、原因を直した後の呼び出しまで
            // 「初回に言った理由」として畳まれ、直ったかどうかを読む手段が消える
            return text(await DeviceInventory.devicesText(
                project: listProject, profile: listProfile, platform: listPlatform,
                abbreviated: { reason in !self.firstTime("machineProfileFallback:\(reason)") }))

        case "ft_list_apps":
            // driver() を先に通す: profile 指定の解決(provision)と udids の記録がここで済み、
            // 直指定でも同じ宛先選択規則に乗る
            let appsDriver = try await driver(args)
            let appsFilter = (args["filter"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // **filter を渡したら既定で system も探す**: 絞り込む唯一の動機は「あのアプリを
            // 見つける」ことで、端末に載っている地図・ブラウザは system 側に居る。既定のままだと
            // 「入っていない」という誤った空振りになる(2026-08-09 に実測して adb へ落ちた)。
            // 明示の includeSystem: false は尊重する
            let includeSystem = args["includeSystem"] as? Bool ?? (appsFilter != nil)
            if Self.platformName(args) == "android" {
                guard let android = appsDriver as? AndroidDriver else {
                    throw MCPError("this Android connection cannot list packages")
                }
                return text(DeviceInventory.appsText(
                    packages: try android.listPackages(includeSystem: includeSystem),
                    includeSystem: includeSystem, filter: appsFilter))
            }
            let deviceName = try await appsDriver.status().device
            let appsKey = Self.engineKey(args)
            // **実機判定をシミュレータへの素通し(bootedSimulatorUDID)より先にする**(欠陥①):
            // 実機の /status は device に機種名("iPhone")しか返さず SIMULATOR_UDID も持たないので、
            // bootedSimulatorUDID は udid の出所がどこであれ必ず throw する。候補 udid を先に
            // 揃えてから実機かどうかを確かめ、実機でなければ初めてシミュレータ側へ素通しする。
            //
            // 候補は3段(先に見つかったものを使う): ①呼び出し引数の `udid:`(利用者の直接指定。
            // `udids[key]` は port: だけの呼び出しでは埋まらないことがあるので、まずこちらを見る)/
            // ②このセッションが既に記憶している udid(`udids[key]`。profile 経由は
            // BridgeProvisioner が実機の udid をそのまま `udids[key]` に載せるのでここで拾える)/
            // ③実機専用のポート記録(`.fleetest/bridge-<port>.device`。`port:` だけで実機を指した
            // ときの唯一の手がかり —— ExploreDriverResolver は SimulatorCatalog しか見ないため、
            // 実機では udids[key] がここまで来ても nil のまま)
            let candidateUDID = (args["udid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? udids[appsKey].flatMap { $0 }
                ?? connectedPorts[appsKey].flatMap { port in
                    (try? RepoRoot.find()).flatMap { BridgeDeviceRecord.load(port: port, repoRoot: $0) }
                }
            // **実機は simctl ではなく devicectl**(欠陥⑤): udid の形はどちらも同じなので、
            // simctl へ素通しすると "Invalid device" で失敗する。実機かどうかは
            // IOSPhysicalDeviceCatalog の一覧に居るかで判定する(判定できなければ
            // シミュレータ側の従来経路へ素通し = 断定しない側に倒す)
            if let candidateUDID,
               let physicalDevices = try? IOSPhysicalDeviceCatalog.devices(),
               physicalDevices.contains(where: { $0.udid == candidateUDID || $0.deviceCtlIdentifier == candidateUDID }) {
                let apps = try IOSPhysicalAppCatalog.apps(udid: candidateUDID)
                return text(DeviceInventory.renderAppLines(
                    apps.map { DeviceInventory.AppRow(id: $0.id, name: $0.name, isUser: $0.isUser) },
                    includeSystem: includeSystem, filter: appsFilter, systemAppsCounted: true))
            }
            let udid = try candidateUDID ?? SimulatorAppCatalog.bootedSimulatorUDID(named: deviceName)
            return text(DeviceInventory.appsText(apps: try SimulatorAppCatalog.apps(udid: udid),
                                                 includeSystem: includeSystem, filter: appsFilter))

        case "ft_logs":
            let logBundleID = args["bundleId"] as? String ?? lastLaunchedBundleID(args)
            // **ブリッジには一切問い合わせない**(CrashLogs の存在理由はまさにブリッジごと
            // 落ちた直後に使うこと)。唯一のブリッジ非依存な実機の手掛かりは
            // `.fleetest/bridge-<port>.device`(BridgeDeviceRecord。実機のときだけ書かれる)で、
            // port は明示引数かこのセッションが覚えている宛先(connectedPorts。driver() を経由した
            // 呼び出しで埋まる)から取る。**どちらも取れなければ nil = 実機でない証拠にはならない
            // ので従来どおり待つ**(best-effort)
            let logsPort = (args["port"] as? Int).map(UInt16.init) ?? connectedPorts[Self.engineKey(args)]
            let logsPhysicalUDID = Self.platformName(args) == "ios"
                ? logsPort.flatMap { port in
                    (try? RepoRoot.find()).flatMap { BridgeDeviceRecord.load(port: port, repoRoot: $0) }
                }
                : nil
            return text(await CrashLogs.text(
                platform: Self.platformName(args),
                bundleID: logBundleID,
                serial: args["serial"] as? String,
                withinSeconds: args["sinceSeconds"] as? Int ?? 300,
                maxLines: args["lines"] as? Int ?? 100,
                crashOnly: (args["all"] as? Bool) != true,
                physicalUDID: logsPhysicalUDID))

        case "ft_install":
            guard let packagePath = args["packagePath"] as? String else {
                throw MCPError("packagePath is required")
            }
            let installKey = Self.engineKey(args)
            try await driver(args).install(packagePath: packagePath)
            // ft_clear_app_data が実機で uninstall+install に化けるときの再インストール元
            // (installedPackagePaths 参照)
            installedPackagePaths[installKey] = packagePath
            // インストール直後の初回起動で権限アラートが出ることがある(systemAlertProbePending 参照)
            systemAlertProbePending.insert(installKey)
            return text("Installed: \(packagePath)")

        case "ft_launch":
            guard let bundleID = args["bundleId"] as? String else { throw MCPError("bundleId is required") }
            let launchKey = Self.engineKey(args)
            let launchDriver = try await driver(args)
            let resumes = args["resume"] as? Bool == true
            // **in-app/hybrid は activate に override が無く launch へ落ちる**(AppDriver の既定
            // 実装。InAppDriver は独自の activate を持たない)ので、resume: true を撃っても
            // 実際には毎回終了→起動が走る —— 嘘の「resumed」を返さず、対応するエンジンを案内する
            if resumes, let engine = engines[launchKey], engine == "inapp" || engine == "hybrid" {
                throw MCPError("resume needs the xcuitest engine (or Android) — the \(engine)"
                    + " engine has no activate-without-relaunch and falls through to a normal"
                    + " launch. Drop resume: true, or attach with the xcuitest engine.")
            }
            // **撃つ前に弾く**(ランナー死の予防。installedState のコメント参照)
            if await installedState(bundleID: bundleID, driver: launchDriver) == false {
                throw MCPError(Self.notInstalledMessage(bundleID: bundleID))
            }
            if resumes {
                try await launchDriver.activate(bundleID: bundleID)
            } else {
                try await launchDriver.launch(bundleID: bundleID)
            }
            // 以後の snapshot は「これの木か」を突き合わせられる(switchedAppNote)
            launchedBundleIDs[launchKey] = bundleID
            backgroundedByNavigate.remove(launchKey)
            // 次の ft_snapshot で一度だけ system alert を確かめる(systemAlertProbePending 参照)。
            // **springboard 自身への attach では立てない** —— そちらはアラートを読みに行く
            // 正規の経路そのものなので、覆いとして扱ってはいけない
            if bundleID != "com.apple.springboard" {
                systemAlertProbePending.insert(launchKey)
            }
            // 前面が入れ替わったので、古い木を起点にした覆い探針の記憶は使い回さない(F 節)
            lastScreenProbe[launchKey] = nil
            // 下書きの起点(F-3 の既定範囲は「直近の ft_launch 以降」)。@TestClass(app:) にも使う。
            // **resume は isLaunch を立てない** —— 立てると draft の既定スコープがここから始まり、
            // ScenarioCodeGen は scene 0 の condition に無条件で launchApp() を出すので、
            // 実際には状態を保ったまま activate しただけの手順が「新規起動」に化けて嘘になる
            interactions.record(InteractionLog.Entry(
                step: nil, unresolved: nil, isLaunch: !resumes, bundleID: bundleID,
                platform: Self.platformName(args),
                summary: resumes ? "activate \(bundleID) (resumed, not relaunched)"
                                  : "launch \(bundleID)"))
            return text(resumes ? "Activated: \(bundleID) (resumed without relaunching)"
                                 : "Launched: \(bundleID)")

        case "ft_open_url":
            guard let url = args["url"] as? String else { throw MCPError("url is required") }
            let openURLDriver = try await driver(args)
            let explicitBundleID = args["bundleId"] as? String
            let openURLBundleID = explicitBundleID ?? launchedBundleIDs[Self.engineKey(args)]
            // installedState は撃たない: simctl openurl/devicectl openURL・am start は OS の URL
            // ルーティングで、installedState が守っている XCUIApplication.launch() のランナー死
            // (ft_launch のコメント参照)とは経路が別
            // **既定で着地を待つ**。URL の配送は非同期なので、
            // `snapshotAfter` だけを渡すと**前の画面が黙って返る** —— 読み手は「開いた先の
            // 画面が欲しい」から snapshotAfter を付けているので、既定が誤りの側に倒れていた
            // (評価者の指摘。こちらも同セッションで踏んで snapshot を2回撮った)。
            // **比較の基準が要る**: `waitForChange` は「操作前の木」と比べるので、まだ1枚も
            // 読んでいないデバイス(ft_launch → ft_open_url が典型)では**待たずに素通りする**。
            // そこで基準が無いときだけ配送**前**に1枚読む。読めなくても配送は続ける
            // (主たる操作は URL の配送で、基準取りの失敗でそれを落とさない)。
            // 明示された `waitFor` / `waitForChange: false` は当然そのまま尊重する
            var openURLArgs = args
            let wantsLandingWait = args["snapshotAfter"] as? Bool == true
                && args["waitFor"] == nil && args["waitForChange"] == nil
            if wantsLandingWait {
                if lastSnapshots[Self.engineKey(args)] == nil {
                    _ = try? await freshSnapshot(openURLDriver, args: args)
                }
                openURLArgs["waitForChange"] = true
            }
            try await openURLDriver.openURL(url, bundleID: openURLBundleID)
            // ディープリンクが未起動のアプリを新規に立ち上げることがある(systemAlertProbePending 参照)
            systemAlertProbePending.insert(Self.engineKey(args))
            var openStep = FlowStep(action: "openURL")
            openStep.text = url
            interactions.record(InteractionLog.Entry(step: openStep, unresolved: nil,
                                                     summary: "openURL \"\(url)\""))
            return text(Self.openURLSummary(url: url, bundleID: openURLBundleID,
                                            bundleIDWasRemembered: explicitBundleID == nil,
                                            snapshotAfter: args["snapshotAfter"] as? Bool == true,
                                            waitedForLanding: wantsLandingWait)
                + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(openURLArgs)))

        case "ft_snapshot":
            // **明示分だけ・丸ごと置き換え**(snapshotAfterBody が読む記憶)。省略したキーは
            // ここで記憶から消える — 次の snapshotAfter は「今の申告」だけを見て継承の可否を決める
            var explicitFilters: [String: Bool] = [:]
            if let v = args["interactiveOnly"] as? Bool { explicitFilters["interactiveOnly"] = v }
            if let v = args["expandBulk"] as? Bool { explicitFilters["expandBulk"] = v }
            rememberedSnapshotFilters[Self.engineKey(args)] = explicitFilters
            let snapshotDriver = try await driver(args)
            var snapshot: SnapshotResponse
            do {
                snapshot = try await freshSnapshot(snapshotDriver, args: args)
            } catch {
                // ホーム画面/システム UI を読もうとして詰まった形なら、読む方法まで返す
                let hint = Self.springboardHint(error, engine: engines[Self.engineKey(args)])
                guard !hint.isEmpty else { throw error }
                throw MCPError(error.localizedDescription + hint)
            }
            var waitNote = ""
            // **待つのはホスト側の仕事**: エージェントに snapshot を撃ち直させると、待った
            // 回数だけ画面一覧が文脈に積まれる(1回あたり数千トークン)
            if let waitFor = args["waitFor"] as? String {
                let seconds = args["timeout"] as? Double ?? Self.defaultWaitSeconds
                let waited = try await Self.waitFor(waitFor, driver: snapshotDriver,
                                                    first: snapshot, seconds: seconds,
                                                    elementLimit: pollElementLimit(args))
                // **撃ち直しが起きたときだけ adoptSnapshot を通す**: 撃ち直しが無ければ
                // `waited.snapshot` は `snapshot`(既にセッション ref)そのものなので、
                // native 前提の adoptSnapshot に通すと同じ木を「別世代」と誤認する
                // (base 込みの ref を native ref と取り違えて比較するため)
                snapshot = waited.refetched ? adoptSnapshot(waited.snapshot, args: args) : waited.snapshot
                if !waited.found {
                    waitNote = "waitFor \"\(waitFor)\" did not appear within"
                        + " \(Self.secondsText(seconds))\(Self.waitTimeoutRemedy)"
                        + " — this is the screen as it is now\(Self.truncationHint(snapshot))"
                        + (waited.partialSeenAfter.map { seenAfter in
                            // **完全一致でなく部分一致が先に出た形を名指しする**: 満額待った理由
                            // (早期打ち切りはしない)まで書かないと、待った時間が無駄に見える
                            " — a partial match was already on screen \(Int(seenAfter.rounded()))s"
                                + " into the wait:\(waited.partialHint) The exact form never"
                                + " appeared, so the wait ran to the deadline"
                        // **記法の助言はここにも要る**: 切り詰めラベルをそのまま渡した waitFor は
                        // 外れるのに、返す木には**同じ文字列が印字されている**ので照合のバグに見える
                        // (2026-08-07 実測)。scrollTo だけに出していて届いていなかった
                        } ?? (Self.notationHint(waitFor, in: snapshot)
                              // **部分一致が出ていたときは出さない**: そちらのほうが具体的な
                              // ヒントなので、的の外れた推測を並べて紛らわせない
                              + Self.similarLabelsHint(waitFor, in: snapshot)))
                        + Self.waitForScrollHint(in: snapshot) + "\n"
                }
            }
            // **プラットフォームはドライバの実体から採る**(profile 指定時は args["platform"] が
            // 空でもプロファイル側で解決済みなので、args を見ると取り違える)
            recordSnapshot(snapshot, snapshotDriver is AndroidDriver ? "android" : "ios", args)
            return text(withPendingWarnings(
                await snapshotBody(snapshot, driver: snapshotDriver, args: args,
                                   extraNote: waitNote),
                args: args))

        case "ft_tap":
            let d = try await driver(args)
            if let ref = args["ref"] as? Int {
                let target = try await verifiedRef(ref, driver: d, args: args)
                // **target.ref はセッション ref**。ブリッジは native の番号しか知らないので、
                // 撃つ直前にだけ nativeRef で戻す(応答・記録には引き続きセッション ref を使う)
                try await d.tap(ref: nativeRef(target.ref, args: args))
                recordInteraction(action: "tap", resolvedRef: target.ref, args: args)
                return text("tap [\(ref)] done.\(target.note)"
                    + reproductionNote(resolvedRef: target.ref, args: args)
                    + Self.changedHint(args) + waitForWithoutSnapshotAfterNote(args)
                    + (await snapshotAfterBody(args)))
            }
            if let x = args["x"] as? Double, let y = args["y"] as? Double {
                try await d.tap(x: x, y: y)
                recordInteraction(action: "tap", resolvedRef: nil, args: args, coordinate: (x, y))
                return text("tap (\(x), \(y)) done" + once("coordinateReproductionNote",
                    full: Self.coordinateReproductionNote,
                    short: Self.coordinateReproductionNoteShort)
                    + waitForWithoutSnapshotAfterNote(args)
                    + (await snapshotAfterBody(args)))
            }
            throw MCPError("ref or x/y is required")

        case "ft_type":
            // **Enter は別ツールにしない**が、**入力を伴わない pressEnter も要る**:
            // iOS はソフトキーボードを閉じる手段が pressEnter しかない(hideKeyboard は Android 専用。
            // docs/commands.md)。そのため text は「pressEnter だけを撃つとき」は省略できる
            let wantsEnter = args["pressEnter"] as? Bool == true
            let content = args["text"] as? String
            let wantsReplace = args["replace"] as? Bool == true
            guard content != nil || wantsEnter else {
                throw MCPError("text is required (or pass pressEnter: true to fire Enter only)")
            }
            let typeDriver = try await driver(args)
            var targetRef = args["ref"] as? Int
            var note = ""
            // **type は追記**(docs/commands.md)。既に入っている欄へ撃つと連結された文字列になり、
            // 戻り値が `Typed: "東京タワー"` だけだと気づけない —— 検索欄なら検索自体は成立するので
            // **沈黙した誤りになる**(2026-08-07 に Google マップで `レストラン東京タワー` を実測)。
            // 撃つ前の値は verifiedRef が撮り直した木から引く(追加の snapshot を払わない)
            var priorValue: String?
            var priorElement: ElementInfo?
            if let ref = targetRef {
                let verified = try await verifiedRef(ref, driver: typeDriver, args: args)
                targetRef = verified.ref
                note = verified.note
                priorElement = lastSnapshots[Self.engineKey(args)]?
                    .elements.first { $0.ref == verified.ref }
                // **「入っている値」の判定は DSL と同じ**。素の `value` を見ていたので、
                // `placeholder` と同値の空欄(iOS 全般 / Android の CMP)でも MCP だけが
                // 追記警告を出していた —— StepExecutor は normalizedValue で黙る側
                priorValue = priorElement.map(TypeReadback.normalizedValue)
                // **入力欄でないものへ打とうとしていないか**。判定は DSL と共有
                // (TapTargetGeometry.nonInputTypeTargetNote。実測と理由はそちらの doc)。
                // MCP は StepExecutor を経由しない別経路なので、ここにも配線が要る
                if let priorElement,
                   let elements = lastSnapshots[Self.engineKey(args)]?.elements,
                   let warn = TapTargetGeometry.nonInputTypeTargetNote(priorElement, in: elements) {
                    note = note.isEmpty ? " (warning: \(warn))"
                        : note + " (warning: \(warn))"
                }
            }
            // **replace は文字が空でも clear する**: {replace:true, text:""} や
            // {replace:true, pressEnter:true} は「クリアだけ」「クリア+Enter」を成立させるための
            // 書き方で、スキーマも "Clear the field before typing" と約束している。下の入力分岐
            // (文字が非空のときだけ通る)の内側に置くと、空文字はそこへ一度も入らず黙って
            // 何もしない(スキーマの約束を破る)
            if wantsReplace {
                try await typeDriver.clearInput(ref: targetRef.map { nativeRef($0, args: args) })
            }
            // **replace + snapshotAfter(Enter を伴わない形)は同じ木を2回読まない**:
            // この組み合わせでは検証が読みたい瞬間(clear/type 直後)と snapshotAfter が読みたい
            // 瞬間が同じなので、snapshotAfterBodyWithStatus を先に1回だけ実行し、成功していれば
            // その木(lastSnapshots)を検証にも使う。失敗時だけ生読みへフォールバックする。
            // **pressEnter を伴う形は対象外**: Enter の前後で状態が変わるので、検証は Enter 前に
            // 読む必要があり(下の呼び出し位置のまま)、最終的に返す木は Enter 後でなければならない
            // —— そもそも2回読む理由がある(この最適化を適用すると Enter 前の古い木を返す)
            // 追記(replace なし)も読み返して確かめるので、同じ merge の対象にする。
            // これが無いと `snapshotAfter: true` の呼び方で**同じ木を2回読む**
            let verifiesAppend = !wantsReplace && !(priorValue ?? "").isEmpty
                && !(content ?? "").isEmpty
            let mergesSnapshotAfterIntoVerification =
                (wantsReplace || verifiesAppend) && !wantsEnter
                && args["snapshotAfter"] as? Bool == true
            var precomputedAfterBody: String?
            func verificationSnapshot() async -> SnapshotResponse? {
                guard mergesSnapshotAfterIntoVerification else {
                    return try? await typeDriver.snapshot(bypassingCache: typeDriver.supportsCacheBypass)
                }
                let result = await snapshotAfterBodyWithStatus(args)
                precomputedAfterBody = result.text
                guard result.succeeded else {
                    return try? await typeDriver.snapshot(bypassingCache: typeDriver.supportsCacheBypass)
                }
                return lastSnapshots[Self.engineKey(args)]
            }
            if let content, !content.isEmpty {
                // targetRef はセッション ref。ブリッジへ渡す直前にだけ native へ戻す
                try await typeDriver.type(ref: targetRef.map { nativeRef($0, args: args) }, text: content)
                // **ref を渡したときだけ読み返しで検証される**。iOS の XCUITest ランナーは
                // ref から対象を引けたときだけ TypeReadback の resend/deleteExcess を回し、
                // 引けない(= ref なし)ときは無検証の `typeText` へ落ちて OK を返す。
                // Android は焦点ノードを読み返すので ref なしでも検証される。
                // **replace のときはここでは読み返さない** —— 下の replaceVerificationNote が
                // 同じ理由(生読み・settle-lite 基準を壊さない)で改めて読むので、二重に払わない
                if targetRef == nil, !(typeDriver is AndroidDriver), !wantsReplace {
                    // **注意書きで済ませず、ここで確かめる**: iOS の XCUITest ランナーは ref から
                    // 対象を引けたときだけ TypeReadback を回すので、ref なしは無検証で OK が返る。
                    // 木は `focused` を持っているのだから、撮り直して**どこへ入ったか**を名指しできる
                    // (Android は焦点ノードを読み返すのでこの1枚は払わない)。
                    // **生読み(adoptSnapshot を通さない)**: この読みは入力という操作の**後**に
                    // 撮っているので、freshSnapshot 経由だと lastSnapshots[key] を上書きし、
                    // 続く snapshotAfterBody の settle-lite 基準(操作前の木のつもり)が
                    // 操作後の木になってしまい「変化なし」と誤報する
                    let rawAfterType = try? await typeDriver.snapshot(
                        bypassingCache: typeDriver.supportsCacheBypass)
                    note += await Self.typedIntoNote(driver: typeDriver, expected: content,
                                                     snapshot: rawAfterType)
                }
                if wantsReplace {
                    // **無条件の「replaced」を断言しない**: clearInput → type の後、
                    // 読み返しなしで無条件に付けていた。in-app iOS の UIKit 経路は検証なしで YES を
                    // 返すので、clear が効いていなくても(旧値の後ろに新しい文字が連結されても)
                    // 「replaced」と嘘をつく。読み返して期待どおり/マスクで検証不能/旧値残存/
                    // 読めないの4形に分ける(replaceVerificationNote)
                    note += Self.replaceVerificationNote(
                        target: priorElement, expected: content, fresh: await verificationSnapshot())
                } else if let prior = priorValue, !prior.isEmpty {
                    // **予告ではなく観測**(2026-08-13。appendVerificationNote の doc に witness)
                    note += Self.appendVerificationNote(target: priorElement, typed: content,
                                                        prior: prior,
                                                        fresh: await verificationSnapshot())
                }
            } else {
                // **clear-only({replace:true, text:"" or 省略})も無条件に「cleared」と断言しない**
                //: 読み返して期待どおり(空)/マスク/残存の3形に分ける
                // (replaceVerificationNote は expected 空でこの3形を返す)
                if wantsReplace {
                    note += Self.replaceVerificationNote(
                        target: priorElement, expected: "", fresh: await verificationSnapshot())
                }
                if let ref = targetRef {
                    // 入力せず Enter だけ撃つときも、対象が指定されていればフォーカスを立ててから。
                    // **タップの直後に撃たない**(下の awaitFocus): 直前に別の欄へ入力していると
                    // フォーカスの移動が間に合わず、Enter が**前の欄**へ飛んで黙って何も起きない
                    // (2026-08-06 に Android で観測。ime カウンタが増えなかった)
                    try await typeDriver.tap(ref: nativeRef(ref, args: args))
                    note += await awaitFocus(ref: ref, driver: typeDriver, args: args)
                }
            }
            // 入力欄も**セレクタで再現できないと書けない**(E)。ref を渡さない
            // (フォーカス任せの)呼び方では対象が確定しないので黙る
            let typedSelector = targetRef.map { reproductionNote(resolvedRef: $0, args: args) } ?? ""
            if let content, !content.isEmpty {
                recordInteraction(action: "type", resolvedRef: targetRef, args: args, text: content,
                                  replace: wantsReplace)
            }
            if wantsEnter { recordInteraction(action: "pressEnter", resolvedRef: nil, args: args) }
            guard wantsEnter else {
                let afterBody: String
                if let precomputedAfterBody {
                    afterBody = precomputedAfterBody
                } else {
                    afterBody = await snapshotAfterBody(args)
                }
                return text("Typed: \"\(content ?? "")\"\(note)\(typedSelector)"
                    + waitForWithoutSnapshotAfterNote(args)
                    + afterBody)
            }
            try await typeDriver.pressEnter()
            return text((content.map { "Typed: \"\($0)\" and pressed Enter" } ?? "Pressed Enter")
                + note + typedSelector + waitForWithoutSnapshotAfterNote(args)
                + (await snapshotAfterBody(args)))

        case "ft_swipe":
            guard let direction = FTSwipeDirection(rawValue: args["direction"] as? String ?? "") else {
                throw MCPError("direction must be one of up/down/left/right")
            }
            let swipeDriver = try await driver(args)
            // **型は入口で確かめる**(2026-08-12 のレビュー指摘): resolveScrollFrameArg が見るのは
            // Int と String だけなので、それ以外(bool・配列・オブジェクト)は空の ScrollFrameArg
            // になり、**容器を無視した全画面スワイプを「inside …」と名乗って**返していた
            if let frame = args["scrollFrame"], !(frame is Int), !(frame is String) {
                throw MCPError("scrollFrame must be a selector string (e.g. \"#list_rows\") or an"
                    + " ft_snapshot ref (an integer)")
            }
            // **未指定は今までと1バイトも変えない**(全画面固定の既定経路)。
            // **例外はキーボード表示中**(2026-08-31): 直近の `ft_snapshot` の控えがキーボードを
            // 申告していれば、素の driver.swipe ではなく DSL の swipe と同じ StepExecutor の
            // "swipe" ステップへ回す(StepExecutor+Actions.swift 参照。座標の合成・fail-fast を
            // MCP に2つ目実装しない)。**控えは古びうる方向にだけ倒す** —— 消えていれば
            // ここを通らず素の swipe へ落ち、StepExecutor 自身の撮り直しがキーボード無しと
            // 判定するので path は結局 nil(黙って全画面固定に戻るだけで誤動作しない)
            guard args["scrollFrame"] != nil else {
                let cached = lastSnapshots[Self.engineKey(args)]
                let keyboardUp = cached?.keyboardFrame != nil || cached?.keyboardShown == true
                guard keyboardUp else {
                    try await swipeDriver.swipe(direction)
                    recordInteraction(action: "swipe", resolvedRef: nil, args: args,
                                      direction: direction.rawValue)
                    // **「動いた」と断言しない**(back と同じ理由。2026-08-06)。スワイプは端に着いて
                    // いれば1px も動かないし、スクロールできない画面では何も起きない
                    return text("swipe \(direction.rawValue) sent."
                        + Self.changedHint(args, otherwise: " If anything moved, the old refs are stale"
                            + " — take a fresh ft_snapshot before using any ref")
                        + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(args)))
                }
                let step = FlowStep(action: "swipe", direction: direction.rawValue)
                let (isAndroid, uiFrameworkHint) = await resolveExecutorHints(swipeDriver, args: args)
                let executor = StepExecutor(driver: swipeDriver, releasesScrollTouch: !isAndroid, isAndroid: isAndroid,
                                            uiFramework: uiFrameworkHint)
                let outcome = await executor.execute(step)
                guard StepExecutor.isSuccess(outcome.status) else {
                    let reason: String
                    switch outcome.status {
                    case .failed(let message), .skipped(let message), .inconclusive(let message):
                        reason = message
                    case .passed, .passedViaFallback, .healed:
                        reason = "could not confirm the result"
                    }
                    throw MCPError(reason)
                }
                recordInteraction(action: "swipe", resolvedRef: nil, args: args,
                                  direction: direction.rawValue)
                return text("swipe \(direction.rawValue) sent"
                    + " (the soft keyboard was up — swiped in the area above it)."
                    + Self.changedHint(args, otherwise: " If anything moved, the old refs are stale"
                        + " — take a fresh ft_snapshot before using any ref")
                    + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(args)))
            }

            // **探索(ft_scroll_to)と同じ StepExecutor に委ねる**(DSL の
            // scrollDown/scrollUp/scrollLeft/scrollRight(scrollFrame:) と同じ FlowStep 形。
            // ScrollGeometry の呼び出し・マージン定数・容器解決・fail-fast は全部あちらに
            // 1本化されている — MCP に2つ目の実装を作らない。**実機で確認した実害**
            //: MCP から driver.swipe(_:intent:path:) を直に叩くと、in-app
            // ブリッジは領域指定つきスクロールを 501 で拒否する設計(Compose/Flutter。
            // InAppBridge/Sources/InAppBridge.swift:673-677「黙って別の領域を動かすより
            // 501 で XCUITest へ回す」)で、その 501→XCUITest フォールバックは
            // `StepExecutor.swipeWithFallback`(StepExecutor+Settle.swift:479
            // `DriverError.isEngineIncapable(error), let td = typeDriver`)にしか無いため、
            // in-app 単独のエンジンで ft_swipe が 501 のまま終わっていた
            let scrollFrameArg = try await resolveScrollFrameArg(args, driver: swipeDriver)
            let scrollFrameLabelNote = scrollFrameArg.note.isEmpty ? ""
                : "note: the scrollFrame ref was re-checked against the current tree\(scrollFrameArg.note).\n"
            let step = Self.swipeScrollFrameStep(direction: direction, scrollFrameArg: scrollFrameArg)
            let (isAndroid, uiFrameworkHint) = await resolveExecutorHints(swipeDriver, args: args)
            let executor = StepExecutor(driver: swipeDriver, releasesScrollTouch: !isAndroid, isAndroid: isAndroid,
                                        uiFramework: uiFrameworkHint)
            let outcome = await executor.execute(step)
            guard StepExecutor.isSuccess(outcome.status) else {
                let reason: String
                switch outcome.status {
                case .failed(let message), .skipped(let message), .inconclusive(let message):
                    reason = message
                case .passed, .passedViaFallback, .healed:
                    reason = "could not confirm the result"
                }
                // **容器なし/経路なしの文言は StepExecutor(FTCore)側の1本だけ**
                // (scrollFrameFailFastMessage)。MCP 側で二重に持たない
                throw MCPError(scrollFrameLabelNote + reason)
            }
            let containerName = scrollFrameArg.original.map(RefGuard.describe)
                ?? scrollFrameArg.locator?.summary ?? "the scrollFrame"
            // **下書きへは実行した step をそのまま渡す**: action "scroll" は
            // scrollDown/scrollUp/scrollLeft/scrollRight(scrollFrame:) として書き戻せる
            // (ScenarioCodeGen の "scroll" ケース)。**ref 形だけは書き戻せない** ——
            // rect は木の中の座標で、セレクタとして再現できないので正直に unresolved で残す
            // (セレクタの無い要素と同じ regime)
            if scrollFrameArg.locator != nil {
                interactions.record(InteractionLog.Entry(
                    step: step, unresolved: nil,
                    summary: "swipe \(direction.rawValue) inside \(containerName)"))
            } else {
                interactions.record(InteractionLog.Entry(
                    step: nil,
                    unresolved: "swipe \(direction.rawValue) inside \(containerName) — the container"
                        + " was given as a ref, which no selector reproduces; name it with a"
                        + " selector to get a scrollDown/scrollUp/scrollLeft/scrollRight line",
                    summary: "swipe \(direction.rawValue) inside \(containerName)"
                        + " [no stable DSL reproduction]"))
            }
            let fallbackNote = outcome.driverFallback.map { " (\($0))" } ?? ""
            return text(scrollFrameLabelNote + "swipe \(direction.rawValue) sent inside \(containerName)."
                + fallbackNote
                + Self.changedHint(args, otherwise: " If anything moved, the old refs are stale"
                    + " — take a fresh ft_snapshot before using any ref")
                + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(args)))

        case "ft_scroll_to":
            return try await scrollTo(args)

        case "ft_batch":
            return try await batch(args)

        case "ft_rotate":
            guard let raw = args["orientation"] as? String,
                  let orientation = FTOrientation.parse(raw) else {
                throw MCPError("orientation must be \"portrait\" or \"landscape\"")
            }
            let rotateDriver = try await driver(args)
            let settled = try await rotateDriver.rotate(to: orientation)
            var rotateStep = FlowStep(action: "rotateTo")
            rotateStep.direction = settled.rawValue
            interactions.record(InteractionLog.Entry(step: rotateStep, unresolved: nil,
                                                     summary: "rotateTo .\(settled.rawValue)"))
            // **回転はツリーの座標系ごと変える**ので、覚えている木は必ず捨てる
            // (古い ref を残すと、次のタップが回転前の座標で撃たれる)
            //
            // **driver.rotate が返るのは「向きが一致した」時点で、レイアウトはまだ動いている
            // ことがある**(実機 iPhone 13 の witness: `RotationSettle.framesFitScreen` の doc)。
            // DSL の rotateTo()(StepExecutor+Actions.swift)と同じ規律で、木が2回続けて指紋一致
            // するまで撮り直す(BackEffect.treesAreIdentical = StaleFrameDetector.treeFingerprint の
            // 等号。2つ目の指紋実装を作らない)。
            // **予算は変化待ちの `changeSettleRereads`(3)×`settleWaitSeconds`(0.4s)=1.2秒を
            // 流用していたが、実機 iPhone では足りなかった**(レイアウトが収まる前に打ち切っていた)。
            // ブリッジ側 POST /rotate の整定ポーリングと同じ締め切り
            // (`FTCore.RotationSettle.deadlineSeconds`)まで、同じ間隔で回す。**cap
            // (`rotationSettleMaxRereads`)が無いと、一度も整定しないドライバでループが止まらない**
            var rotated = try await freshSnapshot(rotateDriver, args: args)
            var settledFrames = false
            let rotationSettlePollInterval = max(RotationSettle.pollIntervalSeconds, settleWaitSeconds)
            let rotationSettleMaxRereads = Int(rotationSettleDeadlineSeconds / rotationSettlePollInterval)
            for _ in 0..<rotationSettleMaxRereads {
                try await Task.sleep(
                    nanoseconds: UInt64(max(0, rotationSettlePollInterval) * 1_000_000_000))
                let reread = try await freshSnapshot(rotateDriver, args: args)
                let fits = RotationSettle.framesFitScreen(reread)
                let unchanged = BackEffect.treesAreIdentical(before: rotated.elements,
                                                             after: reread.elements)
                rotated = reread
                if fits, unchanged { settledFrames = true; break }
            }
            recordSnapshot(rotated, Self.platformName(args), args)
            // **未settleを「もう終わった」と嘘をつかない** —— waitForChange の
            // still-changing 注記と同じ立て付け(MCPServer+Snapshot.swift)
            let relayoutCaveat = settledFrames ? ""
                : " note: the tree did not settle within the check budget — it may still be"
                    + " mid-relayout; take another ft_snapshot before relying on these frames."
            return text("Rotated to \(settled.rawValue). The frames below are in the new"
                + " coordinate system — refs taken before the rotation are gone."
                + relayoutCaveat + "\n\n"
                + (await snapshotBody(rotated, driver: rotateDriver, args: args)))

        case "ft_navigate":
            // **3つを1ツールに束ねる**: back/home/appSwitcher を個別ツールにすると定義が3倍になり、
            // 似た選択肢が並んでエージェントの選択が揺れる(docs/shirates-parity.md の
            // 「別名族を置かない」と同じ判断)
            let target = args["target"] as? String ?? ""
            let navigation = try await driver(args)
            // **back が無効だったかは木の指紋で見る**(home/appSwitcher は対象外)。
            // 覚えている木が無ければチェック自体をしない(照合の起点が無いのに撃つのは
            // 余計な往復を増やすだけ)。指紋は記憶から読むだけなので往復は増えない
            let wantsSnapshotAfter = args["snapshotAfter"] as? Bool == true
            let beforeBackElements = target == "back"
                ? lastSnapshots[Self.engineKey(args)]?.elements : nil
            switch target {
            case "back": try await navigation.back()
            case "home": try await navigation.home()
            case "appSwitcher": try await navigation.openAppSwitcher()
            default: throw MCPError("target must be one of back/home/appSwitcher")
            }
            recordInteraction(action: target, resolvedRef: nil, args: args)
            // **背面へ送ったのはツール自身**という事実だけを覚える(照会に頼らない理由は
            // `backgroundedByNavigate` の doc)。back は画面内で戻るだけのことがあるので数えない
            if target == "home" || target == "appSwitcher" {
                backgroundedByNavigate.insert(Self.engineKey(args))
            }
            // **snapshotAfter を渡されたら木はそちらが撮る**。ここで撮り直すと同じ木を2回
            // 取りに行くだけになるので、**先に本文を組み立ててから**その結果で無効を判定する
            // (`snapshotAfterBody` は adoptSnapshot 経由で `lastSnapshots` を更新するので、
            // 撮った木は指紋で読み返せる)。無効の注記自体は snapshotAfter の有無で消さない ——
            // 木が付いていても「前と同一」は読み手には分からない
            var afterBody = ""
            var snapshotAfterSucceeded = false
            if wantsSnapshotAfter {
                let result = await snapshotAfterBodyWithStatus(args)
                afterBody = result.text
                snapshotAfterSucceeded = result.succeeded
            }
            var backIneffectiveNote = ""
            if let before = beforeBackElements {
                // 判定そのものは FTCore.BackEffect(DSL の back() と共有・2つ目の指紋実装を作らない)。
                // **1回の撮り直しでは判定しない**(ポーリング): アニメーション途中の木を
                // 「変わっていない」と誤読しないため。取得に失敗したら黙って諦める
                // (成功した観測が1つも無ければ「変わっていない」と断言する材料が無い =
                // BackEffect.shouldWarn は observations が空なら false を返す)
                var observations: [[ElementInfo]] = []
                if wantsSnapshotAfter {
                    // **撮り直しに成功した回だけ判定する**: snapshotAfterBody が
                    // 読みに失敗すると lastSnapshots は back 前の木のまま残り、succeeded を見ずに
                    // 読むと指紋が自明に一致して「back は効かなかった」と誤読する(catch した回の
                    // 謝罪文の横に、矛盾する偽の注記が並ぶ)
                    if snapshotAfterSucceeded, let after = lastSnapshots[Self.engineKey(args)] {
                        observations = [after.elements]
                    }
                } else {
                    for _ in 0..<BackEffect.pollCount {
                        try? await Task.sleep(for: .seconds(BackEffect.pollIntervalSeconds))
                        guard let after = try? await freshSnapshot(navigation, args: args) else { continue }
                        observations.append(after.elements)
                        if !BackEffect.treesAreIdentical(before: before, after: after.elements) { break }
                    }
                }
                if BackEffect.shouldWarn(before: before, afterObservations: observations) {
                    backIneffectiveNote = ". note: " + BackEffect.note(advice: BackEffect.mcpAdvice)
                }
            }
            // **「画面が変わった」と断言しない**(2026-08-06 の探索で外した): iOS の back は
            // 端の swipe なので、自前ナビの画面(`#btn_back` を持つ SwiftUI 等)では
            // **何も起きない**。back でアプリ自体を出てしまうこともあり、どちらも
            // 「変わった」と言い切ると誤操作の起点になる
            return text("\(target) sent"
                + Self.changedHint(args, otherwise: ". Take a fresh ft_snapshot to see the result")
                + Self.backNoOpNote(target: target, engine: engines[Self.engineKey(args)])
                + backIneffectiveNote
                + Self.backgroundedAppNote(target: target, engine: engines[Self.engineKey(args)])
                + Self.backgroundingNavigationNote(target: target, engine: engines[Self.engineKey(args)])
                + waitForWithoutSnapshotAfterNote(args) + afterBody)

        case "ft_clear_app_data":
            guard let bundleID = args["bundleId"] as? String else { throw MCPError("bundleId is required") }
            let clearAppDataDriver = try await driver(args)
            let clearAppDataKey = Self.engineKey(args)
            do {
                try await clearAppDataDriver.clearAppData(bundleID: bundleID)
            } catch DriverError.badResponse(let status, let body)
                where status == 501 && body.contains("simulator-only") {
                // **実機に devicectl の同等手段が無い**(BridgeClient.clearAppData の 501)。
                // 代わりに uninstall→install で再現する —— 権限も含めて全部消える点は同じ。
                // **先に消す前に入れ直せることを確かめる**(reinstallSource) —— 記憶したパスは
                // 再ビルドや DerivedData の掃除で消えており、確かめずに uninstall すると
                // 端末からアプリだけ消えて戻せなくなる
                let path: String
                switch Self.reinstallSource(explicit: args["packagePath"] as? String,
                                            remembered: installedPackagePaths[clearAppDataKey],
                                            exists: { FileManager.default.fileExists(atPath: $0) }) {
                case .success(let resolved): path = resolved
                case .failure(let error): throw error
                }
                try await clearAppDataDriver.uninstall(bundleID: bundleID)
                try await clearAppDataDriver.install(packagePath: path)
                // 意図した再インストールなので、以後の別アプリの木は「すり替わり」ではない
                // (ft_terminate と同じ扱い)
                launchedBundleIDs[clearAppDataKey] = nil
                systemAlertProbePending.insert(clearAppDataKey)
                return text("Reinstalled \(bundleID) from \(path) (physical device: app data"
                    + " wiped by uninstall + install; permission grants are reset too)")
            }
            // 次の ft_launch が初回起動と同じ扱いになる(systemAlertProbePending 参照)
            systemAlertProbePending.insert(clearAppDataKey)
            return text("Cleared the data of \(bundleID). The app is stopped — ft_launch to continue")

        case "ft_clear_input":
            // ref 省略 = フォーカス中の欄(DSL の clearInput() と同じ)
            let clearDriver = try await driver(args)
            var clearRef = args["ref"] as? Int
            var clearNote = ""
            var clearTarget: ElementInfo?
            if let ref = clearRef {
                let verified = try await verifiedRef(ref, driver: clearDriver, args: args)
                clearRef = verified.ref
                clearNote = verified.note
                clearTarget = lastSnapshots[Self.engineKey(args)]?
                    .elements.first { $0.ref == verified.ref }
            }
            // clearRef はセッション ref。ブリッジへ渡す直前にだけ native へ戻す
            try await clearDriver.clearInput(ref: clearRef.map { nativeRef($0, args: args) })
            recordInteraction(action: "clearInput", resolvedRef: clearRef, args: args)
            // **無条件の「cleared」を断言しない**(2026-08-13。ft_type replace / 追記と同じ型の掃討)——
            // in-app iOS の UIKit 経路は clearInput の成否を検証なしで YES を返すので、値が残っていても
            // 「消した」と言ってしまう。呼び手はこの後 ft_type を撃つので、**残っていると黙って連結される**。
            // 判定は replace の clear-only 検証と同じ関数(空を期待して読み返す)
            let clearedVerdict = Self.replaceVerificationNote(
                target: clearTarget, expected: "",
                fresh: try? await clearDriver.snapshot(bypassingCache: clearDriver.supportsCacheBypass))
            return text("clearInput sent\(clearNote)\(clearedVerdict)"
                + (clearRef.map { reproductionNote(resolvedRef: $0, args: args) } ?? ""))

        case "ft_draft_scenario":
            return text(draftScenario(args))

        case "ft_dsl_commands":
            return dslCommands(args)

        case "ft_double_tap":
            // **座標へ畳んでから撃つ**: ref はブリッジごとに別名前空間で、501 で別ドライバへ
            // 回るときに取り直しが要る(AppDriver.doubleTap が ref を取らない理由と同じ)
            let doubleTapDriver = try await driver(args)
            let doubleTapPoint: (x: Double, y: Double)
            // **答えは渡された形で返す**: ref を渡したのに座標で返すと、tap/press
            // (`[17]` と返す)と食い違って読み手が取り違える(2026-08-07 の棚卸し)
            var doubleTapWhat: String
            var doubleTapNote = ""
            var doubleTapSelector = ""
            var doubleTapResolvedRef: Int?
            if let ref = args["ref"] as? Int {
                let (element, labelNote) = try await verifiedElement(ref, driver: doubleTapDriver, args: args)
                doubleTapPoint = (element.frame.centerX, element.frame.centerY)
                doubleTapWhat = "[\(ref)]"
                doubleTapResolvedRef = element.ref
                // **ft_tap と同じ被覆にする**(ft_tap は verifiedRef 経由で遮蔽・残像・
                // 中身外し・キーボード被覆も見ている)。ここだけ見落とすと、同じ要素に対して
                // ツールごとに言うことが変わる(2026-08-08 のレビュー)。
                // keyboardFrame は verifiedElement が撮り直した木(lastSnapshots に反映済み)から
                // 作る(木の chrome で広げ、chrome 自身とその部分木は除外する)
                let doubleTapSnapshot = lastSnapshots[Self.engineKey(args)]
                doubleTapNote = RefGuard.preTapWarnings(
                    element, keyboardOcclusion: KeyboardOcclusion.resolve(
                        reported: doubleTapSnapshot?.keyboardFrame,
                        in: doubleTapSnapshot?.elements ?? []),
                    overlayWindows: OverlayWindowOcclusion.resolve(
                        reported: doubleTapSnapshot?.overlayWindowFrames))
                    + RefGuard.overlapWarning(found: element, in: doubleTapSnapshot?
                        .elements ?? [], screen: doubleTapSnapshot?.screen
                        ?? FTRect(x: 0, y: 0, width: 0, height: 0),
                        isAndroid: Self.platformName(args) == "android") + labelNote
                doubleTapSelector = reproductionNote(resolvedRef: element.ref, args: args)
            } else if let x = args["x"] as? Double, let y = args["y"] as? Double {
                doubleTapPoint = (x, y)
                doubleTapWhat = "(\(x), \(y))"
                doubleTapSelector = once("coordinateReproductionNote",
                                         full: Self.coordinateReproductionNote,
                                         short: Self.coordinateReproductionNoteShort)
            } else {
                throw MCPError("ref or x/y is required")
            }
            try await doubleTapDriver.doubleTap(x: doubleTapPoint.x, y: doubleTapPoint.y)
            recordInteraction(action: "doubleTap", resolvedRef: doubleTapResolvedRef, args: args,
                              coordinate: doubleTapResolvedRef == nil ? doubleTapPoint : nil)
            return text("double tap \(doubleTapWhat) done.\(doubleTapNote)\(doubleTapSelector)"
                + Self.changedHint(args)
                + iosEngineHint("Compose Multiplatform", "double tap", args: args)
                + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(args)))

        case "ft_drag":
            let dragDriver = try await driver(args)
            // **掴む側を ref で指せる**: 半開きのシートを広げる操作は
            // 「グラバーを上へ引く」だけなのに、座標しか受けないせいで
            // `#Card grabber` の frame を人が読んで手で計算する必要があった(実測)。
            // 終点は「そこまで運ぶ距離」なので dy/dx でも書ける
            var fromPoint: (x: Double, y: Double)?
            // **once() は実際に使う枝でだけ呼ぶ**: fromRef 側で上書きされる既定値として
            // 呼ぶと、座標形を一度も返していないのに「もう説明した」ことになってしまう
            var dragSelector = ""
            if let ref = args["fromRef"] as? Int {
                // **撮り直した木の frame を使う**(verifiedElement)。覚えていた frame から
                // 座標を作ると、この修正が防ごうとしている「古い座標を撃つ」に自分で落ちる
                let (element, labelNote) = try await verifiedElement(ref, driver: dragDriver, args: args)
                fromPoint = (element.frame.centerX, element.frame.centerY)
                dragSelector = reproductionNote(resolvedRef: element.ref, args: args) + labelNote
            } else if let x = args["fromX"] as? Double, let y = args["fromY"] as? Double {
                fromPoint = (x, y)
                dragSelector = once("coordinateReproductionNote",
                                    full: Self.coordinateReproductionNote,
                                    short: Self.coordinateReproductionNoteShort)
            }
            guard let from = fromPoint else {
                throw MCPError("fromRef or fromX/fromY is required")
            }
            // 終点は絶対座標か相対移動のどちらか(相対は「グラバーを 400 上へ」を素直に書ける)
            let toX = args["toX"] as? Double ?? (from.x + (args["dx"] as? Double ?? 0))
            let toY = args["toY"] as? Double ?? (from.y + (args["dy"] as? Double ?? 0))
            guard toX != from.x || toY != from.y else {
                throw MCPError("the drag does not move: pass toX/toY, or dx/dy")
            }
            let fromX = from.x
            let fromY = from.y
            try await dragDriver.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                                      pressSeconds: 0.05,
                                      durationSeconds: args["durationSeconds"] as? Double ?? 1.5)
            // DSL に drag の対応コマンドが無いので、下書きには TODO 行として残す
            // (座標タップと同じ扱い。黙って消すと探索の再現が途中から辻褄が合わなくなる)
            recordInteraction(action: "drag", resolvedRef: nil, args: args,
                              coordinate: (fromX, fromY))
            // **無検証であることを言う**(swipe / pinch は言っているのに drag / press だけ
            // 「done」で言い切っていた。同じ無検証なのに信頼度が違って見える)
            return text("drag (\(fromX), \(fromY)) → (\(toX), \(toY)) sent.\(dragSelector)"
                + (args["snapshotAfter"] as? Bool == true
                   ? " Nothing about the result is checked — read the tree below to confirm"
                     + " it moved what you meant."
                   : " Nothing about the result is checked — if it should have moved something,"
                     + " confirm with ft_snapshot/ft_screenshot")
                + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(args)))

        case "ft_pinch":
            let scale = args["scale"] as? Double ?? 2.0
            guard scale > 0, scale != 1, scale.isFinite else {
                throw MCPError("scale must be positive and not 1 (>1 zooms in, <1 zooms out)")
            }
            // ref 指定時は frame と identifier の**両方**を渡す(対象の伝え方が経路で違う。
            // Android/in-app は frame の中心・XCUITest は identifier。FTCore/BridgeDTO の PinchRequest)
            let pinchDriver = try await driver(args)
            var frame: FTRect?
            var identifier: String?
            var whole = false
            var areaIgnored = false
            var pinchSelector = ""
            var pinchResolvedRef: Int?
            var pinchCoordinate: (x: Double, y: Double)?
            if let ref = args["ref"] as? Int {
                let (element, labelNote) = try await verifiedElement(ref, driver: pinchDriver, args: args)
                frame = element.frame
                identifier = element.identifier
                pinchResolvedRef = element.ref
                pinchSelector = reproductionNote(resolvedRef: element.ref, args: args) + labelNote
            } else if let x = args["x"] as? Double, let y = args["y"] as? Double {
                // **地図・キャンバスには ref が無い**(2026-08-09 実測): Apple マップの場所カードを
                // 半分出したまま ref 無しで撃つと、指が画面全体に開くのでシートが掴まれ、
                // **地図は 1px も動かずシートが全画面に展開した**。逃げ道が無かったので、
                // ft_tap / ft_long_press / ft_drag と同じく座標を受ける
                pinchCoordinate = (x, y)
                frame = Self.pinchArea(x: x, y: y, radius: args["radius"] as? Double,
                                       screen: lastSnapshots[Self.engineKey(args)]?.screen)
                // **XCUITest は領域を受け取れない**(`PinchRequest.frame` を読むのは Android と
                // in-app だけ。XCTest のピンチは XCUIElement にしか生えておらず、座標版が無い)。
                // 黙って全画面へ退化させると、狙った場所を撃ったつもりで**手前のシートを掴む**
                // —— この修正の動機そのものなので、退化したことを必ず言う
                areaIgnored = engines[Self.engineKey(args)] == "xcuitest"
            } else {
                whole = true
            }
            let pinchDuration = args["durationSeconds"] as? Double ?? 0.5
            try await pinchDriver.pinch(frame: frame, identifier: identifier, scale: scale,
                                        durationSeconds: pinchDuration)
            // 記録は DSL の語彙(pinchOut/pinchIn)で。既定の 0.5s は落とす(codegen が省くため)
            recordInteraction(action: scale > 1 ? "pinchOut" : "pinchIn",
                              resolvedRef: pinchResolvedRef, args: args,
                              coordinate: pinchCoordinate,
                              duration: pinchDuration == 0.5 ? nil : pinchDuration, scale: scale)
            return text("pinch x\(scale) done.\(pinchSelector)"
                // **「小さくなる」とだけ言わない**(2026-08-06 実測): 指が対象の内側に収まる分だけ
                // 小さくなることもあれば、慣性で大きくもなる(scale 2.0 の要求で累積 3.9 倍)
                + " The actual zoom can differ from what you asked for in either direction"
                + " — verify with ft_snapshot/ft_screenshot."
                + (whole ? " The fingers spanned the whole screen, so anything on top of the area"
                    + " you meant (a bottom sheet, a card) may have taken the gesture instead —"
                    + " pass x/y to pinch a specific spot." : "")
                + (areaIgnored ? " x/y was NOT honoured: the XCUITest engine can only pinch an"
                    + " element (XCTest has no coordinate pinch), so the fingers spanned the whole"
                    + " screen and anything drawn over that spot may have taken the gesture."
                    + " Pass profile: naming an in-app/hybrid run profile to pinch a coordinate"
                    + " area (this relaunches the app — re-navigate before retrying)." : "")
                // **同じ逃げ道を2度書かない**(2026-08-08 に長文の苦情があった箇所)。
                // 領域が無視されたときの文は engine も remedy も言い切っているので、
                // 汎用の Flutter 助言はそこでは畳む
                + (areaIgnored ? "" : iosEngineHint("Flutter", "pinch", args: args))
                + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(args)))

        // `ft_press` は旧名(2026-08-15 に `ft_long_press` へ改名)。**受け続ける** ——
        // 手元のメモや既存の手順に残っている名前を「不明なツール」で落とす理由が無い
        case "ft_long_press", "ft_press":
            // 引数名は DSL の tap(holdSeconds:) と同語彙(2026-08-10 の語彙統一)。
            // 旧名は黙って既定値に落とさない(1.0s の長押しに化けて沈黙した誤りになる)。
            // **引数だけで弾ける検証はドライバ取得より前に**(コールドスタートは分単位かかりうる)
            guard args["duration"] == nil else {
                throw MCPError("duration was renamed to holdSeconds (same vocabulary as the"
                    + " DSL's tap(holdSeconds:)) — pass holdSeconds instead")
            }
            let pressDriver = try await driver(args)
            let pressDuration = args["holdSeconds"] as? Double ?? 1.0
            if let ref = args["ref"] as? Int {
                let pressTarget = try await verifiedRef(ref, driver: pressDriver, args: args)
                // pressTarget.ref はセッション ref。ブリッジへ渡す直前にだけ native へ戻す
                try await pressDriver.press(ref: nativeRef(pressTarget.ref, args: args),
                                            duration: pressDuration)
                recordInteraction(action: "press", resolvedRef: pressTarget.ref, args: args,
                                  duration: pressDuration)
                return text("press [\(ref)] done.\(pressTarget.note)"
                    + reproductionNote(resolvedRef: pressTarget.ref, args: args)
                    + Self.changedHint(args)
                    + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(args)))
            }
            // **座標形は ft_tap と揃える**: ドライバは press(x:y:duration:) を要件として持つのに
            // MCP からは ref でしか呼べなかった。地図・キャンバスのように a11y 要素が無い点を
            // 長押しする操作(ピンを落とす・住所を出す)が一切書けない状態だった
            if let x = args["x"] as? Double, let y = args["y"] as? Double {
                try await pressDriver.press(x: x, y: y, duration: pressDuration)
                recordInteraction(action: "press", resolvedRef: nil, args: args, coordinate: (x, y),
                                  duration: pressDuration)
                return text("press (\(x), \(y)) done." + once("coordinateReproductionNote",
                    full: Self.coordinateReproductionNote,
                    short: Self.coordinateReproductionNoteShort)
                    + Self.changedHint(args)
                    + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(args)))
            }
            throw MCPError("ref or x/y is required")

        case "ft_screenshot":
            let screenshotDriver = try await driver(args)
            // 鮮度判定は StaleFrameDetector.judge(FTCore。DSL の occlusion-guard と共有・
            // 契約はそちらのコメント参照)。撮影前の snapshot は取らない
            // (往復は screenshot 1回 + snapshot 1回の計2回)。
            // **限界**: 木の変化が画素に出ない変化(a11y のみ)は誤検知になり得るが、指紋は
            // type/id/label/frame なので実害は薄い
            let png = try await screenshotDriver.screenshot()
            var staleNote: [[String: Any]] = []
            // 木の取得に失敗したら判定せず、記録も汚さない(前回の記録を残す)
            if let after = try? await freshSnapshot(screenshotDriver, args: args) {
                let key = Self.engineKey(args)
                let (record, isStale) = StaleFrameDetector.judge(
                    png: png, elements: after.elements, previous: lastScreenshots[key])
                if isStale {
                    staleNote = [["type": "text", "text":
                        "note: the element tree has changed since the previous ft_screenshot, but"
                        + " this image is byte-identical to that previous one — the frame is likely"
                        + " STALE (a frozen display can keep serving an old frame). Do not read"
                        + " results off this image; trust ft_snapshot, and re-take the screenshot"
                        + " after interacting with the screen."]]
                }
                lastScreenshots[key] = record
            }
            guard (args["fullSize"] as? Bool) != true else {
                return staleNote
                    + [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]]
            }
            // 縮小できないとき(壊れた PNG・ImageIO 失敗)は絵を返さないより原寸のほうがまし
            guard let scaled = ImageDownscale.jpeg(
                png: png,
                maxWidth: args["maxWidth"] as? Int ?? Self.screenshotMaxWidth,
                quality: args["quality"] as? Double ?? Self.screenshotQuality) else {
                return staleNote
                    + [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]]
            }
            return staleNote + [["type": "image", "data": scaled.data.base64EncodedString(),
                                  "mimeType": "image/jpeg"]]

        case "ft_terminate":
            try await driver(args).terminate()
            // 意図して落としたので、以後の別アプリの木は「すり替わり」ではない
            launchedBundleIDs[Self.engineKey(args)] = nil
            systemAlertProbePending.remove(Self.engineKey(args))
            // 前面が消えたので、覆い探針の記憶(F 節)は使い回さない
            lastScreenProbe[Self.engineKey(args)] = nil
            return text("Terminated the app")

        case "ft_list_scenarios":
            return try listScenarios(args)

        case "ft_dry_run":
            return try await dryRun(args)

        case "ft_run_scenario":
            return try await runScenario(args)

        case "ft_list_projects":
            return try listProjects()

        case "ft_doctor":
            let fm = await FMDoctor.checkLive()
            // **視覚系も実呼び出しで確かめる**(能力判定では足りない。text と vision は独立に死ぬ)
            let vision = await FMDoctor.visionCheckLive()
            return text((fm.available ? "✅ " : "❌ ") + fm.detail
                + (fm.available ? "" : "\n   " + FMDoctor.unavailableImpact)
                + "\n" + (vision.available ? "✅ " : FMVisionSupport.isSupported ? "❌ " : "⚠️ ") + vision.detail)

        default:
            throw MCPError("unknown tool: \(tool)")
        }
    }

    func text(_ string: String) -> [[String: Any]] {
        [["type": "text", "text": string]]
    }

    /// `ft_open_url` の1行目。**snapshotAfter の有無で出し分ける**:
    /// 木を返すのに「ft_snapshot を撃ち直せ」と言うのは矛盾するので、そちらは待ち方の案内に替える。
    /// **配送が非同期であることは黙らない** —— settle-lite は**操作前の木を覚えているときしか
    /// 走らない**ので、`ft_launch` 直後(記憶が無い)の `snapshotAfter` は遷移前の画面を
    /// 何の断りもなく返し得る(2026-08-12 のレビュー指摘)
    /// **推測した宛先は推測と分かる形で言う**: `bundleId` を省くと
    /// 「このセッションで最後に ft_launch したアプリ」が既定になるが、素の
    /// "Delivered <url> to <bundleID>." は**利用者が渡した宛先の確認**と字面が同じで、
    /// 読み手は自分が指定していないことに気付けない(実際の探索で気付かなかった)。
    /// しかも Android では bundleID が intent の宛先そのものなので、その間に別アプリへ
    /// 移っていれば**裏に居るアプリが叩き起こされる**。断らずに済ませる代わりに、
    /// 何を根拠に選んだかを必ず添える
    /// `waitedForLanding`: 着地待ち(waitForChange)を実際に適用したか。**要約は実際にやったことを
    /// 言う** —— `waitForChange: false` を渡した相手に「待って読んだ」と書くと、返ってきた木が
    /// 前の画面でも読み手は待った結果だと信じる(2026-08-16 に変異テストの境界を締めて露見)
    static func openURLSummary(url: String, bundleID: String?, bundleIDWasRemembered: Bool,
                               snapshotAfter: Bool, waitedForLanding: Bool = true) -> String {
        let target = bundleID.map {
            " to \($0)" + (bundleIDWasRemembered
                ? " (not given — this session's last ft_launch on this device;"
                    + " pass bundleId if the foreground app has changed since)"
                : "")
        } ?? ""
        let delivered = "Delivered \(url)" + target + "."
        let asynchronous = " Delivery is asynchronous (the app has to receive and handle it)"
        guard !snapshotAfter else {
            // **既定は「待つ」**(配送直後に読むと前の画面が返り得る)。
            // 待っても着地しなかったことは waitForChange の注記が言う
            guard waitedForLanding else {
                return delivered + asynchronous + " — the tree below was read right after delivery"
                    + " (waitForChange: false), so it can still be the previous screen"
            }
            return delivered + asynchronous + " — the tree below was read after waiting for the"
                + " screen to change (pass waitFor with something only the destination has when"
                + " the change alone is not enough, or waitForChange: false to read immediately)"
        }
        return delivered + asynchronous
            + " — if a ft_snapshot right after still shows the old screen, wait and snapshot again"
    }

    /// `ft_swipe(scrollFrame:)` が投げる `FlowStep`(action "scroll" = DSL の
    /// scrollDown/scrollUp/scrollLeft/scrollRight(scrollFrame:) と同じ形)。純関数へ切り出したのは
    /// **direction を書き換えないことをここで固定する**ため: action "scroll" は `FlowStep.direction`
    /// を**指の向き**として読む(`StepExecutor+Actions.swift:55`
    /// `FTSwipeDirection(rawValue: step.direction ?? "")`)。DSL の `scrollImpl`
    /// (`Commands.swift:664`)も `direction.swipe.rawValue`(content→指の向き)を積んでおり、
    /// `ft_swipe` の `direction` 引数はもともと指の向きなので、**ここで逆写像を掛けてはいけない**
    /// (掛けると黙って逆へ振る)。maxSwipes は 1(一画面ぶん)固定。マージン比は渡さない
    /// (nil = `StepExecutor` 側の探索既定に従う。MCP 側で定数を選ばない)
    static func swipeScrollFrameStep(direction: FTSwipeDirection,
                                     scrollFrameArg: ScrollFrameArg) -> FlowStep {
        FlowStep(action: "scroll", direction: direction.rawValue, maxSwipes: 1,
                scrollFrame: scrollFrameArg.locator, scrollFrameRect: scrollFrameArg.rect)
    }

    /// 「撮り直せ」の案内。**snapshotAfter を渡されているときは黙る** —— 木がその下に続くのに
    /// 撮り直しを勧めると、往復を減らすために足した機能が往復を増やす助言と矛盾する
    /// snapshotAfter で木を返すときは「撮り直せ」を畳む(返した木の直上で撮り直しを勧める矛盾を
    /// 作らない)。文言をツール固有にしたいときも**この関数を通す** —— 条件を手元で再導出すると
    /// 抑止の方針変更が各ハンドラへ散る
    static func changedHint(_ args: [String: Any],
                            otherwise message: String = " The screen may have changed —"
                                + " take a fresh ft_snapshot") -> String {
        args["snapshotAfter"] as? Bool == true ? "" : message
    }

    /// ft_clear_app_data が実機で uninstall→install に化けるときの再インストール元。
    /// **純粋関数へ切り出したのは、uninstall を撃つ前に判定を終わらせるため** —— 呼び出し側は
    /// `.failure` を投げてから uninstall/install のどちらも呼ばない。`exists` を注入するのは
    /// テストが実ファイルを要らずに両分岐を確かめるため
    static func reinstallSource(explicit: String?, remembered: String?,
                                exists: (String) -> Bool) -> Result<String, MCPError> {
        guard let path = explicit ?? remembered else {
            return .failure(MCPError("On a physical device there is no clearAppData equivalent —"
                + " data is wiped by reinstalling the app instead. Pass packagePath:"
                + " <path to the .app/.ipa>, or run ft_install first so this can reuse"
                + " that path."))
        }
        guard exists(path) else {
            return .failure(MCPError("The app was NOT uninstalled. The reinstall source \(path)"
                + " no longer exists (a rebuild or clearing DerivedData can move or remove it) —"
                + " pass packagePath: <path to the current .app/.ipa>, or run ft_install first."))
        }
        return .success(path)
    }

    /// 操作した要素を**シナリオで再現するためのセレクタ**(E)。
    ///
    /// ref はセッション限りの番号なのでシナリオには書けない。探索の目的が「操作しながら
    /// 実セレクタを採る」ことである以上、ここで返すべきは ref ではなく**その操作を再現する
    /// 文字列**である。判定は B(曖昧ラベル注記)と同じ `SelectorNaming` を通す。
    ///
    /// **書けないときも黙らない** —— 「安定セレクタが無い」と言われて初めて、読み手は
    /// 祖先を掴むなり id を足すなりの次の手を選べる。
    /// `resolvedRef` は verifiedRef が撮り直した木での ref(掴み直しで動いていることがある)
    func reproductionNote(resolvedRef: Int, args: [String: Any]) -> String {
        guard let snapshot = lastSnapshots[Self.engineKey(args)],
              let element = snapshot.elements.first(where: { $0.ref == resolvedRef })
        else { return "" }
        if let graded = Self.SelectorNaming(snapshot).graded(for: element, in: snapshot) {
            // **セレクタ自体は毎回出すが、但し書きは初回だけ満額**: id の薄いアプリ
            // (地図等)ではタップのたび同じ index-based 注意が繰り返され、id を足せない他社
            // アプリ相手ではノイズになる。indexedSelectorNote(下書き用・L2677/L2771)とは
            // 文言が違うので鍵を共有しない
            let caution = graded.durability == .indexed
                ? once("indexedSelectorCaution", full: graded.durability.caution,
                      short: " — index-based (see the first note)")
                : ""
            return " (selector: \(graded.selector)\(caution))"
        }
        return " — no stable selector for this element, so a scenario cannot reproduce this"
            + " by selector; use a labelled ancestor, or have the app expose an id"
            + Self.homeScreenLaunchHint(snapshot.sessionBundleID)
    }

    /// ホーム画面(ランチャ)で「安定セレクタが無い」と言われた相手への次の手。
    /// アイコンは a11y の id を持たないので**この画面では永久に書けない** —— そこで詰まった読み手が
    /// 欲しいのは別のセレクタではなく「アプリを開く別の口」なので、そちらを名指しする
    static func homeScreenLaunchHint(_ session: String?) -> String {
        guard let session,
              session == "com.apple.springboard" || session.lowercased().contains("launcher")
        else { return "" }
        return ". This is the home screen — if you meant to open an app, ft_launch bundleId:"
            + " <bundle id / package> does it directly (ft_list_apps prints the ids), and a"
            + " scenario can reproduce that."
    }

    /// 座標で撃ったときの断り(E-4)。**推測のセレクタを出さない** —— 座標には
    /// 「その点に何があったか」以上の根拠が無い
    /// **2026-08-16 に「書けない」から「書けるが弱い」へ直した**: DSL に `tap(x:y:)` が入ったので
    /// 座標もシナリオ行になる(`ft_draft_scenario` は置き換えを促す行末コメント付きで出す)。
    /// 用途で重みが違う —— **探索中は座標のほうが速いことがあり、それでよい**。
    /// **シナリオに残すならセレクタが最優先**(レイアウトが動けば座標は別の物を叩く)
    static let coordinateReproductionNote =
        " (writable as tap(x:, y:) — fine while exploring, but replace it with a selector"
        + " before keeping it in a scenario: a layout change makes it hit something else)"
    /// `once` の短縮形(セッション内2回目以降)。**理由の再掲は落とす** —— 1度言えば足りる
    static let coordinateReproductionNoteShort =
        " (writable as tap(x:, y:) — see the first note)"

    /// 溜まっているプロファイル警告を先頭に付けて1度だけ吐き出す
    func withPendingWarnings(_ body: String, args: [String: Any]) -> String {
        let key = Self.engineKey(args)
        guard let warnings = pendingWarnings.removeValue(forKey: key), !warnings.isEmpty
        else { return body }
        return warnings.joined(separator: "\n") + "\n" + body
    }

    /// 繰り返し出る注記を初回だけ満額にする(F-6・2026-08-10)。**通すのは dispatch 経由の
    /// 応答組み立てだけ**にすること — static 関数そのものは short/full を知らないまま変えない
    /// (テストの独立性を保つ: 同じ static 関数を単体で呼ぶテストは常に満額の文を見る)。
    /// **full/short は @autoclosure**: 呼び出し側は素の式を渡すだけでよく、
    /// 選ばれなかった側は評価されない(full/short とも重い計算のことがある —— 実測
    /// unlabeledClickablesNote 等で1本 29〜116ms)
    func once(_ key: String, full: @autoclosure () -> String, short: @autoclosure () -> String) -> String {
        explainedNotes.insert(key).inserted ? full() : short()
    }

    /// 「この鍵は初出か」だけを返す `once` の同型。本文の2形を持たない注記
    /// (見出しそのものを短縮する類)が使う。**鍵の名前空間は `once` と共有**
    func firstTime(_ key: String) -> Bool {
        explainedNotes.insert(key).inserted
    }

    /// `once` を「注記が空のときはキーを消費しない」形にした版。full が空の画面で先に呼ぶと、
    /// その画面には何も出ないのにキーだけ記録され、次に本当に出た画面(初出のはず)が
    /// 短縮形になってしまう。truncatedLabelNote/unlabeledClickablesNote/ambiguousLabelsNote/
    /// duplicateIDsNote が共有する。
    ///
    /// **closure 形**: 呼び手はどちらを出すかだけを決める1つの render を渡し、
    /// これが**1回だけ**評価される —— 旧実装(full:/short: の2引数)は空判定のため full を
    /// 必ず評価し、初出でないときは short も評価していた(定常状態で二重評価。full/short とも
    /// 重い計算のことがある)。空判定は「実際に表示する側」の結果で行う: これらの note 関数は
    /// いずれも `guard !xxx.isEmpty else { return "" }` を abbreviated 分岐より手前に持つので、
    /// 空かどうかは abbreviated の値に依らない
    func onceNonEmpty(_ key: String, render: (_ abbreviated: Bool) -> String) -> String {
        let abbreviated = explainedNotes.contains(key)
        let rendered = render(abbreviated)
        guard !rendered.isEmpty else { return "" }
        if !abbreviated { explainedNotes.insert(key) }
        return rendered
    }

    /// stdout は JSON-RPC 専用(混ぜるとクライアントのパースが壊れる)。診断は必ず stderr へ
    static func logStderr(_ message: String) {
        FileHandle.standardError.write(Data(("[fleetest-mcp] " + message + "\n").utf8))
    }

}
