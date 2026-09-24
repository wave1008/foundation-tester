// MCPServer+SessionTools.swift
// セッション・端末・アプリの管理系ツール(status / list_* / logs / install / launch / open_url / terminate / clear_app_data / doctor)。入口の振り分けは MCPServer+Dispatch.swift の dispatch

import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore

extension MCPServer {

    func ftStatus(_ args: [String: Any]) async throws -> [[String: Any]] {
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
    }

    func ftListDevices(_ args: [String: Any]) async throws -> [[String: Any]] {
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
    }

    func ftListApps(_ args: [String: Any]) async throws -> [[String: Any]] {
        // driver() を先に通す: profile 指定の解決(provision)と udids の記録がここで済み、
        // 直指定でも同じ宛先選択規則に乗る
        let appsDriver = try await driver(args)
        let appsFilter = (args["filter"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // **filter を渡したら既定で system も探す**: 絞り込む唯一の動機は「あのアプリを
        // 見つける」ことで、端末に載っている地図・ブラウザは system 側に居る。既定のままだと
        // 「入っていない」という誤った空振りになる(2026-08-09 に実測して adb へ落ちた)。
        // 明示の includeSystem: false は尊重する
        let includeSystem = args["includeSystem"] as? Bool ?? (appsFilter != nil)
        if let android = appsDriver as? AndroidDriver {
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
    }

    func ftLogs(_ args: [String: Any]) async throws -> [[String: Any]] {
        let logBundleID = try Self.stringArgument(args, "bundleId", emptyHint: Self.attachedAppEmptyHint)
            ?? lastLaunchedBundleID(args)
        // **ブリッジには一切問い合わせない**(CrashLogs の存在理由はまさにブリッジごと
        // 落ちた直後に使うこと)。唯一のブリッジ非依存な実機の手掛かりは
        // `.fleetest/bridge-<port>.device`(BridgeDeviceRecord。実機のときだけ書かれる)で、
        // port は明示引数かこのセッションが覚えている宛先(connectedPorts。driver() を経由した
        // 呼び出しで埋まる)から取る。**どちらも取れなければ nil = 実機でない証拠にはならない
        // ので従来どおり待つ**(best-effort)
        let logsPort = try Self.portArgument(args) ?? connectedPorts[Self.engineKey(args)]
        let logsPhysicalUDID = Self.platformName(args) == "ios"
            ? logsPort.flatMap { port in
                (try? RepoRoot.find()).flatMap { BridgeDeviceRecord.load(port: port, repoRoot: $0) }
            }
            : nil
        return text(await CrashLogs.text(
            platform: Self.platformName(args),
            bundleID: logBundleID,
            serial: args["serial"] as? String,
            withinSeconds: try Self.intArgument(args, "sinceSeconds") ?? 300,
            maxLines: try Self.intArgument(args, "lines") ?? 100,
            crashOnly: (args["all"] as? Bool) != true,
            physicalUDID: logsPhysicalUDID))
    }

    func ftInstall(_ args: [String: Any]) async throws -> [[String: Any]] {
        let packagePath = try Self.requiredStringArgument(args, "packagePath")
        let installKey = Self.engineKey(args)
        try await driver(args).install(packagePath: packagePath)
        // ft_clear_app_data が実機で uninstall+install に化けるときの再インストール元
        // (installedPackagePaths 参照)
        installedPackagePaths[installKey] = packagePath
        // インストール直後の初回起動で権限アラートが出ることがある(systemAlertProbePending 参照)
        systemAlertProbePending.insert(installKey)
        // **既に起動していたアプリの上書きインストールは、たいてい実行中のプロセスを止める**
        // (§19.3 M2)。次の snapshot が switchedAppNote 経由で「クラッシュしたかも」と
        // 誤診しないよう、原因をこの操作へ帰属させておく(ft_launch で消える)
        if launchedBundleIDs[installKey] != nil {
            toolStoppedBundleIDs[installKey] = "ft_install"
        }
        return text("Installed: \(packagePath)")
    }

    func ftLaunch(_ args: [String: Any]) async throws -> [[String: Any]] {
        let bundleID = try Self.requiredStringArgument(args, "bundleId")
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
        // **撃つ前に弾く**(ランナー死の予防。installedVerdict/launchGuardDecision のコメント参照)
        let installVerdict = await installedVerdict(bundleID: bundleID, driver: launchDriver, args: args)
        if let refusal = Self.launchGuardDecision(
            verdict: installVerdict, isAndroid: launchDriver is AndroidDriver,
            engine: engines[launchKey], bundleID: bundleID) {
            throw MCPError(refusal)
        }
        // 確かめられないまま撃つ経路(Android・in-app)は記録に残す
        if case .unknown(let reason) = installVerdict {
            Self.logStderr(Self.uncheckedNote(bundleID: bundleID, reason: reason))
        }
        if resumes {
            try await launchDriver.activate(bundleID: bundleID)
        } else {
            try await launchDriver.launch(bundleID: bundleID)
        }
        // 以後の snapshot は「これの木か」を突き合わせられる(switchedAppNote)
        launchedBundleIDs[launchKey] = bundleID
        launchTimestamps[launchKey] = Date()
        // 再起動した以上、以後の不在は今回の ft_clear_app_data/ft_install のせいではない
        toolStoppedBundleIDs[launchKey] = nil
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
        recordAction(InteractionLog.Entry(
            step: nil, unresolved: nil, isLaunch: !resumes, bundleID: bundleID,
            platform: launchDriver is AndroidDriver ? "android" : "ios",
            summary: resumes ? "activate \(bundleID) (resumed, not relaunched)"
                              : "launch \(bundleID)"), args: args)
        return text(resumes ? "Activated: \(bundleID) (resumed without relaunching)"
                             : "Launched: \(bundleID)")
    }

    func ftOpenUrl(_ args: [String: Any]) async throws -> [[String: Any]] {
        let url = try Self.requiredStringArgument(args, "url")
        let openURLDriver = try await driver(args)
        let explicitBundleID = try Self.stringArgument(
            args, "bundleId", emptyHint: Self.attachedAppEmptyHint)
        let openURLBundleID = explicitBundleID ?? launchedBundleIDs[Self.engineKey(args)]
        // installedVerdict は撃たない: simctl openurl/devicectl openURL・am start は OS の URL
        // ルーティングで、installedVerdict/launchGuardDecision が守っている
        // XCUIApplication.launch() のランナー死(ft_launch のコメント参照)とは経路が別
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
        recordAction(InteractionLog.Entry(step: openStep, unresolved: nil,
                                          summary: "openURL \"\(url)\""), args: args)
        return text(Self.openURLSummary(url: url, bundleID: openURLBundleID,
                                        bundleIDWasRemembered: explicitBundleID == nil,
                                        snapshotAfter: args["snapshotAfter"] as? Bool == true,
                                        waitFor: args["waitFor"] as? String,
                                        waitForChangeExplicit: args["waitForChange"] as? Bool)
            + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(openURLArgs)))
    }

    func ftClearAppData(_ args: [String: Any]) async throws -> [[String: Any]] {
        let bundleID = try Self.requiredStringArgument(args, "bundleId")
        let clearAppDataDriver = try await driver(args)
        let clearAppDataKey = Self.engineKey(args)
        do {
            try await clearAppDataDriver.clearAppData(bundleID: bundleID)
        } catch let clearError where ReinstallSource.isClearAppDataUnsupported(clearError) {
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
            launchTimestamps[clearAppDataKey] = nil
            systemAlertProbePending.insert(clearAppDataKey)
            return text("Reinstalled \(bundleID) from \(path) (physical device: app data"
                + " wiped by uninstall + install; permission grants are reset too)")
        }
        // 次の ft_launch が初回起動と同じ扱いになる(systemAlertProbePending 参照)
        systemAlertProbePending.insert(clearAppDataKey)
        // この呼び出しでアプリを止めた事実を記録する(§19.3 M2)。launchedBundleIDs は
        // ここでは消さない(再インストール分岐と違い bundleID はまだ同じアプリのまま —
        // 次の ft_launch は「初回起動」ではなく「再起動」)。switchedAppNote がこれを見て
        // 「クラッシュしたかも」ではなく「この操作で止めた」と言う
        toolStoppedBundleIDs[clearAppDataKey] = "ft_clear_app_data"
        return text("Cleared the data of \(bundleID). The app is stopped — ft_launch to continue")
    }

    func ftTerminate(_ args: [String: Any]) async throws -> [[String: Any]] {
        // **対象が分からなければ黙って何もしないのではなく、名指しで断る**(§19.3 M3):
        // ドライバの terminate() は Android では currentPackage が無いと何も撃たずに
        // 戻る(AndroidDriver.terminate)。target を知らずに「Terminated the app」と
        // 答えると、何も終了させていないのに成功したと誤解させる
        // **ドライバの terminate() は名指しできない**(attach 中のアプリを止めるだけ)。明示の
        // bundleId が起動中のアプリと違えば断り、起動していない台への明示指定は「送った」まで
        // しか言わない(Android は currentPackage が無ければ何も撃たない)
        let terminateKey = Self.engineKey(args)
        let explicitBundleID = try Self.stringArgument(args, "bundleId", emptyHint: Self.attachedAppEmptyHint)
        guard let terminateBundleID = explicitBundleID ?? launchedBundleIDs[terminateKey]
        else {
            throw MCPError("no known target to terminate — nothing was launched in this"
                + " session and no bundleId was given. Pass bundleId, or ft_launch first.")
        }
        if let explicitBundleID, let launched = launchedBundleIDs[terminateKey],
           explicitBundleID != launched {
            throw MCPError("this session launched \(launched), and ft_terminate can only stop the"
                + " app it is attached to — omit bundleId (or pass \(launched)) to stop that app")
        }
        let terminateUnverified = explicitBundleID != nil && launchedBundleIDs[terminateKey] == nil
        try await driver(args).terminate()
        // 意図して落としたので、以後の別アプリの木は「すり替わり」ではない
        launchedBundleIDs[terminateKey] = nil
        launchTimestamps[terminateKey] = nil
        toolStoppedBundleIDs[terminateKey] = nil
        systemAlertProbePending.remove(terminateKey)
        // 前面が消えたので、覆い探針の記憶(F 節)は使い回さない
        lastScreenProbe[terminateKey] = nil
        return text(terminateUnverified
            ? "Terminate sent for \(terminateBundleID) (nothing was launched in this session, so the"
                + " driver stopped whichever app it is attached to — on Android nothing is stopped"
                + " without a prior ft_launch; nothing about the result is checked)"
            : "Terminated \(terminateBundleID)")
    }

    func ftDoctor(_ args: [String: Any]) async throws -> [[String: Any]] {
        let fm = await FMDoctor.checkLive()
        // **視覚系も実呼び出しで確かめる**(能力判定では足りない。text と vision は独立に死ぬ)
        let vision = await FMDoctor.visionCheckLive()
        return text((fm.available ? "✅ " : "❌ ") + fm.detail
            + (fm.available ? "" : "\n   " + FMDoctor.unavailableImpact)
            + "\n" + (vision.available ? "✅ " : FMVisionSupport.isSupported ? "❌ " : "⚠️ ") + vision.detail)
    }
}
