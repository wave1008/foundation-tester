// MCPServer+Driver.swift
// ドライバ解決(エンジン・ポート/シリアル・版ズレゲート)と接続系の注記。本体は MCPServer.swift(instance 状態はそちらに置く)

import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore

extension MCPServer {

    // MARK: - ドライバ

    /// **`driver(_:)` の唯一の呼び口はここ**: 解決(`resolveDriver`)の直後に、物理 Android なら
    /// 起こす処理を挟む。全ツールが `driver(args)` を通るので、ここ1箇所で全ツールに効く。
    /// **差し替えドライバ(テスト)では何もしない**(`prepareAndroidDeviceIfNeeded` が
    /// `makeDriver == nil` を見る)ので、既存のテストの呼び出し列は1つも変わらない
    func driver(_ args: [String: Any]) async throws -> AppDriver {
        let resolved = try await resolveDriver(args)
        await prepareAndroidDeviceIfNeeded(resolved, args: args)
        return resolved
    }

    /// **物理 Android の消灯を、操作の前に起こしてから進む**(実測):
    /// 消灯中は `ft_snapshot` が注記なしで常時表示の木を返し、`ft_tap` は `done` を返し、
    /// `ft_launch` は「アプリが前面に来なかった」としか言わない —— 消灯そのものには一度も触れない。
    /// run 経路(`ProfileWorkerFactory.preparePhysicalAndroidDevices` → `AndroidPhysicalDevice.
    /// prepareForRun`)と**同じ処理を同じ粒度で**呼ぶ(起こす・ロック解除。消灯の抑止は
    /// 端末の設定のまま変えない——2026-09-05 のユーザー決定はそのまま尊重する)。
    /// **このセッションでその機へ初めて触れたときは準備を丸ごと**(`preparedPhysicalAndroid`)、
    /// **2回目以降は画面の状態を1往復で見て、消灯・ロック中のときだけ起こす**(`wakeIfAsleep`)。
    /// 初回だけだと、セッションの途中で消えた後の `ft_launch` が 23 秒後に「アプリが前面に来なかった」
    /// とだけ言い、常時表示の snapshot を「システムダイアログ」と誤って言った(2026-09-11 Pixel 3a)。
    /// 確認は 0.1 秒前後(run のシナリオごとの確認と同じ関数)
    func prepareAndroidDeviceIfNeeded(_ resolved: AppDriver, args: [String: Any]) async {
        guard resolved is AndroidDriver, makeDriver == nil else { return }
        let key = Self.engineKey(args)
        guard let serial = connectedAndroidSerials[key],
              DevicePicker.isPhysicalAndroidSerial(serial) else { return }
        guard !preparedPhysicalAndroid.contains(key) else {
            await AndroidPhysicalDevice.wakeIfAsleep(serial: serial, log: Self.logStderr)
            return
        }
        preparedPhysicalAndroid.insert(key)
        await AndroidPhysicalDevice.prepareForRun(serial: serial, log: Self.logStderr)
    }

    // **実行と同じエンジンで探索する**のが原則(揃えないと snapshot もジェスチャの成否も食い違う)。
    // profile 指定時は resolveProfileTarget が ft_run_scenario と同じデバイスを解決し、iosDriver が
    // プロファイルのエンジンに追従する。profile 無しの iOS は ExploreDriverResolver が
    // 稼働中ブリッジを見て決める(in-app が居れば hybrid を組む・居なければ XCUITest)
    func resolveDriver(_ args: [String: Any]) async throws -> AppDriver {
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
                // **maintainer-notes §51.10**: エンジン(xcuitest/inapp/hybrid)が同じ機のまま入れ替わっていないかも
                // 確かめる(udid だけでは捕まらない・ref を使わない呼び出しでも効かせる)。
                // 食い違っていれば `.refuse`(記憶に依る呼び出し)か `.rebuildSilently`
                // (依らない呼び出し。下の生成へそのまま落ちる)のどちらか
                switch await primaryEngineCheck(key, args: args) {
                case .refuse(let message):
                    throw MCPError(message)
                case .rebuildSilently:
                    break
                case .unchanged:
                    // **hybrid の fallback(XCUITest)ポートも本人確認する**(maintainer-notes §51.2): 主(in-app)の udid が
                    // 変わっていなくても、`HybridFallbackDriver` の fallback は別ポートを握ったままで
                    // 建て直しにより別の機へ移り得る。fallback には ref が乗らないので(primary と違い)
                    // 捨てるべきセッション記憶が無い —— キャッシュだけ落として下の生成へ通す
                    // (`.inappOnly` へ静かに縮退することもある)
                    if await hybridFallbackDrifted(key) {
                        drivers[key] = nil
                        hybridFallbackPorts[key] = nil
                    } else {
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
                }
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
            var xcuiFallbackPort: UInt16?
            switch target {
            case .ios(let provisioned, let iosApp):
                (created, probePort, xcuiFallbackPort) = try await Self.iosDriver(
                    provisioned: provisioned, bundleID: iosApp?.bundleID)
            case .android(let serial, _):
                created = try AndroidDriver(serial: serial)
            }
            drivers[key] = created
            engines[key] = {
                if case .ios(let provisioned, _) = target { provisioned.physical ? "xcuitest" : provisioned.engine }
                else { "android" }
            }()
            // **hybrid のときだけ fallback ポートを覚える**(それ以外は前の機の値が残らないよう nil)。
            // 主(connectedPorts)とは別枠 —— `hybridFallbackDrifted` が次回のキャッシュ命中で読む
            hybridFallbackPorts[key] = engines[key] == "hybrid" ? xcuiFallbackPort : nil
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
                                               nowUDID: provisioned.udid))
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
            // profile 経由なら対象 bundleID が分かるので、engine を問わず静的に判定して覚える
            // (DSL と同じ AppUIFrameworkQuery。静的に決まらなければ resolveExecutorHints が
            // in-app の自己申告まで問う)。実機は appPathPhysical(.app / .ipa)か台帳で答える
            if case .ios(let provisioned, let iosApp) = target, let bundleID = iosApp?.bundleID,
               let framework = AppUIFrameworkQuery.staticAnswer(for: .init(
                   platform: "ios", bundleID: bundleID,
                   appPath: iosApp?.packagePath(physical: provisioned.physical),
                   udid: provisioned.udid, physical: provisioned.physical)).framework {
                uiFrameworkHints[key] = framework
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
            // **maintainer-notes §51.10**(profile 経路の同じ確認と理由は同じ): エンジンが同じ機のまま入れ替わって
            // いないかも確かめる(Android のキーは connectedPorts が無いので即 .unchanged)
            switch await primaryEngineCheck(key, args: args) {
            case .refuse(let message):
                throw MCPError(message)
            case .rebuildSilently:
                break
            case .unchanged:
                // **hybrid の fallback(XCUITest)ポートも本人確認する**(maintainer-notes §51.2。profile 経路の
                // 同じ確認と理由は同じ)。fallback には ref が乗らないのでキャッシュだけ落とし、
                // 下の生成へ通す(セッション記憶は主の udid が変わっていないので保つ)
                if await hybridFallbackDrifted(key) {
                    drivers[key] = nil
                    hybridFallbackPorts[key] = nil
                } else {
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
            }
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
            // **hybrid のときだけ fallback ポートを覚える**(profile 経路と同じ理由・同じ枠)
            hybridFallbackPorts[key] = resolved.engine == "hybrid" ? resolved.xcuiPort : nil
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
    /// **判定できないときは黙る**(旧ブリッジは版を返さない = nil。それを「古い」と断じると常時警告)。
    ///
    /// **判定(running/expected の比較)は `BridgeTargetResolution.versionSkew` を通す**
    /// (CLI の手動駆動サブコマンドと共有)。ここに残すのは MCP 向けの文言だけ
    /// (`fleetest-mcp` を名指しする対処。CLI 側は別の文を組む)
    static func bridgeVersionSkew(driver: AppDriver) async -> String? {
        guard let skew = await BridgeTargetResolution.versionSkew(driver: driver) else { return nil }
        let side = skew.bridgeIsNewer
            ? "the bridge is NEWER than this build (v\(skew.running) > v\(skew.expected)) —"
                + " your fleetest-mcp binary is stale, so rebuild it"
                + " (swift build --product fleetest-mcp) or pull"
            : "the bridge is OLDER than this build (v\(skew.running) < v\(skew.expected)) —"
                + " restart it with `fleetest bridge down --all && fleetest bridge up`"
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
    /// どちらも無ければ nil(従来どおり resolveIOSPort が既定ポート → 探索の順で決める)。
    /// **udidPorts が空のときだけ追加調査(IO)を払う** —— 応答が1本でもあれば従来どおり素通り
    static func portForIOS(_ args: [String: Any]) async throws -> UInt16? {
        let port = try Self.portArgument(args)
        guard let udid = (args["udid"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else {
            return port
        }
        let udidPorts = await bridgePorts(forUDID: udid)
        guard udidPorts.isEmpty else {
            return try reconcilePort(port, udid: udid, udidPorts: udidPorts)
        }
        // **明示 port は scan より先に、その1本だけ狙い撃ちで本人確認する**(maintainer-notes §51.6):
        // `bridgePorts(forUDID:)` は全ポートへ一律2秒の窓で scan するだけなので、高負荷で busy な
        // XCUITest(quiescence 待ちで数十秒ブロックしうる)は生きていても scan の結果に載らない。
        // 呼び手が port を明示しているなら、その1本だけをもっと長い窓で確かめたほうが scan の
        // 取りこぼしより確実。一致すれば即採用・食い違えば拒否・確かめられなければ(無応答/読めない)
        // 下の一般診断へフォールバックする(timedOut を「居ない」に畳まないのは
        // `noResponsiveBridgeMessage` 側の規律と同じ)
        if let port {
            switch await Self.explicitPortIdentityProbe(port: port, udid: udid, repoRoot: try? RepoRoot.find()) {
            case .confirmedMatch:
                return port
            case .confirmedMismatch(let actualUDID):
                throw MCPError(Self.explicitPortMismatchMessage(port: port, udid: udid, actualUDID: actualUDID))
            case .unknown:
                break
            }
        }
        let diagnosis = await Self.udidBridgeDiagnosis(udid: udid)
        return try reconcilePort(port, udid: udid, udidPorts: udidPorts, diagnosis: diagnosis)
    }

    /// 明示 port だけを狙い撃ちして udid を本人確認した結果(maintainer-notes §51.6)。**「確かめられない」を
    /// 「一致した/しなかった」に畳まない** —— 3値のまま呼び出し元(`portForIOS`)へ渡す
    enum ExplicitPortIdentity: Equatable, Sendable {
        /// `/status` が答え、udid(実機は `statusForIdentityCheck` が記録で補う)が一致した
        case confirmedMatch
        /// `/status` が答えたが、別の udid を名乗った —— scan の取りこぼしではなく本当の食い違い
        case confirmedMismatch(actualUDID: String)
        /// 応答が無い/読めない/udid を判定できない —— 一致とも不一致とも言えない
        case unknown
    }

    /// `explicitPortIdentityProbe` が payload を確かめる窓。**scan の2秒より長く取る** ——
    /// scan の窓の短さが maintainer-notes §51.6 の取りこぼしの原因なので、そこに揃えると同じ取りこぼしを再現する。
    /// `udidBridgeDiagnosisBudget`(3秒)に揃え、追加コストの上限を「診断1回ぶん」に留める
    static let explicitPortIdentityProbeTimeoutSeconds: Double = 3

    /// 明示 port の `/status` を1回だけ撃って udid を確かめる。**`statusForIdentityCheck` で
    /// 実機の未申告 udid を記録から補う**(`BridgeDiscovery.scan` と同じ規則) —— 補わないと
    /// 実機は毎回 `.unknown` に落ちる。判定そのものは `FTCore.BridgeIdentityCheck`(udid が
    /// 両側にあるときは udid だけを比べる枝なので `physical` は未使用・ダミー値でよい)を再利用する
    static func explicitPortIdentityProbe(
        port: UInt16, udid: String, repoRoot: URL?
    ) async -> ExplicitPortIdentity {
        let endpoint = repoRoot.map { BridgeEndpoint.load(port: port, repoRoot: $0) }
            ?? BridgeEndpoint(port: port)
        guard let reported = try? await BridgeClient(
            endpoint: endpoint, timeoutSeconds: Self.explicitPortIdentityProbeTimeoutSeconds
        ).status(timeout: Self.explicitPortIdentityProbeTimeoutSeconds) else { return .unknown }
        let status = BridgeDiscovery.statusForIdentityCheck(reported, port: port, repoRoot: repoRoot)
        guard let statusUDID = status.udid else { return .unknown }
        let expected = BridgeIdentityCheck.Expected(port: port, udid: udid, physical: false, engine: nil)
        return BridgeIdentityCheck.matches(expected: expected, status: status)
            ? .confirmedMatch : .confirmedMismatch(actualUDID: statusUDID)
    }

    /// 明示 port の直接確認で「別の udid」と確定したときの文面(maintainer-notes §51.6)。scan 経由の同種の食い違い
    /// (`reconcilePort` 第2 guard)とトーンは揃えるが、ここでは udidPorts が空(scan が何も
    /// 見つけていない)ので「その udid の他の応答ポート一覧」は出さず、確かめた1件だけを示す
    static func explicitPortMismatchMessage(port: UInt16, udid: String, actualUDID: String) -> String {
        "port \(port) is not a bridge answering on udid \(udid) — it answered as a different device"
            + " (udid \(actualUDID)). Pass only one of port/udid, or use the port and udid that"
            + " belong to the same device"
    }

    /// `reconcilePort` が「応答したポートが1本も無い」ときに使う追加事実。**IO は呼び出し側
    /// (`udidBridgeDiagnosis`)が集め、ここへは値として渡す** —— reconcilePort 自体は
    /// 走査を伴わない純粋関数のまま保つ(2026-08-09 の変異テストが踏んだ理由と同じ)
    struct UDIDBridgeDiagnosis: Equatable, Sendable {
        /// LISTEN しているが `/status` がタイムアウト上限まで無応答(= 本当に busy の根拠。
        /// `BridgeDiscovery.StatusProbe.timedOut`)。空なら「本当に居ない」
        let listeningButUnresponsive: [UInt16]
        /// その udid を今使っている run の pid(`RunLease.holderPID`。`markDeviceInUse` と
        /// 同じ台帳・同じ鍵)。分かれば文面に添える
        let heldByRunPID: Int32?
        /// `bridge up` の完成コマンドを組むための実体判定(`SimulatorCatalog.lookupUDID(udid:)`
        /// = ft_list_devices と同じ経路)の4値。**`.notFound`(一覧を読めたが載っていない)と
        /// `.unreadable`(一覧そのものが読めなかった)を混同しない** —— 混同すると、
        /// 負荷下で simctl がタイムアウトしただけの回を「そのデバイスは存在しない」と断定する
        let lookup: SimulatorCatalog.UDIDLookup
        /// LISTEN しているが `/status` への接続がタイムアウトよりはるかに早く応答無しで切れた
        /// (= ブリッジが消えて転送役(実機なら iproxy)だけ残っている根拠。
        /// `BridgeDiscovery.StatusProbe.transportFailed`)。**既定 `[]`**(既存呼び出し元・
        /// 既存テストの3引数の形をそのまま通すため末尾に置く。デフォルト値付きプロパティは
        /// 合成 memberwise init で省略可能なパラメータになるのは **`var` のときだけ** ——
        /// 既定値つきの `let` は memberwise init から丸ごと外れて渡せなくなる)
        var wedgedPorts: [UInt16] = []
        /// **診断そのものが確定したか**(maintainer-notes §51.6)。`false`(既定)= この値の他の欄
        /// (空の `listeningButUnresponsive`/`wedgedPorts`)は「確かめて本当に空だった」ことを表す。
        /// `true` = 予算超過で診断を最後まで走らせられず、他の欄は「集まらなかった」だけで
        /// 空になっている ——  この区別が無いと、時間切れの結果が①〜④のどの分岐にも当たらず
        /// 「no running bridge」(= 本当に居ない)へ黙って落ち、生きたブリッジに `bridge up` を
        /// 勧めて2本目を起動させかけた。**`var` + 既定値**(`wedgedPorts` と同じ理由: 合成
        /// memberwise init で省略可能にするため `let` にしない)
        var timedOut: Bool = false

        /// 診断を呼ばなかった(必要が無かった)ときの既定。**`timedOut` は `false`** ——
        /// `reconcilePort` の default 引数・省略呼び出しのテストがこの値を「診断していない」
        /// 意味で使っており、その経路は今までどおり「no running bridge」の文面に落ちる
        static let unknown = UDIDBridgeDiagnosis(
            listeningButUnresponsive: [], heldByRunPID: nil, lookup: .unreadable("diagnosis timed out"))

        /// 実際に診断(`udidBridgeDiagnosis`)を試みたが、予算(`udidBridgeDiagnosisBudget`)内に
        /// 終わらなかったときの値。`.unknown` と違い `timedOut: true` を立てるので、
        /// `noResponsiveBridgeMessage` はこれを「居ない」とは読まず `bridgeDiagnosisUnconfirmedMessage`
        /// へ回す
        static let diagnosisTimedOut = UDIDBridgeDiagnosis(
            listeningButUnresponsive: [], heldByRunPID: nil,
            lookup: .unreadable("diagnosis timed out"), timedOut: true)
    }

    /// `udidBridgeDiagnosis` が確かめる候補ポートの上限。**2026-09-16 実機実測**: 旧実装は全ポート
    /// 範囲(最大32本)へ `PortHolder.describe`(`lsof` を毎回起こす同期ブロッキング)を
    /// `withTaskGroup` で同時に起こしており、Swift の協調スレッドプールのワーカーを synchronous な
    /// `DispatchSemaphore.wait`(`Shell.run` → `ProcessExitWait.prepareTimed`)で埋め尽くし、
    /// `ft_status` を含む MCP プロセス全体が200秒以上前進できなくなった
    /// (CLAUDE.md「協調スレッドプールにブロッキングを載せない」— `PipeLinePump`/専用スレッドの
    /// 規律と同じ話)。**新しい実装は lsof を一切起こさず**、候補ポートは台帳から絞る
    /// (`candidatePorts`)。台帳が壊れて候補が異常に多くても、確かめるのはここまで
    /// (`BridgeDiscovery.isBound` 1回 300ms 上限 × この件数で worst case を秒単位に収める)
    static let maxUDIDBridgeCandidatePorts = 4

    /// `udidBridgeDiagnosis` の全体(`ps` / `simctl` / 必要なら `devicectl` / probe)に掛ける
    /// 上限。根拠: `candidatePorts` 内の `ps` は数十 ms、`SimulatorCatalog.lookupUDID` は通常
    /// `xcrun simctl list` の数百 ms で終わるが、udid がシミュレータ一覧に無いと
    /// `IOSPhysicalDeviceCatalog.devices()` = `xcrun devicectl list devices`(timeout 30 秒)まで
    /// 引く。probe(`BridgeDiscovery.probeStatus`。isBound 300ms 上限 + `udidProbeTimeoutSeconds`)は
    /// 候補上限本まで**並列**に撃つので、直列合算ではなく1回ぶんだけ足で乗る。
    /// **この 30 秒をそのまま `ft_status`(対話的な口)へ持ち込まない** —— 尽きたら
    /// `UDIDBridgeDiagnosis.diagnosisTimedOut`(= 完走できなかった。`.unknown` とは別の値 —— maintainer-notes §51.6)
    /// へ落とす。診断自体は打ち切らず走り続ける(`TaskBudget.run` と同じ立場: 諦めるのは
    /// 待つことだけ)
    static let udidBridgeDiagnosisBudget: Duration = .seconds(3)

    /// probe 1回(`BridgeDiscovery.probeStatus`)の窓。**scan の既定(2秒)より短くする** ——
    /// 候補上限本まで並列に撃つとはいえ、`ps`/`simctl`/`devicectl` の残り予算
    /// (`udidBridgeDiagnosisBudget`)を圧迫しないため。判別に使う実測(~2.5ms。
    /// `BridgeDiscovery.transportFailureFraction` のコメント参照)との比では 1 秒でも
    /// busy/wedged の判別に十分な余裕がある
    static let udidProbeTimeoutSeconds: Double = 1

    /// `udidPorts` が空だったときの追加調査(IO)。**lsof は一切起こさない**(上の doc 参照)。
    /// 候補ポートは台帳から絞り(`candidatePorts`。プロセスを起こすのは中の `ps` 1回だけ)、
    /// LISTEN と `/status` の両方の判定は `BridgeDiscovery.probeStatus`(生ソケットの connect+poll +
    /// 非ブロッキングな `/status` の await。`iosConnectionLostHint` の busy/wedged 判定と同じ部品)を
    /// 候補上限本まで**並列**に撃って行う。
    /// run の使用中は `RunLease.holderPID`(`markDeviceInUse` と同じ台帳)、
    /// 実体判定は `SimulatorCatalog.lookupUDID(udid:)`(ft_list_devices と同じ経路。読み取り失敗も
    /// `.unreadable` として運び、「載っていない」と混同しない)をそのまま使う。
    ///
    /// **台帳走査(ps/simctl/devicectl)だけを専用 Thread(`runOffCooperativePool`)へ逃がし
    /// (`udidBridgeDiagnosisBlocking`)、probe は通常の async 文脈で `withTaskGroup` により
    /// 並列に撃つ**(`probedUDIDBridgeDiagnosis`)—— `BridgeDiscovery.probeStatus` 内の `isBound` は
    /// 300ms 止まりの短い同期呼び出しで、候補上限(`maxUDIDBridgeCandidatePorts`)本までなら
    /// 協調スレッドプールを塞いでも許容範囲(`iosConnectionLostHint` も同じ部品を1回だけ直接
    /// 呼んでいる)。**`udidBridgeDiagnosisBlocking` は丸ごと同期**(`await` を1つも持たない) ——
    /// これを async 関数の本体に直に書くと、`Shell.run` の完了待ち(`DispatchSemaphore.wait`。
    /// 真のスレッドブロッキング)が Swift の協調スレッドプールのワーカーをそのまま占有する
    /// (2026-09-16 に一度この関数で lsof の並列版を踏んでいる。同じ関数がもう一度、本数が減った
    /// だけで同じ性質を持っていた)。`TaskBudget.run` が `udidBridgeDiagnosisBudget` で
    /// 両段(台帳走査 + probe)の合計へ上限を掛ける
    /// (CLAUDE.md「協調スレッドプールにブロッキングを載せない」)
    static func udidBridgeDiagnosis(udid: String) async -> UDIDBridgeDiagnosis {
        let outcome = await TaskBudget.run(Self.udidBridgeDiagnosisBudget) {
            await Self.probedUDIDBridgeDiagnosis(udid: udid)
        }
        guard case .value(let value) = outcome else { return .diagnosisTimedOut }
        return value
    }

    /// `udidBridgeDiagnosis` の本体(2段)。①台帳走査(同期・専用 Thread)②候補ポートへの
    /// probe(async・並列)。呼び手(`udidBridgeDiagnosis`)の `TaskBudget.run` が両段の合計を
    /// 上限で打ち切る
    private static func probedUDIDBridgeDiagnosis(udid: String) async -> UDIDBridgeDiagnosis {
        let repoRoot = try? RepoRoot.find()
        // 台帳走査は `budgeted`(= TaskBudget + 専用 Thread)を通す。**呼び手の
        // `TaskBudget.run` と二重に見えるが、こちらを外すと `budgeted` が production から
        // 1度も呼ばれなくなり、その予算のテストが自分自身しか確かめなくなる**
        let candidates = await Self.budgeted(
            Self.udidBridgeDiagnosisBudget,
            fallback: UDIDDiagnosisCandidates(ports: [], heldByRunPID: nil,
                                              lookup: .unreadable("diagnosis timed out"), timedOut: true)) {
            Self.udidBridgeDiagnosisBlocking(udid: udid, repoRoot: repoRoot)
        }
        guard !candidates.ports.isEmpty else {
            return UDIDBridgeDiagnosis(listeningButUnresponsive: [],
                                       heldByRunPID: candidates.heldByRunPID, lookup: candidates.lookup,
                                       timedOut: candidates.timedOut)
        }
        let probes = await withTaskGroup(of: (UInt16, BridgeDiscovery.StatusProbe).self) { group in
            for port in candidates.ports {
                group.addTask {
                    (port, await BridgeDiscovery.probeStatus(
                        port: port, repoRoot: repoRoot, timeoutSeconds: Self.udidProbeTimeoutSeconds))
                }
            }
            var result: [UInt16: BridgeDiscovery.StatusProbe] = [:]
            for await (port, probe) in group { result[port] = probe }
            return result
        }
        return UDIDBridgeDiagnosis(
            listeningButUnresponsive: candidates.ports.filter { probes[$0] == .timedOut },
            heldByRunPID: candidates.heldByRunPID, lookup: candidates.lookup,
            wedgedPorts: candidates.ports.filter { probes[$0] == .transportFailed })
    }

    /// `probedUDIDBridgeDiagnosis` が専用 Thread で集める材料(候補ポート・run 保持者・実体判定)
    private struct UDIDDiagnosisCandidates: Sendable {
        let ports: [UInt16]
        let heldByRunPID: Int32?
        let lookup: SimulatorCatalog.UDIDLookup
        /// **台帳走査そのものが予算超過で打ち切られたか**(既定 `false`)。`true` のときは
        /// `ports` が空でも「候補が無かった」ではなく「集められなかった」——
        /// `UDIDBridgeDiagnosis.timedOut` へそのまま運ぶ
        var timedOut: Bool = false
    }

    /// `udidBridgeDiagnosis` の同期本体。**`await` を書かない**(上の doc 参照)。
    /// LISTEN と `/status` の判定は行わない —— それは probe(async)へ一本化し、
    /// ここは候補ポートを集めるだけにする
    private static func udidBridgeDiagnosisBlocking(
        udid: String, repoRoot: URL?
    ) -> UDIDDiagnosisCandidates {
        let candidates = Self.cappedCandidatePorts(
            Array(Self.candidatePorts(forUDID: udid, repoRoot: repoRoot)))
        let heldByRunPID = repoRoot.flatMap {
            RunLease.holderPID(stateDir: $0.appendingPathComponent(".fleetest"), key: udid)
        }
        return UDIDDiagnosisCandidates(ports: candidates, heldByRunPID: heldByRunPID,
                                       lookup: SimulatorCatalog.lookupUDID(udid: udid))
    }

    /// 同期の仕事(`work`)を専用 Thread で実行し、`budget` 以内に返らなければ `fallback` を返す。
    /// **仕事はそのまま走り続ける**(打ち切らない・キャンセルしない) —— `FTCore.TaskBudget` と
    /// 同じ立場で、諦めた後に本当に終わるまでの時間を測り直す機構は持たない。
    /// **`udidBridgeDiagnosis` のテストはここへ時間のかかるダミー work を注入する**:
    /// 実際の `ps`/`simctl`/`devicectl` を1つも起こさずに「上限超過 → 既定へ落ちる」を固定できる
    static func budgeted<T: Sendable>(
        _ budget: Duration, fallback: T, _ work: @escaping @Sendable () -> T
    ) async -> T {
        let outcome = await TaskBudget.run(budget) {
            await Self.runOffCooperativePool(name: "fleetest-mcp-budgeted-diagnosis", work)
        }
        guard case .value(let value) = outcome else { return fallback }
        return value
    }

    /// 協調スレッドプールを塞がない同期実行の器。**専用 Thread**(`FTCore.RegionText
    /// .prewarmOnce` / `HostMetricsSampler` / `ParentDeathWatch.arm` と同じ作法)を起こし、
    /// `work` の戻り値を継続で1回だけ渡す。`work` は真にブロッキングな同期処理(`Shell.run` 等)を
    /// 置いてよい場所 —— ここより外(呼び出し元の async 文脈)では絶対に直呼びしない
    static func runOffCooperativePool<T: Sendable>(
        name: String, _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let thread = Thread {
                continuation.resume(returning: work())
            }
            thread.name = name
            thread.start()
        }
    }

    /// `candidatePorts` の結果に上限を掛ける(純粋関数・テスト用)。昇順にしてから切るので
    /// **上限を超えたときに確かめるのは常にポート番号の小さい側**(呼び出しごとに違う集合を
    /// 拾って結果が揺れるのを避ける)
    static func cappedCandidatePorts(_ candidates: [UInt16]) -> [UInt16] {
        Array(candidates.sorted().prefix(maxUDIDBridgeCandidatePorts))
    }

    /// この udid に紐づく可能性のあるポート(台帳由来)。**プロセスを起こすのは
    /// `BridgeLauncher.portsByUDID` の中の `ps` 1回だけ**(ポート数ぶん起こさない。lsof は
    /// 起こさない)。
    /// - xcuitest(実機も含む。実機も xcodebuild が `-destination id=<UDID>` を渡すので同じ経路):
    ///   `.pid` 台帳 + `ps` の照合(provision の「同一デバイスに2本目を立てない」判定と同じ経路)。
    /// - in-app: dylib 注入で別プロセス管理をしないため `.pid` を持たない。`.inapp` 台帳を直接読む
    ///   (`InAppBridgeState.write` の契約 = 「udid bundleID [digest]」を1行・空白区切り、の先頭語)。
    ///   `read` は FTBridgeClient 内部専用で fleetest-mcp からは呼べないため、ここでは udid の
    ///   1語だけを自前で取り出す(読むだけで FTBridgeClient は変更しない)
    static func candidatePorts(forUDID udid: String, repoRoot: URL?) -> Set<UInt16> {
        guard let repoRoot else { return [] }
        var ports = Set(BridgeLauncher.portsByUDID([udid], repoRoot: repoRoot)[udid] ?? [])
        let stateDir = repoRoot.appendingPathComponent(".fleetest")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil) else { return ports }
        for entry in entries where entry.lastPathComponent.hasPrefix("bridge-")
            && entry.pathExtension == "inapp" {
            guard let port = UInt16(entry.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "bridge-", with: "")),
                  let content = try? String(contentsOf: entry, encoding: .utf8),
                  content.split(separator: " ").first.map(String.init) == udid else { continue }
            ports.insert(port)
        }
        return ports
    }

    /// `port` と `udid` の突き合わせ。**走査から切り離した純粋関数** —— 実ブリッジが要ると
    /// 「食い違い」の枝がテストで一度も実行されず、判定を壊しても素通しする
    /// (2026-08-09 の変異テストで実際に素通しした)。
    /// **udid 側は複数ポートを許す**: 同じシミュレータに in-app / XCUITest の
    /// 2本が立つのが常態で、先頭の1本とだけ比べると正しい併記(udid + その in-app port)を
    /// 「別デバイス」と誤って拒否する(Simulator で 3/3 再現)
    static func reconcilePort(_ port: UInt16?, udid: String, udidPorts: [UInt16],
                              diagnosis: UDIDBridgeDiagnosis = .unknown) throws -> UInt16? {
        guard !udidPorts.isEmpty else {
            throw MCPError(Self.noResponsiveBridgeMessage(udid: udid, diagnosis: diagnosis))
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

    /// `reconcilePort` が応答ポート0本のときに組む文面(純粋関数・5形固定):
    /// ①LISTEN もしていない(本当に居ない・実体を名前引きできた) ②同①だが実体を判定できない
    /// ③LISTEN しているが `/status` がタイムアウト上限まで無応答(= busy。「居ない」とは言わない)
    /// ④LISTEN しているが `/status` への接続が早期に切れる(= wedged。ブリッジが消えて転送役
    /// だけ残っている。③と事実が違うので文面も分ける)。**④を③より先に見る** ——
    /// 両方が非空になる実測は無いが、wedged は「待っても戻らない」という強い事実なので
    /// busy 側の「Retry in a moment」より優先する。
    /// ⑤診断そのものが予算内に終わらなかった(`timedOut`。maintainer-notes §51.6)。①〜④は
    /// すべて「診断が完走した」上での分岐なので、**timedOut を全部より先に見る** —— 完走して
    /// いない回は busy/wedged の判定材料(probe の結果)自体が集まっていないので、空の
    /// `listeningButUnresponsive`/`wedgedPorts` を「本当に空だった」と読むと、確かめていない
    /// のに「居ない・bridge up しろ」を言うことになる(実際にこれで、明示 port が生きている
    /// 実機ブリッジへ2本目の起動を勧めかけた)
    static func noResponsiveBridgeMessage(udid: String, diagnosis: UDIDBridgeDiagnosis) -> String {
        guard !diagnosis.timedOut else {
            return Self.bridgeDiagnosisUnconfirmedMessage(udid: udid)
        }
        guard diagnosis.wedgedPorts.isEmpty else {
            return Self.bridgeWedgedOnUDIDMessage(udid: udid, diagnosis: diagnosis)
        }
        guard diagnosis.listeningButUnresponsive.isEmpty else {
            return Self.bridgeBusyOnUDIDMessage(udid: udid, diagnosis: diagnosis)
        }
        return "no running bridge is on udid \(udid). ft_list_devices shows which devices have one;"
            + " \(Self.bridgeUpSuggestion(udid: udid, lookup: diagnosis.lookup))"
            + " (a device without a bridge cannot be driven from MCP)"
    }

    /// 診断(`udidBridgeDiagnosis`)自体が予算内に終わらなかったときの文面(maintainer-notes §51.6)。**「居ない」と
    /// 断定せず `bridge up` も勧めない** —— ①〜④のどの事実も集められていないので、確かめられた
    /// のは「確かめられなかった」ことだけ。生きているブリッジへ2本目を起動させる案内を誤って出さない
    static func bridgeDiagnosisUnconfirmedMessage(udid: String) -> String {
        "could not confirm whether a bridge for udid \(udid) is running — the diagnosis did not"
            + " finish within its time budget (the Mac or the device may be busy right now)."
            + " This does not mean the bridge is gone, and `fleetest bridge up` is not suggested;"
            + " retry the call in a moment."
    }

    /// `bridge up` の完成コマンド(純粋関数)。**udid は名前より優先して解決される**
    /// (`SimulatorCatalog.resolve` — シミュレータなら `--device "<udid>"` がそのまま通り、
    /// 名前引き・同名複数台の曖昧さを迂回できる)。**実機は `--physical` を明示しないと
    /// 通らない** —— 実機 UDID は `bridge up` の「36 文字・ダッシュ5分割」形状判定に一致しない
    /// ため、`--physical` を付けなければシミュレータ名の文字列として名前引きされ必ず失敗する。
    /// **判定できないとき(`.notFound`/`.unreadable`)は嘘のコマンドを書かない** ——
    /// virtual/physical のどちらを付けるべきか断定できないので、確認の手順だけを返す。
    /// **`.notFound`(一覧は読めたが載っていない)と `.unreadable`(一覧を読めなかった)は文面を分ける**
    /// —— 後者を前者と同じ文言にすると、simctl がタイムアウトしただけの回を
    /// 「そのデバイスは存在しない」と読者に断定させる(2026-09-17 実測: 高負荷下の5.3秒応答時に発生)
    static func bridgeUpSuggestion(udid: String, lookup: SimulatorCatalog.UDIDLookup) -> String {
        switch lookup {
        case .simulator:
            return "start it with `fleetest bridge up --device \"\(udid)\"`"
        case .physical:
            return "start it with `fleetest bridge up --device \"\(udid)\" --physical`"
        case .notFound:
            return "no exact start command can be offered (that udid is not currently listed as"
                + " either a simulator or a physical device) — check ft_list_devices for its current"
                + " udid, then run `fleetest bridge up --device \"<udid>\"` for a simulator, or add"
                + " `--physical` for a physical device"
        case .unreadable(let reason):
            return "could not read the simulator/physical device lists (\(reason)), so no exact"
                + " start command can be offered — check ft_list_devices for its current udid, then"
                + " run `fleetest bridge up --device \"<udid>\"` for a simulator, or add `--physical`"
                + " for a physical device"
        }
    }

    /// LISTEN はしているが `/status` に答えなかったときの文面(純粋関数)。**「居ない」とは
    /// 言わない**(`BridgeDiscovery.busyMessage` と同じ立場。あちらは port 指定済みの再接続
    /// 専用なので、udid 解決の入口にはこちらが要る)。**`bridge up` は勧めない** ——
    /// 本当にどこにも居ないと確かめられたときだけの案内なので、ここで勧めると同じ機に
    /// 2本目を起動させる
    static func bridgeBusyOnUDIDMessage(udid: String, diagnosis: UDIDBridgeDiagnosis) -> String {
        let ports = diagnosis.listeningButUnresponsive.map { "port \($0)" }.joined(separator: ", ")
        var message = "a bridge for udid \(udid) is listening on \(ports) but did not answer"
            + " /status within the scan window — it may be busy with another request (XCUITest can"
            + " block the bridge for tens of seconds while waiting for the screen to settle)."
        if let heldByRunPID = diagnosis.heldByRunPID {
            message += " A fleetest run (pid \(heldByRunPID)) is using this device right now, which"
                + " is the likely cause."
        }
        message += " Retry in a moment; `fleetest bridge up` is for a device with no bridge at all"
            + " and would start a second one on this device."
        return message
    }

    /// LISTEN しているが `/status` への接続が早期に(タイムアウトよりはるかに早く)切れたときの
    /// 文面(純粋関数)。`bridgeBusyOnUDIDMessage` とは事実が違う —— busy はタイムアウト上限まで
    /// 応答を保持するが、こちらは接続が即座に失敗する(実測は
    /// `BridgeDiscovery.transportFailureFraction` のコメント参照)。**「busy」とは言わない**
    /// —— 待っても戻らない。**`bridge up` は勧めてよい** —— `bridgeBusyOnUDIDMessage` が
    /// 勧めない理由(「生きているブリッジに2本目を起動させる」)はここでは成り立たない:
    /// 転送(実機なら iproxy)は生きていてもブリッジ本体は既に消えている
    static func bridgeWedgedOnUDIDMessage(udid: String, diagnosis: UDIDBridgeDiagnosis) -> String {
        let ports = diagnosis.wedgedPorts.map { "port \($0)" }.joined(separator: ", ")
        var message = "a bridge for udid \(udid) is listening on \(ports), but the connection to"
            + " /status fails almost immediately instead of timing out — the bridge process is gone;"
            + " only its transport (on a physical device, iproxy) is still holding the port."
            + " This will not recover on its own. On a physical device, this typically follows the"
            + " screen locking, or the device leaving USB/network range."
        if let heldByRunPID = diagnosis.heldByRunPID {
            message += " A fleetest run (pid \(heldByRunPID)) is using this device right now."
        }
        message += " \(Self.bridgeUpSuggestion(udid: udid, lookup: diagnosis.lookup))"
        return message
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

    /// **profile と明示の宛先(udid/port/serial)は併用させない**。profile の枝は宛先を
    /// ft_run_scenario と同じ規則でプロファイルから決め、明示の宛先を1度も見ないので、黙って通すと
    /// **名指ししていない台**(プロファイルが選ぶ台)を操作する(実測: udid で -08 を名指ししたのに
    /// プロファイルの -01 でアプリを起動した)。platform は併用してよい(プロファイル内の OS を選ぶ)
    /// —— ここがシナリオ系の `profileConflict` と違う点。呼ぶのは `call()` の入口(udid を畳む前)。
    /// 記憶の注入は profile 指定時に働かない
    /// (`foldInRememberedDevice`)ので、ここに掛かるのは利用者が明示した組み合わせだけ
    static func profileWithExplicitTargetRefusal(_ args: [String: Any]) -> String? {
        guard let profile = args["profile"] as? String,
              argsGaveIOSTarget(args) || argsGaveAndroidTarget(args) else { return nil }
        return "profile \"\(profile)\" picks its own device (the same one ft_run_scenario would use), so it"
            + " cannot be combined with udid/port/serial — the call would drive the profile's device, not"
            + " the one you named. Drop profile to drive the named device (the engine then follows the"
            + " bridge running on it), or drop udid/port/serial to use the profile's device"
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
    /// **空白を許す形で見る**。引用符の中の `ref:` を拾う誤検知はあり得るが、
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
        // **udid を申告するのはシミュレータ上のブリッジだけ**(in-app・XCUITest とも SIMULATOR_UDID)。
        // 実機のランナーは申告しない(nil)ので、実機のポートを実機のランナー自身が答えている間は
        // 何もしない。**実機のポートをシミュレータのブリッジが奪った形は now = シミュレータの udid に
        // なるので捕まる**(2026-09-15 の負荷テストで DSL 側に起きた F8b の形。DSL は
        // FTCore.BridgeIdentityCheck が同じ udid 比較を持つ)。黙るのは**実機同士の入れ替わり**
        // (両方 nil)だけで、奪う側の採番・kill は PortHolder の ownerUDID / 生きた iproxy の除外で
        // 源から止めてある。`.fleetest/bridge-<port>.device` で補う余地はあるが広げない
        // (広げると誤拒否の側にリスクが移る)
        let endpoint = (try? RepoRoot.find()).map { BridgeEndpoint.load(port: port, repoRoot: $0) }
            ?? BridgeEndpoint(port: port)
        guard let now = try? await BridgeClient(endpoint: endpoint, timeoutSeconds: 5).status().udid,
              let moved = Self.keyChangedDevice(previous: recorded, now: now) else { return nil }
        forgetDeviceState(key)
        return Self.movedDeviceRefusal(port: port, previousUDID: moved, nowUDID: now)
    }

    /// **主ポートのエンジンが変わっていないか(maintainer-notes §51.10)**: `deviceIdentityChanged` は
    /// udid しか見ず、しかも `usesRememberedDeviceState` で ref を使う呼び出しにしか効かない —— 同じ
    /// udid のまま run のたびのブリッジ建て直しでエンジンが xcuitest ⇄ inapp/hybrid に入れ替わった形を
    /// 見逃す。**実測**: xcuitest でキャッシュ済みのドライバの port が in-app ブリッジへ化け、ref を
    /// 使わない `ft_terminate`(`usesRememberedDeviceState` のゲートを通らない)が
    /// 「in-app では未サポート」の 501 を返した(in-app には /terminate が無い)。逆向き
    /// (キャッシュは in-app 期待だが実は xcuitest)なら tap/snapshot は成功で返るが、**別の ref 体系・
    /// 別の挙動**を渡している —— 気付ける形の失敗がむしろ良性
    /// (`usesRememberedDeviceState` を流用しない理由も同じ: ref を使わない呼び出しでこそ実際に踏んだ)。
    /// **iOS のキャッシュ命中では毎回確かめる**(`hybridFallbackDrifted` と同じコストの考え方 ——
    /// 1回の loopback probe)。判定は同じ `FTBridgeClient.HybridFallbackIdentity` の1箇所
    func primaryEngineDrift(_ key: String) async -> BridgeIdentityCheck.HybridFallbackDrift {
        guard let port = connectedPorts[key], let expectedUDID = udids[key] ?? nil,
              let engine = engines[key] else { return .none }
        let expectedEngine = engine == "xcuitest" ? "xcuitest" : "inapp"
        return await HybridFallbackIdentity.drifted(
            port: port, expectedUDID: expectedUDID, expectedEngine: expectedEngine,
            repoRoot: try? RepoRoot.find())
    }

    /// `primaryEngineDrift` の結果を、この call をどう扱うかへ落とす。**旧エンジンの ref はどの道
    /// 無効**なので、`.none` 以外は必ず `forgetDeviceState`(fallback 専用の `hybridFallbackDrifted`
    /// と違い、こちらは primary = ref の起点そのもの)。
    /// - `.sameDeviceEngineChanged`: **この呼び出し自身が記憶に依っているときだけ拒否**
    ///   (`usesRememberedDeviceState`)—— 依っていなければ、捨てた上でこの call 自身を新しい
    ///   ドライバで再解決させれば足りるので、利用者に「撮り直せ」と言う理由が無い
    ///   (`ft_terminate` はまさにこの形 = 黙って直った状態で続行してよい)
    /// - `.differentDevice`: **ref の有無を問わず必ず拒否**する。ここで黙って作り直すと、
    ///   ref を使わない呼び出し(`ft_tap x/y`・`ft_type` 等)が警告なしで別の台へ効き続け、
    ///   以後のセッションがその台に固定される
    enum PrimaryEngineCheck: Equatable {
        case unchanged, rebuildSilently, refuse(String)
    }

    /// `primaryEngineDrift`(I/O)が拾った事実から、この call をどう扱うかを決める
    /// **走査から切り離した純粋関数**(`keyChangedDevice`/`hybridFallbackDrift` と同じ理由・
    /// テスト用): 実ブリッジ無しで「記憶に依る呼び出しだけ拒否する」判定そのものを固定できる
    static func primaryEngineOutcome(
        drift: BridgeIdentityCheck.HybridFallbackDrift, usesRememberedDeviceState: Bool,
        port: UInt16?, expectedEngine: String?, expectedUDID: String?, callerNamedUDID: Bool
    ) -> PrimaryEngineCheck {
        switch drift {
        case .none:
            return .unchanged
        case .differentDevice:
            // args の udid は呼び手の明示だけ(記憶の補完は port しか書かない)= 今そのポートに居る台を
            // 名指しした同意なので作り直してよい。明示が無ければ断り続ける(primaryEngineCheck が記憶を残す)
            guard !callerNamedUDID else { return .rebuildSilently }
            return .refuse(differentDeviceRefusal(port: port, expectedUDID: expectedUDID))
        case .sameDeviceEngineChanged:
            guard usesRememberedDeviceState else { return .rebuildSilently }
            return .refuse(engineChangedRefusal(port: port, expectedEngine: expectedEngine))
        }
    }

    /// `primaryEngineOutcome` の I/O 込みの入口。**`.unchanged` 以外は `forgetDeviceState`**
    /// (旧エンジンの ref はどの道無効。`.rebuildSilently` でも捨てる — 呼び出し元はこの call を
    /// 下の生成で再解決させるだけで、拒否文を返す理由は無い)。
    /// **例外は別の台を断ったとき**: 記憶(udid・キャッシュ)を捨てると次の同じ呼び出しが生成経路へ落ち、
    /// `keyChangedDevice` の previous が nil になって**黙って別の台に固定される**。残して毎回断る
    func primaryEngineCheck(_ key: String, args: [String: Any]) async -> PrimaryEngineCheck {
        let drift = await primaryEngineDrift(key)
        let callerNamedUDID = (args["udid"] as? String).map { !$0.isEmpty } ?? false
        let outcome = Self.primaryEngineOutcome(
            drift: drift, usesRememberedDeviceState: Self.usesRememberedDeviceState(args),
            port: connectedPorts[key], expectedEngine: engines[key], expectedUDID: udids[key] ?? nil,
            callerNamedUDID: callerNamedUDID)
        if case .unchanged = outcome { return outcome }
        if drift == .differentDevice, case .refuse = outcome { return outcome }
        forgetDeviceState(key)
        return outcome
    }

    /// 同じ機のまま(udid は同じ)ブリッジのエンジンだけが変わっていたときに呼び出しを断る文。
    /// **`movedDeviceRefusal` と文面を分ける** —— 「別の機だ」と早合点させない(繋ぎ直す先の
    /// 機は無い。同じ機のブリッジが建て直しでエンジンを変えただけ)
    static func engineChangedRefusal(port: UInt16?, expectedEngine: String?) -> String {
        let where_ = port.map { "port \($0)" } ?? "this bridge"
        let engineLabel = expectedEngine.map { "the \($0) engine" } ?? "its previous engine"
        return "\(where_) no longer answers as \(engineLabel) this session cached it for"
            + " (the same device appears to have rebuilt its bridge with a different engine)"
            + " — refusing this call because it relies on state remembered for the previous engine"
            + " (a ref, or the launched app that ft_open_url defaults to; refs do not carry across"
            + " engines). That state has been dropped. Take a fresh ft_snapshot and use the new refs."
    }

    /// primary ポートが別の udid へ移っていたときに呼び出しを断る文。**`movedDeviceRefusal` と役割は
    /// 同じ**(捨てたものを名指しする)が、ここは `primaryEngineOutcome` が持つ材料(実測の
    /// 「今の」udid は無く、期待していた udid だけ)に合わせて文面を作る。**ref の有無を問わず
    /// 常にこの文を返す**(`sameDeviceEngineChanged` の `engineChangedRefusal` と違い、
    /// `usesRememberedDeviceState` の分岐は無い)
    static func differentDeviceRefusal(port: UInt16?, expectedUDID: String?) -> String {
        let where_ = port.map { "port \($0)" } ?? "this bridge"
        let expectedLabel = expectedUDID ?? "the device this session cached it for"
        return "\(where_) now belongs to a different device than \(expectedLabel)"
            + " — nothing was sent. This session keeps refusing calls on this port until you pass"
            + " udid explicitly (the device you mean to drive); call ft_list_devices to see which"
            + " device is on which port now."
    }

    /// **hybrid キャッシュ命中の fallback(XCUITest)ポートが別の機/別エンジンへ移っていないか**
    /// (maintainer-notes §51.2): `deviceIdentityChanged` は主(in-app・`connectedPorts`/`udids`)しか
    /// 見ないので、`HybridFallbackDriver` の fallback が握る `hybridFallbackPorts[key]` は
    /// ノーチェックのまま残っていた。ブリッジは run のたびに建て直され**同じポート番号が
    /// 別デバイス(あるいは同じデバイスの in-app ブリッジ)に化ける**ため、home/appSwitcher/drag/
    /// 座標 press/gesture/pinch(すべて fallback 経由。primary の in-app は 501 で必ず回る)が
    /// 黙って別の機を操作しうる。
    ///
    /// **`usesRememberedDeviceState` のゲートは流用しない**: あちらは ref が指す要素が
    /// 別物になる形だけを守る規律で、fallback は ref を一切受けない(HybridFallbackDriver の
    /// doc「ref を使う操作は回さない」)ので ref の有無では判定できない。hybrid のキャッシュ命中
    /// でだけ効くので、コストは Android・xcuitest 単独・inapp 単独の呼び出しには掛からない。
    ///
    /// **I/O・判定とも `FTBridgeClient.HybridFallbackIdentity`(`FTCore.BridgeIdentityCheck`)の
    /// 1箇所**(ライブ操作(api live serve)と共有 —— 二つ目の実装を書かない。「不明(/status を
    /// 読めない・タイムアウト)は変わったに倒さない」もそちらが守る)。ここに残るのは MCP の
    /// キャッシュ(`hybridFallbackPorts`/`udids`)から材料を集めるだけ。
    /// **食い違っていてもここでは断らない** —— 呼び出し元がキャッシュを落として次の解決に委ねる
    /// (fallback には捨てるべき ref/起動アプリの記憶が無いので、断って利用者へ「撮り直せ」と
    /// 言う理由が無い。udid は分かっているので次の解決が静かに `.inappOnly` へ縮退することもある)
    func hybridFallbackDrifted(_ key: String) async -> Bool {
        guard let port = hybridFallbackPorts[key], let expectedUDID = udids[key] ?? nil else {
            return false
        }
        return await HybridFallbackIdentity.drifted(
            port: port, expectedUDID: expectedUDID, repoRoot: try? RepoRoot.find()) != .none
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
    /// **`profile:` も名指しとして数える**: profile で実機を指すセッションは udid/port を
    /// 一度も渡さないので、ここが profile を見ないと2台目を触っても曖昧さガードに数えられず
    /// 省略呼び出しが黙って別の機(仮想デバイス側)へ流れる(実機監査 2026-08-13 で実際に踏んだ)
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
    /// pid ファイルの残りで別ポートを選ぶ(Fleetest.swift の警告)。
    /// **判定は `FTBridgeClient.BridgeTargetResolution.iosPort` を通す**(CLI の手動駆動
    /// サブコマンドと共有)。ここは `BridgeTargetError` を `MCPError` へ包むだけ
    /// (文言は BridgeDiscovery のまま1文字も変えない)
    static func resolveIOSPort(explicit: UInt16?) async throws -> UInt16 {
        do {
            return try await BridgeTargetResolution.iosPort(explicit: explicit, log: Self.logStderr)
        } catch let error as BridgeTargetError {
            throw MCPError(error.errorDescription ?? "\(error)")
        }
    }

    /// profile 無しの Android 宛先。**serial 無しで adb を撃たない**(複数台なら
    /// "more than one device/emulator" が生で出る)。
    /// **判定は `FTAndroid.AndroidTargetResolution.serial` を通す**(CLI と共有)。
    /// ここは `AndroidTargetError` を `MCPError` へ包むだけ
    static func resolveAndroidSerial(explicit: String?) throws -> String {
        do {
            return try AndroidTargetResolution.serial(explicit: explicit, log: Self.logStderr)
        } catch let error as AndroidTargetError {
            throw MCPError(error.errorDescription ?? "\(error)")
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
    static func iosDriver(provisioned: ProvisionedIOSDevice, bundleID: String?) async throws
        -> (driver: AppDriver, probePort: UInt16?, xcuiPort: UInt16?) {
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
            return (driver, probe, nil)
        }
        let inapp = InAppDriver(repoRoot: try RepoRoot.find(), udid: provisioned.udid,
                                port: provisioned.port)
        guard provisioned.engine == "hybrid", let xcuiPort = provisioned.xcuiPort,
              let bundleID else {
            return (inapp, provisioned.port, nil)
        }
        // attach は**同じインスタンス**を委譲とフォールバックの両方に使う(実行側と同じ理由:
        // activate/attached 状態を1本にしないと余計な activate が挟まる)
        let attach = AppAttachDriver(port: xcuiPort, host: provisioned.host, bundleID: bundleID,
                                     physicalUDID: provisioned.physical ? provisioned.udid : nil)
        // hybrid の主は in-app(provisioned.port)。同一性はそちらへ問う。
        // **合成は HybridDriverComposition の1箇所**(ライブ操作・シナリオ実行と同じ形にする)
        return (HybridDriverComposition.inAppFirst(
                    inApp: inapp, attach: attach,
                    foreignApp: SessionRecoveryDriver(base: BridgeClient(
                        port: xcuiPort, host: provisioned.host,
                        physicalUDID: provisioned.physical ? provisioned.udid : nil)),
                    bundleID: bundleID),
                provisioned.port, xcuiPort)
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
    /// は末尾に畳み込む。
    /// **`frameworkKey` が判明していて一致しなければ黙る**(この助言は `framework` 1つに
    /// 固有の欠陥で、他のフレームワーク(判明した uikit や、もう一方の compose/flutter)には
    /// 効かない誤誘導になる)。**不明なら従来どおり出すが「もしこのフレームワークなら」に弱める**
    /// (uiFrameworkHints は判定に成功した回しか埋まらないので、まだ問い合わせていない接続は不明側)
    func iosEngineHint(_ framework: String, frameworkKey: AppUIFramework, _ gesture: String,
                      args: [String: Any]) -> String {
        guard engines[Self.engineKey(args)] == "xcuitest" else { return "" }
        // `fleetest bridge up --engine inapp` と案内しない —— そのフラグは存在しない
        // (in-app ブリッジは in-app/hybrid の実行プロファイル経由でだけ立つ。2026-08-08 に確認)
        let advice = " pass profile: naming an in-app/hybrid run profile, which starts"
            + " an in-app bridge (this relaunches the app — re-navigate before retrying)."
        switch uiFrameworkHints[Self.engineKey(args)] {
        case .some(let known) where known != frameworkKey:
            return ""
        case .some:
            return " If nothing changed on iOS: \(framework) apps do not receive \(gesture) on the"
                + " XCUITest engine —" + advice
        case .none:
            return " If nothing changed on iOS and this is a \(framework) app: it would not receive"
                + " \(gesture) on the XCUITest engine —" + advice
        }
    }

    /// **launch する前に**確かめる。未インストールのまま `XCUIApplication.launch()` を撃つと、
    /// XCUI が記録する issue が(main queue 上 = テストのスタック外なので)ランナーごと落とし、
    /// ブリッジが消える —— 2026-08-06 の外部フィードバック #7 の真因はこれで、
    /// 「Safari 操作後に切断」に見えていたのは**別ポートで先に死んでいたランナー**だった。
    /// requireLiveApp と同じ形(XCUI に触れる前に弾いて手前でエラーにする)。
    ///
    /// ブリッジ側は未インストールと未起動を区別できない(XCUIApplication はどちらも notRunning)
    /// のでホストが確かめる。iOS のシステムアプリ(springboard/Safari)も get_app_container が
    /// runtime のパスを返すので誤って弾かない(2026-08-06 実測)。
    ///
    /// **判定そのものを返す**(Bool? ではない): 「確かめられない」ときに撃つか断つかは呼び出し側
    /// (`launchGuardDecision`)がエンジン・OS を見て決める。ここで nil = 素通しへ潰すと、
    /// in-app とそれ以外で扱いを変えられなくなる
    func installedVerdict(
        bundleID: String, driver: AppDriver, args: [String: Any]
    ) async -> InstalledAppCheck.InstallVerdict {
        // 差し替えドライバ(テスト)ではデバイスを照会しない = simctl/adb を撃たない。
        // **`.unknown` を返さない** —— 門は unknown を「撃たない」側に倒すので、差し替え
        // ドライバの launch が全部断られる
        guard makeDriver == nil else { return .installed }
        let verdict: InstalledAppCheck.InstallVerdict
        if let android = driver as? AndroidDriver {
            if let installed = android.isInstalled(bundleID: bundleID) {
                verdict = installed ? .installed : .notInstalled
            } else {
                verdict = .unknown("adb")
            }
        } else {
            // **実機は simctl ではなく devicectl**(§19.3 M8。ft_list_apps の同型判定と揃える —
            // MCPServer+SessionTools.swift の ftListApps 参照): 実機の udid を simulatorInstallVerdict
            // へ渡すと、udid の形が同じシミュレータ名(既定は機種名なので実機と同名になりやすい)を
            // 誤って照会し、別デバイスの在否を答える。候補は3段(ft_list_apps と同じ優先順)
            let key = Self.engineKey(args)
            let candidateUDID = (args["udid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? udids[key].flatMap { $0 }
                ?? connectedPorts[key].flatMap { port in
                    (try? RepoRoot.find()).flatMap { BridgeDeviceRecord.load(port: port, repoRoot: $0) }
                }
            // **シミュレータの UDID(UUID 形)では devicectl を撃たない** —— 毎 ft_launch に 1 秒級の
            // `devicectl list devices` を払わせない。実機の UDID は `00008110-…`(8-16)で UUID にならない
            if let candidateUDID, UUID(uuidString: candidateUDID) == nil,
               let physicalDevices = try? IOSPhysicalDeviceCatalog.devices(),
               physicalDevices.contains(where: {
                   $0.udid == candidateUDID || $0.deviceCtlIdentifier == candidateUDID
               }) {
                if let apps = try? IOSPhysicalAppCatalog.apps(udid: candidateUDID) {
                    verdict = apps.contains { $0.id == bundleID } ? .installed : .notInstalled
                } else {
                    verdict = .unknown("devicectl could not list installed apps")
                }
            } else if let candidateUDID, UUID(uuidString: candidateUDID) != nil {
                // udid が分かるならデバイス名版(同名複数台で曖昧になりうる)を経由しない
                verdict = InstalledAppCheck.simulatorInstallVerdict(udid: candidateUDID, bundleID: bundleID)
            } else if let device = try? await driver.status().device {
                verdict = InstalledAppCheck.simulatorInstallVerdict(deviceName: device, bundleID: bundleID)
            } else {
                verdict = .unknown("the bridge did not report a device")
            }
        }
        return verdict
    }

    /// 撃つ側(Android・in-app)で確かめられなかったときの記録。**断る側では出さない** ——
    /// あちらは拒否文言そのものが呼び出し元へ届く
    static func uncheckedNote(bundleID: String, reason: String) -> String {
        "could not verify whether \(bundleID) is installed (\(reason)) — launching anyway."
    }

    static func notInstalledMessage(bundleID: String) -> String {
        "\(bundleID) is not installed on this device."
            + " Install it with ft_install packagePath: <.app or .apk>, or check the bundle ID"
            + " (Android: the package name)."
    }

    /// **ft_launch の門**。nil = 撃ってよい・非 nil = その文言で断る。判定そのものは
    /// `InstalledAppCheck.launchGuard`(ライブ操作の launch/activate と共有する唯一の定義元)へ
    /// 委ね、ここは MCP 向けの文言(ft_install を指す等)を組むだけ
    static func launchGuardDecision(
        verdict: InstalledAppCheck.InstallVerdict, isAndroid: Bool, engine: String?, bundleID: String
    ) -> String? {
        switch InstalledAppCheck.launchGuard(
            verdict: verdict, isAndroid: isAndroid, engine: engine, bundleID: bundleID) {
        case .allow: return nil
        case .refuse(.notInstalled): return notInstalledMessage(bundleID: bundleID)
        case .refuse(.unknown(let reason)): return uncheckedLaunchRefusal(bundleID: bundleID, reason: reason)
        }
    }

    /// **確かめられなかったので撃たない**ときの文言。①確かめられなかった理由 ②撃った場合に
    /// 起きること(XCUITest ランナーの main queue ハング → ブリッジ自壊。§T1 実測)③次の手、の3点を持つ
    static func uncheckedLaunchRefusal(bundleID: String, reason: String) -> String {
        "could not verify whether \(bundleID) is installed (\(reason))."
            + " Launching an app that turns out to be missing hangs XCUIApplication.launch(),"
            + " and after about 60s the XCUITest bridge self-terminates"
            + " (\"handler timed out after 60s; bridge self-terminating\") — this call refuses"
            + " instead of risking that."
            + " Retry in a moment (the check may succeed once the device is less busy),"
            + " install it first with ft_install packagePath: <.app or .apk>,"
            + " or double-check the bundle ID."
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
            + " ft_launch bundleId: <your app> resume: true to go back to it without losing its"
            + " state (xcuitest engine only), or ft_launch bundleId: <your app> to relaunch it"
            + " from scratch."
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

    /// home/appSwitcher 直後の XCUITest は「セッションはアプリのまま・画面は別」になり、次の
    /// ft_snapshot がアプリの古い木か 500 を返す。**撃つ前に言うしかない**(先に言う。
    /// 踏んでから調べさせない)。
    ///
    /// **同名の `backgroundedSessionNote(_:driver:)` とは別物**: あちらは木を撮ったあとに
    /// `/appstate` へ聞いて「今 前面か」を言う(実機の iPhone 13 では**その照会が
    /// 前面と答えて黙った**実測がある)。こちらは照会に頼らず「ツール自身が背面化させた」
    /// という事実だけで言うので、プラットフォームの答えが当てにならない機械でも必ず出る
    static func backgroundingNavigationNote(target: String, engine: String?) -> String {
        guard target == "home" || target == "appSwitcher",
              engine == nil || engine == "xcuitest" else { return "" }
        if target == "appSwitcher" {
            return ". The App Switcher opened, but the session still points at the app, so"
                + " ft_snapshot may keep returning the app's tree, and a tap by ref there could"
                + " land on whatever the switcher is drawing instead. Check ft_screenshot to see"
                + " what is actually on screen, then ft_launch your app again to bring it back"
        }
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
            + " (slower reads; ft_snapshot shows whatever is on screen now — the home screen /"
            + " app switcher — not the app) until you bring it back with ft_launch"
    }

    /// 待ちの既定(秒)。定義元は FTCore.DefaultWait(DSL の FTRuntime.defaultTimeout と共有)
    static let defaultWaitSeconds: Double = DefaultWait.seconds

    /// ポーリング間隔(秒)。短くしても律速は snapshot 自体(iOS in-app で約 0.12s)。
    /// waitFor と waitForChange(snapshotAfterBody)が共有する
    static let waitPollSeconds: Double = 0.3

    /// waitForChange が「変わった」後に安定(直前の読みと一致)を確かめる再読の上限。
    /// 1回で一致するのが普通で、上限まで揺れ続けたら採り直しをやめて still-changing を注記する
    /// —— waitSeconds を食い潰さない固定小コストに抑えるための蓋(settleWaitSeconds × この回数)
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
    ///
    /// **システム UI の面には言わない**(2026-08-28・実機 Pixel 4a で実害確認)。Android の
    /// `foregroundAppID()` は **topmost *app* package**(`mCurrentFocus` のアクティビティ名)を
    /// 返すので、通知シェード / クイック設定のように**アクティビティを持たない窓**が前面に居ると
    /// `com.android.systemui` は決して一致しない —— 木がまさにその面のものでも
    /// **必ず**「前面に居ない・木は古い・ft_launch で戻せ」と言っていた。事実と逆なうえ、
    /// 助言どおり `ft_launch com.android.systemui` を撃つ道理も無い。
    /// **`switchedAppNote` は同じ集合を見て既にこれを避けている**(欠陥⑧)—— こちらが
    /// その掃討漏れだった。判定材料が無いのだから**黙る**(この関数の既存の縮退と同じ)。
    /// iOS の springboard では再現しない(実測: 誤警告なし)ので触っていない
    static func backgroundedSessionNote(_ snapshot: SnapshotResponse,
                                        driver: AppDriver) async -> String {
        guard let bundleID = snapshot.sessionBundleID,
              !systemDialogPackages.contains(bundleID),
              let foreground = try? await driver.isAppForeground(bundleID: bundleID),
              !foreground else { return "" }
        return "\(bundleID) is NOT in the foreground: this tree is its last state, not what is on"
            + " screen now (another app or a system screen is in front)."
            + " Bring it back with ft_launch before trusting these refs\n"
    }

    /// **このセッションが home / appSwitcher を送ったあと、まだ ft_launch で戻していない**
    /// ときの注記。`/appstate` の照会と違い**プラットフォームに聞かない**ので、答えが
    /// 当てにならない機械(実機 iPhone 13 で前面と答えた実測)でも必ず出る。
    /// **文言は `HybridFallbackDriver.backgroundSnapshot` と合わせてある**(2026-09-06): 背面化中は
    /// 再前面化せず今の画面(SpringBoard 等)をそのまま読むので、対象アプリの「最後の状態」ではなく
    /// 「今そこに実際にあるもの」だと案内する
    /// **名指しは対象アプリ**: 背面化中の読みは SpringBoard を参照するので snapshot の
    /// sessionBundleID は com.apple.springboard になっている。呼び手は launch したアプリの ID を渡し、
    /// それが無いときも springboard を「戻すべきアプリ」と言わない
    /// **`treeIsAppsOwn`**: 木の sessionBundleID がそのアプリのまま(XCUITest のセッションは背面化
    /// してもアプリに付いたままで、**アプリ自身の木**を返し続ける)なら「今の画面」とは言わない ——
    /// 実機 iPhone 13 では appSwitcher の直後に「the tree below is whatever is actually on screen」と
    /// 言いながらアプリの木を返していた(§19.3 担当報告の再現)。hybrid の背面化読み(SpringBoard を
    /// 参照 = sessionBundleID が springboard)のときだけ従来の「今そこにあるもの」
    static func sentToBackgroundNote(_ sessionBundleID: String?, treeIsAppsOwn: Bool) -> String {
        let app = sessionBundleID.flatMap { $0 == "com.apple.springboard" ? nil : $0 } ?? "the app"
        if treeIsAppsOwn {
            return "⚠️ This session sent home/appSwitcher and has not brought \(app) back:"
                + " the tree below is still \(app)'s own tree (the session stays attached to it),"
                + " NOT what is on screen now (home screen / app switcher / a system screen) —"
                + " a tap by ref here lands on whatever is drawn there instead."
                + " Check with ft_screenshot, and ft_launch \(app) to return.\n"
        }
        return "⚠️ This session sent home/appSwitcher and has not brought \(app) back:"
            + " the tree below is whatever is actually on screen now (home screen / app switcher /"
            + " a system screen), not \(app)'s. Check with ft_screenshot, and ft_launch to return.\n"
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
    ///
    /// `processEvidence`(Android のみ・呼び出し側が adb で引く)が `running == false` を
    /// 言っているときは、原因を「操作でアプリを離れた」から「プロセスが無い(クラッシュの疑い)」
    /// へ差し替える —— 2026-09-05・実機 Pixel 4a で実測: #btn_crash_confirm でプロセスを落とすと、
    /// 通常文言は launcher へ迷い込んだとしか言わず、実際に落ちたことを伝えられない。
    /// **`stoppedByTool` はさらに確度が高い事実**(推測ではなく、ツール自身が撃った操作)なので
    /// processEvidence より先に見る —— 明示 ft_clear_app_data / ft_install の直後は
    /// 「クラッシュしたかも」ではなく「この操作で止めた」と言う(§19.3 M2)
    static func switchedAppNote(launched: String?, snapshot: SnapshotResponse,
                                processEvidence: AndroidAppProcessEvidence? = nil,
                                stoppedByTool: String? = nil) -> String {
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
        if let stoppedByTool {
            return "⚠️ This tree belongs to \(session), NOT the app you launched (\(launched))"
                + " — \(launched) is not running because \(stoppedByTool) stopped it just now"
                + " (not a crash). ft_launch \(launched) to start it again.\n"
        }
        if let processEvidence, !processEvidence.running {
            var note = "⚠️ This tree belongs to \(session), NOT the app you launched (\(launched))"
                + " — and \(launched) has no process any more: it may have crashed."
            if !processEvidence.crashSummary.isEmpty {
                note += " Last crash in logcat -b crash: "
                    + processEvidence.crashSummary.joined(separator: " / ") + "."
                    // **`crashOnly` は ft_logs の引数名ではない**: 実際のスキーマは
                    // `all`(既定 false = crash バッファのみ)なので、無指定の ft_logs が
                    // そのまま全文を出す
                    + " ft_logs shows the full trace."
            }
            return note + " ft_launch \(launched) to start it again.\n"
        }
        return "⚠️ This tree belongs to \(session), NOT the app you launched (\(launched))."
            + " Leaving the app (back from its first screen, home, an app switch) hands the"
            + " tools to whatever is in front now — and sibling test apps can look identical."
            + " ft_launch \(launched) before trusting these refs\n"
    }

    /// `launched` の launch timestamp が分からないときの既定の遡り窓(秒)。ft_logs の既定
    /// (`sinceSeconds` 省略時 300)と揃える —— このツールが「直近」とみなす幅の唯一の他の定義元
    static let defaultCrashAttributionWindowSeconds = 300

    /// crash 引用に使う `sinceSeconds` の純関数。**5秒の余裕を足す** —— launch から
    /// クラッシュまでの実時間+adb 往復のぶんを切り捨てて肝心のクラッシュ行を落とさないため。
    /// 分からなければ ft_logs と同じ既定(5分)に倒す(無制限には戻さない)
    static func crashAttributionWindowSeconds(launchedAt: Date?, now: Date) -> Int {
        guard let launchedAt else { return defaultCrashAttributionWindowSeconds }
        return max(5, Int(now.timeIntervalSince(launchedAt).rounded(.up)) + 5)
    }

    /// `switchedAppNote` の `processEvidence` 引数を埋める(Android のみ・adb 2〜3往復)。
    /// **すり替わっていない通常の呼び出しでは adb を払わない**(session == launched ならここで
    /// 抜ける)。serial は明示引数か、このセッションが覚えている宛先(connectedAndroidSerials。
    /// resolveAndroidSerial と違い**曖昧でも例外にしない** —— これは付加情報で、
    /// 取れなければ nil のまま adb の既定(単一接続時のみ解決)に委ねる。
    ///
    /// **crashSummary は直近の launch 以降に絞り直す**: `AndroidAppProcessEvidenceQuery
    /// .query` は `adb logcat -d -b crash` を時間で絞らず丸ごと読むので、素の crashSummary は
    /// 数分〜数時間前の**別プロセス**のクラッシュも拾う(crash バッファは端末側で自然に消えるまで
    /// 残り続ける)。`launchTimestamps` を起点に `AndroidLogcat.recent(sinceSeconds:)`
    /// (ft_logs と同じ時間フィルタ)で撮り直し、その範囲内のブロックだけを名指しする。
    /// launch を覚えていない(このセッションが ft_launch していない・profile 経由で既存の
    /// セッションに繋いだ)ときは `defaultCrashAttributionWindowSeconds` へ落ちる
    /// (無制限に戻すと元の欠陥に戻るので、「分からない」を「無限に遡ってよい」とは読まない)
    func androidProcessEvidenceForSwitch(launched: String?, snapshot: SnapshotResponse,
                                         driver: AppDriver, args: [String: Any])
        -> AndroidAppProcessEvidence? {
        guard driver is AndroidDriver, let launched, let session = snapshot.sessionBundleID,
              session != launched else { return nil }
        let serial = (args["serial"] as? String) ?? connectedAndroidSerials[Self.engineKey(args)]
        guard let evidence = AndroidAppProcessEvidenceQuery.query(package: launched, serial: serial)
        else { return nil }
        guard !evidence.running, !evidence.crashSummary.isEmpty else { return evidence }
        let sinceSeconds = Self.crashAttributionWindowSeconds(
            launchedAt: launchTimestamps[Self.engineKey(args)], now: Date())
        guard let scoped = try? AndroidLogcat.recent(serial: serial, packageName: nil, crashOnly: true,
                                                     sinceSeconds: sinceSeconds, maxLines: 5000)
        else { return AndroidAppProcessEvidence(running: evidence.running, crashSummary: []) }
        let scopedSummary = AndroidAppProcessEvidenceQuery.crashSummary(
            fromCrashLog: scoped.lines.joined(separator: "\n"), package: launched)
        return AndroidAppProcessEvidence(running: evidence.running, crashSummary: scopedSummary)
    }
}
