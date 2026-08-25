// MCPServer+Driver.swift
// ドライバ解決(エンジン・ポート/シリアル・版ズレゲート)と接続系の注記。本体は MCPServer.swift(instance 状態はそちらに置く)

import Foundation
import FTAgent
import FTAndroid
import FTBridgeClient
import FTCore

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
            // **直接ポート経路と同じ確認を通す**(2026-08-13 の掃討)。profile 経由でもブリッジは
            // 建て直され、そのとき同じ profile キーが別の機を指し得る —— 片方だけ守ると
            // 「profile を使う利用者にだけ穴が残る」形になる
            if let cached = drivers[key] {
                if let moved = await deviceIdentityChanged(key, args: args) { throw MCPError(moved) }
                // **profile のキャッシュ命中でも記憶を更新する**(欠陥②・2026-08-14): 下の
                // direct 経路のキャッシュ命中と同じ理由(rememberResolvedTarget のコメント参照)。
                // platform 変数はここではまだ無い(resolveProfileTarget を経ていない)ので、
                // connectionLostHint と同じく **記録(connectedPorts/connectedAndroidSerials)で
                // 判別する**(表示ラベルの接頭辞では判別しない、と同じ規律)。iosPort は生成側と
                // 揃えて `connectedPorts[key]` をそのまま渡す(そちらに実機は
                // `probePort ?? provisioned.port` が既に入っている)
                if connectedPorts[key] != nil {
                    rememberResolvedTarget(platform: "ios", args: args,
                                           iosPort: connectedPorts[key], iosUDID: udids[key] ?? nil,
                                           androidSerial: nil)
                } else if let serial = connectedAndroidSerials[key] {
                    rememberResolvedTarget(platform: "android", args: args,
                                           iosPort: nil, iosUDID: nil, androidSerial: serial)
                }
                return cached
            }
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
            var probePort: UInt16?
            switch target {
            case .ios(let provisioned, let iosApp):
                (created, probePort) = try await Self.iosDriver(
                    provisioned: provisioned, bundleID: iosApp?.bundleID)
            case .android(let serial, _):
                created = try AndroidDriver(serial: serial)
            }
            drivers[key] = created
            engines[key] = {
                if case .ios(let provisioned, _) = target { provisioned.physical ? "xcuitest" : provisioned.engine }
                else { "android" }
            }()
            // **udid と port を両方記録する**(port は 2026-08-13 に追加)。`deviceIdentityChanged`
            // はこの2つが揃っているときだけ動くので、**port を書かないとガードが黙って no-op になる**
            // (直接ポート経路で実際に踏んだ形。DeviceStateInvalidationTests が両方を守る)。
            // **記録するのは `provisioned.port` ではなく実際に繋いだ loopback ポート**
            // (`iosDriver` の probePort。理由はあちらの doc)—— 誤ったポートを記録すると
            // ガードが無関係な機のブリッジを読み、正しい呼び出しを拒否して記憶まで捨てる
            if case .ios(let provisioned, _) = target {
                // **生成経路でも機の入れ替わりを見る**(2026-08-13 のレビュー指摘)。
                // キャッシュ命中側だけに置くと、`enforceVersion` の拒否(`drivers[key]` だけを
                // nil にする)のあとブリッジが別のフリート機へ建て直された回に、
                // 前の機の ref 世代と起動アプリが生き残る(直接ポート経路と同じ手当て)
                if let previousUDID = Self.keyChangedDevice(previous: udids[key] ?? nil,
                                                            now: provisioned.udid) {
                    forgetDeviceState(key)
                    pendingWarnings[key, default: []].append(
                        Self.reusedPortWarning(port: probePort ?? provisioned.port,
                                               previousUDID: previousUDID,
                                               nowUDID: provisioned.udid ?? ""))
                }
                udids[key] = provisioned.udid
                // **実機は probePort が常に nil**(loopback 経由ではないため。iosDriver 参照)。
                // それをそのまま記録すると connectionLostHint の入口(connectedPorts の有無で
                // iOS/Android を振り分ける)が実機の profile 呼び出しを一度も iOS 経路に乗せず、
                // 回復(forgetConnection)が永久に起きない
                connectedPorts[key] = probePort ?? provisioned.port
            }
            if case .android(let serial, _) = target {
                connectedAndroidSerials[key] = serial
            }
            // engine=xcuitest はブリッジが uiFramework を申告しないが、profile 経由なら
            // 対象 bundleID が分かるのでバンドルのマーカーで判定して覚える(scroll_to の
            // 空打ちゲート用。DSL の xcuitest 経路と同じ判定 = AppBundleInspector)
            if case .ios(let provisioned, let iosApp) = target, !provisioned.physical,
               engines[key] == "xcuitest", let bundleID = iosApp?.bundleID,
               let hint = AppBundleInspector.detect(
                   udid: provisioned.udid, bundleID: bundleID, physical: false) {
                uiFrameworkHints[key] = hint
            }
            // **profile 経由でも宛先を記録する**。ここが空だと ft_status が
            // 「どこに繋がっているか」を出せず、**同名のデバイスが並ぶフリートでどの1台か
            // 分からない** —— Android の status.device は全エミュレータで
            // `sdk_gphone64_arm64` になるので、serial が出ないと識別子がゼロになる
            connections[key] = switch target {
            case .ios(let provisioned, _):
                "\(provisioned.simulatorName) port \(provisioned.port)"
            case .android(let serial, let deviceName):
                "\(deviceName) serial \(serial)"
            }
            // **profile 経由もセッション記憶へ記録する**(ここを呼ばないと profile 経由の宛先が
            // 一度も記憶されない)。args は
            // port/udid/serial ではなく `profile` を持つので、記録可否は recordsIOSMemory/
            // recordsAndroidMemory 側で `profile:` を明示扱いする(上記参照)。
            // **iOS は probePort でなく `probePort ?? provisioned.port` を使う**: 実機は
            // loopback 経由ではないため probePort が常に nil(iosDriver 参照)——
            // それをそのまま渡すと実機の宛先が rememberResolvedTarget の `guard let iosPort` で
            // 弾かれ、実機がまた記録されなくなる
            switch target {
            case .ios(let provisioned, _):
                rememberResolvedTarget(platform: "ios", args: args,
                                       iosPort: probePort ?? provisioned.port,
                                       iosUDID: provisioned.udid, androidSerial: nil)
            case .android(let serial, _):
                rememberResolvedTarget(platform: "android", args: args,
                                       iosPort: nil, iosUDID: nil, androidSerial: serial)
            }
            // **profile 経由もゲートを通す**(G-2 の「全操作系」): BridgeProvisioner が版で
            // 再利用可否を決めるので普段はここで落ちないが、**落ちないことと検査しないことは別**
            // —— 供給の判断とホストの期待がズレた回に、黙って旧ブリッジを操作させない
            try await enforceVersion(driver: created, key: key, args: args)
            return created
        }

        // **engineKey と同じ解決を使う**(Self.platformName): ここに2つ目の既定を書くと、
        // 「どのドライバを作るか」と「どの鍵で覚えるか」が食い違う。実際 serial だけの
        // 呼び出しは、記憶側が Android と読むのにドライバは iOS を作っていた
        let platform = Self.platformName(args)
        // **udid → port の解決はここ1箇所**(H-2)。port は残す(既存の呼び出しを壊さない)
        let explicitPort = try await Self.portForIOS(args)
        let key = Self.driverCacheKey(platform: platform, port: explicitPort.map(Int.init),
                                      serial: args["serial"] as? String)
        if let cached = drivers[key] {
            // **キャッシュ命中のドライバが、まだ同じ機を指しているかを確かめる**。
            // engineKey は `direct:ios:<port>:` で、**port は機の同一性ではない** ——
            // ブリッジを建て直すと同じ port が別のシミュレータのものになる。実機で再現:
            // 8123 で機A の木を採った後、`bridge down --port 8123` → `bridge up --device 機B
            // --port 8123` としてから**同じセッション**で古い ref を撃つと、
            // `tap [4] done`(成功)で**機B の同名要素を叩いた**。
            // 生成時の `keyChangedDevice` では防げない —— この間セッションは1回も呼んでおらず
            // `forgetConnection` が走らないので、**ドライバはキャッシュ命中し生成が起きない**。
            // 「死んだブリッジなら失敗経路が拾う」も誤り: 新しいブリッジは正常に応答する。
            if let moved = await deviceIdentityChanged(key, args: args) {
                throw MCPError(moved)
            }
            // **キャッシュ命中でも記憶を更新する**(2026-08-12 の実アプリ監査で踏んだ)。
            // 記録を「ドライバを生成したとき」に紐付けると、2度目に同じ機を明示した呼び出しは
            // ここで返って記憶を動かさず、**A→B→A のあとの省略呼び出しが B へ行く**。
            // 実害: iOS を明示 launch した直後の無指定 ft_snapshot が Android のツリーを返し、
            // 注記は「最も新しいターゲット = <Android>」と名乗った(直前の明示は iOS なので嘘)。
            // 失敗モードが沈黙(黙って別 OS の機を操作する)なので、生成の有無に依らせない
            rememberResolvedTarget(platform: platform, args: args,
                                   iosPort: connectedPorts[key] ?? explicitPort, iosUDID: udids[key] ?? nil,
                                   androidSerial: args["serial"] as? String)
            return cached
        }
        let created: AppDriver
        switch platform {
        case "ios":
            // **記憶の適用はここでは行わない**: dispatch 入口(call() の
            // foldInRememberedDevice)が省略呼び出しへ既に port/udid を差し込んでいるので、
            // ここに来る時点で args は明示指定と区別が付かない。ここでは解決後の値を
            // 「記録」するだけにする(rememberResolvedTarget) —— 適用と記録を二重に持たない
            let port = try await Self.resolveIOSPort(explicit: explicitPort)
            let resolved = await ExploreDriverResolver.resolve(
                preferred: port, repoRoot: try? RepoRoot.find(),
                logger: { Self.logStderr($0) })
            // **このキーが前と別の機を指し始めていたら、キーの記憶を全部捨てる**。
            // ドライバを作り直す経路は forgetConnection(ここは既に forgetDeviceState 済み)
            // だけではない —— 版ズレ拒否(enforceVersion)も drivers[key] だけを nil にするので、
            // そちらを通った後は木・ref 世代・起動アプリが前の機のまま残る。
            // 判定は port ではなく **udid**(キーに入っている port は再利用され得るが、
            // udid は機そのもの)。**どちらかが不明なときは何もしない** —— 「分からない」を
            // 「変わった」と読むと、udid を採れない構成で毎回記憶が飛ぶ
            if let previousUDID = Self.keyChangedDevice(previous: udids[key] ?? nil,
                                                        now: resolved.udid) {
                forgetDeviceState(key)
                pendingWarnings[key, default: []].append(
                    Self.reusedPortWarning(port: port, previousUDID: previousUDID,
                                           nowUDID: resolved.udid ?? ""))
            }
            created = resolved.driver
            engines[key] = resolved.engine
            udids[key] = resolved.udid
            // **宛先は port だけでなく udid まで書く**(2026-08-12 の実アプリ監査): ブリッジは
            // 落ちても monitor が別ポートで建て直すので、**同じセッション中にポートが動く**
            // (実測: -03 が 8128→8126、-07 が 8136→8147)。port だけを覚えて使い回す読み手は、
            // その port が今どの機かを確かめる手段が無かった
            connections[key] = Self.connectionLabel(port: port, udid: resolved.udid)
            connectedPorts[key] = port
            rememberResolvedTarget(platform: "ios", args: args,
                                   iosPort: port, iosUDID: resolved.udid, androidSerial: nil)
            // **稼働中のブリッジが古いままではないか**を1度だけ確かめる(2026-08-06 に踏んだ)。
            // profile 経由は BridgeProvisioner が版で再利用可否を決めるが、**この経路は
            // 生きているポートへ素で繋ぐだけ**なので、版を上げても旧ランナーが使われ続ける。
            // 実害: ブリッジ側の修正2件を入れて版も上げたのに、ft_snapshot は直る前の木を
            // 返し続け、`bridge down && bridge up` するまで「直っていない」に見えた。
            // Android は AndroidBridge が expectedBridgeVersionCode で入れ替えるのでこの穴が無い
            try await enforceVersion(driver: created, key: key, args: args)
        case "android":
            // iOS と同じ理由で記憶の「適用」は入口(foldInRememberedDevice)側だけに置く
            let explicitSerial = args["serial"] as? String
            let serial = try Self.resolveAndroidSerial(explicit: explicitSerial)
            created = try AndroidDriver(serial: serial)
            engines[key] = "android"
            connections[key] = "serial \(serial)"
            connectedAndroidSerials[key] = serial
            rememberResolvedTarget(platform: "android", args: args,
                                   iosPort: nil, iosUDID: nil, androidSerial: serial)
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
    /// **既定は拒否**(警告だけで通さない):
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


    /// ft_status の `@ …` に出す宛先の表記(純粋関数・テスト用)。**udid が分からないブリッジ
    /// (申告しない旧版)では port だけ** —— 「不明」と書くより短く、嘘も混ざらない。
    /// **表示専用**: `connectionLostHint` の経路判別は `connectedPorts`/
    /// `connectedAndroidSerials` の記録を見るので、ここの書式を変えても判定には影響しない
    static func connectionLabel(port: UInt16, udid: String?) -> String {
        guard let udid, !udid.isEmpty else { return "port \(port)" }
        return "port \(port) (udid \(udid))"
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
        return try reconcilePort(port, udid: udid, udidPorts: await bridgePorts(forUDID: udid))
    }

    /// `port` と `udid` の突き合わせ。**走査から切り離した純粋関数** —— 実ブリッジが要ると
    /// 「食い違い」の枝がテストで一度も実行されず、判定を壊しても素通しする
    /// (2026-08-09 の変異テストで実際に素通しした)。
    /// **udid 側は複数ポートを許す**: 同じシミュレータに in-app / XCUITest の
    /// 2本が立つのが常態で、先頭の1本とだけ比べると正しい併記(udid + その in-app port)を
    /// 「別デバイス」と誤って拒否する(Simulator で 3/3 再現)
    static func reconcilePort(_ port: UInt16?, udid: String, udidPorts: [UInt16]) throws -> UInt16? {
        guard !udidPorts.isEmpty else {
            throw MCPError("no running bridge is on udid \(udid)."
                + " ft_list_devices shows which devices have one; start it with"
                + " `ftester bridge up` (a device without a bridge cannot be driven from MCP)")
        }
        guard let port else { return udidPorts.first }
        guard udidPorts.contains(port) else {
            let list = udidPorts.map(String.init).joined(separator: ", ")
            // **「別デバイス」と断定しない**: この分岐は「その port が udid の走査結果に無い」
            // だけで、別デバイスの port とは限らない —— 背面化した in-app ブリッジは
            // /status に答えず走査から消える(実測: Maps を launch した後の RN の in-app)
            throw MCPError("port \(port) is not a bridge answering on udid \(udid)"
                + " — it is another device's bridge, or a bridge that stopped answering"
                + " (an in-app bridge suspends when its app leaves the foreground, so it cannot"
                + " drive other apps — use the device's xcuitest port for those)."
                + " Answering bridge(s) on that udid:"
                + " port \(list). Pass only one of port/udid, or use one of those ports")
        }
        return port
    }

    /// udid を申告している稼働中ブリッジのポート(走査順・全部)。**申告が無いブリッジ(旧版)は
    /// 素通し** —— 「見つからない」と「そのブリッジは答えられない」を混ぜないため。
    /// **scan の応答をそのまま濾すだけ**: scan は全ポートへ並列 timeout 2s で
    /// 既に status を撃っており、その StatusResponse は udid を含む(BridgeDTO.swift)
    static func bridgePorts(forUDID udid: String) async -> [UInt16] {
        await BridgeDiscovery.scan(excluding: 0, repoRoot: try? RepoRoot.find())
            .filter { $0.udid == udid }.map(\.port)
    }

    /// **iOS の明示ターゲット述語**。args に有効な udid(非空文字列)または port(Int)があるか。
    /// **キーの存在ではなく値を見る**: `args["udid"] != nil` は `udid: ""` を
    /// 「指定あり」と誤読する非対称を生む(Android の serial は元から isEmpty で見ている)。
    /// **driver() のキャッシュキー判定・記憶の適用可否(foldInRememberedDevice)・
    /// 記憶の記録可否(iosMemoryAfterResolve 呼び出し側)はすべてこの1つを通す**
    static func argsGaveIOSTarget(_ args: [String: Any]) -> Bool {
        let udid = (args["udid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return udid != nil || args["port"] is Int
    }

    /// Android 版の同じ述語(serial)
    static func argsGaveAndroidTarget(_ args: [String: Any]) -> Bool {
        (args["serial"] as? String).flatMap { $0.isEmpty ? nil : $0 } != nil
    }

    /// **fold が注入した呼び出しかどうかの目印**。foldInRememberedDevice が
    /// 省略呼び出しへ port/serial を差し込むとき一緒に立てる —— スキーマ検証後にしか付かず、
    /// engineKey(platform/port/serial/profile しか見ない)にも影響せず、ブリッジへ渡る辞書にも
    /// 漏れない(ドライバの各メソッドは args から個別の値を取り出すだけで、辞書ごとは渡さない)。
    /// **記憶の記録可否だけに使う** —— recordsIOSMemory/recordsAndroidMemory 参照
    static let deviceFromMemoryKey = "_deviceFromMemory"

    static func injectedFromMemory(_ args: [String: Any]) -> Bool {
        args[deviceFromMemoryKey] as? Bool == true
    }

    /// **記憶した状態に依存する呼び出しか**(純粋関数)。この形だけが「機が変わると黙って
    /// 別物へ届く」——  ref は世代から引き、`bundleId` 省略の `ft_open_url` は記憶した起動アプリへ配る。
    /// 座標タップや素の ft_snapshot は記憶を使わないので、確認の往復を払う価値が無い。
    /// **`ft_batch` は先頭ステップだけ ref を受ける**ので steps も見る
    /// **ref を受ける引数名は `ref` だけではない**(2026-08-13 のレビュー指摘): `ft_drag` は
    /// `fromRef` で受け、`verifiedElement` 経由で同じ世代から引く。名前を1つ見落とすと
    /// **その1ツールだけ穴が開いたまま**になるので、`refBearingKeys` を唯一の定義元にして
    /// `MCPServerToolDefinitionsTests` がスキーマ側と突き合わせる
    static let refBearingKeys = ["ref", "fromRef", "scrollFrame"]

    /// 整数を受けるが **ref ではない**引数。`refBearingKeys` と合わせて
    /// **整数を受ける引数を全部説明しきる**(`MCPServerToolDefinitionsTests` がスキーマと
    /// 等号照合する)—— 新しい整数引数を足したらどちらかへ入れることになるので、
    /// 「ref を受ける引数が1つ増えたのにガードが知らない」が起きない。
    /// **綴りの類似で判定しない**(2026-08-13 に3度踏んだ): `ref` → `fromRef` →
    /// `scrollFrame` と、名前からは ref だと分からない引数が毎回出てきた
    static let nonRefIntegerKeys = ["lastN", "lines", "maxElements", "maxSwipes", "maxWidth",
                                    "port", "sinceSeconds"]

    static func usesRememberedDeviceState(_ args: [String: Any]) -> Bool {
        if Self.refBearingKeys.contains(where: { args[$0] != nil }) { return true }
        if let steps = args["steps"] as? String, stepsCarryARef(steps) { return true }
        if args["url"] != nil, args["bundleId"] == nil { return true }
        return false
    }

    /// `ft_batch` の先頭ステップが ref を持つか。**`contains("ref:")` では足りない**
    /// (2026-08-13 のレビュー指摘): パーサは `tap ref : 12` という綴りも受理する。
    /// **空白を許す形で見る**。引用符の中の `ref:` を拾う偽陽性はあり得るが、
    /// **外した場合は黙って別の機を操作する**のに対し、余分に拾っても `/status` 1往復
    /// (実測6〜9ms)なので、**安全側へ倒す**
    static func stepsCarryARef(_ steps: String) -> Bool {
        var sawRef = false
        var index = steps.startIndex
        while let found = steps.range(of: "ref", range: index..<steps.endIndex) {
            var cursor = found.upperBound
            while cursor < steps.endIndex, steps[cursor] == " " { cursor = steps.index(after: cursor) }
            if cursor < steps.endIndex, steps[cursor] == ":" { sawRef = true; break }
            index = found.upperBound
        }
        return sawRef
    }

    /// キャッシュ命中のドライバが**別の機を指し始めていたら**、そのキーの記憶を捨てて理由を返す
    /// (非 nil = 呼び出しを断る文)。
    ///
    /// **確認は `usesRememberedDeviceState` の呼び出しだけ**に絞る: 同一性の確認は
    /// `/status` 1往復(実測 6〜9ms)で、ref 系はどのみち木を撮りにブリッジへ行くので
    /// **限界費用がほぼ無い**。全呼び出しに掛けると、XCUITest の quiescence(実測 33.7 秒)中に
    /// 記憶を使わない呼び出しまで詰まらせる。
    /// **udid を採れないとき(実機・旧ブリッジ)は何もしない** —— 「分からない」を「変わった」と
    /// 読むと毎回記憶が飛ぶ(`keyChangedDevice` と同じ規律)。
    /// Android は engineKey に serial(= 機そのもの)が入っているので、この穴が構造的に無い
    /// **問い合わせは掴んでいるドライバ越しにやらない**(2026-08-13 に実装2回目で踏んだ):
    /// 実運用のドライバは `SessionRecoveryDriver` に包まれており、**建て直した直後のブリッジは
    /// まだセッションを持たない**ので `status()` が 409 で落ちる。`try?` で握ると
    /// **機が変わったときにちょうどガードが黙る** —— 陰性が「常に false を返す検出器」と
    /// 区別できない形そのものだった(実機の陽性対照で発覚)。ポートへ直に `/status` を撃つ
    /// **platform は引数で取らない**(2026-08-13 の掃討): 必要な2つ(`udids` と
    /// `connectedPorts`)は **iOS でしか埋まらない**ので、前提のほうが platform 判定より強い。
    /// profile 経路は解決前に platform 文字列を持たないため、引数で取ると呼び手ごとに
    /// 合成することになり、そこで取り違える余地が生まれる
    func deviceIdentityChanged(_ key: String, args: [String: Any]) async -> String? {
        guard Self.usesRememberedDeviceState(args),
              let recorded = udids[key] ?? nil, let port = connectedPorts[key] else { return nil }
        // **宛先ホストは BridgeEndpoint.load で解決する**(欠陥④・2026-08-14): 127.0.0.1 決め打ちだと
        // 実機の lan トランスポート(ランナーを 0.0.0.0 に bind してデバイスの LAN IP へ直接 HTTP)
        // ではデバイスに届かず、同じポート番号で loopback に応答した**別の機**の udid を読んでしまう
        // (BridgeDiscovery.isBound/scan・ExploreDriverResolver と同じ解決点に揃える)。
        // **実機のブリッジは /status に udid を申告しないので status().udid は常に nil になり、
        // このガードは実機では実質 no-op**(誤って拒否することは無いが、保護もされない)。
        // `.ftester/bridge-<port>.device` の記録で補える余地はあるが、今回は広げない
        // (no-op のままなら実害は無く、広げると誤拒否の側にリスクが移る)
        let endpoint = (try? RepoRoot.find()).map { BridgeEndpoint.load(port: port, repoRoot: $0) }
            ?? BridgeEndpoint(port: port)
        guard let now = try? await BridgeClient(port: endpoint.port, timeoutSeconds: 5,
                                                host: endpoint.host).status().udid,
              let moved = Self.keyChangedDevice(previous: recorded, now: now) else { return nil }
        forgetDeviceState(key)
        return Self.movedDeviceRefusal(port: port, previousUDID: moved, nowUDID: now)
    }

    /// ポートが別の機へ移っていたときに呼び出しを断る文。**捨てたものを名指しする** ——
    /// 「別の機だ」だけだと、読み手は手元の ref をそのまま撃ち直す
    static func movedDeviceRefusal(port: UInt16?, previousUDID: String, nowUDID: String) -> String {
        let where_ = port.map { "port \($0)" } ?? "this bridge"
        return "\(where_) now belongs to a different simulator (was \(previousUDID), now \(nowUDID))"
            + " — refusing this call because it relies on state remembered for the previous device"
            + " (a ref, or the launched app that ft_open_url defaults to). That state has been"
            + " dropped. Take a fresh ft_snapshot and use the new refs."
    }

    /// **同じ engineKey が別の機を指し始めたか**(非 nil = 前の udid。走査から切り離した純粋関数)。
    /// 判定は port ではなく **udid** —— キーに入っている port は再利用され得るが、udid は機そのもの。
    /// **どちらかが不明なら nil**(何もしない): 「分からない」を「変わった」と読むと、
    /// udid を採れない構成(xcuitest 以外・実機)で毎回記憶が飛ぶ
    static func keyChangedDevice(previous: String?, now: String?) -> String? {
        guard let previous, let now, previous != now else { return nil }
        return previous
    }

    /// ポートが別のシミュレータへ移っていたときの警告。**捨てたものを名指しする** ——
    /// 「何かが消えた」だけだと、読み手は手元の ref をそのまま撃ち続ける
    static func reusedPortWarning(port: UInt16, previousUDID: String, nowUDID: String) -> String {
        "⚠️ port \(port) now belongs to a different simulator (was \(previousUDID), now \(nowUDID))"
            + " — refs, the remembered launched app and this session's notes for it were dropped."
            + " Take a fresh ft_snapshot before using any ref."
    }

    /// **セッション記憶(iOS)を使うかどうかの純粋関数**。走査から切り離してある(reconcilePort と
    /// 同じ理由: 実ブリッジ無しでテストできないと、条件を壊しても素通しする)。
    /// **適用は dispatch 入口(foldInRememberedDevice)だけが呼ぶ** —— driver() 側では
    /// 入口が既に args へ port/udid を埋めているので、ここを二度通す必要は無い
    static func iosExplicitWithMemory(
        argsGaveTarget: Bool, remembered: (port: UInt16, udid: String?)?
    ) -> (port: UInt16, udid: String?)? {
        argsGaveTarget ? nil : remembered
    }

    /// 解決成功後にセッション記憶(iOS)を更新すべき値。**この呼び出しの args に udid/port の
    /// どちらかがあったときだけ**上書きする — 自動解決の結果を記憶に混ぜると、次に無指定で
    /// 呼んだときに「利用者が選んだのではない機」を黙って踏襲することになる
    static func iosMemoryAfterResolve(
        argsHadExplicitTarget: Bool, resolvedPort: UInt16, resolvedUDID: String?
    ) -> (port: UInt16, udid: String?)? {
        argsHadExplicitTarget ? (resolvedPort, resolvedUDID) : nil
    }

    /// driver() が iOS 記憶を更新してよいかの判定。fold が注入した呼び出し
    /// (deviceFromMemoryKey 付き)は port/udid を持っていても**明示扱いしない** —— さもないと
    /// この直後の iosMemoryAfterResolve が「利用者が選んだ」として記憶を上書きし、ポート再利用で
    /// 別デバイスに化けたときに記憶が黙って乗り換わる。
    /// **`profile:` も名指しとして数える**(実機監査 2026-08-13): 実機のブリッジは `/status` に
    /// udid を載せないため udid/port で指せず、`profile:` が実機を指す唯一の現実的な手段。
    /// ここが profile を見ないと、実機を使うセッションは2台目を触っても曖昧さガードに数えられず
    /// 省略呼び出しが黙って別の機(仮想デバイス側)へ流れる
    static func recordsIOSMemory(_ args: [String: Any]) -> Bool {
        (argsGaveIOSTarget(args) || args["profile"] is String) && !injectedFromMemory(args)
    }

    /// iOS と同じ規律の Android 版。serial は空文字列も「無指定」として扱う(resolveAndroidSerial
    /// と揃える)。**適用は foldInRememberedDevice だけが呼ぶ**(iOS 側と同じ理由)。
    /// **iosExplicitWithMemory と同形**: 使わない tuple 要素(explicit)は持たない —
    /// 明示判定は argsGaveAndroidTarget に一本化してある
    static func androidExplicitWithMemory(argsGaveTarget: Bool, remembered: String?) -> String? {
        guard !argsGaveTarget, let remembered, !remembered.isEmpty else { return nil }
        return remembered
    }

    /// iosMemoryAfterResolve の Android 版。**記録するのは解決済みの serial だけ** ——
    /// 「記録してよいか」は Bool で受ける(serial 型の値で可否を表すと、その値自体が
    /// serial として使われる誤用を招く)
    static func androidMemoryAfterResolve(
        argsHadExplicitTarget: Bool, resolvedSerial: String
    ) -> String? {
        argsHadExplicitTarget ? resolvedSerial : nil
    }

    /// recordsIOSMemory の Android 版。fold が注入した serial は記憶の記録に使わない。
    /// **`profile:` も名指しとして数える**(iOS 側と同じ理由・対称に直す)。
    /// serial は空文字列を「無指定」として扱う(resolveAndroidSerial と揃える)
    static func recordsAndroidMemory(_ args: [String: Any], explicitSerial: String?) -> Bool {
        guard !injectedFromMemory(args) else { return false }
        if let explicitSerial, !explicitSerial.isEmpty { return true }
        return args["profile"] is String
    }

    /// 解決済みの宛先をセッション記憶へ記録する。**driver() の4箇所(profile の新規生成・
    /// キャッシュ命中、direct の新規生成・キャッシュ命中)が共に呼ぶ唯一の記録点** —— どれか1つ
    /// でも欠けると、その経路で触った機が記憶にも曖昧さの候補にも載らず、省略呼び出しが黙って
    /// 別の機(別 OS のことすらある)へ行く
    /// (実測 2026-08-13: profile の新規生成だけが呼んでいなかったため、実機を profile で触った後に
    /// 仮想デバイスを port で触ると、宛先を省いた呼び出しが拒否されず仮想デバイスへ流れた。
    /// 2026-08-14: profile のキャッシュ命中も同じ理由で漏れていた —— profile:A → port:B →
    /// profile:A の順に触ると、2回目の profile:A がキャッシュ命中で記憶を更新せず、
    /// セッションの記憶が B のまま止まった)。
    /// 何を記録するかの判定は recordsIOSMemory / recordsAndroidMemory が持つ(明示指定でなければ
    /// 記録しない・fold が注入した宛先も記録しない)ので、ここは配線だけ
    func rememberResolvedTarget(
        platform: String, args: [String: Any],
        iosPort: UInt16?, iosUDID: String?, androidSerial: String?
    ) {
        switch platform {
        case "ios":
            guard let iosPort, let remembered = Self.iosMemoryAfterResolve(
                argsHadExplicitTarget: Self.recordsIOSMemory(args),
                resolvedPort: iosPort, resolvedUDID: iosUDID) else { return }
            lastExplicitIOSTarget = remembered
            lastExplicitPlatform = "ios"
            seenExplicitIOSPorts.insert(remembered.port)
            everNamedIOSTarget = true
        case "android":
            guard let androidSerial, let remembered = Self.androidMemoryAfterResolve(
                argsHadExplicitTarget: Self.recordsAndroidMemory(
                    args, explicitSerial: args["serial"] as? String),
                resolvedSerial: androidSerial) else { return }
            lastExplicitAndroidSerial = remembered
            lastExplicitPlatform = "android"
            seenExplicitAndroidSerials.insert(remembered)
            everNamedAndroidTarget = true
        default: break
        }
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

    /// profile 経由の iOS ドライバ。**実行プロファイルのエンジンに追従する**(XCUITest 固定に
    /// しない —— in-app が実装できない home/drag/座標 press は HybridFallbackDriver が埋める)。
    /// エンジンを揃える理由は**探索と実行で見えるものを一致させる**こと: snapshot の内容も
    /// ジェスチャの成否もエンジンで変わるので、揃えないと「MCP では動いたのにシナリオでは falls」
    /// (およびその逆)が起きる。
    ///
    /// 合成は実行側(ScenarioRunnerMain)と同じ形:
    ///   in-app(注入) → WebView 画面だけ XCUITest へ委譲 → 不可な操作だけ XCUITest へ回す
    /// **hybrid でないとき(inapp 単独・xcuitest・実機)は素の1本**にする
    /// **`probePort` は「同一性を確かめに行ってよい loopback のポート」**。
    /// `provisioned.port` を外から使ってはいけない —— xcuitest 分岐は `XCUIBridgeResolver` が
    /// **接続先を振り替える**ことがあり、実機は loopback ですらない。誤ったポートを
    /// `connectedPorts` に記録すると、`deviceIdentityChanged` が**無関係な機のブリッジを読んで
    /// 正しい呼び出しを拒否し、記憶まで捨てる**(穴を塞ぐより悪い)。
    /// **確かめられないときは nil**(ガードは何もしない = 従来どおり)
    static func iosDriver(provisioned: ProvisionedIOSDevice,
                          bundleID: String?) async throws -> (driver: AppDriver, probePort: UInt16?) {
        guard !provisioned.physical, provisioned.engine == "inapp" || provisioned.engine == "hybrid" else {
            // xcuitest(と実機)は従来どおり。resolve は接続先が in-app だったときの振り替えも担う
            let resolution = await XCUIBridgeResolver.resolve(
                preferred: provisioned.port, repoRoot: try? RepoRoot.find(),
                logger: { Self.logStderr($0) })
            // **実機は UDID を渡す**: install/uninstall は simctl ではなく devicectl が要り、
            // clearAppData は「実機では不可」と即答できる(渡さないとデバイス名で simctl を
            // 撃つことになり、的外れな失敗になる)
            let driver = SessionRecoveryDriver(base: BridgeClient(
                port: resolution.endpoint.port, host: resolution.endpoint.host,
                physicalUDID: provisioned.physical ? provisioned.udid : nil))
            // **実際に繋いだポート**を返す(preferred ではない)。実機は loopback ではないので nil
            let probe = (provisioned.physical || resolution.endpoint.host != BridgeEndpoint.loopbackHost)
                ? nil : resolution.endpoint.port
            return (driver, probe)
        }
        let inapp = InAppDriver(repoRoot: try RepoRoot.find(), udid: provisioned.udid,
                                port: provisioned.port)
        guard provisioned.engine == "hybrid", let xcuiPort = provisioned.xcuiPort,
              let bundleID else {
            return (inapp, provisioned.port)
        }
        // attach は**同じインスタンス**を委譲とフォールバックの両方に使う(実行側と同じ理由:
        // activate/attached 状態を1本にしないと余計な activate が挟まる)
        let attach = AppAttachDriver(port: xcuiPort, bundleID: bundleID)
        // hybrid の主は in-app(provisioned.port)。同一性はそちらへ問う
        return (HybridFallbackDriver(primary: WebViewDelegatingDriver(primary: inapp, delegated: attach),
                                     fallback: attach, primaryBundleID: bundleID,
                                     foreignApp: SessionRecoveryDriver(base: BridgeClient(port: xcuiPort))),
                provisioned.port)
    }

    /// **実際に主となったエンジンが XCUITest のときだけ**添える切り分け。XCUITest では
    /// 成立しないジェスチャがあり(表と実測は docs/commands.md)、何も起きなかったときに
    /// 原因が分からないと詰む。**Android と in-app/hybrid には付けない**(前者はこの制限が
    /// 無く、後者は成立する。無関係な助言は誤誘導になる)。
    /// エンジンは driver(_:) が記録する = **推測しない**(profile 無しでも稼働中の in-app
    /// ブリッジを掴めば hybrid になるため、引数だけからは決まらない)
    /// **1文に圧縮**: UIKit アプリでも xcuitest エンジンなら毎回この助言が出ており、
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

    /// **iOS のシステムダイアログはこの木に出ない**ことを、詰まった場所で言う。
    ///
    /// 位置情報・通知の許可や「"◯◯"で開きますか?」は **SpringBoard が別プロセスで描く**ので、
    /// アプリに閉じた XCUITest のセッションからは**存在しないのと同じ**に見える。しかも
    /// アプリはその間入力を受け取れないので、症状は「操作しても木が1つも変わらない」になる ——
    /// **`ft_snapshot` を何度撮っても手掛かりが出ない**形。評価者は座標でダイアログを叩いて
    /// 切り抜けており(画面サイズが変われば壊れる)、読む口が既にあること自体に気付けなかった。
    ///
    /// Android は木のセッションごと別パッケージへ移るので `switchedAppNote` が捕まえる ——
    /// **この穴は iOS 固有**。
    ///
    /// 出す場所は「操作しても変わらなかった」と告げる3箇所(waitFor の identical 判定・
    /// settle-lite の再読み・ft_batch の still identical)だけ = **読み手が実際に詰まった瞬間**。
    /// ゲートは `springboardHint` と同じ(engine 不明 or xcuitest。in-app は注入先アプリしか
    /// 見えないので springboard を掴めず、勧めても実行できない)
    static func systemDialogHint(engine: String?) -> String {
        guard engine == nil || engine == "xcuitest" else { return "" }
        return " If a system dialog is up (a permission prompt, an \"Open in …\" confirmation),"
            + " it is drawn by SpringBoard and not by the app, so it never appears in this tree"
            + " — and the app cannot receive input while it is there, which looks exactly like"
            + " this. Read it with ft_launch bundleId: com.apple.springboard (non-destructive),"
            + " operate it by ref there, then ft_launch your app again."
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

    /// 待ちの既定(秒)。定義元は FTCore.DefaultWait(DSL の FTRuntime.defaultTimeout と共有)
    static let defaultWaitSeconds: Double = DefaultWait.seconds

    /// ポーリング間隔(秒)。短くしても律速は snapshot 自体(iOS in-app で約 0.12s)。
    /// waitFor と waitForChange(snapshotAfterBody)が共有する
    static let waitPollSeconds: Double = 0.3

    /// waitForChange が「変わった」後に安定(直前の読みと一致)を確かめる再読の上限。
    /// 1回で一致するのが普通で、上限まで揺れ続けたら採り直しをやめて still-changing を注記する
    /// —— timeout を食い潰さない固定小コストに抑えるための蓋(settleWaitSeconds × この回数)
    static let changeSettleRereads = 3

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
    /// `elementLimit`: ポーリングの読みへ毎回かける要素上限(nil = ブリッジの既定)。
    /// **ここを通さないと web ページの天井ラッチが待ちの経路だけ効かない**(2026-08-15 の実害):
    /// 最初の1枚は `freshSnapshot` がラッチして天井で撮り直すのに、その直後の waitFor が
    /// 素の 120 で撮り直すため、**返る木は切り詰められたまま**になり
    /// 「maxElements を上げろ」の旧注記が出続けていた(`raiseElementLimitOnNextSnapshot` は
    /// 1回ぶんの指定なので、freshSnapshot の読みで消費されている)
    static func waitFor(_ selector: String, driver: AppDriver, first: SnapshotResponse,
                        seconds: Double, elementLimit: Int? = nil) async throws
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
            if let elementLimit { driver.raiseElementLimitOnNextSnapshot(elementLimit) }
            latest = driver.supportsCacheBypass
                ? try await driver.snapshot(bypassingCache: true) : try await driver.snapshot()
            refetched = true
            if matches(selector, in: latest) { return (true, latest, nil, "", true) }
            notePartial(latest, elapsed: Date().timeIntervalSince(start))
        }
        // ループが1周も回らなかった(seconds <= 0 等)ときは latest === first のまま = 未撃ち直し
        return (false, latest, partialSeenAfter, partialHint, refetched)
    }

    /// セレクタ式(`#id` / ラベル / `.type` / `||` 等)がこの画面に1つでも当たるか。
    /// **解決ロジックは `matchedElements`(MCPServer+Snapshot.swift)そのもの** —— 2つ目の
    /// セレクタ解決を作らない
    static func matches(_ selector: String, in snapshot: SnapshotResponse) -> Bool {
        !matchedElements(selector, in: snapshot).isEmpty
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
