// MCPServer+Driver.swift
// ドライバ解決(エンジン・ポート/シリアル・版ズレゲート)と接続系の注記。本体は MCPServer.swift(instance 状態はそちらに置く)

import Foundation
import FTAgent
import FTAndroid
import FTBridgeClient
import FTCore
import FTDSL

extension MCPServer {

    // MARK: - ドライバ

    // **実行と同じエンジンで探索する**のが原則(揃えないと snapshot もジェスチャの成否も食い違う)。
    // profile 指定時は resolveProfileTarget が ft_run_scenario と同じデバイスを解決し、iosDriver が
    // プロファイルのエンジンに追従する。profile 無しの iOS は ExploreDriverResolver が
    // 稼働中ブリッジを見て決める(in-app が居れば hybrid を組む・居なければ XCUITest)
    func driver(_ args: [String: Any]) async throws -> AppDriver {
        if let makeDriver {
            // 差し替えドライバのエンジンは分からない。**助言が出る側(xcuitest)を既定**にする
            // (テストは engines を先に埋めて別のエンジンを名乗れる)
            let key = Self.engineKey(args)
            if engines[key] == nil {
                engines[key] = (args["platform"] as? String) == "android" ? "android" : "xcuitest"
            }
            let driver = try await makeDriver(args)
            // **差し替え経路でもゲートを通せるようにする**(G): 素通しにすると拒否そのものが
            // 一度も実行されず、文言だけ検証して安心する形になる。ただし既定は off ——
            // 版照合は status() を1回撃つので、呼び出し列を固定している既存テストが軒並みずれる。
            // 実運用(makeDriver 無し)の経路は下で**常に**通る
            if checksVersionOnInjectedDriver {
                try await enforceVersion(driver: driver, key: key, args: args)
            }
            return driver
        }
        if let profileName = args["profile"] as? String {
            let key = Self.driverCacheKey(profile: profileName, project: args["project"] as? String,
                                          platform: args["platform"] as? String)
            if let cached = drivers[key] { return cached }
            let project = try ScenarioHost.project(named: args["project"] as? String)
            var prologue: [String] = []
            // profile 指定の初回はブリッジ provision を伴い、コールドスタートは分単位かかりうる
            // (既存ブリッジ再利用時は数秒。進捗は stderr に出る)
            let (_, _, target) = try await resolveProfileTarget(
                project: project, profileName: profileName,
                platformArg: args["platform"] as? String, prologue: &prologue)
            prologue.forEach(Self.logStderr)
            // **警告を stderr に捨てない**(外部フィードバック 2026-08-06)。MCP クライアントは
            // stderr を見ないので、「runs の name が machines のデバイスに解決できない」等の
            // 設定ミスが**実行するまで表に出なかった**。次の応答に1度だけ載せる
            pendingWarnings[key] = prologue.filter { $0.hasPrefix("⚠️") }
            let created: AppDriver
            switch target {
            case .ios(let provisioned, let iosApp):
                created = try await Self.iosDriver(provisioned: provisioned, bundleID: iosApp?.bundleID)
            case .android(let serial, _):
                created = try AndroidDriver(serial: serial)
            }
            drivers[key] = created
            engines[key] = {
                if case .ios(let provisioned, _) = target { provisioned.physical ? "xcuitest" : provisioned.engine }
                else { "android" }
            }()
            if case .ios(let provisioned, _) = target { udids[key] = provisioned.udid }
            // engine=xcuitest はブリッジが uiFramework を申告しないが、profile 経由なら
            // 対象 bundleID が分かるのでバンドルのマーカーで判定して覚える(scroll_to の
            // 空打ちゲート用。DSL の xcuitest 経路と同じ判定 = AppBundleInspector)
            if case .ios(let provisioned, let iosApp) = target, !provisioned.physical,
               engines[key] == "xcuitest", let bundleID = iosApp?.bundleID,
               let hint = AppBundleInspector.detect(
                   udid: provisioned.udid, bundleID: bundleID, physical: false) {
                uiFrameworkHints[key] = hint
            }
            // **profile 経由でも宛先を記録する**(2026-08-06)。ここが空だと ft_status が
            // 「どこに繋がっているか」を出せず、**同名のデバイスが並ぶフリートでどの1台か
            // 分からない** —— Android の status.device は全エミュレータで
            // `sdk_gphone64_arm64` になるので、serial が出ないと識別子がゼロになる
            connections[key] = switch target {
            case .ios(let provisioned, _):
                "\(provisioned.simulatorName) port \(provisioned.port)"
            case .android(let serial, let deviceName):
                "\(deviceName) serial \(serial)"
            }
            // **profile 経由もゲートを通す**(G-2 の「全操作系」): BridgeProvisioner が版で
            // 再利用可否を決めるので普段はここで落ちないが、**落ちないことと検査しないことは別**
            // —— 供給の判断とホストの期待がズレた回に、黙って旧ブリッジを操作させない
            try await enforceVersion(driver: created, key: key, args: args)
            return created
        }

        let platform = (args["platform"] as? String)
            ?? ProcessInfo.processInfo.environment["FTESTER_PLATFORM"]
            ?? "ios"
        // **udid → port の解決はここ1箇所**(H-2)。port は残す(既存の呼び出しを壊さない)
        let explicitPort = try await Self.portForIOS(args)
        let key = Self.driverCacheKey(platform: platform, port: explicitPort.map(Int.init),
                                      serial: args["serial"] as? String)
        if let cached = drivers[key] { return cached }
        let created: AppDriver
        switch platform {
        case "ios":
            let port = try await Self.resolveIOSPort(explicit: explicitPort)
            let resolved = await ExploreDriverResolver.resolve(
                preferred: port, repoRoot: try? RepoRoot.find(),
                logger: { Self.logStderr($0) })
            created = resolved.driver
            engines[key] = resolved.engine
            udids[key] = resolved.udid
            connections[key] = "port \(port)"
            // **稼働中のブリッジが古いままではないか**を1度だけ確かめる(2026-08-06 に踏んだ)。
            // profile 経由は BridgeProvisioner が版で再利用可否を決めるが、**この経路は
            // 生きているポートへ素で繋ぐだけ**なので、版を上げても旧ランナーが使われ続ける。
            // 実害: ブリッジ側の修正2件を入れて版も上げたのに、ft_snapshot は直る前の木を
            // 返し続け、`bridge down && bridge up` するまで「直っていない」に見えた。
            // Android は AndroidBridge が expectedBridgeVersionCode で入れ替えるのでこの穴が無い
            try await enforceVersion(driver: created, key: key, args: args)
        case "android":
            let serial = try Self.resolveAndroidSerial(explicit: args["serial"] as? String)
            created = try AndroidDriver(serial: serial)
            engines[key] = "android"
            connections[key] = "serial \(serial)"
        default:
            throw MCPError("platform must be ios or android: \(platform)")
        }
        drivers[key] = created
        return created
    }

    /// 版ズレを既定で拒否する(G)。押し通しは `allowVersionSkew: true` で、その場合は
    /// **毎回の応答に警告が付き続ける**(1度言って黙らない)。
    /// 拒否したときは覚えたドライバを捨てる —— 建て直した後に古い判定が残らないように
    func enforceVersion(driver: AppDriver, key: String, args: [String: Any]) async throws {
        guard let skew = await Self.bridgeVersionSkew(driver: driver) else {
            versionSkew[key] = nil
            return
        }
        versionSkew[key] = skew
        guard args["allowVersionSkew"] as? Bool == true else {
            drivers[key] = nil
            throw MCPError(skew)
        }
        pendingWarnings[key, default: []].append(Self.skewOverrideWarning(skew))
    }

    /// 繋いだブリッジの版が食い違っているときの文。一致・判定不能なら nil。
    ///
    /// **既定は拒否**(G。2026-08-09 に方針を反転した): 以前は警告だけで通していたが、
    /// MCP の出力はシナリオへ書く文字列を供給するためにあるので、**古いブリッジの出す古い注記から
    /// 誤ったセレクタが書き込まれる**ほうが「セッションが止まる」より高くつく。
    /// アドホック探索なら警告で足りるが、生成が目的だとそうではない。
    ///
    /// **どちらが新しいかを明示する**(G-4): 対処が変わる ——
    /// ブリッジが古い = 建て直す / ホストが古い = こちらを建て直す(or pull)。
    /// **判定できないときは黙る**(旧ブリッジは版を返さない = nil。それを「古い」と断じると常時警告)
    static func bridgeVersionSkew(driver: AppDriver) async -> String? {
        guard let running = try? await driver.status().protocolVersion,
              running != BridgeAPI.bridgeProtocolVersion else { return nil }
        let expected = BridgeAPI.bridgeProtocolVersion
        let side = running > expected
            ? "the bridge is NEWER than this build (v\(running) > v\(expected)) —"
                + " your ftester-mcp binary is stale, so rebuild it"
                + " (swift build --product ftester-mcp) or pull"
            : "the bridge is OLDER than this build (v\(running) < v\(expected)) —"
                + " restart it with `ftester bridge down --all && ftester bridge up`"
        return "bridge protocol mismatch: \(side)."
            + " Refusing to operate: a stale bridge answers with the behaviour and the notes of"
            + " its own version, and selectors written from those notes are silently wrong."
            + " Pass allowVersionSkew: true to proceed anyway."
    }

    /// 版ズレのまま押し通されたときに毎回付ける警告(G-3)。**1度言って黙らない** ——
    /// 押し通した事実は、その後の全応答の信頼度に掛かり続ける
    static func skewOverrideWarning(_ skew: String) -> String {
        "⚠️ allowVersionSkew: proceeding despite a bridge/host mismatch. \(skew)"
    }


    /// `udid` / `port` から iOS の宛先ポートを決める(H-2)。**両方渡されたら port を優先**し、
    /// **食い違うなら明示的に失敗する** —— 黙ってどちらかを採ると、読み手は指したつもりの
    /// デバイスと別の機を操作したことに最後まで気付けない。
    /// どちらも無ければ nil(従来どおり resolveIOSPort が既定ポート → 探索の順で決める)
    static func portForIOS(_ args: [String: Any]) async throws -> UInt16? {
        let port = (args["port"] as? Int).map(UInt16.init)
        guard let udid = (args["udid"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else {
            return port
        }
        return try reconcilePort(port, udid: udid, udidPort: await bridgePort(forUDID: udid))
    }

    /// `port` と `udid` の突き合わせ。**走査から切り離した純粋関数** —— 実ブリッジが要ると
    /// 「食い違い」の枝がテストで一度も実行されず、判定を壊しても素通しする
    /// (2026-08-09 の変異テストで実際に素通しした)
    static func reconcilePort(_ port: UInt16?, udid: String, udidPort: UInt16?) throws -> UInt16? {
        guard let udidPort else {
            throw MCPError("no running bridge is on udid \(udid)."
                + " ft_list_devices shows which devices have one; start it with"
                + " `ftester bridge up` (a device without a bridge cannot be driven from MCP)")
        }
        guard let port else { return udidPort }
        guard port == udidPort else {
            throw MCPError("port \(port) and udid \(udid) point at different devices"
                + " (that udid is on port \(udidPort)). Pass only one of them")
        }
        return port
    }

    /// udid を申告している稼働中ブリッジのポート。**申告が無いブリッジ(旧版)は素通し** ——
    /// 「見つからない」と「そのブリッジは答えられない」を混ぜないため、見つからなければ nil
    static func bridgePort(forUDID udid: String) async -> UInt16? {
        for found in await BridgeDiscovery.scan(excluding: 0, repoRoot: try? RepoRoot.find()) {
            guard let client = try? BridgeClient(port: found.port),
                  let status = try? await client.status(), status.udid == udid else { continue }
            return found.port
        }
        return nil
    }

    /// profile 無しの iOS 宛先。**明示 port は探索しない**(利用者が宛先を決めている)。
    /// 既定ポートが死んでいるのは珍しくない —— `bridge up` は稼働中ブリッジの再利用や
    /// pid ファイルの残りで別ポートを選ぶ(FTester.swift の警告)
    static func resolveIOSPort(explicit: UInt16?) async throws -> UInt16 {
        if let explicit { return explicit }
        let preferred = BridgeAPI.defaultPort
        let repoRoot = try? RepoRoot.find()
        if await BridgeDiscovery.isAlive(port: preferred, repoRoot: repoRoot) { return preferred }
        // **応答なしを死と読まない**: 待受が続いているなら乗り換え先は別デバイスになる
        let bound = BridgeDiscovery.isBound(port: preferred, repoRoot: repoRoot)
        let found = bound ? [] : await BridgeDiscovery.scan(excluding: preferred, repoRoot: repoRoot)
        switch BridgeDiscovery.decide(preferredAlive: false, preferredBound: bound, found: found) {
        case .usePreferred:
            return preferred
        case .preferredBusy:
            throw MCPError(BridgeDiscovery.busyMessage(preferred: preferred))
        case .adopt(let bridge):
            logStderr(BridgeDiscovery.adoptedNote(preferred: preferred, found: bridge))
            return bridge.port
        case .none:
            throw MCPError(BridgeDiscovery.noBridgeMessage(preferred: preferred))
        case .ambiguous(let bridges):
            throw MCPError(BridgeDiscovery.ambiguousMessage(preferred: preferred, found: bridges))
        }
    }

    /// profile 無しの Android 宛先。**serial 無しで adb を撃たない**(複数台なら
    /// "more than one device/emulator" が生で出る)
    static func resolveAndroidSerial(explicit: String?) throws -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        let serials = AndroidSerialResolver.connectedSerials()
        switch AndroidSerialResolver.decide(explicit: nil, connected: serials) {
        case .use(let serial):
            logStderr(AndroidSerialResolver.adoptedNote(
                AndroidSerialResolver.describe(serials: [serial])[0]))
            return serial
        case .none:
            throw MCPError(AndroidSerialResolver.noDeviceMessage)
        case .ambiguous(let devices):
            throw MCPError(AndroidSerialResolver.ambiguousMessage(
                AndroidSerialResolver.describe(serials: devices.map(\.serial))))
        }
    }

    /// profile 経由の iOS ドライバ。**実行プロファイルのエンジンに追従する**(2026-08-04。
    /// それ以前は常に XCUITest だった —— StepExecutor を通らない ft_* が in-app では
    /// home/drag/座標 press で素の 501 になるためで、その穴は HybridFallbackDriver が埋めた)。
    /// エンジンを揃える理由は**探索と実行で見えるものを一致させる**こと: snapshot の内容も
    /// ジェスチャの成否もエンジンで変わるので、揃えないと「MCP では動いたのにシナリオでは falls」
    /// (およびその逆)が起きる。
    ///
    /// 合成は実行側(ScenarioRunnerMain)と同じ形:
    ///   in-app(注入) → WebView 画面だけ XCUITest へ委譲 → 不可な操作だけ XCUITest へ回す
    /// **hybrid でないとき(inapp 単独・xcuitest・実機)は素の1本**にする
    static func iosDriver(provisioned: ProvisionedIOSDevice, bundleID: String?) async throws -> AppDriver {
        guard !provisioned.physical, provisioned.engine == "inapp" || provisioned.engine == "hybrid" else {
            // xcuitest(と実機)は従来どおり。resolve は接続先が in-app だったときの振り替えも担う
            let resolution = await XCUIBridgeResolver.resolve(
                preferred: provisioned.port, repoRoot: try? RepoRoot.find(),
                logger: { Self.logStderr($0) })
            // **実機は UDID を渡す**: install/uninstall は simctl ではなく devicectl が要り、
            // clearAppData は「実機では不可」と即答できる(渡さないとデバイス名で simctl を
            // 撃つことになり、的外れな失敗になる)
            return SessionRecoveryDriver(base: BridgeClient(
                port: resolution.endpoint.port, host: resolution.endpoint.host,
                physicalUDID: provisioned.physical ? provisioned.udid : nil))
        }
        let inapp = InAppDriver(repoRoot: try RepoRoot.find(), udid: provisioned.udid,
                                port: provisioned.port)
        guard provisioned.engine == "hybrid", let xcuiPort = provisioned.xcuiPort,
              let bundleID else {
            return inapp
        }
        // attach は**同じインスタンス**を委譲とフォールバックの両方に使う(実行側と同じ理由:
        // activate/attached 状態を1本にしないと余計な activate が挟まる)
        let attach = AppAttachDriver(port: xcuiPort, bundleID: bundleID)
        return HybridFallbackDriver(primary: WebViewDelegatingDriver(primary: inapp, delegated: attach),
                                    fallback: attach, primaryBundleID: bundleID,
                                    foreignApp: SessionRecoveryDriver(base: BridgeClient(port: xcuiPort)))
    }

    /// **実際に主となったエンジンが XCUITest のときだけ**添える切り分け。XCUITest では
    /// 成立しないジェスチャがあり(表と実測は docs/commands.md)、何も起きなかったときに
    /// 原因が分からないと詰む。**Android と in-app/hybrid には付けない**(前者はこの制限が
    /// 無く、後者は成立する。無関係な助言は誤誘導になる)。
    /// エンジンは driver(_:) が記録する = **推測しない**(profile 無しでも稼働中の in-app
    /// ブリッジを掴めば hybrid になるため、引数だけからは決まらない)
    /// **1文に圧縮**(2026-08-08): UIKit アプリでも xcuitest エンジンなら毎回この助言が出ており、
    /// 長文の苦情があった。「in-app は起動し直る」制約(dylib は起動時にしか差し込めない。
    /// 2026-08-06 に実際に踏んだ: マップ画面で double tap → ホームから `#nav_scroll` が開いた)
    /// は末尾に畳み込む
    func iosEngineHint(_ framework: String, _ gesture: String, args: [String: Any]) -> String {
        guard engines[Self.engineKey(args)] == "xcuitest" else { return "" }
        // `ftester bridge up --engine inapp` と案内しない —— そのフラグは存在しない
        // (in-app ブリッジは in-app/hybrid の実行プロファイル経由でだけ立つ。2026-08-08 に確認)
        return " If nothing changed on iOS: \(framework) apps do not receive \(gesture) on the"
            + " XCUITest engine — pass profile: naming an in-app/hybrid run profile, which starts"
            + " an in-app bridge (this relaunches the app — re-navigate before retrying)."
    }

    /// **launch する前に**確かめる。未インストールのまま `XCUIApplication.launch()` を撃つと、
    /// XCUI が記録する issue が(main queue 上 = テストのスタック外なので)ランナーごと落とし、
    /// ブリッジが消える —— 2026-08-06 の外部フィードバック #7 の真因はこれで、
    /// 「Safari 操作後に切断」に見えていたのは**別ポートで先に死んでいたランナー**だった。
    /// requireLiveApp と同じ形(XCUI に触れる前に弾いて手前でエラーにする)。
    ///
    /// ブリッジ側は未インストールと未起動を区別できない(XCUIApplication はどちらも notRunning)
    /// のでホストが確かめる。**確かめられないときは nil = 素通し**(実機・同名デバイス複数・
    /// simctl/adb 不調。断定しない側に倒す)。iOS のシステムアプリ(springboard/Safari)も
    /// get_app_container が runtime のパスを返すので誤って弾かない(2026-08-06 実測)
    func installedState(bundleID: String, driver: AppDriver) async -> Bool? {
        // 差し替えドライバ(テスト)ではデバイスを照会しない = simctl/adb を撃たない
        guard makeDriver == nil else { return nil }
        if let android = driver as? AndroidDriver {
            let installed = android.isInstalled(bundleID: bundleID)
            if installed == nil { Self.logStderr(Self.uncheckedNote(bundleID: bundleID, reason: "adb")) }
            return installed
        }
        guard let device = try? await driver.status().device else {
            Self.logStderr(Self.uncheckedNote(bundleID: bundleID, reason: "the bridge did not report a device"))
            return nil
        }
        switch InstalledAppCheck.simulatorInstallVerdict(deviceName: device, bundleID: bundleID) {
        case .installed: return true
        case .notInstalled: return false
        case .unknown(let reason):
            // **素通しは必ず言う**: 黙って通すと、ランナーが死んでから原因を探すことになる
            Self.logStderr(Self.uncheckedNote(bundleID: bundleID, reason: reason))
            return nil
        }
    }

    static func uncheckedNote(bundleID: String, reason: String) -> String {
        "could not verify whether \(bundleID) is installed (\(reason)) — launching anyway."
            + " If it is missing, the XCUITest runner will exit and this bridge will disappear."
    }

    static func notInstalledMessage(bundleID: String) -> String {
        "\(bundleID) is not installed on this device."
            + " Install it with ft_install packagePath: <.app or .apk>, or check the bundle ID"
            + " (Android: the package name)."
    }

    /// XCUITest のセッションは**そのアプリに閉じている**ので、ホーム画面やシステム UI は
    /// 素では読めない。ただし**読む方法はある**(springboard 参照セッション。BridgeRouter の
    /// handleLaunch が bundleID=com.apple.springboard を非破壊で特別扱いする)。
    /// 詰まる2つの応答 —— セッション不在の 409 と、背面アプリ照会の kAXErrorServerNotFound ——
    /// にだけ足す(2026-08-06 フィードバック #6)。
    /// **in-app/hybrid には付けない**: in-app ブリッジは注入先アプリ専用で springboard を掴めない
    static func springboardHint(_ error: Error, engine: String?) -> String {
        guard engine == nil || engine == "xcuitest" else { return "" }
        guard case DriverError.badResponse(let status, let body) = error,
              status == 409 || (status == 500 && body.contains("kAXErrorServerNotFound")) else {
            return ""
        }
        return "\nTo read the home screen or a system dialog instead of the app,"
            + " ft_launch bundleId: com.apple.springboard — it attaches to SpringBoard without"
            + " launching anything, and ft_snapshot then returns the home screen."
            + " ft_launch your app again to go back."
    }

    /// home 直後の XCUITest は「セッションはアプリのまま・画面はホーム」になり、次の
    /// ft_snapshot がアプリの古い木か 500 を返す。**先に言う**(踏んでから調べさせない)
    static func homeScreenReadNote(target: String, engine: String?) -> String {
        guard target == "home", engine == nil || engine == "xcuitest" else { return "" }
        return ". The session still points at the app, so ft_snapshot cannot read the home screen"
            + " — ft_launch bundleId: com.apple.springboard first (non-destructive)"
    }

    /// back が**空振りし得る**ことと、**アプリの外へ出る**ことの2つを言う。
    /// iOS は端の swipe(`XCUIApplication` の navigation gesture)なので、画面側が
    /// システムの戻るを実装していないと 1px も動かない。Android は最初の画面からの back で
    /// アプリが終了し、前面が別アプリになる(`switchedAppNote` が次の snapshot で捕まえる)
    static func backNoOpNote(target: String, engine: String?) -> String {
        guard target == "back" else { return "" }
        let iosNote = engine == "android" ? ""
            : " On iOS this is an edge swipe: screens with their own in-app back button"
                + " (and no system navigation) do not move at all."
        return "." + iosNote
            + " If it was the app's first screen, back leaves the app and the tools follow"
            + " whatever is in front now — ft_launch to come back."
    }

    /// **in-app 経路で背面化すると、以降は XCUITest ブリッジ側が受ける**
    /// (in-app ブリッジはアプリのプロセス内に住み、suspend されると応答しない。
    /// 寄せ替えは HybridFallbackDriver が持つ)。XCUITest は外側のプロセスなので関係なく、
    /// back は前面のままなので関係ない
    static func backgroundedAppNote(target: String, engine: String?) -> String {
        guard target != "back", engine == "inapp" || engine == "hybrid" else { return "" }
        return ". The app is in the background now, so the tools run through the XCUITest bridge"
            + " (slower reads, and the snapshot still describes the app itself)"
            + " until you bring it back with ft_launch"
    }

    /// 待ちの既定(秒)。**DSL の defaultTimeout と同じ 5**(FTRuntime)。揃えておかないと
    /// 「MCP では出たのにシナリオでは間に合わない」が起きる
    static let defaultWaitSeconds: Double = 5

    /// ポーリング間隔(秒)。短くしても律速は snapshot 自体(iOS in-app で約 0.12s)
    private static let waitPollSeconds: Double = 0.3

    /// selector が出るまで snapshot を撃ち直す。**照合は DSL と同じ**(FTSelector →
    /// StepExecutor)なので、ここで書ける式はそのままシナリオへ持ち込める。
    ///
    /// **完全一致が出るまで満額待つ**(2026-08-10。案B): 周回ごとに部分一致の有無だけ
    /// (`notationHint` はメモリ上の計算で往復を払わない)見て、最初に見えた経過秒とヒントを
    /// 覚える。**早期打ち切りはしない** —— ローディング中のプレースホルダが部分一致で先に出て、
    /// 本命が後から来る画面があるため(打ち切ると本命を待ち損ねる)
    /// `refetched`: 撃ち直しが1回でも起きたか(2026-08-10 の ref 世代管理で追加)。false のとき
    /// `snapshot` は引数 `first` そのもの(値も ref 番号も変わっていない)。呼び手はこれを見て
    /// `adoptSnapshot` を通すかどうかを決める —— **通さないと世代が進まない従来どおりの結果に
    /// なるだけで無害だが、通すと事故る**: `first` は既にセッション ref(base 込み)なので、
    /// native 前提の adoptSnapshot にそのまま渡すと素の native と誤認して余計な世代を作る
    static func waitFor(_ selector: String, driver: AppDriver, first: SnapshotResponse,
                        seconds: Double) async throws
        -> (found: Bool, snapshot: SnapshotResponse, partialSeenAfter: Double?, partialHint: String,
            refetched: Bool) {
        var partialSeenAfter: Double?
        var partialHint = ""
        func notePartial(_ snapshot: SnapshotResponse, elapsed: Double) {
            guard partialSeenAfter == nil else { return }
            let hint = notationHint(selector, in: snapshot)
            guard !hint.isEmpty else { return }
            partialSeenAfter = elapsed
            partialHint = hint
        }
        if matches(selector, in: first) { return (true, first, nil, "", false) }
        notePartial(first, elapsed: 0)
        let start = Date()
        let deadline = start.addingTimeInterval(seconds)
        var latest = first
        var refetched = false
        while Date() < deadline {
            try await Task.sleep(for: .seconds(waitPollSeconds))
            // **キャッシュを捨てて撮る**: 同じ木を読み続けると、出ていても永遠に出ない
            latest = driver.supportsCacheBypass
                ? try await driver.snapshot(bypassingCache: true) : try await driver.snapshot()
            refetched = true
            if matches(selector, in: latest) { return (true, latest, nil, "", true) }
            notePartial(latest, elapsed: Date().timeIntervalSince(start))
        }
        // ループが1周も回らなかった(seconds <= 0 等)ときは latest === first のまま = 未撃ち直し
        return (false, latest, partialSeenAfter, partialHint, refetched)
    }

    /// セレクタ式(`#id` / ラベル / `.type` / `||` 等)がこの画面に1つでも当たるか
    static func matches(_ selector: String, in snapshot: SnapshotResponse) -> Bool {
        let parsed = FTSelector.parse(selector)
        return ([parsed.primary] + parsed.fallbacks).contains { locator in
            !(StepExecutor.resolvedCandidates(locator, elements: snapshot.elements) ?? []).isEmpty
        }
    }

    /// 要素木の軽量指紋(ft_navigate の back 判定・ft_screenshot の鮮度判定で使う)。
    /// **定義元は FTCore.StaleFrameDetector.treeFingerprint**(DSL の occlusion-guard と共有)。
    /// ref を含めない理由・単独では拾えない限界はそちらのコメント参照
    static func treeFingerprint(_ snapshot: SnapshotResponse) -> Int {
        StaleFrameDetector.treeFingerprint(of: snapshot.elements)
    }

    /// PNG 生バイトのハッシュ(ft_screenshot の鮮度判定用)。定義元は FTCore.StaleFrameDetector.hashBytes
    static func hashBytes(_ data: Data) -> Int {
        StaleFrameDetector.hashBytes(data)
    }

    /// セッションのアプリが前面に居ないときの注記(居るとき・判定できないときは空)。
    /// 判定は 1 往復(/appstate)なので snapshot の1割程度。**黙って嘘を返すよりは安い**
    static func backgroundedSessionNote(_ snapshot: SnapshotResponse,
                                        driver: AppDriver) async -> String {
        guard let bundleID = snapshot.sessionBundleID,
              let foreground = try? await driver.isAppForeground(bundleID: bundleID),
              !foreground else { return "" }
        return "\(bundleID) is NOT in the foreground: this tree is its last state, not what is on"
            + " screen now (another app or a system screen is in front)."
            + " Bring it back with ft_launch before trusting these refs\n"
    }

    /// システムダイアログのパッケージ/バンドル ID。これらへの切り替わりは「別アプリに迷い込んだ」
    /// ではなく「対象アプリの上にシステム UI が出ている」なので、案内を変える(欠陥⑧)。
    /// 実測: 位置情報の許可ダイアログ(permissioncontroller)で通常の案内(ft_launch し直す)に
    /// 従うと、ダイアログを放置したままアプリを再起動してループした
    static let systemDialogPackages: Set<String> = [
        "com.google.android.permissioncontroller", "com.android.permissioncontroller",
        "com.android.packageinstaller", "com.google.android.packageinstaller",
        "com.android.systemui",
    ]

    /// **この木は ft_launch したアプリのものか**。違えば名指しで止める。
    ///
    /// `backgroundedSessionNote` と役割が違う: あちらは「session のアプリが背面」を見るが、
    /// **session 自体が別アプリへ移ってしまう経路**(Android)ではあちらは永遠に沈黙する。
    /// ここは「起動したもの」対「木が名乗るもの」を比べるので、session が追従しても捕まる。
    ///
    /// **判定材料が無いときは黙る**(嘘を足さない): ft_launch していない・木が名乗らない。
    static func switchedAppNote(launched: String?, snapshot: SnapshotResponse) -> String {
        guard let launched, let session = snapshot.sessionBundleID, session != launched else {
            return ""
        }
        // springboard は ft_launch bundleId: com.apple.springboard がホーム画面へ attach する
        // 正規の使い方(ツール説明に明記)なので、その用途を否定しない文言にする
        if session == "com.apple.springboard" {
            return "⚠️ This tree is the home screen (springboard), not \(launched)."
                + " Reading it is fine — ft_launch bundleId: com.apple.springboard is the supported"
                + " way to attach there — but ft_launch \(launched) first if you meant to keep"
                + " testing the app.\n"
        }
        if systemDialogPackages.contains(session) {
            return "⚠️ \(session) is a system dialog drawn over \(launched)"
                + " (e.g. a permission prompt), not the app itself. Operate the dialog"
                + " (tap its buttons, or back) to get back to \(launched) — ft_launch restarts"
                + " the app and leaves the dialog on screen, so you would loop without progress.\n"
        }
        return "⚠️ This tree belongs to \(session), NOT the app you launched (\(launched))."
            + " Leaving the app (back from its first screen, home, an app switch) hands the"
            + " tools to whatever is in front now — and sibling test apps can look identical."
            + " ft_launch \(launched) before trusting these refs\n"
    }
}
