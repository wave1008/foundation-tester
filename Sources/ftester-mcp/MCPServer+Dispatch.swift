// MCPServer+Dispatch.swift
// ツールの入口(call/dispatch)と各ツールの実装。本体は MCPServer.swift(instance 状態はそちらに置く)

import Foundation
import FTAgent
import FTAndroid
import FTBridgeClient
import FTCore
import FTDSL

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
    /// **ラベル変化だけは note で返す**(2026-08-10) —— これは double_tap/drag/pinch が
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
        let fresh = try await freshSnapshot(driver, args: args)
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

    /// 引数から見た宛先プラットフォーム。**既定は iOS**(FTESTER_PLATFORM で上書き)
    static func platformName(_ args: [String: Any]) -> String {
        (args["platform"] as? String)
            ?? ProcessInfo.processInfo.environment["FTESTER_PLATFORM"] ?? "ios"
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
            project: project, registered: LocalConfig.currentMachineName(),
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
            // InAppBridge/build.sh が無く provision が必ず落ちる(.ftester の状態も CLI と食い違う)
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
    /// 先代が蹴り出される。FTester.swift の bridge up 参照)。素のメッセージからは追えない
    func call(tool: String, args: [String: Any]) async throws -> [[String: Any]] {
        let clock = ContinuousClock()
        let start = clock.now
        // **udid は入口で port へ畳む**(2026-08-10)。`driver(_:)` は解決後のポートで
        // ドライバを引くのに、`engineKey` は生の引数しか見ないので、udid で指した機は
        // すべて port=nil の同じキーに落ちていた。engineKey が引く記憶は
        // lastSnapshots / launchedBundleIDs / uiFrameworkHints / connections /
        // pendingWarnings / udids / engines / rememberedSnapshotFilters の8つで、
        // **2台を udid で操作すると混ざる**
        // (実測: 機A に Preferences・機B に Maps を launch した後、機A への
        //  ft_open_url が com.apple.Maps へ配ると申告した。Android では intent の
        //  宛先そのものなので、同じ機の中で別アプリへ実際に配送される)。
        // 入口で畳めば 35 箇所の呼び出しを触らずに全部が揃う
        let resolved: [String: Any]
        do {
            resolved = Self.strippingSelectorQuotes(try await Self.foldingUDIDIntoPort(args))
        } catch {
            let hint = await connectionLostHint(error, args: args)
            throw hint.isEmpty ? error : MCPError(error.localizedDescription + hint)
        }
        do {
            return Self.withElapsed(try await dispatch(tool: tool, args: resolved),
                                    since: start, clock: clock)
        } catch {
            let hint = await connectionLostHint(error, args: resolved)
                + Self.setTextRefusedHint(tool: tool, args: resolved,
                                          message: error.localizedDescription)
            guard !hint.isEmpty else { throw error }
            throw MCPError(error.localizedDescription + hint)
        }
    }

    /// `ft_type(ref:)` が Android の注入器に断られたときの回避策。**挙動は変えない** ——
    /// ACTION_SET_TEXT を受け付けない widget(NumberPicker など)が実在し、その欄でも
    /// **フォーカス済みの欄へキーで撃つ経路(ref なし)は通る**(2026-08-12 にエミュレータで実測)。
    /// 失敗文に書かないと、読み手は「この欄には入力できない」と読んで諦める。
    /// 走査から切り離した純粋関数(実デバイスが要ると、この枝はテストで一度も実行されない)
    static func setTextRefusedHint(tool: String, args: [String: Any], message: String) -> String {
        guard tool == "ft_type", args["ref"] != nil,
              message.contains("cannot type into the field that was tapped") else { return "" }
        return " Some widgets refuse ACTION_SET_TEXT outright (Android's NumberPicker among them)."
            + " Tap the field with ft_tap first, then call ft_type WITHOUT ref — that path types"
            + " into the focused field through the keyboard instead of setting its text."
    }

    /// セレクタ引数の両端の引用符を入口で剥がす(2026-08-12 の実アプリ監査)。
    /// DSL は Swift の文字列リテラルが引用符を剥がすが、MCP は生文字列で受けるので、
    /// `"*立川*"` は**引用符ごと完全一致ラベル**になり黙って一致しない(先頭が `"` なので
    /// `*` 記法も展開されない)。ft_batch は逆に引用符必須なので、跨いで使うと必ず混入する。
    /// 両端が同じ引用符で**中にその引用符が無い**ときだけ剥がす(`"a"||"b"` を壊さない)。
    /// 引用符そのものを含むラベルは `=` エスケープ(`="…"`)で従来どおり書ける
    static func strippingSelectorQuotes(_ args: [String: Any]) -> [String: Any] {
        var out = args
        for key in ["selector", "waitFor", "scrollFrame"] {
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

    /// **デバイス側に何秒かかったかを毎回返す**(2026-08-09)。読み手はこれが無いと、自分の
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

    func connectionLostHint(_ error: Error, args: [String: Any]) async -> String {
        // 差し替えドライバ(テスト)では走査しない = 実ポートを叩かない
        guard makeDriver == nil else { return "" }
        let key = Self.engineKey(args)
        guard let connection = connections[key], connection.hasPrefix("port") else { return "" }
        switch error {
        case DriverError.bridgeConnectionRefused:
            // 接続拒否は「誰も待受していない」が確定しているので、走査は今の状況を添えるだけ
            forgetConnection(key)
            let running = await BridgeDiscovery.scan(excluding: 0, repoRoot: try? RepoRoot.find())
            return Self.connectionLostMessage(connection: connection, running: running,
                                              sameDevice: Self.deviceName(forUDID: udids[key].flatMap { $0 }))
        case DriverError.bridgeUnreachable:
            // **タイムアウトは死を意味しない**(2026-08-12 の実アプリ監査で踏んだ): 素の文言は
            // 「未起動 / 遅い / suspend」の3択を並べるだけで、直後に ft_status を撃つと
            // 「そのポートにブリッジが無い」と一意に答えられた —— 判定材料はあるのに
            // 操作系が使っていなかった。**確かめてから断定する**: 走査してポートが消えていれば
            // 死亡と言い切り、生きていれば何も足さない(遅い/suspend の可能性が残るため、
            // 素の3択メッセージのままにする)
            guard let port = connectedPorts[key] else { return "" }
            let running = await BridgeDiscovery.scan(excluding: 0, repoRoot: try? RepoRoot.find())
            guard Self.bridgeVanished(port: port, running: running) else { return "" }
            forgetConnection(key)
            return Self.connectionLostMessage(connection: connection, running: running,
                                              sameDevice: Self.deviceName(forUDID: udids[key].flatMap { $0 }))
        default:
            return ""
        }
    }

    /// 死んだ接続の udid を、稼働中カタログの端末名へ引き直す(best-effort)。
    /// 失敗しても黙る —— `connectionLostMessage` の「同じ端末を先に」が効かず、
    /// 通し番号での畳み方に落ちるだけ
    static func deviceName(forUDID udid: String?) -> String? {
        guard let udid else { return nil }
        return (try? SimulatorCatalog.devices())?.first { $0.udid == udid }?.name
    }

    /// タイムアウトのとき「そのブリッジは消えた」と言い切ってよいか。**走査から切り離した
    /// 純粋関数** —— 実ブリッジが要ると、この枝はテストで一度も実行されず、判定を壊しても
    /// 素通しする(`reconcilePort` が 2026-08-09 の変異テストで実際に踏んだのと同じ型)
    static func bridgeVanished(port: UInt16, running: [BridgeDiscovery.Found]) -> Bool {
        !running.contains { $0.port == port }
    }

    /// 掴んでいたドライバは死んでいる。次の呼び出しで解決し直させる
    private func forgetConnection(_ key: String) {
        drivers[key] = nil
        connections[key] = nil
        connectedPorts[key] = nil
    }

    /// 名指しする上限本数(2026-08-12): 実測で17本が1行に並び、読み手が要るのは
    /// 「今この端末で使えるポート」だけだった。残りは件数へ畳む(runningBridgesSummary)
    static let connectionLostShownCap = 3

    static func connectionLostMessage(connection: String, running: [BridgeDiscovery.Found],
                                      sameDevice: String? = nil) -> String {
        let now = running.isEmpty
            ? "no iOS bridge is running now"
            : "running bridges now: \(Self.runningBridgesSummary(running, sameDevice: sameDevice))"
        return "\nThe XCUITest runner behind \(connection) exited — a second runner on the same"
            + " simulator kicks out the first, and the app under test crashing takes an in-app"
            + " bridge with it. \(now). Start one with `ftester bridge up`; the session does not"
            + " survive, so ft_launch your app again."
    }

    /// **同じ端末を先に、残りは件数へ畳む**(純粋関数)。`sameDevice` が分かるとき(死んだ接続の
    /// udid をカタログへ引き直せたとき)はそれを優先して並べる —— `connection`(port/udid)と
    /// `Found`(端末名)は互いに引けないことが多いので、分からないときは並び替えず先頭
    /// `connectionLostShownCap` 本だけを名指しする(嘘のグルーピングは作らない。
    /// 「on other devices」も sameDevice が分かっているときだけ言う)
    static func runningBridgesSummary(_ running: [BridgeDiscovery.Found],
                                      sameDevice: String?) -> String {
        let sorted = running.sorted { $0.port < $1.port }
        let ordered: [BridgeDiscovery.Found]
        if let sameDevice {
            ordered = sorted.filter { $0.device == sameDevice } + sorted.filter { $0.device != sameDevice }
        } else {
            ordered = sorted
        }
        let shown = ordered.prefix(connectionLostShownCap)
        let remaining = ordered.count - shown.count
        let suffix = remaining <= 0 ? ""
            : sameDevice != nil ? " (+\(remaining) more on other devices)" : " (+\(remaining) more)"
        return shown.map(\.label).joined(separator: ", ") + suffix
    }

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
                + " / session: \(session)\(foreground)", args: args))

        case "ft_list_devices":
            let listProject = args["project"] as? String
            let listProfile = args["profile"] as? String
            let listPlatform = args["platform"] as? String
            // **鍵は見出しが実際に出る回だけ消費する**(onceNonEmpty と同じ理由): プロファイルが
            // 解決できた回や platform が不正な回で消費すると、本当の初出が短縮形になる
            var abbreviatedFallback = false
            if DeviceInventory.isSupportedPlatform(listPlatform),
               case .unavailable = DeviceInventory.resolveMachine(project: listProject,
                                                                  profile: listProfile) {
                abbreviatedFallback = !firstTime("machineProfileFallback")
            }
            return text(await DeviceInventory.devicesText(
                project: listProject, profile: listProfile, platform: listPlatform,
                abbreviatedFallbackHeader: abbreviatedFallback))

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
            let udid = try udids[Self.engineKey(args)].flatMap { $0 }
                ?? SimulatorAppCatalog.bootedSimulatorUDID(named: deviceName)
            return text(DeviceInventory.appsText(apps: try SimulatorAppCatalog.apps(udid: udid),
                                                 includeSystem: includeSystem, filter: appsFilter))

        case "ft_logs":
            let logBundleID = args["bundleId"] as? String ?? lastLaunchedBundleID(args)
            return text(await CrashLogs.text(
                platform: Self.platformName(args),
                bundleID: logBundleID,
                serial: args["serial"] as? String,
                withinSeconds: args["sinceSeconds"] as? Int ?? 300,
                maxLines: args["lines"] as? Int ?? 100,
                crashOnly: (args["all"] as? Bool) != true))

        case "ft_install":
            guard let packagePath = args["packagePath"] as? String else {
                throw MCPError("packagePath is required")
            }
            try await driver(args).install(packagePath: packagePath)
            return text("Installed: \(packagePath)")

        case "ft_launch":
            guard let bundleID = args["bundleId"] as? String else { throw MCPError("bundleId is required") }
            let launchDriver = try await driver(args)
            // **撃つ前に弾く**(ランナー死の予防。installedState のコメント参照)
            if await installedState(bundleID: bundleID, driver: launchDriver) == false {
                throw MCPError(Self.notInstalledMessage(bundleID: bundleID))
            }
            try await launchDriver.launch(bundleID: bundleID)
            // 以後の snapshot は「これの木か」を突き合わせられる(switchedAppNote)
            launchedBundleIDs[Self.engineKey(args)] = bundleID
            // 下書きの起点(F-3 の既定範囲は「直近の ft_launch 以降」)。@TestClass(app:) にも使う
            interactions.record(InteractionLog.Entry(
                step: nil, unresolved: nil, isLaunch: true, bundleID: bundleID,
                platform: Self.platformName(args), summary: "launch \(bundleID)"))
            return text("Launched: \(bundleID)")

        case "ft_open_url":
            guard let url = args["url"] as? String else { throw MCPError("url is required") }
            let openURLDriver = try await driver(args)
            let openURLBundleID = args["bundleId"] as? String ?? launchedBundleIDs[Self.engineKey(args)]
            // installedState は撃たない: simctl openurl/devicectl openURL・am start は OS の URL
            // ルーティングで、installedState が守っている XCUIApplication.launch() のランナー死
            // (ft_launch のコメント参照)とは経路が別
            try await openURLDriver.openURL(url, bundleID: openURLBundleID)
            var openStep = FlowStep(action: "openURL")
            openStep.text = url
            interactions.record(InteractionLog.Entry(step: openStep, unresolved: nil,
                                                     summary: "openURL \"\(url)\""))
            return text("Delivered \(url)"
                + (openURLBundleID.map { " to \($0)" } ?? "") + "."
                + " Delivery is asynchronous (the app has to receive and handle it) — if a"
                + " ft_snapshot right after still shows the old screen, wait and snapshot again")

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
                                                    first: snapshot, seconds: seconds)
                // **撃ち直しが起きたときだけ adoptSnapshot を通す**: 撃ち直しが無ければ
                // `waited.snapshot` は `snapshot`(既にセッション ref)そのものなので、
                // native 前提の adoptSnapshot に通すと同じ木を「別世代」と誤認する
                // (base 込みの ref を native ref と取り違えて比較するため)
                snapshot = waited.refetched ? adoptSnapshot(waited.snapshot, args: args) : waited.snapshot
                if !waited.found {
                    waitNote = "waitFor \"\(waitFor)\" did not appear within \(seconds)s"
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
                              // ヒントなので、的の外れた推測を並べて紛らわせない(2026-08-10)
                              + Self.similarLabelsHint(waitFor, in: snapshot))) + "\n"
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
            if let ref = targetRef {
                let verified = try await verifiedRef(ref, driver: typeDriver, args: args)
                targetRef = verified.ref
                note = verified.note
                priorValue = lastSnapshots[Self.engineKey(args)]?
                    .elements.first { $0.ref == verified.ref }?.value
            }
            if let content, !content.isEmpty {
                // targetRef はセッション ref。ブリッジへ渡す直前にだけ native へ戻す
                try await typeDriver.type(ref: targetRef.map { nativeRef($0, args: args) }, text: content)
                // **ref を渡したときだけ読み返しで検証される**。iOS の XCUITest ランナーは
                // ref から対象を引けたときだけ TypeReadback の resend/deleteExcess を回し、
                // 引けない(= ref なし)ときは無検証の `typeText` へ落ちて OK を返す。
                // Android は焦点ノードを読み返すので ref なしでも検証される
                if targetRef == nil, !(typeDriver is AndroidDriver) {
                    // **注意書きで済ませず、ここで確かめる**: iOS の XCUITest ランナーは ref から
                    // 対象を引けたときだけ TypeReadback を回すので、ref なしは無検証で OK が返る。
                    // 木は `focused` を持っているのだから、撮り直して**どこへ入ったか**を名指しできる
                    // (Android は焦点ノードを読み返すのでこの1枚は払わない)。
                    // **生読み(adoptSnapshot を通さない)**: この読みは入力という操作の**後**に
                    // 撮っているので、freshSnapshot 経由だと lastSnapshots[key] を上書きし、
                    // 続く snapshotAfterBody の settle-lite 基準(操作前の木のつもり)が
                    // 操作後の木になってしまい「変化なし」と誤報する(2026-08-10)
                    let rawAfterType = try? await typeDriver.snapshot(
                        bypassingCache: typeDriver.supportsCacheBypass)
                    note += await Self.typedIntoNote(driver: typeDriver, expected: content,
                                                     snapshot: rawAfterType)
                }
                if let prior = priorValue, !prior.isEmpty {
                    note += " (the field already held \"\(SnapshotRenderer.truncate(prior, 30))\";"
                        + " ft_type appends, so it now reads"
                        + " \"\(SnapshotRenderer.truncate(prior + content, 60))\"."
                        + " Call ft_clear_input first if you meant to replace it)"
                }
            } else if let ref = targetRef {
                // 入力せず Enter だけ撃つときも、対象が指定されていればフォーカスを立ててから。
                // **タップの直後に撃たない**(下の awaitFocus): 直前に別の欄へ入力していると
                // フォーカスの移動が間に合わず、Enter が**前の欄**へ飛んで黙って何も起きない
                // (2026-08-06 に Android で観測。ime カウンタが増えなかった)
                try await typeDriver.tap(ref: nativeRef(ref, args: args))
                note += await awaitFocus(ref: ref, driver: typeDriver, args: args)
            }
            // 入力欄も**セレクタで再現できないと書けない**(E)。ref を渡さない
            // (フォーカス任せの)呼び方では対象が確定しないので黙る
            let typedSelector = targetRef.map { reproductionNote(resolvedRef: $0, args: args) } ?? ""
            if let content, !content.isEmpty {
                recordInteraction(action: "type", resolvedRef: targetRef, args: args, text: content)
            }
            if wantsEnter { recordInteraction(action: "pressEnter", resolvedRef: nil, args: args) }
            guard wantsEnter else {
                return text("Typed: \"\(content ?? "")\"\(note)\(typedSelector)"
                    + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(args)))
            }
            try await typeDriver.pressEnter()
            return text((content.map { "Typed: \"\($0)\" and pressed Enter" } ?? "Pressed Enter")
                + note + typedSelector + waitForWithoutSnapshotAfterNote(args)
                + (await snapshotAfterBody(args)))

        case "ft_swipe":
            guard let direction = FTSwipeDirection(rawValue: args["direction"] as? String ?? "") else {
                throw MCPError("direction must be one of up/down/left/right")
            }
            try await driver(args).swipe(direction)
            recordInteraction(action: "swipe", resolvedRef: nil, args: args,
                              direction: direction.rawValue)
            // **「動いた」と断言しない**(back と同じ理由。2026-08-06)。スワイプは端に着いていれば
            // 1px も動かないし、スクロールできない画面では何も起きない
            return text("swipe \(direction.rawValue) sent."
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
            let settled = try await driver(args).rotate(to: orientation)
            var rotateStep = FlowStep(action: "rotateTo")
            rotateStep.direction = settled.rawValue
            interactions.record(InteractionLog.Entry(step: rotateStep, unresolved: nil,
                                                     summary: "rotateTo .\(settled.rawValue)"))
            // **回転はツリーの座標系ごと変える**ので、覚えている木は必ず捨てる
            // (古い ref を残すと、次のタップが回転前の座標で撃たれる)
            let rotated = try await freshSnapshot(try await driver(args), args: args)
            recordSnapshot(rotated, Self.platformName(args), args)
            return text("Rotated to \(settled.rawValue). The frames below are in the new"
                + " coordinate system — refs taken before the rotation are gone.\n\n"
                + (await snapshotBody(rotated, driver: try await driver(args), args: args)))

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
            let beforeBackFingerprint = target == "back"
                ? lastSnapshots[Self.engineKey(args)].map(Self.treeFingerprint) : nil
            switch target {
            case "back": try await navigation.back()
            case "home": try await navigation.home()
            case "appSwitcher": try await navigation.openAppSwitcher()
            default: throw MCPError("target must be one of back/home/appSwitcher")
            }
            recordInteraction(action: target, resolvedRef: nil, args: args)
            // **snapshotAfter を渡されたら木はそちらが撮る**。ここで撮り直すと同じ木を2回
            // 取りに行くだけになるので、**先に本文を組み立ててから**その結果で無効を判定する
            // (`snapshotAfterBody` は adoptSnapshot 経由で `lastSnapshots` を更新するので、
            // 撮った木は指紋で読み返せる)。無効の注記自体は snapshotAfter の有無で消さない ——
            // 木が付いていても「前と同一」は読み手には分からない
            let afterBody = wantsSnapshotAfter ? await snapshotAfterBody(args) : ""
            var backIneffectiveNote = ""
            if let before = beforeBackFingerprint {
                // **1回の撮り直しでは判定しない**(ポーリング): アニメーション途中の木を
                // 「変わっていない」と誤読しないため。取得に失敗したら黙って諦める
                // (成功した観測が1つも無ければ「変わっていない」と断言する材料が無い)
                var sawChange = false
                var sawAnySnapshot = false
                if wantsSnapshotAfter {
                    // 撮り直しは snapshotAfterBody が済ませている(settle-lite も込み)
                    if let after = lastSnapshots[Self.engineKey(args)] {
                        sawAnySnapshot = true
                        sawChange = Self.treeFingerprint(after) != before
                    }
                } else {
                    for _ in 0..<4 {
                        try? await Task.sleep(for: .seconds(0.3))
                        guard let after = try? await freshSnapshot(navigation, args: args) else { continue }
                        sawAnySnapshot = true
                        if Self.treeFingerprint(after) != before { sawChange = true; break }
                    }
                }
                if sawAnySnapshot, !sawChange {
                    backIneffectiveNote = ". note: the tree is identical to the one before back —"
                        + " back appears to have had no effect on this screen (apps drawing their"
                        + " own back button often ignore the system back); tap the app's own back"
                        + " control, or send back again"
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
                + Self.homeScreenReadNote(target: target, engine: engines[Self.engineKey(args)])
                + waitForWithoutSnapshotAfterNote(args) + afterBody)

        case "ft_clear_app_data":
            guard let bundleID = args["bundleId"] as? String else { throw MCPError("bundleId is required") }
            try await driver(args).clearAppData(bundleID: bundleID)
            return text("Cleared the data of \(bundleID). The app is stopped — ft_launch to continue")

        case "ft_clear_input":
            // ref 省略 = フォーカス中の欄(DSL の clearInput() と同じ)
            let clearDriver = try await driver(args)
            var clearRef = args["ref"] as? Int
            var clearNote = ""
            if let ref = clearRef {
                let verified = try await verifiedRef(ref, driver: clearDriver, args: args)
                clearRef = verified.ref
                clearNote = verified.note
            }
            // clearRef はセッション ref。ブリッジへ渡す直前にだけ native へ戻す
            try await clearDriver.clearInput(ref: clearRef.map { nativeRef($0, args: args) })
            recordInteraction(action: "clearInput", resolvedRef: clearRef, args: args)
            return text("cleared\(clearNote)"
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
                // keyboardFrame は verifiedElement が撮り直した木(lastSnapshots に反映済み)から採る
                doubleTapNote = RefGuard.preTapWarnings(
                    element, keyboardFrame: lastSnapshots[Self.engineKey(args)]?.keyboardFrame)
                    + RefGuard.overlapWarning(found: element, in: lastSnapshots[Self.engineKey(args)]?
                        .elements ?? [], screen: lastSnapshots[Self.engineKey(args)]?.screen
                        ?? FTRect(x: 0, y: 0, width: 0, height: 0)) + labelNote
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
            // **掴む側を ref で指せる**(2026-08-09): 半開きのシートを広げる操作は
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
                // ft_tap / ft_press / ft_drag と同じく座標を受ける
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

        case "ft_press":
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
            // 長押しする操作(ピンを落とす・住所を出す)が一切書けない状態だった(2026-08-07)
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
            // **限界**: 木の変化が画素に出ない変化(a11y のみ)は偽陽性になり得るが、指紋は
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
            let vision = FMDoctor.visionReport
            return text((fm.available ? "✅ " : "❌ ") + fm.detail
                + (fm.available ? "" : "\n   " + FMDoctor.unavailableImpact)
                + "\n" + (vision.available ? "✅ " : "⚠️ ") + vision.detail)

        default:
            throw MCPError("unknown tool: \(tool)")
        }
    }

    func text(_ string: String) -> [[String: Any]] {
        [["type": "text", "text": string]]
    }

    /// 探索の操作列から Swift シナリオの**下書き**を組む(F)。
    ///
    /// **ファイルには書かない**(F-2): 置き場所と命名はスキルの仕事で、MCP は文字列を返すだけ。
    /// 生成そのものは `ScenarioCodeGen.render` に委ねる —— 記録機能(`ftester api gen-scenario`)と
    /// 同じ生成器を通すので、CAE の形も DSL の綴りも1箇所で決まる(2つ目の実装を作らない)。
    ///
    /// **アサーションは推測で作らない**(F-5): expectation は空の骨格で出し、
    /// ft_dry_run の「アサーションの無い expectation ブロック」検出に埋めさせる。
    /// **セレクタを解決できなかった手は TODO で残す**(F-4) —— 消すと手順と食い違う
    func draftScenario(_ args: [String: Any]) -> String {
        let recorded = (args["all"] as? Bool == true)
            ? interactions.entries : interactions.sinceLastLaunch
        guard !recorded.isEmpty else {
            return "No interactions recorded yet. Drive the app with ft_launch / ft_tap / ft_type"
                + " / ft_scroll_to first — this tool turns that sequence into a scenario draft."
        }
        // **刈り込みは下書きの質そのもの**(2026-08-10): 記録は「やったこと」であって
        // 「意図」ではないので、行き止まりのタップや試し打ちがそのまま載る。自動では
        // 本筋と回り道を見分けられない(どちらも成功した操作)ので、**番号を見せて選ばせる**
        let (scope, droppedCount, ignoredNumbers) = InteractionLog.prune(
            recorded, lastN: args["lastN"] as? Int,
            drop: (args["drop"] as? [Any])?.compactMap { $0 as? Int } ?? [])
        guard !scope.isEmpty else {
            return "Every recorded step was pruned away (\(recorded.count) recorded,"
                + " \(droppedCount) dropped). Call ft_draft_scenario again with a smaller"
                + " drop list — the numbering is 1-based over the steps shown in the listing."
        }
        let target = interactions.target(in: scope)
        let unresolved = scope.compactMap(\.unresolved)
        let steps = scope.compactMap(\.step)
        // **解決できなかった手はその場に残す**(2026-08-10)。まとめて先頭へ出すと action の
        // 並びからその手が消え、生成コードが実際の手順と食い違う(33 手の下書きで実際に起きた:
        // チェックアウト→住所画面へ移る手が抜けたまま #btn_add_address を叩く形になった)
        var notesBeforeStep: [Int: [String]] = [:]
        // 一覧の番号(1 起点・刈り込み後)→ steps の位置。scenes: もこの対応で読む
        var stepIndexForListing: [Int] = []
        var resolved = 0
        for (position, entry) in scope.enumerated() {
            stepIndexForListing.append(resolved)
            if let described = entry.unresolved {
                notesBeforeStep[resolved, default: []].append(
                    "TODO: no stable selector — \(described)"
                        + " (step \(position + 1) of the exploration)")
            } else if entry.step != nil {
                resolved += 1
            }
        }
        let sceneBreaks = ((args["scenes"] as? [Any])?.compactMap { $0 as? Int } ?? [])
            .compactMap { number -> Int? in
                guard number >= 1, number <= stepIndexForListing.count else { return nil }
                return stepIndexForListing[number - 1]
            }
        let flow = Flow(name: args["title"] as? String ?? "explored with ft_* (draft)",
                        app: target.app, platform: target.platform,
                        goal: nil, generatedBy: Self.draftGeneratedBy, steps: steps)
        let className = (args["className"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "DraftedScenario"
        let code = ScenarioCodeGen.render(flow: flow, className: className,
                                          generatedBy: Self.draftGeneratedBy,
                                          emptyExpectation: true,
                                          notesBeforeStep: notesBeforeStep,
                                          sceneBreaks: sceneBreaks)
        var header = "Draft for \(target.app.isEmpty ? "(unknown app)" : target.app)"
            + " from \(scope.count) recorded interaction(s)"
            + (unresolved.isEmpty ? "" : ", \(unresolved.count) of which have no stable selector")
            + ".\nWrite it under TestProjects/<project>/scenarios/ and run ft_dry_run."
            + " **The expectation block is intentionally empty** — dry-run will report it,"
            + " and that is the signal to fill in what this scenario proves.\n"
        if interactions.droppedFromFront > 0 {
            header += "note: the \(interactions.droppedFromFront) oldest interaction(s) were"
                + " dropped from the log (it keeps the most recent"
                + " \(InteractionLog.maximumEntries)).\n"
        }
        if droppedCount > 0 {
            header += "note: \(droppedCount) step(s) were pruned at your request.\n"
        }
        if !ignoredNumbers.isEmpty {
            // **黙って無視しない**: 番号を1つ外しただけで別の手が落ちるので、
            // 「効かなかった指定がある」ことに気付けないと誤った下書きを持ち帰る
            header += "⚠️ drop \(ignoredNumbers.map(String.init).joined(separator: ", "))"
                + " is out of range (1…\(recorded.count)) and was ignored.\n"
        }
        return header + Self.pruningListing(scope) + "\n" + code
    }

    /// 下書きに書かれる形。`FTSelector` を通して往復させ、**ScenarioCodeGen が出す綴りに揃える**
    /// (あちらも `serialize` で書き戻すので、ここを通せば注記とコードが必ず一致する)
    static func asWritten(_ selector: String) -> String {
        let parsed = FTSelector.parse(selector)
        let serialized = FTSelector.serialize(primary: parsed.primary, fallbacks: parsed.fallbacks)
        return serialized.isEmpty ? selector : serialized
    }

    /// 下書きの行末に残す但し書き。安定なセレクタには**付けない** ——
    /// 全行にコメントが付くと読み飛ばされ、本当に危ない行が埋もれる
    static func indexedSelectorNote(_ durability: Durability) -> String? {
        durability == .indexed
            ? "index-based selector — breaks if the number of same-type siblings changes"
            : nil
    }

    /// 下書きに入った手の番号付き一覧。**これを見て `drop:` を組む**ので、番号は
    /// 刈り込み後の並び(次の呼び出しで同じ番号が同じ手を指す)
    static func pruningListing(_ scope: [InteractionLog.Entry]) -> String {
        let rows = scope.enumerated().map { index, entry -> String in
            "  \(index + 1). \(entry.summary.isEmpty ? "(unnamed step)" : entry.summary)"
        }
        return "Steps in this draft — re-run with drop: [n, …] to remove the dead ends,"
            + " lastN: <k> to keep only the last k, or scenes: [n, …] to cut it into scenes"
            + " at those steps:\n" + rows.joined(separator: "\n") + "\n"
    }

    static let draftGeneratedBy = "ftester MCP exploration (ft_draft_scenario)"

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
            // **セレクタ自体は毎回出すが、但し書きは初回だけ満額**(2026-08-10): id の薄いアプリ
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
    }

    /// 座標で撃ったときの断り(E-4)。**推測のセレクタを出さない** —— 座標には
    /// 「その点に何があったか」以上の根拠が無い
    static let coordinateReproductionNote =
        " (coordinates cannot be reproduced by selector — a scenario written from this"
        + " will break as soon as the layout moves)"
    /// `once` の短縮形(セッション内2回目以降)。**理由の再掲は落とす** —— 1度言えば足りる
    static let coordinateReproductionNoteShort =
        " (coordinates cannot be reproduced by selector — see the first note)"

    /// 操作を1手ぶん記録する(F)。**E と同じ `SelectorNaming` でセレクタを決める** ——
    /// 戻り値に出したセレクタと、下書きに書かれるセレクタが食い違わないようにするため。
    ///
    /// セレクタを解決できなかった手も**捨てずに**残す(`unresolved`)。落とすと、
    /// 出来上がったシナリオが実際の手順と食い違う(F-4)
    func recordInteraction(action: String, resolvedRef: Int?, args: [String: Any],
                           text: String? = nil, direction: String? = nil,
                           coordinate: (x: Double, y: Double)? = nil,
                           duration: Double? = nil, scale: Double? = nil) {
        var selector: String?
        var durability: Durability = .stable
        var described = "\(action)"
        if let resolvedRef,
           let snapshot = lastSnapshots[Self.engineKey(args)],
           let element = snapshot.elements.first(where: { $0.ref == resolvedRef }) {
            let graded = Self.SelectorNaming(snapshot).graded(for: element, in: snapshot)
            selector = graded?.selector
            durability = graded?.durability ?? .stable
            described = "\(action) ref \(resolvedRef) — \(RefGuard.describe(element))"
        } else if let coordinate {
            described = "\(action) at (\(coordinate.x), \(coordinate.y))"
        }
        // ロケータ不要の手(swipe / フォーカス任せの type / 全画面ピンチ)はセレクタが無くても行にできる
        let needsLocator = !["swipe", "type", "pressEnter", "back", "home", "appSwitcher",
                             "pinchOut", "pinchIn"]
            .contains(action) || (resolvedRef != nil || coordinate != nil)
        if selector == nil, needsLocator, action != "swipe" {
            interactions.record(InteractionLog.Entry(step: nil, unresolved: described,
                                                     summary: "\(described) [no selector]"))
            return
        }
        var step = FlowStep(action: action)
        if let selector { step.locator = FTSelector.parse(selector).primary }
        step.text = text
        step.direction = direction
        // 実際に撃った値を残す(落とすと draft が既定値で再生成され、3秒の長押しが
        // 1秒に化けたシナリオが黙って出る)
        step.duration = duration
        step.scale = scale
        // **下書きの本文にも格付けを残す**(2026-08-10 の掃討): 注記と ft_tap の戻り値だけに
        // 印を出しても、その場で読まれなければ意味が無い —— 添字付きのセレクタは
        // シナリオに書かれた後で静かに壊れるので、コードの側に理由を残す。
        // **セッション内2回目以降は短縮形**(once)にする — 同じ探索で添字セレクタが何度も
        // 出る画面(一覧行の連打など)では、同じ長文がそのぶん下書きに繰り返される
        step.note = selector == nil ? nil : Self.indexedSelectorNote(durability).map { full in
            once("indexedSelectorNote", full: full, short: "index-based selector (see the first note)")
        }
        let detail = [selector.map { "\"\($0)\"" }, text.map { "\"\($0)\"" }, direction]
            .compactMap { $0 }.joined(separator: " ")
        interactions.record(InteractionLog.Entry(
            step: step, unresolved: nil,
            summary: detail.isEmpty ? action : "\(action) \(detail)"))
    }

    /// 溜まっているプロファイル警告を先頭に付けて1度だけ吐き出す
    func withPendingWarnings(_ body: String, args: [String: Any]) -> String {
        let key = Self.engineKey(args)
        guard let warnings = pendingWarnings.removeValue(forKey: key), !warnings.isEmpty
        else { return body }
        return warnings.joined(separator: "\n") + "\n" + body
    }

    /// 繰り返し出る注記を初回だけ満額にする(F-6・2026-08-10)。**通すのは dispatch 経由の
    /// 応答組み立てだけ**にすること — static 関数そのものは short/full を知らないまま変えない
    /// (テストの独立性を保つ: 同じ static 関数を単体で呼ぶテストは常に満額の文を見る)
    func once(_ key: String, full: String, short: String) -> String {
        explainedNotes.insert(key).inserted ? full : short
    }

    /// 「この鍵は初出か」だけを返す `once` の同型。本文の2形を持たない注記
    /// (見出しそのものを短縮する類)が使う。**鍵の名前空間は `once` と共有**
    func firstTime(_ key: String) -> Bool {
        explainedNotes.insert(key).inserted
    }

    /// `once` を「注記が空のときはキーを消費しない」形にした版。full が空の画面で先に呼ぶと、
    /// その画面には何も出ないのにキーだけ記録され、次に本当に出た画面(初出のはず)が
    /// 短縮形になってしまう。truncatedLabelNote/unlabeledClickablesNote/ambiguousLabelsNote が共有する
    func onceNonEmpty(_ key: String, full: String, short: String) -> String {
        guard !full.isEmpty else { return "" }
        return once(key, full: full, short: short)
    }

    /// 撮ったスナップショットの `#id` をプロジェクトの台帳へ足す(ft_dry_run が綴り誤りの照合に使う。
    /// SelectorInventory 参照)。**best-effort** —— プロジェクトを特定できない・書けないなら黙って諦める
    /// (探索の邪魔をしない。台帳が薄いと dry-run が黙るだけで、誤検知にはならない)
    static func recordSelectors(_ snapshot: SnapshotResponse, _ platform: String,
                                _ args: [String: Any]) {
        guard let project = try? ScenarioHost.project(named: args["project"] as? String) else { return }
        SelectorInventory.record(ids: SelectorInventory.ids(in: snapshot), platform: platform,
                                 at: SelectorInventory.url(projectRoot: project.rootURL))
    }

    /// stdout は JSON-RPC 専用(混ぜるとクライアントのパースが壊れる)。診断は必ず stderr へ
    static func logStderr(_ message: String) {
        FileHandle.standardError.write(Data(("[ftester-mcp] " + message + "\n").utf8))
    }

    /// シナリオ一覧(自動ビルド込み。コンパイルエラーはそのまま返す=エージェントが直せる)
    private func listScenarios(_ args: [String: Any]) throws -> [[String: Any]] {
        let project = try ScenarioHost.project(named: args["project"] as? String)
        if !(args["skipBuild"] as? Bool ?? false) {
            try ScenarioHost.build(project: project)
        }
        let scenarios = try ScenarioHost.list(project: project)
        let lines = scenarios.map { info in
            "\(info.id)"
                + (info.title.isEmpty ? "" : " — \(info.title)")
                + " (\(info.platform ?? "ios/android"), app: \(info.app))"
                + (info.deleted ? " [deleted @Deleted — excluded from bulk runs]" : "")
        }
        return text(lines.isEmpty
                    ? "No scenarios (add a @TestClass under TestProjects/\(project.name)/scenarios/)"
                    : "Project: \(project.name)\n" + lines.joined(separator: "\n"))
    }

    private func listProjects() throws -> [[String: Any]] {
        guard let root = ScenarioHost.packageRoot() else {
            throw MCPError("Package.swift not found (run this inside the repository)")
        }
        let projects = ProjectStore.all(repoRoot: root)
        guard !projects.isEmpty else {
            return text("No projects (create one with: ftester project create <name>)")
        }
        let machineName = LocalConfig.currentMachineName() ?? "unregistered"
        var lines = ["This machine: \(machineName)"]
        for project in projects {
            let runs = ProfileResolver.runProfileNames(project: project)
            let machines = ProfileResolver.machineNames(project: project)
            lines.append("\(project.name)"
                + " — run profiles: \(runs.isEmpty ? "none" : runs.joined(separator: ", "))"
                + " / machines: \(machines.isEmpty ? "none" : machines.joined(separator: ", "))")
        }
        return text(lines.joined(separator: "\n"))
    }

    /// dry-run(**デバイス不要**)。コンパイルの次・デバイス実行の前に挟む検証で、デバイスを
    /// 使わずにセレクタ構文エラー・到達しない scene・アサーション0の expectation を落とす。
    /// デバイスに触れないのでロケータが実在するかは分からない(それは ft_run_scenario の仕事)
    private func dryRun(_ args: [String: Any]) async throws -> [[String: Any]] {
        guard let id = args["id"] as? String else { throw MCPError("id is required") }
        let project = try ScenarioHost.project(named: args["project"] as? String)
        if !(args["skipBuild"] as? Bool ?? false) {
            try ScenarioHost.build(project: project)
        }
        let all = try ScenarioHost.list(project: project)
        guard let info = all.first(where: { $0.id == id })
            ?? all.first(where: { $0.id.hasPrefix(id + ".") }) else {
            throw MCPError("scenario not found: \(id) (available: \(all.map(\.id).joined(separator: ", ")))")
        }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftester-mcp-dryrun-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var lines: [String] = []
        // dry-run は NullDriver 固定なので接続情報は使われない(platform だけが ios { } / android { } を分ける)
        let passed = await ScenarioHost.run(
            project: project, scenarioID: info.id,
            connection: DriverConnection(platform: info.platform ?? "ios"),
            // **`enabled: false`(= 子へ --no-fm)**。heal だけ切ると失敗のたびに triage が走り、
            // デバイスも画面も無いのに FM の直列化待ちを数秒払う(2026-08-12 実測)
            fm: FMConfig(enabled: false, heal: false), reportDir: tempDir.path,
            dryRun: true) { event in
                lines.append(contentsOf: ScenarioLogFormatter.lines(for: event))
            }
        // レポートは一時ディレクトリに書かれ、この関数を抜けると消える。
        // 案内すると開けないパスを渡すことになるので落とす(dry-run に証跡は要らない)
        lines.removeAll { $0.contains("→ report:") }
        lines.append(passed
            ? "✅ dry-run passed (no device was touched — selectors were only syntax-checked)"
            : "❌ dry-run failed")
        return text(lines.joined(separator: "\n"))
    }

    /// シナリオ実行(自動ビルド込み)。サブプロセス(ftester-scenarios)に委譲する
    private func runScenario(_ args: [String: Any]) async throws -> [[String: Any]] {
        guard let id = args["id"] as? String else { throw MCPError("id is required") }
        let project = try ScenarioHost.project(named: args["project"] as? String)
        if !(args["skipBuild"] as? Bool ?? false) {
            try ScenarioHost.build(project: project)
        }
        let all = try ScenarioHost.list(project: project)
        guard let info = all.first(where: { $0.id == id })
            ?? all.first(where: { $0.id.hasPrefix(id + ".") }) else {
            throw MCPError("scenario not found: \(id) (available: \(all.map(\.id).joined(separator: ", ")))")
        }

        var fm = FMConfig(heal: args["heal"] as? Bool ?? false)
        var reportDir = project.reportsDir.path
        var defaultTimeout: Double?
        var connection: DriverConnection
        var prologue: [String] = []

        if let profileName = args["profile"] as? String {
            // 接続先はシナリオの platform に合う先頭デバイス。プロファイル自身の machine 指定が最優先
            let (_, resolved, target) = try await resolveProfileTarget(
                project: project, profileName: profileName,
                platformArg: info.platform, prologue: &prologue)
            fm = resolved.fm
            // heal 引数は master(fm.enabled)が有効な場合のみ ON にする override(未指定は resolved のまま)
            if let healArg = args["heal"] as? Bool {
                fm.heal = healArg && fm.enabled
            }
            reportDir = resolved.reportDir.path
            defaultTimeout = resolved.defaultTimeout
            switch target {
            case .ios(let provisioned, let iosApp):
                connection = ProfileWorkerFactory.iosConnection(device: provisioned, iosApp: iosApp)
            case .android(let serial, let deviceName):
                connection = DriverConnection(platform: "android", serial: serial, deviceName: deviceName)
            }
        } else {
            let platform = info.platform ?? (args["platform"] as? String ?? "ios")
            // **宛先の決め方は探索系(driver(_:))と同じにする**。片方だけ賢いと
            // 「ft_snapshot は繋がるのに ft_run_scenario だけ既定ポートで落ちる」になる
            connection = DriverConnection(
                platform: platform,
                port: platform == "ios"
                    ? try await Self.resolveIOSPort(explicit: (args["port"] as? Int).map(UInt16.init))
                    : nil,
                serial: platform == "android"
                    ? try Self.resolveAndroidSerial(explicit: args["serial"] as? String)
                    : nil)
        }

        var lines: [String] = prologue
        _ = await ScenarioHost.run(project: project, scenarioID: info.id,
                                   connection: connection,
                                   fm: fm, reportDir: reportDir,
                                   defaultTimeout: defaultTimeout) { event in
            lines.append(contentsOf: ScenarioLogFormatter.lines(for: event))
        }
        return text(lines.joined(separator: "\n"))
    }

    /// DSL コマンド索引(`ftester api dsl-commands` と同じ出典 = Sources/FTDSL/CommandIndex.swift)。
    /// **既定は名前と署名だけ**にする: 全 136 件の要約まで返すと 15KB 級になり、
    /// 「どのコマンドがあるか」を知りたいだけの呼び出しでコンテキストを食う。
    /// 要約が要るときは name / category で絞る
    private func dslCommands(_ args: [String: Any]) -> [[String: Any]] {
        let category = args["category"] as? String
        let name = args["name"] as? String
        var commands = DSLCommandIndex.all
        if let category { commands = commands.filter { $0.category == category } }
        if let name { commands = commands.filter { $0.name == name } }
        guard !commands.isEmpty else {
            let categories = Set(DSLCommandIndex.all.map(\.category)).sorted()
            return text("no command matched. Categories: \(categories.joined(separator: ", "))."
                + " A name that is not in this index does not exist (it will not compile)")
        }
        let detailed = name != nil || category != nil
        let lines = commands.map { command in
            detailed ? "\(command.signature) — \(command.summary)" : command.signature
        }
        let header = detailed
            ? "\(commands.count) command(s)"
            : "\(commands.count) commands (pass category: or name: for summaries)."
                + " Chain-only: \(DSLCommandIndex.chainOnlyNames.sorted().joined(separator: ", "))"
        return text(([header] + lines).joined(separator: "\n"))
    }
}
