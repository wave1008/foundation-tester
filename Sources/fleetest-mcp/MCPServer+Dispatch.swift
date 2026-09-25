// MCPServer+Dispatch.swift
// ツールの入口(call/dispatch)と共有ヘルパー。各ツールの実装は MCPServer+{Session,Screen,Gestures}Tools.swift 等、
// 本体は MCPServer.swift(instance 状態はそちらに置く)

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
        // **アラートの前面では断る**(`verifiedRef` と同じ門。ここを通る double_tap / drag / pinch だけが
        // 門の外に居て、XCTest が「許可しない」を押して done と返していた —— 実機 SE3 で実測)
        let key = Self.engineKey(args)
        var gateNote = ""
        if launchedBundleIDs[key] != "com.apple.springboard",
           let described = resolved?.element ?? fresh.elements.first(where: { $0.ref == ref }) {
            switch await Self.systemAlertGate(described, driver: driver, engine: engines[key]) {
            case .refuse(let refusal): throw MCPError(refusal)
            case .proceed(let note): gateNote = note
            }
        }
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
            return (element, gateNote)
        }
        switch RefGuard.relocate(target, in: fresh.elements, screen: fresh.screen) {
        case .gone:
            throw MCPError(RefGuard.goneMessage(ref: ref, target: target,
                                                truncatedCount: fresh.truncatedCount))
        case .ghost(let found):
            return (found, gateNote)
        case .found(let found, _):
            return (found, gateNote + (RefGuard.labelChangeNote(old: target.label, new: found.label) ?? ""))
        }
    }

    /// driver(_:) が使うキャッシュキーと同じ引き当て(エンジンの記録先)。**93 箇所から
    /// 呼ばれる non-throwing 関数**なので型ゲートは `try?` で通す(誤った型は nil = 従来どおり
    /// port なしのキーに畳む)——実際の接続は `portArgument`/`portForIOS`(throws)が別途
    /// 検査するので、ここが緩くても「文字列を渡したのに繋がってしまう」ことにはならない
    static func engineKey(_ args: [String: Any]) -> String {
        if let profileName = args["profile"] as? String {
            return driverCacheKey(profile: profileName, project: args["project"] as? String,
                                  platform: args["platform"] as? String)
        }
        return driverCacheKey(platform: platformName(args), port: try? Self.intArgument(args, "port"),
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
        // **profile だけの呼び出しはプロファイルの台で決める**: driver() は resolveProfileTarget で
        // Android の台に解決するのに、ここが既定の iOS を返すと ft_list_apps が simctl へ落ち、
        // ft_rotate / ft_logs / verifiedRef が iOS 側の記録・言い回しになる。読めなければ既定へ
        // (driver() 側が改めて明確なエラーを出す)。**ドライバが手元にある呼び手は
        // `driver is AndroidDriver` を優先する**(ft_snapshot と同じ。ファイルを読み直さない)
        if let profile = args["profile"] as? String,
           let platform = profilePlatform(profile: profile, project: args["project"] as? String) {
            return platform
        }
        return ProcessInfo.processInfo.environment["FLEETEST_PLATFORM"] ?? "ios"
    }

    /// 実行プロファイルの**最初の台**の platform。resolveProfileTarget が使う
    /// `resolved.devices.first?.platform` と同じ順序(ProfileResolver.runDeviceMachines は resolve()
    /// と同じ devices の記述順で enabled の台を返す)を、アプリ解決・provision 抜きで読む。
    /// プロジェクト/プロファイルが読めなければ nil
    static func profilePlatform(profile: String, project projectName: String?) -> String? {
        guard let project = try? ScenarioHost.project(named: projectName) else { return nil }
        return ProfileResolver.runDeviceMachines(project: project, runProfileName: profile)
            .first?.platform
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
        let resolved = try ProfileResolver.resolve(project: project, runName: profileName)
        prologue.append(contentsOf: resolved.warnings.map { "⚠️ \($0)" })
        // CLI の profile 経路(ProfileRunner/ApiRunCommand)と同じ1箇所(FTCore.RunEnvironment)を
        // 通す —— Play Protect のキルスイッチだけでなく iosFastInput/iosPreActionWarmup/
        // enableAnimations も同時に注入する
        RunEnvironment.apply(resolved)
        // **ブリッジ準備より前に appPath の原本を apps/ へ運ぶ**(ProfileRunner/ApiRunCommand と同じ)。
        // resolved.apps[].appPath は常にステージ先を指すので、運ばずに provision へ渡すと
        // autoInstall が存在しないパスを simctl install して落ちる
        let staged = try WorkspaceAppStaging.stageWorkspaceApps(resolved)
        if !staged.isEmpty {
            prologue.append("→ Staged app package(s) into the workspace: " + staged.joined(separator: ", "))
        }
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
    /// 旧名 → 現名。**別名は call() の入口で現名へ畳む**(dispatch の case に旧名を並べない)——
    /// `toolAcceptsDeviceTarget` はスキーマ(現名)しか知らないので、dispatch だけで受けると
    /// 宛先の記憶が別名の呼び出しに効かず、**別の機を長押しする**(実測: `ft_tap port: 8138` の後の
    /// `ft_press x: y:` が既定ポートへ行った)。旧名を落とさない理由は手元のメモ・既存の手順に
    /// 残っている名前を「不明なツール」にしないため(ツール一覧には現名だけを出す ——
    /// 名前だけで呼ぶかを決めるクライアントが `ft_press` をハードウェアキーと読んだ)
    static let toolAliases: [String: String] = ["ft_press": "ft_long_press"]

    static func canonicalToolName(_ tool: String) -> String { toolAliases[tool] ?? tool }

    /// ツール引数の数値を丸ごと `ArgumentBounds` に掛ける(`call` の入口の1箇所)。
    /// 表に無い鍵・`.unbounded` の鍵は素通し。**型違いはここでは断らない** ——
    /// 型の文言は `intArgument`/`doubleArgument` が値を読むときに出す(2つの文言を作らない)
    static func checkArgumentBounds(_ args: [String: Any]) throws {
        for (key, value) in args {
            let numeric: Double?
            switch value {
            case let intValue as Int: numeric = Double(intValue)
            case let doubleValue as Double: numeric = doubleValue
            default: numeric = nil
            }
            guard let numeric, let violation = ArgumentBounds.violation(key, numeric) else { continue }
            throw MCPError(violation)
        }
    }

    /// 「対象の指し方」が複数ある引数は、各 case が `if let ref = … else if let x,y = …` の順で
    /// 見るため、両方渡すと後発の枝が黙って捨てられる(実測: `ft_tap {ref:1, x:1, y:1}` →
    /// "tap [1] done." — x/y は一度も読まれない。`ft_drag` は `toX ?? fromX + dx` の形なので
    /// `toX`/`dx` を両方渡すと `dx` が同じ理由で消える)。CLAUDE.md「指定したのに黙って効かない
    /// 形を作らない」。表は tool → 「同じ的を指す鍵グループ」の配列(1ツールに複数の
    /// チェック軸がありうる = ft_drag の from 側と to 側)。**片方だけの指定(x のみ等)は対象外**
    /// (「ref or x/y is required」が別途断る)
    static let exclusiveArgumentGroups: [String: [[[String]]]] = [
        "ft_tap": [[["ref"], ["x", "y"]]],
        "ft_double_tap": [[["ref"], ["x", "y"]]],
        "ft_long_press": [[["ref"], ["x", "y"]]],
        "ft_pinch": [[["ref"], ["x", "y"]]],
        "ft_drag": [
            [["fromRef"], ["fromX", "fromY"]],
            [["toX"], ["dx"]],
            [["toY"], ["dy"]],
        ],
    ]

    /// 違反なら文言、無ければ nil。`checkArgumentBounds` の直後(デバイス/ブリッジに触る前)で呼ぶ
    static func targetExclusivityViolation(tool: String, args: [String: Any]) -> String? {
        guard let checks = exclusiveArgumentGroups[tool] else { return nil }
        for groups in checks {
            let populated = groups.filter { keys in keys.contains { args[$0] != nil } }
            guard populated.count > 1 else { continue }
            let phrase = groups.map { $0.joined(separator: "/") }.joined(separator: " or ")
            return "\(tool) takes either \(phrase), not both"
        }
        return nil
    }

    func call(tool: String, args: [String: Any]) async throws -> [[String: Any]] {
        let tool = Self.canonicalToolName(tool)
        // **未知のツール名はここで断る**(デバイスを触るより前)。この後の
        // foldingUDIDIntoPort は udid → port の解決にブリッジ走査を撃つので、ここで弾かないと
        // 「打ち間違えたツール名」が「ブリッジが無い」という誤った診断になる
        // (実測: 存在しない udid + 打ち間違えたツール名 → "no running bridge is on udid …")。
        // dispatch(tool:args:) の default: にある同じ throw は二重の備えとして残す
        guard Self.toolDefinitions.contains(where: { $0["name"] as? String == tool }) else {
            throw MCPError("unknown tool: \(tool)")
        }
        // JSON null の欄は「省略」に畳む(droppingNullArguments 参照)。foldingUDIDIntoPort より前
        let args = Self.droppingNullArguments(args)
        // **値域は入口で1回だけ全数見る**(`intArgument`/`doubleArgument` の門だけでは足りない)
        // —— 条件付きでしか読まれない欄(`waitSeconds` は snapshotAfter のときだけ等)は、
        // 読まれない回に 0/負がそのまま通り、呼び手は「効いた」と誤解する
        try Self.checkArgumentBounds(args)
        // **秒数の相互検査は値域の隣**(seconds ≤ maxGestureSeconds(省略時は既定10秒)。
        // 単独の checkArgumentBounds は型/絶対上限(60秒)のスキーマ検査しかできない)
        if let violation = ArgumentBounds.gestureCapViolation(args) {
            throw MCPError(violation)
        }
        if let violation = Self.targetExclusivityViolation(tool: tool, args: args) {
            throw MCPError(violation)
        }
        // profile と udid/port/serial の併用は**畳む前に**断る(udid の畳み込みはブリッジ走査を撃つ)
        if Self.toolAcceptsDeviceTarget(tool), let refusal = Self.profileWithExplicitTargetRefusal(args) {
            throw MCPError(refusal)
        }
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
        // 入口で畳めば 35 箇所の呼び出しを触らずに全部が揃う。
        // **宛先を取らないツールでは畳まない**(`toolAcceptsDeviceTarget`)—— 畳み込みは
        // udid → port の解決にブリッジ走査を撃ち、居なければ「no running bridge」で落ちる。
        // 端末を1つ駆動している呼び手は `udid` を毎回添えるので、ブリッジが死んだ瞬間に
        // **一覧・診断のツールまで道連れ**になり、文面が案内する `ft_list_devices` 自身が
        // 同じエラーを返す袋小路になっていた(実地 2026-09-23 の負荷テスト)
        let folded: [String: Any]
        if Self.toolAcceptsDeviceTarget(tool) {
            do {
                // **udid を宣言していないツールでは走査しない**(ft_logs = ブリッジが死んだ後に読むツール。
                // 畳むと「no running bridge」で落ち、読みたいクラッシュログに届かない)
                folded = Self.strippingSelectorQuotes(Self.toolFoldsUDID(tool)
                    ? try await Self.foldingUDIDIntoPort(args) : args)
            } catch {
                let hint = await connectionLostHint(error, args: args)
                throw hint.isEmpty ? error : MCPError(error.localizedDescription + hint)
            }
        } else {
            folded = Self.strippingSelectorQuotes(args)
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
            // **失敗したら1回だけブリッジを建て直して撃ち直す**(MCPServer+BridgeRecovery.swift)。
            // 建て直せなければ元のエラーがそのまま catch へ落ち、connectionLostHint 等は従来どおり
            var content = try await dispatchRetryingAfterBridgeRecovery(tool: tool, args: resolved)
            if !rememberedNote.isEmpty {
                content = [["type": "text", "text": rememberedNote]] + content
            }
            if Self.toolAcceptsDeviceTarget(tool), let runNote = markDeviceInUse(args: resolved) {
                content = [["type": "text", "text": runNote]] + content
            }
            if let note = takeUIFrameworkUnknownNote(args: resolved) {
                content = [["type": "text", "text": note]] + content
            }
            let elapsedMs = Int(((clock.now - start) / .milliseconds(1)).rounded())
            if Self.toolAcceptsDeviceTarget(tool) {
                await recheckXCUITestRunnerIfSlow(args: resolved, elapsedMs: elapsedMs)
            }
            return Self.withElapsed(content, since: start, clock: clock)
        } catch {
            // run が台を使っている最中は失敗しやすい(アプリの起こし直し・ブリッジの建て直し)ので、失敗にも言う
            let runNote = Self.toolAcceptsDeviceTarget(tool) ? markDeviceInUse(args: resolved) : nil
            let hint = await connectionLostHint(error, args: resolved)
                + Self.setTextRefusedHint(tool: tool, args: resolved,
                                          message: error.localizedDescription)
                + Self.noReadableWindowHint(error)
                + Self.accessibilityOutageHint(error)
                + (runNote.map { " " + $0 } ?? "")
            guard !hint.isEmpty else { throw error }
            throw MCPError(error.localizedDescription + hint)
        }
    }

    /// 実機で uiFramework が判定できないまま探索した回の直後に1回だけ(resolveExecutorHints が立てる)
    func takeUIFrameworkUnknownNote(args: [String: Any]) -> String? {
        let key = Self.engineKey(args)
        guard uiFrameworkUnknownPending.remove(key) != nil else { return nil }
        return "ℹ️ the UI framework of the app on this physical device is unknown (no .app/.ipa seen for"
            + " this bundle id yet): the relief drag after a scroll is decided per element from the"
            + " accessibility tree (custom-drawn elements get it; an older bridge that reports no element"
            + " classes sends none). ft_install it from its .app/.ipa once to settle it; the result is"
            + " remembered for the bundle id"
    }

    /// **この MCP が操作している台に印を置き(run が後回しにする)、run が使用中なら1行で言う**
    /// (ユーザー決定: run は MCP の台を避け、MCP は run の台を触ったら警告する = 断らない)。
    /// 台の鍵は解決済みの記録(udids / connectedAndroidSerials)から採る = run の lease と同じ鍵。
    /// 記録が無い(接続する前に失敗した回)ときは引数の udid / serial。どれも無ければ何もしない
    func markDeviceInUse(args: [String: Any]) -> String? {
        let key = Self.engineKey(args)
        let recorded = (udids[key] ?? nil) ?? connectedAndroidSerials[key]
        guard let stateDir = deviceLeaseStateDir,
              let deviceKey = recorded ?? (args["udid"] as? String) ?? (args["serial"] as? String),
              !deviceKey.isEmpty else { return nil }
        // 印と文言は MCPDeviceLease の1箇所(ft_run_scenario も同じ口を使う)
        return MCPDeviceLease.writeAndWarnIfInUse(
            stateDir: stateDir, key: deviceKey, pid: ProcessInfo.processInfo.processIdentifier)
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

    /// Android の a11y 根が一時的に読めない(422・DriverError.isNoReadableWindow)ときの対処。
    /// **判定(status + 本文接頭辞)は FTCore が持つ・文言はここだけ**(共有するのは判定であって
    /// 文言ではない)。実測 Pixel 3a/Android 12: 13〜37 秒で自然回復。同じ ft_snapshot を
    /// 即座に撃ち直しても同じ答えなので、それを捨てないよう明言する
    static func noReadableWindowHint(_ error: Error) -> String {
        guard DriverError.isNoReadableWindow(error) else { return "" }
        return " This is a transient device-side condition, not an app or tool bug — it clears on"
            + " its own (observed 13-37s). Retrying the exact same call again immediately will"
            + " most likely return this same error, so wait a few seconds first. Bringing the app"
            + " back to the foreground tends to clear it faster: ft_navigate target: \"home\", or"
            + " ft_launch."
    }

    /// XCTest の a11y サーバが一時的に落ちている(500 + kAXErrorAPIDisabled)ときの対処。
    /// **判定は `SessionRecoveryDriver.isAccessibilityTemporarilyDown` の1箇所**(run の
    /// 再キューと同じ判定)・文言はここだけ。`SessionRecoveryDriver` が 1/2/3 秒の間隔で
    /// 読みを撃ち直した**後**に出るので、呼び手にできるのは「数秒おいてから」だけ。
    /// これが無いと生の `Error Domain=com.apple.dt.xctest.automation-support.error Code=8 …` が
    /// そのまま返り、run では「環境要因」と分かっている事象を呼び手が**アプリの不具合**と
    /// 読み違える(実地 2026-09-23 の負荷テスト)
    static func accessibilityOutageHint(_ error: Error) -> String {
        guard SessionRecoveryDriver.isAccessibilityTemporarilyDown(error) else { return "" }
        return " The device's accessibility server is momentarily down (kAXErrorAPIDisabled) —"
            + " this is an environment fault, not an app or tool bug, and the reads were already"
            + " retried for a few seconds. It usually clears within seconds: wait, then try again."
            + " If every call keeps failing this way, restart the simulator/device."
    }

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
            return try await ftStatus(args)

        case "ft_list_devices":
            return try await ftListDevices(args)

        case "ft_list_apps":
            return try await ftListApps(args)

        case "ft_logs":
            return try await ftLogs(args)

        case "ft_install":
            return try await ftInstall(args)

        case "ft_launch":
            return try await ftLaunch(args)

        case "ft_open_url":
            return try await ftOpenUrl(args)

        case "ft_snapshot":
            return try await ftSnapshot(args)

        case "ft_tap":
            return try await ftTap(args)

        case "ft_type":
            return try await ftType(args)

        case "ft_swipe":
            return try await ftSwipe(args)

        case "ft_scroll_to":
            return try await scrollTo(args)

        case "ft_batch":
            return try await batch(args)

        case "ft_rotate":
            return try await ftRotate(args)

        case "ft_navigate":
            return try await ftNavigate(args)

        case "ft_hide_keyboard":
            return try await ftHideKeyboard(args)

        case "ft_clear_app_data":
            return try await ftClearAppData(args)

        case "ft_clear_input":
            return try await ftClearInput(args)

        case "ft_draft_scenario":
            return text(try draftScenario(args))

        case "ft_dsl_commands":
            return try dslCommands(args)

        case "ft_double_tap":
            return try await ftDoubleTap(args)

        case "ft_drag":
            return try await ftDrag(args)

        case "ft_pinch":
            return try await ftPinch(args)

        case "ft_gesture":
            return try await ftGesture(args)

        // 旧名 `ft_press` は call() の toolAliases が現名へ畳む(ここに並べると記憶の適用から漏れる)
        case "ft_long_press":
            return try await ftLongPress(args)

        case "ft_screenshot":
            return try await ftScreenshot(args)

        case "ft_capture_element":
            return try await ftCaptureElement(args)

        case "ft_terminate":
            return try await ftTerminate(args)

        case "ft_list_scenarios":
            return try listScenarios(args)

        case "ft_dry_run":
            return try await dryRun(args)

        case "ft_run_scenario":
            return try await runScenario(args)

        case "ft_list_projects":
            return try listProjects()

        case "ft_doctor":
            return try await ftDoctor(args)

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
    /// `waitFor`/`waitForChangeExplicit`: **要約は実際に何を待つかを言う** —— 呼び手が
    /// `waitFor` を渡しているのに(snapshotAfterBody 側では効いている)要約だけが
    /// 「waitForChange: false」を名乗ると、渡していない引数を渡したことにされる(§19.3 M4)。
    /// `waitForChangeExplicit` は `args["waitForChange"] as? Bool`(渡していなければ nil)。
    /// 優先順: waitFor > 明示 false > それ以外(暗黙の着地待ち・明示 true)は汎用文言
    /// `routedByScheme`: **iOS は宛先を名乗らない** —— simctl openurl / devicectl openURL は
    /// スキームの持ち主へ OS が配る(bundleId は同意ダイアログの了承と in-app の再起動先にしか
    /// 使わない)。名乗ると、別アプリの bundleId を渡した呼び手に「そこへ届けた」と誤って請け合う。
    /// Android は intent の宛先そのものなので従来どおり名乗る
    static func openURLSummary(url: String, bundleID: String?, bundleIDWasRemembered: Bool,
                               routedByScheme: Bool,
                               snapshotAfter: Bool, waitFor: String? = nil,
                               waitForChangeExplicit: Bool? = nil) -> String {
        let target: String
        if routedByScheme {
            let scheme = URL(string: url)?.scheme.map { "\"\($0)\" " } ?? ""
            target = " (iOS hands it to the app that registers the \(scheme)URL scheme —"
                + " bundleId does not choose the recipient)"
        } else {
            target = bundleID.map {
                " to \($0)" + (bundleIDWasRemembered
                    ? " (not given — this session's last ft_launch on this device;"
                        + " pass bundleId if the foreground app has changed since)"
                    : "")
            } ?? ""
        }
        let delivered = "Delivered \(url)" + target + "."
        let asynchronous = " Delivery is asynchronous (the app has to receive and handle it)"
        guard !snapshotAfter else {
            if let waitFor {
                return delivered + asynchronous + " — the tree below was read after waiting for"
                    + " \"\(waitFor)\" to appear"
            }
            // **既定は「待つ」**(配送直後に読むと前の画面が返り得る)。
            // 待っても着地しなかったことは waitForChange の注記が言う
            if waitForChangeExplicit == false {
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
    /// `ft_swipe` の `finger` 引数は指の向きなので、**ここで逆写像を掛けてはいけない**
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
        // **判定は FTCore.ReinstallSource の1箇所**(DSL の clearAppData と共有)。
        // ここが持つのは MCP の読み手向けの文言だけ —— あちらは `packagePath:` を渡せるが、
        // DSL の読み手が渡せるのは実行プロファイルの `appPathPhysical` で、同じ文では言えない
        switch ReinstallSource.resolve(explicit: explicit, remembered: remembered, exists: exists) {
        case .usable(let path):
            return .success(path)
        case .unknown:
            return .failure(MCPError("On a physical device there is no clearAppData equivalent —"
                + " data is wiped by reinstalling the app instead. Pass packagePath:"
                + " <path to the .app/.ipa>, or run ft_install first so this can reuse"
                + " that path."))
        case .missing(let path):
            return .failure(MCPError("The app was NOT uninstalled. The reinstall source \(path)"
                + " no longer exists (a rebuild or clearing DerivedData can move or remove it) —"
                + " pass packagePath: <path to the current .app/.ipa>, or run ft_install first."))
        }
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

    /// ブリッジが操作の応答に載せた注記(`AppDriver.lastActionNote`。
    /// `tap(ref:)` の「activate 不発 → 合成タッチ」と `type` の打ち直しが立てる)を、MCP の応答にも
    /// 載せる。DSL は `StepExecutor+Actions.swift` の `driverFallback` へ同じ値を運んでいるので、
    /// MCP だけが黙って捨てると同じ事実を MCP 経由の探索者だけが見えない
    static func driverFallbackNote(_ driver: AppDriver) -> String {
        guard let note = driver.lastActionNote, !note.isEmpty else { return "" }
        return " (\(note))"
    }

    /// `ft_type` / `ft_clear_input` が入力欄でない ref(かつ内側に入力欄が
    /// ちょうど1つある容器でもない)へ撃たれたときの拒否文。`TapTargetGeometry.
    /// nonInputTypeTargetNote` が nil を返す(= 警告すら出せない)ケースの受け皿 ——
    /// 0個(そもそも入力の器ではない)・2個以上(どれを指すべきか言えない)のどちらも、
    /// 黙って撃つと**別の要素を操作してしまう**(ボタンを押す・焦点のある別の欄へ入る)
    static func notATextFieldRefusal(_ target: ElementInfo, ref: Int) -> String {
        "[\(ref)] is a \(target.type), not a text field, and it does not contain exactly one text"
            + " field either — refusing before anything is typed/cleared (typing into it anyway"
            + " tends to fire whatever it is instead — a button, a link — or land on an unrelated"
            + " field that currently has focus). Take a fresh ft_snapshot and target the actual"
            + " input field, or omit ref: to act on whatever currently has focus."
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

    /// `ft_double_tap` / `ft_drag` / `ft_long_press` を座標で撃ったときの
    /// 応答が、`coordinateReproductionNote`(tap 用)をそのまま流用して「writable as tap(x:, y:)」
    /// と言っていた —— 実際には doubleTap に座標形は無く、drag に対応する DSL コマンドも無く、
    /// long press は holdSeconds を省くとただの tap に化ける。操作ごとに正しい書き方を言う

    /// `doubleTap` は DSL でセレクタしか取らない(座標形が無い)
    static let doubleTapCoordinateNote =
        " (not writable as a DSL step: doubleTap only takes a selector in the DSL, not x/y —"
        + " target the element with a selector once you have one for it)"
    static let doubleTapCoordinateNoteShort =
        " (still no coordinate form for doubleTap — see the first note)"

    /// 座標どうしの drag の DSL の形は `swipePointToPoint`(docs/commands.md)。tap の note を流用すると
    /// 別の操作(タップ)が書かれる。press(動かす前の静止)は swipePointToPoint に対応が無い
    static let dragCoordinateNote =
        " (writable as swipePointToPoint(startX:startY:endX:endY:) — fine while exploring, but replace it"
        + " with a selector before keeping it in a scenario: a layout change makes it hit something else)"
    static let dragCoordinateNoteShort =
        " (writable as swipePointToPoint — see the first note)"

    /// 長押しの座標形は `tap(x:, y:, holdSeconds:)` —— **holdSeconds を省くとただの tap になる**ので、
    /// tap の note をそのまま出すと holdSeconds が消えたシナリオ行が書かれる。**maxGestureSeconds を
    /// 上書きしていたら同じく落とさない** —— 落とすと既定10秒を超える長押しが書き写した先で断られる
    static func coordinateHoldReproductionNote(holdSeconds: Double, maxGestureSeconds: Double? = nil) -> String {
        " (writable as tap(x:, y:, holdSeconds: \(FTSeconds.format(holdSeconds))\(Self.maxGestureSecondsArgSuffix(maxGestureSeconds))) — fine while"
            + " exploring, but replace it with a selector before keeping it in a scenario:"
            + " a layout change makes it hit something else)"
    }
    static func coordinateHoldReproductionNoteShort(holdSeconds: Double, maxGestureSeconds: Double? = nil) -> String {
        " (writable as tap(x:, y:, holdSeconds: \(FTSeconds.format(holdSeconds))\(Self.maxGestureSecondsArgSuffix(maxGestureSeconds))) — see the first note)"
    }
    /// `, maxGestureSeconds: X` の断片(無ければ空文字)。座標形の複数の reproduction note が共有する
    static func maxGestureSecondsArgSuffix(_ value: Double?) -> String {
        value.map { ", maxGestureSeconds: \(FTSeconds.format($0))" } ?? ""
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
        ConsoleOut.err("[fleetest-mcp] " + message)
    }

}
