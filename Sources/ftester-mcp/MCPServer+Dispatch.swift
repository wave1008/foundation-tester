// MCPServer+Dispatch.swift
// ツールの入口(call/dispatch)と各ツールの実装。本体は MCPServer.swift(instance 状態はそちらに置く)

import Foundation
import FTAgent
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

    /// 引数から見た宛先プラットフォーム。**既定は iOS**(FTESTER_PLATFORM で上書き)
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
        return ProcessInfo.processInfo.environment["FTESTER_PLATFORM"] ?? "ios"
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

    /// **ツールが device ターゲット(port/serial/udid)を受けるか**。schema 駆動(port または serial
    /// プロパティの有無)にしてあるので、ツール一覧を追加でメンテしなくても toolDefinitions と
    /// 自動的に揃う。**port だけでは見ない**(2026-08-12): scope: .none で serial だけを個別宣言する
    /// ツール(ft_logs)が port を持たないため、port 単独判定だと fold から漏れて記憶が効かなかった。
    /// device を受けないツール(ft_doctor 等)へ記憶を適用すると、宛先と無関係な応答に
    /// 「この機を使い回しています」という誤解を招く注記が付く
    static func toolAcceptsDeviceTarget(_ tool: String) -> Bool {
        guard let definition = toolDefinitions.first(where: { $0["name"] as? String == tool }),
              let schema = definition["inputSchema"] as? [String: Any],
              let props = schema["properties"] as? [String: Any] else { return false }
        return props["port"] != nil || props["serial"] != nil
    }

    /// **省略呼び出しへ記憶した宛先を注入する**(dispatch 入口。call() 参照)。
    /// 条件は明示ターゲット述語(argsGaveIOSTarget/argsGaveAndroidTarget)と1本化してある ——
    /// ここだけ udid:"" を「指定あり」と誤読すると、記憶の適用だけが抑止されて記録は素通しする
    /// 非対称に戻る。**profile 指定時は触らない**(宛先はプロファイルが決める)。
    ///
    /// platform の決め方(2026-08-12・4欠陥修正): **udid/port か serial のどちらかが明示されて
    /// いれば、その platform だけを見る**(serial 明示に iOS の記憶を注入しない/逆も同じ)。
    /// **どちらも無ければ platform 引数 → 直近に明示された platform(lastExplicitPlatform)→
    /// 既定(ios)の順**で決める —— 契約は「udid, port, AND serial を全部省略したら同じデバイスへ」
    /// なので、Android を明示した直後の全省略呼び出しは Android の記憶へ行かなければならない
    /// (既定 "ios" に負けて iOS 分岐へ迷い込んでいた)。
    /// iOS 側は **port だけ注入し udid は注入しない**(2026-08-12): udid を注入すると
    /// driver() の portForIOS → bridgePorts(forUDID:) が毎回 BridgeDiscovery.scan を強いられ、
    /// XCUITest quiescence(実測33.7秒)で busy なブリッジが scan に載らず reconcilePort が
    /// throw する(isBound による busy 救済が効くのは connectionLostHint の経路だけ)。
    /// 注入した呼び出しには `deviceFromMemoryKey` を立てる —— driver() 側の
    /// recordsIOSMemory/recordsAndroidMemory がこれを見て、自動注入を「利用者が選んだ」として
    /// 記憶を上書きしない(port 再利用で別デバイスに化けたときに記憶が黙って乗り換わるのを防ぐ)
    func foldInRememberedDevice(_ args: [String: Any]) -> RememberedDeviceFold {
        guard args["profile"] == nil else { return .unchanged }
        let explicitPlatform = args["platform"] as? String
        let platform: String
        if let explicitPlatform {
            platform = explicitPlatform
        } else if Self.argsGaveAndroidTarget(args) {
            platform = "android"
        } else if Self.argsGaveIOSTarget(args) {
            platform = "ios"
        } else {
            platform = lastExplicitPlatform ?? Self.platformName(args)
        }
        switch platform {
        case "ios":
            let iosOther = Self.platformWasInferred(args)
                && !seenExplicitAndroidSerials.isEmpty ? "Android" : nil
            guard let remembered = Self.iosExplicitWithMemory(
                argsGaveTarget: Self.argsGaveIOSTarget(args), remembered: lastExplicitIOSTarget)
            else {
                return lostTargetFold(gaveTarget: Self.argsGaveIOSTarget(args),
                                      everNamed: everNamedIOSTarget,
                                      survivors: seenExplicitIOSPorts.map(String.init),
                                      apply: { label in
                                          var out = args
                                          out["port"] = Int(label) ?? 0
                                          if explicitPlatform == nil { out["platform"] = "ios" }
                                          return out
                                      },
                                      deviceNoun: "iOS devices", unitNoun: "ports",
                                      otherPlatform: iosOther)
            }
            var out = args
            out["port"] = Int(remembered.port)
            if explicitPlatform == nil { out["platform"] = "ios" }
            // **ログは適用が決まってから**(2026-08-13 のレビュー指摘): 先に出すと、
            // 曖昧で拒否した呼び出しまで「その機へ行った」と読める痕跡を stderr に残す
            let iosFold = Self.finishingFold(out, chosen: "port \(remembered.port)",
                                      allSeenLabels: seenExplicitIOSPorts.map(String.init),
                                      deviceNoun: "iOS devices", unitNoun: "ports",
                                      otherPlatform: Self.platformWasInferred(args)
                                          && !seenExplicitAndroidSerials.isEmpty ? "Android" : nil,
                                      noteKey: "rememberedDevice:ios:\(remembered.port)",
                                      firstTime: firstTime)
            if case .applied = iosFold {
                Self.logStderr("no udid/port given — reusing this session's earlier target"
                    + " (port \(remembered.port), udid \(remembered.udid ?? "unknown"))")
            }
            return iosFold
        case "android":
            let androidOther = Self.platformWasInferred(args)
                && !seenExplicitIOSPorts.isEmpty ? "iOS" : nil
            guard let remembered = Self.androidExplicitWithMemory(
                argsGaveTarget: Self.argsGaveAndroidTarget(args), remembered: lastExplicitAndroidSerial)
            else {
                return lostTargetFold(gaveTarget: Self.argsGaveAndroidTarget(args),
                                      everNamed: everNamedAndroidTarget,
                                      survivors: Array(seenExplicitAndroidSerials),
                                      apply: { label in
                                          var out = args
                                          out["serial"] = label
                                          if explicitPlatform == nil { out["platform"] = "android" }
                                          return out
                                      },
                                      deviceNoun: "Android devices", unitNoun: "serials",
                                      otherPlatform: androidOther)
            }
            var out = args
            out["serial"] = remembered
            if explicitPlatform == nil { out["platform"] = "android" }
            let androidFold = Self.finishingFold(out, chosen: "serial \(remembered)",
                                      allSeenLabels: Array(seenExplicitAndroidSerials),
                                      deviceNoun: "Android devices", unitNoun: "serials",
                                      otherPlatform: Self.platformWasInferred(args)
                                          && !seenExplicitIOSPorts.isEmpty ? "iOS" : nil,
                                      noteKey: "rememberedDevice:android:\(remembered)",
                                      firstTime: firstTime)
            if case .applied = androidFold {
                Self.logStderr("no serial given — reusing this session's earlier Android target"
                    + " (serial \(remembered))")
            }
            return androidFold
        default:
            return .unchanged
        }
    }

    /// 記憶した宛先が**失敗で消えた後**の省略呼び出し(2026-08-13 の監査。セッションの形 = OS 跨ぎ)。
    ///
    /// **実測した事故**: ①port 8138 を明示して成功 → ②存在しない port 8999 を明示して失敗 →
    /// ③宛先を省いた呼び出しが、**8138 でも 8999 でもない別のシミュレータ**(ホーム画面が返った)
    /// へ黙って行った。記憶は**解決時**に書かれるので ② が 8138 を 8999 で上書きし、
    /// 失敗の後始末(`forgetConnection`)が 8999 を消して**記憶を空にする**。空になると
    /// 「まだ1台も指していない新しいセッション」と同じ扱いになり、`resolveIOSPort(explicit: nil)`
    /// = **ブリッジ探索**へ落ちて、このセッションが一度も名指ししていない機を拾う。
    /// 曖昧さのガードは記憶を見るので、記憶が空ではそもそも働かない。
    ///
    /// 規則: **一度でも宛先を名指ししたセッションでは、省略呼び出しを探索へ落とさない**。
    /// 生き残りが1つならそこへ戻し(= ③ は 8138 へ行く)、0 か複数なら断る。
    func lostTargetFold(gaveTarget: Bool, everNamed: Bool, survivors: [String],
                        apply: (String) -> [String: Any],
                        deviceNoun: String, unitNoun: String,
                        otherPlatform: String?) -> RememberedDeviceFold {
        guard !gaveTarget, everNamed else { return .unchanged }
        // **「候補が2台以上」はここで数えない** —— 曖昧さの判定は `isAmbiguousMemory` の1箇所に
        // あり、下の `finishingFold` が同じ規則で断る。ここで先に数えると規則が2箇所になり、
        // しかも**片方を壊しても何も落ちない**(変異で実証した)
        guard let survivor = survivors.first else {
            return .ambiguous(message: Self.lostTargetRefusal(
                survivors: survivors, deviceNoun: deviceNoun, unitNoun: unitNoun,
                otherPlatform: otherPlatform))
        }
        return Self.finishingFold(apply(survivor), chosen: "\(unitNoun.dropLast()) \(survivor)",
                                  allSeenLabels: survivors, deviceNoun: deviceNoun,
                                  unitNoun: unitNoun, otherPlatform: otherPlatform,
                                  noteKey: "lostTarget:\(deviceNoun):\(survivor)",
                                  firstTime: firstTime)
    }

    /// `lostTargetFold` が断るときの文。**探索へ落ちない理由を言う** —— 「見つからない」とだけ
    /// 返すと、読み手は宛先を渡すのではなくブリッジを建て直しにいく
    static func lostTargetRefusal(survivors: [String], deviceNoun: String, unitNoun: String,
                                  otherPlatform: String?) -> String {
        let sorted = survivors.sorted()
        let left = sorted.isEmpty
            ? " The \(deviceNoun) this session had targeted are no longer reachable."
            : " This session still has \(sorted.count) reachable \(unitNoun)"
                + " (\(sorted.prefix(rememberedDeviceListCap).joined(separator: ", ")))."
        let crossed = otherPlatform.map {
            " This session has also driven \($0), and no platform was given either."
        } ?? ""
        return "no udid/port/serial given, and this session's earlier target is gone.\(left)\(crossed)"
            + " Refusing to fall back to whichever bridge happens to be running: that would operate"
            + " a device you never named, and unlike a bad answer that is not something you can take"
            + " back. Pass udid or port (iOS) / serial (Android) to say which."
    }

    /// `foldInRememberedDevice` の結果。**曖昧なら適用せず拒否する**(2026-08-13)。
    /// 以前は「2台以上を触っていたら毎回注記しつつ直近の1台へ流す」だったが、
    /// **注記は事故を1件も止めなかった** —— 監査19(serial だけの呼び出しが黙って iOS へ)・
    /// 監査20(キャッシュ命中で記憶が更新されない)・udid 2台の記憶混線は**3件とも
    /// 「2台以上を触ったセッション」でだけ起きている**。逆に1台しか触っていないセッションは
    /// 原理的に外しようがないので、そこは従来どおり黙って適用してよい。
    /// 「記憶が安全なのは、それが一意なときちょうど」が規則の本体
    enum RememberedDeviceFold {
        case unchanged
        case applied(args: [String: Any], note: String)
        /// 宛先が一意に決まらない省略呼び出し。**推測せず call() が MCPError にする**
        case ambiguous(message: String)
    }

    /// ios/android 分岐の共通尾部(2026-08-12 の掃討・2026-08-12 曖昧化対応で拡張):
    /// マーカーを立て、注記を組む(rememberedDeviceNote 参照)。
    /// `firstTime` はキー消費(explainedNotes への insert)を伴うので呼び手のクロージャで渡す
    /// (このメソッドを static のままにするため — instance メソッド化すると呼び出し側で
    /// `Self.` と裸の呼び出しが混在して読みにくくなる)。
    /// **曖昧なときは鍵を消費しない**: 消費してしまうと、後で forgetConnection が候補を
    /// 1件まで減らして非曖昧に戻ったとき、この宛先はまだ一度も「初回の満額注記」を
    /// 受け取っていないのに firstTime が false になり黙ってしまう
    private static func finishingFold(
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

    /// 記憶した宛先が一意でないか。**判定はここ1箇所**(注記側と拒否側で条件がずれると、
    /// 「注記は出さないが拒否はする」のような食い違いが生まれる)
    static func isAmbiguousMemory(allSeenLabels: [String], otherPlatform: String?) -> Bool {
        allSeenLabels.count >= 2 || otherPlatform != nil
    }

    /// 曖昧な省略呼び出しを断る文(純粋関数。デバイスも走査も要らない)。
    /// **候補を名指しする** —— 断るだけだと読み手は何を渡せばよいか分からず、
    /// 総当たりで udid を試して結局どれかの機を操作することになる。
    /// 上限は `rememberedDeviceListCap`(注記側と同じ。超えたら件数だけ)
    static func rememberedDeviceRefusal(
        allSeenLabels: [String], deviceNoun: String, unitNoun: String, otherPlatform: String?
    ) -> String {
        let sorted = allSeenLabels.sorted()
        var driven = ""
        if sorted.count >= 2 {
            let list = sorted.count > rememberedDeviceListCap
                ? "\(sorted.count) \(unitNoun)"
                : "\(unitNoun) \(sorted.joined(separator: ", "))"
            driven = " This session has driven \(sorted.count) \(deviceNoun) (\(list))."
        }
        let crossed = otherPlatform.map {
            " This session has also driven \($0), and no platform was given either."
        } ?? ""
        return "no udid/port/serial given, and the target is not unique.\(driven)\(crossed)"
            + " Refusing to guess: picking the most recently used device silently would run this"
            + " on the wrong one, and unlike a bad answer that is not something you can take back."
            + " Pass udid or port (iOS) / serial (Android) to say which."
            + " (While only one device had been targeted, it was reused automatically.)"
    }

    /// **platform 自体が推測されたか**(= 呼び出しが platform も宛先も1つも渡していない)。
    /// この形だけが `lastExplicitPlatform` に落ちるので、両 platform を触っていれば
    /// 「どちらの機へ行くか」自体が曖昧になる。platform か宛先のどちらかが明示されていれば
    /// 行き先の platform は確定しているので、跨ぎの曖昧さは無い
    static func platformWasInferred(_ args: [String: Any]) -> Bool {
        args["platform"] as? String == nil
            && !argsGaveAndroidTarget(args) && !argsGaveIOSTarget(args)
    }

    /// 名指しする候補の上限本数。超えたら一覧を並べず件数だけ言う(rememberedDeviceNote)
    static let rememberedDeviceListCap = 6

    /// 省略呼び出しへ記憶した宛先を注入したときの注記の本文(純粋関数。デバイスも走査も要らない)。
    /// **ここへ来るのは宛先が一意なときだけ** —— 曖昧な形は `rememberedDeviceRefusal` が
    /// 断るので、この文が「どちらへ行ったか分からない」状況を説明することはもう無い。
    ///
    /// - `chosen`: 実際に注入した宛先の表示形("port 8123" / "serial emulator-5554")
    /// - `firstTime`: セッションで初回だけ出す(同じ1台を使い続ける間、毎回言う価値は無い)
    static func rememberedDeviceNote(chosen: String, firstTime: Bool) -> String {
        guard firstTime else { return "" }
        return "(reusing this session's earlier device: \(chosen)"
            + " — pass udid/port/serial to target another)\n"
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

    /// **経路の振り分けは記録(`connectedPorts`/`connectedAndroidSerials`)で決め、表示ラベルの
    /// 接頭辞では決めない**(2026-08-14): `connections[key]` は表示用で、profile 経由の書式
    /// ("<device name> port/serial <値>")は "port"/"serial " のどちらの接頭辞にも一致しない ——
    /// 直接指定と profile とで判別条件を分けると、profile 経由はどちらの回復ハンドラにも
    /// 一度も入らず、死んだブリッジへ永久に再ダイヤルし続ける(実機の陽性対照で確認)
    func connectionLostHint(_ error: Error, args: [String: Any]) async -> String {
        // 差し替えドライバ(テスト)では走査しない = 実ポートを叩かない
        guard makeDriver == nil else { return "" }
        let key = Self.engineKey(args)
        guard let connection = connections[key] else { return "" }
        if connectedPorts[key] != nil {
            return await iosConnectionLostHint(error, key: key, connection: connection)
        }
        if let serial = connectedAndroidSerials[key] {
            return await androidConnectionLostHint(error, key: key, connection: connection, serial: serial)
        }
        return ""
    }

    /// iOS(port 経由のブリッジ)の死活。Android には無い判定材料(BridgeDiscovery.isBound/scan)を
    /// 使うので、判定そのものを共有しない(androidConnectionLostHint 参照)
    func iosConnectionLostHint(_ error: Error, key: String, connection: String) async -> String {
        switch error {
        case DriverError.bridgeConnectionRefused:
            // 接続拒否は「誰も待受していない」が確定しているので、走査は今の状況を添えるだけ
            let running = await BridgeDiscovery.scan(excluding: 0, repoRoot: try? RepoRoot.find())
            return connectionLostAndForget(key: key, connection: connection, running: running)
        case DriverError.bridgeUnreachable:
            // **タイムアウトは死を意味しない**(2026-08-12 の実アプリ監査で踏んだ): 素の文言は
            // 「未起動 / 遅い / suspend」の3択を並べるだけで、直後に ft_status を撃つと
            // 「そのポートにブリッジが無い」と一意に答えられた —— 判定材料はあるのに
            // 操作系が使っていなかった。**確かめてから断定する**: 走査してポートが消えていれば
            // 死亡と言い切り、生きていれば何も足さない(遅い/suspend の可能性が残るため、
            // 素の3択メッセージのままにする)
            guard let port = connectedPorts[key] else { return "" }
            let repoRoot = try? RepoRoot.find()
            // **応答なしを死と読まない**(2026-08-12 の別監査で踏んだ、同じ勘違いの再発): scan は
            // 応答しないブリッジを「消えた」と数えるが、busy なブリッジ(XCUITest quiescence は
            // 実測33.7秒 /status 無応答・tap 等の interaction timeout は20秒)は生きたまま scan にも
            // 載らない。**bound(誰かが listen しているか)を verdict へそのまま渡し、production の
            // 判定点を bridgeUnreachableVerdict の1箇所に一本化する**(手前で `if bound { return }`
            // すると verdict の .busy 枝が production から一度も通らず、テストでしか確認できない
            // 判定になる)。
            // **実機では bound だけを信じない**(欠陥④): 到達手段が usb のとき listen しているのは
            // ランナーではなく iproxy(別プロセス)なので、ランナーが死んでも bound は true のまま
            // 残る。pid ファイルの所有プロセス生死(bridgeOwnerAlive)で補強し、「bound を信じてよいか」
            // (trustBound)を verdict と scan 要否の両方で共有する(手書きの条件式を2箇所に置かない)。
            // 信じてよいときだけ走査を省ける(busy なブリッジは scan に載らず判定に使われない)
            let bound = BridgeDiscovery.isBound(port: port, repoRoot: repoRoot)
            let ownerAlive = Self.bridgeOwnerAlive(port: port, repoRoot: repoRoot)
            let running = Self.trustBound(bound: bound, ownerAlive: ownerAlive)
                ? [] : await BridgeDiscovery.scan(excluding: 0, repoRoot: repoRoot)
            switch Self.bridgeUnreachableVerdict(
                bound: bound, ownerAlive: ownerAlive,
                vanished: Self.bridgeVanished(port: port, running: running)) {
            case .busy:
                return Self.bridgeBusyHint(connection: connection, engine: engines[key])
            case .stillUnclear:
                return ""
            case .vanished:
                return connectionLostAndForget(key: key, connection: connection, running: running)
            }
        default:
            return ""
        }
    }

    /// iOS の2分岐(bridgeConnectionRefused/.vanished)の共通尾部(2026-08-12 の掃討): 記憶を
    /// 捨てて、今の状況を添えたメッセージを組む
    func connectionLostAndForget(key: String, connection: String,
                                 running: [BridgeDiscovery.Found]) -> String {
        // **udid は忘れる前に読む**(2026-08-13 のレビュー指摘)。`forgetConnection` は
        // `forgetDeviceState` 経由で `udids[key]` も消すようになったので、後から読むと
        // 常に nil = 「同じ機のブリッジを先に挙げる」案内が**黙って死んでいた**
        let udid = udids[key].flatMap { $0 }
        forgetConnection(key)
        return Self.connectionLostMessage(connection: connection, running: running,
            sameDevice: Self.deviceName(forUDID: udid, in: running))
    }

    /// Android(serial 経由のブリッジ)の死活。**iOS のような安価な「待受しているか」判定が無い**
    /// ので、`AndroidSerialResolver.connectedSerials()`(`adb devices`)への再照会そのものを
    /// 識別材料にする —— adb の失敗文言は経路(clear/install/forward…)ごとに違って狭く確実な
    /// 部分文字列が取れないので、文字列ではなく probe で確かめる。
    /// **forgetConnection の Android 分岐(lastExplicitAndroidSerial の消去)はここが唯一の呼び手**
    /// (2026-08-12 まで到達不能だった —— 死んだ serial への省略呼び出しがセッション中ずっと
    /// 同じ死んだ serial へ再ダイヤルされ続けていた)
    func androidConnectionLostHint(_ error: Error, key: String, connection: String,
                                   serial: String) async -> String {
        switch error {
        case DriverError.bridgeUnreachable, DriverError.bridgeConnectionRefused, DriverError.badResponse:
            break
        default:
            return ""
        }
        // 端末がまだ adb につながっているなら、今回の失敗は別の理由(アプリ側のエラー等)。
        // probe だけで判定するので、広めに構えても実害は「adb devices を1回余計に撃つ」だけ
        guard Self.androidSerialVanished(serial, connected: AndroidSerialResolver.connectedSerials())
        else { return "" }
        forgetConnection(key)
        return "\nThe Android device behind \(connection) is no longer connected (adb devices"
            + " does not list it — unplugged, or the emulator was shut down). Reconnect it, then"
            + " target it again with serial: (or omit it once only one device is connected)."
    }

    /// probe(`adb devices` 相当の一覧)から見てこの serial は消えたか。**走査から切り離した
    /// 純粋関数**(bridgeVanished と同じ理由: 実 adb が要るとテストで判定を壊しても素通しする)
    static func androidSerialVanished(_ serial: String, connected: [String]) -> Bool {
        !connected.contains(serial)
    }

    /// bridgeUnreachable の3択。**走査から切り離した純粋関数**(reconcilePort/bridgeVanished と
    /// 同じ理由: 実ブリッジが要るとこの判定はテストで一度も両方向を通らず、壊しても素通しする)。
    /// bound(誰かが listen している)は vanished より優先する —— busy なブリッジは scan にも
    /// 載らない(bridgeVanished は true になる)ので、bound を見ずに vanished だけで決めると
    /// busy を死と誤判定する。**ただし bound は無条件に信じない**(trustBound 参照。欠陥④:
    /// 実機は listen を iproxy が引き継ぐため、ランナー死後も bound は true のまま残る)
    enum BridgeUnreachableVerdict: Equatable { case busy, vanished, stillUnclear }

    static func bridgeUnreachableVerdict(
        bound: Bool, ownerAlive: Bool?, vanished: Bool
    ) -> BridgeUnreachableVerdict {
        if trustBound(bound: bound, ownerAlive: ownerAlive) { return .busy }
        return vanished ? .vanished : .stillUnclear
    }

    /// bound(誰かが listen している)をそのまま信じてよいか。**判定はここ1箇所** ——
    /// iosConnectionLostHint(走査を省くかどうか)と bridgeUnreachableVerdict(.busy を返すか)の
    /// 両方がこれを使う。`ownerAlive == false` のときだけ疑う —— `nil`(pid ファイルが無い =
    /// in-app ブリッジ等、判定材料が無い)は疑わない側に倒す(仮想デバイスの in-app 経路を
    /// 巻き添えにしないため)
    static func trustBound(bound: Bool, ownerAlive: Bool?) -> Bool {
        bound && ownerAlive != false
    }

    /// `.ftester/bridge-<port>.pid`(xcodebuild の pid。BridgeLauncher.pidPath と同じ規約)の
    /// 所有プロセスが生きているか。ファイルが無い/読めない/pid が数値でなければ nil(不明)。
    /// **実機の usb トランスポートでは listen しているのがランナーでなく iproxy(別プロセス)** —
    /// isBound だけではランナー死後も true のままなので、この判定で補強する(欠陥④)
    static func bridgeOwnerAlive(port: UInt16, repoRoot: URL?) -> Bool? {
        guard let repoRoot,
              let pidString = try? String(
                  contentsOf: repoRoot.appendingPathComponent(".ftester/bridge-\(port).pid"),
                  encoding: .utf8),
              let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return kill(pid, 0) == 0
    }

    /// bound(誰かが listen している)なポートへ「exited」と言わないための正直な文言。
    /// **forgetConnection も呼ばない**呼び手側の判断とセットで使う(iosConnectionLostHint 参照)。
    /// **エンジンで文面を出し分ける**(2026-08-12): in-app/hybrid ブリッジは対象アプリが
    /// 前面のときしか応答しない(kernel が handshake を返すので isBound は true のまま)ので、
    /// XCUITest 向けの「busy・リトライせよ」は永遠に的外れな助言になる
    static func bridgeBusyHint(connection: String, engine: String?) -> String {
        guard engine == "inapp" || engine == "hybrid" else {
            return "\nThe XCUITest runner behind \(connection) did not answer in time, but the"
                + " port is still bound — likely busy (a long-running operation, such as waiting"
                + " for the screen to settle, can block the bridge for tens of seconds). Retry the"
                + " call; the connection was not dropped."
        }
        return "\nThe in-app bridge behind \(connection) is not answering — it only answers while"
            + " the app it is injected into is in the foreground. Bring it back with ft_launch,"
            + " or use this device's xcuitest bridge port instead."
    }

    /// 死んだ接続の udid を、**手元にある scan 結果**から端末名へ引き直す(best-effort)。
    /// 失敗しても黙る —— `connectionLostMessage` の「同じ端末を先に」が効かず、
    /// 通し番号での畳み方に落ちるだけ。
    /// **SimulatorCatalog を再照会しない**(2026-08-12): 呼び手は既に `running`(BridgeDiscovery.scan
    /// の結果)を持っており、カタログ名とブリッジ申告名がズレると「同じ機を先頭に」が壊れる
    static func deviceName(forUDID udid: String?, in running: [BridgeDiscovery.Found]) -> String? {
        guard let udid else { return nil }
        return running.first { $0.udid == udid }?.device
    }

    /// タイムアウトのとき「そのブリッジは消えた」と言い切ってよいか。**走査から切り離した
    /// 純粋関数** —— 実ブリッジが要ると、この枝はテストで一度も実行されず、判定を壊しても
    /// 素通しする(`reconcilePort` が 2026-08-09 の変異テストで実際に踏んだのと同じ型)
    static func bridgeVanished(port: UInt16, running: [BridgeDiscovery.Found]) -> Bool {
        !running.contains { $0.port == port }
    }

    /// 掴んでいたドライバは死んでいる。次の呼び出しで解決し直させる。
    /// **記憶(lastExplicitIOSTarget/lastExplicitAndroidSerial)も一致すれば一緒に忘れる**
    /// (2026-08-12): resolveIOSPort/resolveAndroidSerial は記憶されたポート/serial を生存確認
    /// なしで返す(driver() 参照)ので、ここで消さないと、死んだ接続の後の省略呼び出しが
    /// 同じ死んだポート/serial へ永久に再ダイヤルし続ける。**internal**(テストが直接呼ぶ)
    func forgetConnection(_ key: String) {
        if let port = connectedPorts[key] {
            if lastExplicitIOSTarget?.port == port { lastExplicitIOSTarget = nil }
            // 消えたポートは「このセッションで触った他の候補」として名乗る意味が無い
            // (rememberedDeviceNote が曖昧さの判定に使う集合。生きているものだけ残す)
            seenExplicitIOSPorts.remove(port)
        }
        // **`connections[key]` の書式から抽出しない**(2026-08-14): profile 経由のラベルは
        // "<device name> serial <serial>" で `hasPrefix("serial ")` に一致せず、profile で
        // 触った Android 機は記憶が一度も消えなかった(connectionLostHint と同じ根の欠陥)
        if let serial = connectedAndroidSerials[key] {
            if lastExplicitAndroidSerial == serial { lastExplicitAndroidSerial = nil }
            seenExplicitAndroidSerials.remove(serial)
        }
        forgetDeviceState(key)
    }

    /// engineKey に紐づく状態を**全部**捨てる(2026-08-13)。
    ///
    /// **なぜ「ドライバだけ」では足りないか**: engineKey は `direct:ios:<port>:<serial>` で、
    /// iOS のポートは**同じセッション中に動く**(監視が別ポートで建て直す。実測: -03 が
    /// 8128→8126、-07 が 8136→8147)。つまり**一度死んだポートが後で別のシミュレータに
    /// 再利用され得る**。`forgetConnection` が drivers/connections/connectedPorts しか
    /// 消していなかったので、そのとき `lastSnapshots` と `refGenerations` は**前の機の木**、
    /// `launchedBundleIDs` は**前の機で起動したアプリ**のまま生き残っていた ——
    /// 古い ref が別の機の木を起点に解決され、`ft_open_url` が前の機のアプリへ配送する。
    /// 出力がずれるだけの記憶(注記・フィルタ)と違い、**これは操作が別物へ届く型**なので
    /// 「キーが指す機が変わったら全部捨てる」を1箇所に固める。
    ///
    /// **`nextRefBase` だけは残す**(単調増加の不変条件)。ここで 0 へ戻すと、捨てた世代と
    /// 同じ base が新しい世代へ再配布され、セッション内で ref が一意という保証が壊れる ——
    /// 世代管理そのものが防いでいる「番号は同じだが別要素」を、後始末の側から作ってしまう。
    ///
    /// **engineKey で引く記憶を新設したらここへ足す**。足し忘れは
    /// `DeviceStateInvalidationTests.testEveryEngineKeyedMemoIsAccountedForHere` が検出する
    /// (`MCPServer.swift` の `[String: …]` を走査して、この関数か `deliberatelyKept` の
    /// どちらにも現れない名前を落とす)—— この後始末は網羅が本体なので、1つ漏れると
    /// 「ほとんど捨てたが1つだけ前の機のまま」という最も分かりにくい形になる
    func forgetDeviceState(_ key: String) {
        drivers[key] = nil
        connections[key] = nil
        connectedPorts[key] = nil
        connectedAndroidSerials[key] = nil
        engines[key] = nil
        udids[key] = nil
        versionSkew[key] = nil
        lastSnapshots[key] = nil
        refGenerations[key] = nil
        launchedBundleIDs[key] = nil
        uiFrameworkHints[key] = nil
        lastScreenshots[key] = nil
        rememberedSnapshotFilters[key] = nil
        sheetRescueFutile[key] = nil
        pendingWarnings[key] = nil
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
            // ③実機専用のポート記録(`.ftester/bridge-<port>.device`。`port:` だけで実機を指した
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
            let explicitBundleID = args["bundleId"] as? String
            let openURLBundleID = explicitBundleID ?? launchedBundleIDs[Self.engineKey(args)]
            // installedState は撃たない: simctl openurl/devicectl openURL・am start は OS の URL
            // ルーティングで、installedState が守っている XCUIApplication.launch() のランナー死
            // (ft_launch のコメント参照)とは経路が別
            // **既定で着地を待つ**(2026-08-16 の外部評価)。URL の配送は非同期なので、
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
                              // ヒントなので、的の外れた推測を並べて紛らわせない(2026-08-10)
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
                // **「入っている値」の判定は DSL と同じ**(2026-08-13)。素の `value` を見ていたので、
                // `placeholder` と同値の空欄(iOS 全般 / Android の CMP)でも MCP だけが
                // 追記警告を出していた —— StepExecutor は normalizedValue で黙る側
                priorValue = priorElement.map(TypeReadback.normalizedValue)
                // **入力欄でないものへ打とうとしていないか**(2026-08-14)。判定は DSL と共有
                // (TypeReadback.nonInputTargetNote。実測と理由はそちらの doc)。
                // MCP は StepExecutor を経由しない別経路なので、ここにも配線が要る
                if let priorElement,
                   let elements = lastSnapshots[Self.engineKey(args)]?.elements,
                   let warn = TapTargetGeometry.nonInputTypeTargetNote(priorElement, in: elements) {
                    note = note.isEmpty ? " (warning: \(warn))"
                        : note + " (warning: \(warn))"
                }
            }
            // **replace は文字が空でも clear する**(2026-08-12): {replace:true, text:""} や
            // {replace:true, pressEnter:true} は「クリアだけ」「クリア+Enter」を成立させるための
            // 書き方で、スキーマも "Clear the field before typing" と約束している。下の入力分岐
            // (文字が非空のときだけ通る)の内側に置くと、空文字はそこへ一度も入らず黙って
            // 何もしない(スキーマの約束を破る)
            if wantsReplace {
                try await typeDriver.clearInput(ref: targetRef.map { nativeRef($0, args: args) })
            }
            // **replace + snapshotAfter(Enter を伴わない形)は同じ木を2回読まない**(2026-08-12):
            // この組み合わせでは検証が読みたい瞬間(clear/type 直後)と snapshotAfter が読みたい
            // 瞬間が同じなので、snapshotAfterBodyWithStatus を先に1回だけ実行し、成功していれば
            // その木(lastSnapshots)を検証にも使う。失敗時だけ生読みへフォールバックする。
            // **pressEnter を伴う形は対象外**: Enter の前後で状態が変わるので、検証は Enter 前に
            // 読む必要があり(下の呼び出し位置のまま)、最終的に返す木は Enter 後でなければならない
            // —— そもそも2回読む理由がある(この最適化を適用すると Enter 前の古い木を返す)
            // 追記(replace なし)も読み返して確かめるので、同じ merge の対象にする(2026-08-13)。
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
                    // 操作後の木になってしまい「変化なし」と誤報する(2026-08-10)
                    let rawAfterType = try? await typeDriver.snapshot(
                        bypassingCache: typeDriver.supportsCacheBypass)
                    note += await Self.typedIntoNote(driver: typeDriver, expected: content,
                                                     snapshot: rawAfterType)
                }
                if wantsReplace {
                    // **無条件の「replaced」を断言しない**(2026-08-12): clearInput → type の後、
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
                // (2026-08-12): 読み返して期待どおり(空)/マスク/残存の3形に分ける
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
            // **未指定は今までと1バイトも変えない**(全画面固定の既定経路)
            guard args["scrollFrame"] != nil else {
                try await swipeDriver.swipe(direction)
                recordInteraction(action: "swipe", resolvedRef: nil, args: args,
                                  direction: direction.rawValue)
                // **「動いた」と断言しない**(back と同じ理由。2026-08-06)。スワイプは端に着いていれば
                // 1px も動かないし、スクロールできない画面では何も起きない
                return text("swipe \(direction.rawValue) sent."
                    + Self.changedHint(args, otherwise: " If anything moved, the old refs are stale"
                        + " — take a fresh ft_snapshot before using any ref")
                    + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(args)))
            }

            // **探索(ft_scroll_to)と同じ StepExecutor に委ねる**(DSL の
            // scrollDown/scrollUp/scrollLeft/scrollRight(scrollFrame:) と同じ FlowStep 形。
            // ScrollGeometry の呼び出し・マージン定数・容器解決・fail-fast は全部あちらに
            // 1本化されている — MCP に2つ目の実装を作らない。**実機で確認した実害**
            // (2026-08-12): MCP から driver.swipe(_:intent:path:) を直に叩くと、in-app
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
            let executor = StepExecutor(driver: swipeDriver, releasesScrollTouch: !isAndroid,
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
            let beforeBackElements = target == "back"
                ? lastSnapshots[Self.engineKey(args)]?.elements : nil
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
                    // **撮り直しに成功した回だけ判定する**(2026-08-12): snapshotAfterBody が
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
                        in: doubleTapSnapshot?.elements ?? []))
                    + RefGuard.overlapWarning(found: element, in: doubleTapSnapshot?
                        .elements ?? [], screen: doubleTapSnapshot?.screen
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

    /// 実体は `FTCore.SelectorNaming.asWritten`(2026-08-15 に移設。needsEscaping/computeGraded が
    /// 使うため SelectorNaming と一緒に FTCore へ移った)。ここは呼び出し元の綴りを変えないための転送
    static func asWritten(_ selector: String) -> String {
        SelectorNaming.asWritten(selector)
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

    /// `ft_open_url` の1行目。**snapshotAfter の有無で出し分ける**(2026-08-12):
    /// 木を返すのに「ft_snapshot を撃ち直せ」と言うのは矛盾するので、そちらは待ち方の案内に替える。
    /// **配送が非同期であることは黙らない** —— settle-lite は**操作前の木を覚えているときしか
    /// 走らない**ので、`ft_launch` 直後(記憶が無い)の `snapshotAfter` は遷移前の画面を
    /// 何の断りもなく返し得る(2026-08-12 のレビュー指摘)
    /// **推測した宛先は推測と分かる形で言う**(2026-08-13): `bundleId` を省くと
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
            // **既定が「待つ」に変わった**(2026-08-16)。以前は配送直後に読んでいたので
            // 前の画面が返り得た。待っても着地しなかったことは waitForChange の注記が言う
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
            + Self.homeScreenLaunchHint(snapshot.sessionBundleID)
    }

    /// ホーム画面(ランチャ)で「安定セレクタが無い」と言われた相手への次の手(2026-08-15 の外部評価)。
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

    /// 操作を1手ぶん記録する(F)。**E と同じ `SelectorNaming` でセレクタを決める** ——
    /// 戻り値に出したセレクタと、下書きに書かれるセレクタが食い違わないようにするため。
    ///
    /// セレクタを解決できなかった手も**捨てずに**残す(`unresolved`)。落とすと、
    /// 出来上がったシナリオが実際の手順と食い違う(F-4)
    /// 記録した手のセレクタを**どの木で名付けるか**(2026-08-13)。
    ///
    /// **`lastSnapshots` は「最後に読んだ木」であって「その ref が属する木」ではない。**
    /// 記録より先に撮り直す経路がある —— `ft_type` は入力の読み返しと `snapshotAfter` を
    /// 記録の前に通すので、そこでは ref は別世代の番号になっている。実機の観測:
    ///
    ///     REC action=tap  ref=14 refs=1,2,3,…    → 引ける
    ///     REC action=type ref=21 refs=26,27,28,… → 引けない(木が入力後の世代)
    ///
    /// 引けないと `// TODO: no stable selector — type` として下書きへ落ちる ——
    /// **`#id` を持つ欄でも**。Google メッセージの `#ContactSearchField` で 3/3 再現し、
    /// 修正後は 2/2 で `type("#ContactSearchField", …)` になった。
    ///
    /// **世代が無いときだけ最新の木へ落ちる**(世代を持たない経路 = 座標タップ等は従来どおり)。
    ///
    /// **配線(ここを呼ぶこと)も単体テストで守っている**(`DraftTypeSelectorTests`)。
    /// ただし台本には条件がある —— **操作後の木の顔ぶれを変えること**。`adoptSnapshot` は
    /// identity(ref/type/identifier/label)が同じなら世代を使い回すので、`value` だけが
    /// 変わる木では ref が進まず**欠陥そのものが起きない**(最初に書いたテストはこれで
    /// 空回りし、変異が生き残った)。詳細は FakeDriver.scriptedSnapshots の罠の項
    static func namingSnapshot(ref: Int, generation: SnapshotResponse?,
                               latest: SnapshotResponse?) -> SnapshotResponse? {
        if let generation, generation.elements.contains(where: { $0.ref == ref }) { return generation }
        return latest
    }

    func recordInteraction(action: String, resolvedRef: Int?, args: [String: Any],
                           text: String? = nil, direction: String? = nil,
                           coordinate: (x: Double, y: Double)? = nil,
                           duration: Double? = nil, scale: Double? = nil,
                           replace: Bool = false) {
        var selector: String?
        var durability: Durability = .stable
        var described = "\(action)"
        // **ref が属する世代の木で名付ける**(2026-08-13)。`lastSnapshots` は「最後に読んだ木」で、
        // **記録より先に撮り直す経路がある**(ft_type は入力の読み返し・snapshotAfter を
        // 記録の前に通す)。そこを見ると ref は別世代の番号なので引けず、**#id を持つ欄でも
        // 下書きが `// TODO: no stable selector — type` になる**。実機の観測:
        //   REC action=tap  ref=14 refs=1,2,3,…   → 引ける
        //   REC action=type ref=21 refs=26,27,28,… → 引けない(木が入力後の世代)
        // 世代を先に見て、無ければ従来どおり最新の木へ落ちる
        if let resolvedRef,
           let snapshot = Self.namingSnapshot(
               ref: resolvedRef, generation: generationSnapshot(containing: resolvedRef, args: args),
               latest: lastSnapshots[Self.engineKey(args)]),
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
        // **座標タップは行にできる**(2026-08-16。DSL の `tap(x:y:)`)。以前は TODO 行へ落ちて
        // いたが、それは書ける形が無かったからで、今は 1:1 で書き出せる。
        // **ただし用途で重みが違う**(ユーザー方針): 対話中の探索では座標のほうが速いことがあるが、
        // **シナリオに残す目的ならセレクタが最優先**。下書きは実行できる行を出したうえで、
        // 置き換えるべきであることを行末コメントに残す(ScenarioCodeGen が `step.note` を出す)
        if action == "tap", selector == nil, let coordinate {
            var step = FlowStep(action: "tap", x: coordinate.x, y: coordinate.y)
            step.duration = duration
            step.note = "coordinates — replace with a selector before keeping this;"
                + " a layout change makes it hit something else"
            interactions.record(InteractionLog.Entry(step: step, unresolved: nil,
                                                     summary: described))
            return
        }
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
        step.replace = replace ? true : nil
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
    /// (テストの独立性を保つ: 同じ static 関数を単体で呼ぶテストは常に満額の文を見る)。
    /// **full/short は @autoclosure**(2026-08-12): 呼び出し側は素の式を渡すだけでよく、
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
    /// **closure 形**(2026-08-12): 呼び手はどちらを出すかだけを決める1つの render を渡し、
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
                + " (\(info.platform ?? "ios/android"), app: \(info.app ?? "from the run profile"))"
                + (info.deleted ? " [deleted @Deleted — excluded from bulk runs]"
                   : (info.draft ? " [draft @Draft — excluded from bulk runs]" : ""))
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
        // 「この機械の登録名」は廃止したので出さない(ProfileResolver.determineMachine の宣言)。
        // 使うマシンプロファイルは実行プロファイルの machine が決めるため、下の一覧で足りる
        var lines: [String] = []
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

    /// DSL コマンド索引(`ftester api dsl-commands` と同じ出典 = Sources/FTCore/CommandIndex.swift)。
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
