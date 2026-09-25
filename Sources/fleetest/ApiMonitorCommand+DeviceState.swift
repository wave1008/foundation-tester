// ApiMonitorCommand+DeviceState.swift
// `fleetest api monitor` のデバイス状態判定(simctl/adb 一括走査・凍結判定・スクリーンショット取得)。ApiMonitorCommand.swift から分離。

import ArgumentParser
import CoreGraphics
import Foundation
import FTAndroid
import FTBridgeClient
import FTCore
import FTRemote
import ImageIO
import UniformTypeIdentifiers

extension ApiMonitorCommand {
    // MARK: - デバイス状態判定

    /// iOS は simctl 一覧+ブリッジ /status、Android は起動中 AVD 一覧をそれぞれ一括取得して
    /// 各デバイスへ振り分ける(デバイス毎に simctl/adb を叩くと台数に比例して遅くなるため)。
    /// internal: ApiListDevicesCommand.swift が単発の状態判定にも同じロジックを再利用する
    /// includeUnregistered: true のとき、台帳未記載でも起動中(iOS booted sim /
    /// Android running AVD)なら合成した DeviceRuntimeState を追加で返す(unregisteredStates 参照。
    /// 実機は対象外)。list-devices(--profile 指定時と同様スコープを絞る意図)は既定 false のまま。
    /// `skipped`(id 衝突で落とした合成デバイス)は**返すだけ** —— 常駐監視は毎周期ここを通るので、
    /// その場で出すと原因が残る間ずっと同じ行が流れ続ける(呼び手が変化を見て出す)
    static func determineStates(targets: [MonitorTarget],
                                repoRoot: URL? = try? RepoRoot.find(),
                                includeUnregistered: Bool = false)
        async -> (states: [DeviceRuntimeState], skipped: [String]) {
        async let bridgeStatusesTask = scanBridgeStatuses(repoRoot: repoRoot)
        let simCatalog = (try? SimulatorCatalog.devices()) ?? []
        let runningAVDs = (try? AndroidDeviceCatalog.runningAVDs()) ?? [:]
        // 実機は AVD 照合に載らないので adb の接続一覧で見る(エミュレータも含む全 serial)
        let connectedSerials = Set((try? AndroidDeviceCatalog.connectedSerials()) ?? [])
        // ブート未完了なのに connected 扱いでスクショ取得(=ブリッジAPK自動インストール)を
        // 試みるとパッケージマネージャ未起動で失敗するため、起動中の対象のみブート完了を確認する
        let androidCandidateSerials = Set(targets.compactMap { target -> String? in
            guard target.platform == "android" else { return nil }
            // 実機は serial 直指定(接続していれば候補)。エミュレータは AVD 照合で serial を得る
            if target.spec.isPhysical {
                return target.spec.serial.flatMap { connectedSerials.contains($0) ? $0 : nil }
            }
            guard let avd = target.spec.avd else { return nil }
            let canonical = AndroidDeviceCatalog.canonicalAVDID(avd)
            return runningAVDs.first(where: { $0.value == canonical })?.key
        })
        let registeredCanonicalAVDIDs = Set(targets.compactMap { target -> String? in
            guard target.platform == "android", !target.spec.isPhysical, let avd = target.spec.avd
            else { return nil }
            return AndroidDeviceCatalog.canonicalAVDID(avd)
        })
        // includeUnregistered のときは未登録の running AVD の serial もブート完了スキャンに加える
        // (加えないと合成デバイスがブリッジAPK自動インストールを一切試みず永久に booted のまま)
        // 未登録のエミュレータ + **接続中の実機**(実機も合成対象。unregisteredStates の doc)。
        // **1回の scanBootCompleted に畳む** —— 別に呼ぶと同じ adb 往復を毎サイクル二重に払う
        let unregisteredAndroidSerials: Set<String> = includeUnregistered
            ? Set(runningAVDs.filter { !registeredCanonicalAVDIDs.contains($0.value) }.keys)
                .union(connectedSerials.filter { !$0.hasPrefix("emulator-") })
            : []
        async let bootCompletedTask = scanBootCompleted(
            serials: androidCandidateSerials.union(unregisteredAndroidSerials))

        let bridgeStatuses = await bridgeStatusesTask
        let bootCompleted = await bootCompletedTask

        let registeredStates = targets.map { target in
            target.platform == "ios"
                ? iosState(target: target, catalog: simCatalog, bridgeStatuses: bridgeStatuses,
                           repoRoot: repoRoot)
                : androidState(target: target, runningAVDs: runningAVDs,
                               connectedSerials: connectedSerials, bootCompleted: bootCompleted)
        }
        guard includeUnregistered else { return (registeredStates, []) }

        let registeredIosUdids = Set(registeredStates.compactMap { $0.iosUdid })
        // **接続中の実機も合成する**(unregisteredStates の doc)。列挙元は api installed-devices と
        // 同じ(iOS=IOSPhysicalDeviceCatalog / Android=adb の serial)。ブリッジの有無は登録済みと
        // 同じ判定(BridgeLauncher.portsMatching + /status が返ったポート)で決める
        let physicalSerialsForInventory = connectedSerials.filter { !$0.hasPrefix("emulator-") }
        let inventory = physicalInventory(serials: physicalSerialsForInventory)
        let physicalIOS = inventory.ios
        var iosBridgePorts: [String: UInt16] = [:]
        for device in physicalIOS {
            let ports = repoRoot.map { BridgeLauncher.portsMatching(udid: device.udid, repoRoot: $0) } ?? []
            if let port = ports.first(where: { bridgeStatuses[$0] != nil }) {
                iosBridgePorts[device.udid] = port
            }
        }
        let physicalSerials = physicalSerialsForInventory
        let androidPhysicalNames = inventory.androidNames
        let (unregistered, skipped) = unregisteredStates(
            simCatalog: simCatalog, runningAVDs: runningAVDs, bootCompleted: bootCompleted,
            registeredTargets: targets, registeredIosUdids: registeredIosUdids,
            physicalIOS: physicalIOS, iosBridgePorts: iosBridgePorts,
            connectedPhysicalSerials: physicalSerials, androidPhysicalNames: androidPhysicalNames)
        return (registeredStates + unregistered, skipped)
    }

    /// 未登録(台帳未記載)の起動中デバイスを合成する。iOS は booted なシミュレータの
    /// うち registeredIosUdids に無いもの、Android は runningAVDs のうち canonical AVD ID が
    /// registeredTargets の avd に無いもの。
    /// **接続中の実機も合成する** —— 拡張の「(起動中のデバイス)」は
    /// 台帳を引かないので、ここで合成しないと**繋いである実機が一覧に出ず**、
    /// 実機バッジも付かない。識別子は iOS=udid / Android=serial で、登録済みのぶんは除く。
    /// 合成 id が登録ターゲット(または他の合成デバイス)の id と衝突したらスキップする — 拡張側は id を
    /// 一意キーとして devices を Map 管理するため、重複 id は片方が消える形で表示が壊れる。
    /// I/O を持たない pure 関数(ユニットテスト対象のため private にしない。skipped は呼び出し側が
    /// stderr へログする用のメッセージ)
    static func unregisteredStates(
        simCatalog: [SimDeviceInfo],
        runningAVDs: [String: String],
        bootCompleted: [String: Bool],
        registeredTargets: [MonitorTarget],
        registeredIosUdids: Set<String>,
        physicalIOS: [IOSPhysicalDeviceInfo] = [],
        /// udid → ブリッジのポート(iosState と同じ判定を親から渡す。空 = ブリッジ無し)
        iosBridgePorts: [String: UInt16] = [:],
        /// adb で見えている実機の serial(emulator- は含めない)
        connectedPhysicalSerials: Set<String> = [],
        /// serial → 表示名(ro.product.model 等。空なら serial をそのまま名前にする)
        androidPhysicalNames: [String: String] = [:]
    ) -> (states: [DeviceRuntimeState], skipped: [String]) {
        var usedIds = Set(registeredTargets.map { $0.id })
        var states: [DeviceRuntimeState] = []
        var skipped: [String] = []

        let bootedUnregistered = simCatalog.filter {
            $0.booted && !$0.physical && !registeredIosUdids.contains($0.udid)
        }
        // 未登録同士で同名の booted sim が複数あると合成 id が衝突するため、udid 先頭8桁で一意化する
        var nameCounts: [String: Int] = [:]
        for sim in bootedUnregistered { nameCounts[sim.name, default: 0] += 1 }
        for sim in bootedUnregistered {
            let name = (nameCounts[sim.name] ?? 0) > 1
                ? "\(sim.name) [\(sim.udid.prefix(8))]" : sim.name
            let target = MonitorTarget(
                platform: "ios", spec: DeviceSpec(name: name, osVersion: sim.os, udid: sim.udid),
                registered: false)
            guard !usedIds.contains(target.id) else {
                skipped.append("[monitor] Skipped an unregistered simulator due to an id collision: \(target.id)")
                continue
            }
            usedIds.insert(target.id)
            // connected にする理由: 拡張の画面配信(monitorDeviceStreamController.ts)は
            // state==="connected" のデバイスにしか helper を張らない。未登録シミュレータは
            // udid だけで simstream が動く(ブリッジ不要)ため、booted のままだと
            // 「接続中」スピナーが永久に回る
            states.append(DeviceRuntimeState(
                target: target, state: "connected", detail: "unregistered",
                iosPort: nil, androidSerial: nil, iosUdid: sim.udid))
        }

        let registeredCanonicalAVDIDs = Set(registeredTargets.compactMap { target -> String? in
            guard target.platform == "android", !target.spec.isPhysical, let avd = target.spec.avd
            else { return nil }
            return AndroidDeviceCatalog.canonicalAVDID(avd)
        })
        for (serial, avdID) in runningAVDs where !registeredCanonicalAVDIDs.contains(avdID) {
            let target = MonitorTarget(
                platform: "android", spec: DeviceSpec(name: avdID, avd: avdID), registered: false)
            guard !usedIds.contains(target.id) else {
                skipped.append("[monitor] Skipped an unregistered emulator due to an id collision: \(target.id)")
                continue
            }
            usedIds.insert(target.id)
            if bootCompleted[serial] == true {
                states.append(DeviceRuntimeState(
                    target: target, state: "connected", detail: serial,
                    iosPort: nil, androidSerial: serial))
            } else {
                states.append(DeviceRuntimeState(
                    target: target, state: "booted", detail: "waiting for boot to finish (\(serial))",
                    iosPort: nil, androidSerial: nil))
            }
        }

        // ---- 接続中の実機(iOS=devicectl / Android=adb)----------------------------------
        // **登録済みのぶんは除く**(登録側は machines プロファイルの名前・ポートで既に並んでいる)。
        // 状態の決め方は登録済みと同じ規則: iOS はブリッジがあれば connected(port)・無ければ
        // booted(= 繋がっているがブリッジ未起動)、Android はブート完了で connected
        let registeredSerials = Set(registeredTargets.compactMap { target -> String? in
            guard target.platform == "android", target.spec.isPhysical else { return nil }
            return target.spec.serial
        })
        for device in physicalIOS where !registeredIosUdids.contains(device.udid) {
            let target = MonitorTarget(
                platform: "ios",
                spec: DeviceSpec(name: device.name, kind: .physical, osVersion: "iOS \(ApiInstalledDevicesCommand.normalizeOS(device.os))", udid: device.udid),
                registered: false)
            guard !usedIds.contains(target.id) else {
                skipped.append("[monitor] Skipped an unregistered iPhone due to an id collision: \(target.id)")
                continue
            }
            usedIds.insert(target.id)
            let wired = device.transport == "wired"
            if let port = iosBridgePorts[device.udid] {
                states.append(DeviceRuntimeState(
                    target: target, state: "connected", detail: "port \(port)",
                    iosPort: port, androidSerial: nil, iosUdid: device.udid, wired: wired))
            } else {
                states.append(DeviceRuntimeState(
                    target: target, state: "booted", detail: "bridge not running",
                    iosPort: nil, androidSerial: nil, iosUdid: device.udid, wired: wired))
            }
        }
        for serial in connectedPhysicalSerials.sorted() where !registeredSerials.contains(serial) {
            let name = androidPhysicalNames[serial].flatMap { $0.isEmpty ? nil : $0 } ?? serial
            let target = MonitorTarget(
                platform: "android",
                spec: DeviceSpec(name: name, kind: .physical, serial: serial),
                registered: false)
            guard !usedIds.contains(target.id) else {
                skipped.append("[monitor] Skipped an unregistered Android device due to an id collision: \(target.id)")
                continue
            }
            usedIds.insert(target.id)
            if bootCompleted[serial] == true {
                states.append(DeviceRuntimeState(
                    target: target, state: "connected", detail: serial,
                    iosPort: nil, androidSerial: serial))
            } else {
                states.append(DeviceRuntimeState(
                    target: target, state: "booted", detail: "waiting for boot to finish (\(serial))",
                    iosPort: nil, androidSerial: nil))
            }
        }

        return (states, skipped)
    }

    /// 接続中の実機の列挙(devicectl + adb getprop)は **毎サイクル叩かない** —— 実測で
    /// 0.5〜1 秒かかり、既定 2 秒周期の監視ループには重すぎる(シミュレータの一覧は simctl 1回で
    /// 済むのと違い、実機は端末ごとに問い合わせが要る)。**繋ぎ替えは分単位の出来事**なので
    /// TTL で足りる。**新しい serial を見つけたら TTL を待たずに引き直す**(繋いだ端末が
    /// 30 秒出てこないと「認識しない」と読めてしまう)
    static let physicalInventoryTTLSeconds: TimeInterval = 30
    struct PhysicalInventory {
        let ios: [IOSPhysicalDeviceInfo]
        /// serial → ro.product.model(空 = 取れなかった。呼び出し側が serial を使う)
        let androidNames: [String: String]
        let takenAt: Date
    }
    nonisolated(unsafe) private static var physicalInventoryCache: PhysicalInventory?
    private static let physicalInventoryLock = NSLock()

    /// TTL 内ならキャッシュ、切れていれば引き直す。**判定だけを純粋関数に切り出してある**
    /// (I/O を持つ本体はテストできないため。needsRefresh がこの規律の witness)
    static func needsRefresh(cache: PhysicalInventory?, serials: Set<String>, now: Date) -> Bool {
        guard let cache else { return true }
        if now.timeIntervalSince(cache.takenAt) >= physicalInventoryTTLSeconds { return true }
        return !serials.isSubset(of: Set(cache.androidNames.keys))
    }

    private static func physicalInventory(serials: Set<String>) -> PhysicalInventory {
        physicalInventoryLock.lock()
        defer { physicalInventoryLock.unlock() }
        if let cache = physicalInventoryCache, !needsRefresh(cache: cache, serials: serials, now: Date()) {
            return cache
        }
        let inventory = PhysicalInventory(
            ios: ((try? IOSPhysicalDeviceCatalog.devices()) ?? []).filter(\.connected),
            androidNames: androidModelNames(serials: serials),
            takenAt: Date())
        physicalInventoryCache = inventory
        return inventory
    }

    /// 実機の表示名(`ro.product.model`)。**取れなければ空**にして呼び出し側が serial を使う。
    /// api installed-devices の androidPhysicalDevices と同じ値を出す(名前が2種類あると
    /// 「デバイスを選択」で足したときにタイルの名前が変わって見える)
    static func androidModelNames(serials: Set<String>) -> [String: String] {
        guard !serials.isEmpty, let adb = try? AndroidDriver.findADB() else { return [:] }
        var result: [String: String] = [:]
        for serial in serials {
            let model = (try? Shell.run([adb, "-s", serial, "shell", "getprop", "ro.product.model"],
                                        timeout: 10))?
                .output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            result[serial] = model
        }
        return result
    }

    /// connected からの降格を確定させるまでに要する連続失敗回数(1回の失敗では降格しない)
    static let connectedDowngradeMissThreshold = 3

    /// Android ヘルスプローブ(adb 経由)の再実行間隔(秒)。毎サイクル叩くと adb 負荷が
    /// 高いため低頻度化する
    static let healthProbeIntervalSeconds: TimeInterval = 30

    /// **配信を抑制中のデバイスでも凍結判定のために撮る**間隔(秒)。
    ///
    /// タイルをストリーミング表示しているデバイスは `suppressFrames` でフレーム配信を止めるが、
    /// **観測まで止めてはいけない** —— 抑制のガードが凍結判定より手前にあったため
    /// 実運用の全デバイス(iOS 10 + Android 8)が判定対象から外れ、`Frozen:` が恒久的に 0 になった。
    /// 配信しないぶん cadence だけ落とす(2連続で確定なので最悪 12 秒で出る。凍結は分単位)
    static let frozenProbeIntervalSeconds: TimeInterval = 6

    /// 1サイクルぶんの「撮る/配る」判断。
    /// **純粋関数として切り出してある**のは、「配信を抑制しても観測は続く」という不変条件を
    /// 単体テストで固定するため(MonitorFrozenWiringTests)。この不変条件が壊れたのが
    /// 凍結カウンタ恒久 0 の実害で、当時は判断がループ本体に埋まっていて誰も試せなかった
    struct CaptureDecision: Equatable {
        let id: String
        /// webview へフレームを配るか。**撮るかどうかとは独立**
        let deliver: Bool
    }

    /// 差分の名前を並べる上限。配信の張り/畳みは1台ずつ届くので通常は1〜数件。超えるのは
    /// パネルの表示切替(全台の抑止 ⇄ 解除)と機械単位の畳みで、全台の名前は1行 5KB 超になるうえ
    /// 情報にならない(台数で足りる)
    static let suppressionDeltaNameCap = 8

    static func suppressionDeltaLine(ids: Set<String>, previous: Set<String>) -> String {
        func side(_ sign: String, _ names: [String]) -> String {
            let shown = names.prefix(suppressionDeltaNameCap).joined(separator: ", ")
            let rest = names.count - suppressionDeltaNameCap
            return "\(sign) \(names.count): " + shown + (rest > 0 ? ", … (\(rest) more)" : "")
        }
        let added = ids.subtracting(previous).sorted()
        let removed = previous.subtracting(ids).sorted()
        var delta: [String] = []
        if !added.isEmpty { delta.append(side("+", added)) }
        if !removed.isEmpty { delta.append(side("-", removed)) }
        return "[monitor] Frame suppression: \(ids.count) device(s)"
            + (delta.isEmpty ? " (unchanged)" : " " + delta.joined(separator: "; "))
    }

    /// - 非抑制: 毎サイクル撮って配る
    /// - 抑制中: `probeInterval` 間隔で**撮るだけ**(配らない)
    ///
    /// `lastProbeAt` は「撮ると決めた」デバイスだけ更新する(撮らなかった回で時計を進めると
    /// 間隔が延び続ける)
    static func capturePlan(ids: [String],
                            suppressed: (String) -> Bool,
                            lastProbeAt: inout [String: Date],
                            probeInterval: TimeInterval = frozenProbeIntervalSeconds,
                            now: Date = Date()) -> [CaptureDecision] {
        var plan: [CaptureDecision] = []
        for id in ids {
            guard suppressed(id) else {
                lastProbeAt[id] = now
                plan.append(CaptureDecision(id: id, deliver: true))
                continue
            }
            if let last = lastProbeAt[id], now.timeIntervalSince(last) < probeInterval { continue }
            lastProbeAt[id] = now
            plan.append(CaptureDecision(id: id, deliver: false))
        }
        return plan
    }

    /// simctl で撮る対象か(抑制の判定は呼び出し側)。**候補の選定と、順繰りの時計を残すかの
    /// 両方がこれを見る** —— 別々に書くと片方だけ直したときに「撮る対象なのに毎サイクル時計を
    /// 捨てる」= 順繰りが回らない、が起きる。
    ///
    /// **"booted" も対象**: ブリッジの無い台の state は登録の有無で割れる —— 未登録の合成
    /// デバイスは "connected"、**台帳に載っている台は "booted"**。connected だけを見ていた頃は、
    /// 台帳に載っていてブリッジを持たない台の絵の出所がゼロで、タイルが「接続中」のまま
    /// 永久に埋まらなかった。実機は simctl で撮れないので対象外
    /// (そちらは devicepoll がブリッジ経由で撮る)。I/O を持たない pure 関数
    static func isSimctlCaptureTarget(state: DeviceRuntimeState) -> Bool {
        (state.state == "connected" || state.state == "booted")
            && state.target.platform == "ios"
            && state.iosPort == nil
            && state.iosUdid != nil
            && !state.target.spec.isPhysical
    }

    /// ブリッジを持たない iOS シミュレータを **1サイクルに1台だけ** simctl で撮るための選択。
    /// **最後に撮ってから最も経った台**を返し、その台の時計を進める(順繰り)。
    ///
    /// **更新間隔の定数は置かない** —— `xcrun simctl io <udid> screenshot` は実測 1.7 秒
    /// (M2 Ultra・iPhone 17 Pro シミュレータ)で、既定の interval(2秒)より長い。1サイクル1台に
    /// 固定すると1サイクルあたりの追加コストは撮影1回で頭打ちになり、更新間隔は「対象の台数」から
    /// 自然に決まる(2台なら約2サイクル、10台なら約10サイクル)。
    /// I/O を持たない pure 関数(MonitorSimctlCaptureTests)
    static func simctlCapturePick(ids: [String], lastCapturedAt: inout [String: Date],
                                  now: Date = Date()) -> String? {
        guard let pick = ids.min(by: {
            (lastCapturedAt[$0] ?? .distantPast) < (lastCapturedAt[$1] ?? .distantPast)
        }) else { return nil }
        lastCapturedAt[pick] = now
        return pick
    }

    /// モニターが配る凍結判定。**3つの根拠を合流させる**:
    ///   ① 自前の観測(一様フレーム。`MonitorFrozenDebounce`)
    ///   ② run が公表した判定(`DeviceFrozenStore`。run 前トリアージが書く)
    ///   ③ 陽性対照の注入(`FrozenInjection`)
    ///
    /// ②を見るのが要点 —— run は9台の凍結を見つけて回復まで走っていたのに、
    /// モニターは自前の観測しか持たず `Frozen: 0` を出し続けた。純粋関数にしてあるのは、
    /// この「run が知っていることをモニターが知る」経路を陽性対照で毎回通すため
    /// 配信ヘルパーが台を名指しする綴り(LocalStreamHolder.DeviceIdentity)。ヘルパーが張れない
    /// 状態(ブリッジ無し・未接続)は nil = 二重の判定をしない
    static func streamIdentity(_ state: DeviceRuntimeState) -> LocalStreamHolder.DeviceIdentity? {
        if state.target.platform == "ios" {
            if state.target.spec.isPhysical { return state.iosPort.map { .iosPhysical(port: $0) } }
            return state.iosUdid.map { .iosSimulator(udid: $0) }
        }
        return state.androidSerial.map { .android(serial: $0) }
    }

    /// `physical` は自前の受動観測(debounce)の写し先を決めるためだけに要る。
    /// **実機の一様フレームは消灯でも出る**ので `.uniformBlank`(確定)にしてはいけない ——
    /// ここを分けないと、夜間に消灯しているだけの実機がタイルで ❄️ になる。
    /// 写し方の規則は `FrozenVerdict.observe(uniformBlank:injected:physical:)` の1箇所
    /// (run 前トリアージと同じものを通す = 同じ台について答えが食い違わない)
    static func frozenVerdict(id: String, key: String?,
                              debounce: MonitorFrozenDebounce,
                              stateDir: URL?,
                              inRun: Bool = false,
                              physical: Bool = false,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              now: Date = Date()) -> FrozenVerdict {
        let published = stateDir.flatMap { dir in
            key.flatMap { DeviceFrozenStore.current(stateDir: dir, key: $0, now: now) }
        } ?? .healthy
        let injected = FrozenInjection.isInjected(key: key, environment: environment)
            ? FrozenVerdict([.injected]) : .healthy
        // **run 中は自前の受動観測を確定に使わない**: run はアプリを terminate→relaunch し続けるので
        // 合間の一様(真っ黒)フレームは正常に出るし、黒画面の2種(描画要求なし/本物の wedge)は
        // 受動観測では分けられない(docs/verification.md)。run 中に本物が起きれば
        // run 側の能動プローブが published(DeviceFrozenStore)経由でここへ届く。
        // 注入(陽性対照)と published は run 中も残す
        let own = inRun ? .healthy : debounce.verdict(id: id, physical: physical)
        return own.merged(with: published).merged(with: injected)
    }

    /// pause したまま resume が来ない場合に自動的に resume 扱いにするまでの秒数(安全弁)
    static let pauseSafetyValveSeconds: TimeInterval = 120
    /// pause 中、resume(または安全弁)を検知するためのポーリング間隔(秒)
    static let pausedPollSeconds: TimeInterval = 0.2

    /// observed に debounce を適用する。connected への昇格は即時反映。confirmed が connected
    /// だったデバイスが今回そうでない場合は即降格させず、connectedDowngradeMissThreshold 回連続
    /// するまで connected 維持(接続情報も直前値を保持しスクショ取得を試み続ける)。
    /// それ以外の遷移(booted/offline 間)は debounce 不要のため即時反映。
    // debounce / androidState は副作用を持たない判定ロジック。FleetestTests から検証するため
    // internal(タイルの点滅・実機の状態判定はデバイス無しで壊せる)。private へ戻さないこと。
    static func debounce(
        _ observed: [DeviceRuntimeState],
        confirmed: inout [String: ConfirmedDeviceState],
        onDowngrade logDowngrade: (String) -> Void
    ) -> [DeviceRuntimeState] {
        observed.map { state in
            let id = state.target.id
            if state.state == "connected" {
                confirmed[id] = ConfirmedDeviceState(
                    state: "connected", detail: state.detail,
                    iosPort: state.iosPort, androidSerial: state.androidSerial,
                    iosUdid: state.iosUdid, missStreak: 0)
                return state
            }
            guard var current = confirmed[id], current.state == "connected" else {
                confirmed[id] = ConfirmedDeviceState(
                    state: state.state, detail: state.detail,
                    iosPort: nil, androidSerial: nil, iosUdid: nil, missStreak: 0)
                return state
            }
            current.missStreak += 1
            if current.missStreak >= connectedDowngradeMissThreshold {
                confirmed[id] = ConfirmedDeviceState(
                    state: state.state, detail: state.detail,
                    iosPort: nil, androidSerial: nil, iosUdid: nil, missStreak: 0)
                logDowngrade(
                    "[monitor] Lost the connection to \(id)" +
                    " (demoted after \(connectedDowngradeMissThreshold) consecutive /status failures: \(state.state))")
                return state
            }
            confirmed[id] = current
            // 維持中: connected のまま、接続情報(port/serial/udid)も直前の値を使い続ける。
            // iosUdid を持ち越さないと leaseKey が nil になり lease 未更新+inRun=false に振れる。
            return DeviceRuntimeState(
                target: state.target, state: "connected", detail: current.detail,
                iosPort: current.iosPort, androidSerial: current.androidSerial,
                iosUdid: current.iosUdid)
        }
    }

    /// iOS: ブリッジ(127.0.0.1:port)の /status が応答 → connected。
    /// 応答しないが simctl 上で Booted → booted。それ以外 → offline
    private static func iosState(
        target: MonitorTarget, catalog: [SimDeviceInfo],
        bridgeStatuses: [UInt16: StatusResponse], repoRoot: URL? = nil
    ) -> DeviceRuntimeState {
        let sim: SimDeviceInfo
        do {
            sim = try SimulatorCatalog.resolve(spec: target.spec, in: catalog)
        } catch {
            return DeviceRuntimeState(target: target, state: "offline",
                                      detail: error.localizedDescription,
                                      iosPort: nil, androidSerial: nil)
        }
        // 実機は /status の device が機種名("iPhone")で返り、実行プロファイルのデバイス名
        // (例「iPhone wave(実機)」)と一致しない。名前照合では永久に connected にならないので、
        // ランナープロセスの -destination id=<UDID> で帰属を決める。resolve が通っている
        // = 接続済みなので、ブリッジが無くても booted(未接続なら上の catch で offline)
        if target.spec.isPhysical {
            let ports = repoRoot.map { BridgeLauncher.portsMatching(udid: sim.udid, repoRoot: $0) } ?? []
            if let port = ports.first(where: { bridgeStatuses[$0] != nil }) {
                return DeviceRuntimeState(target: target, state: "connected",
                                          detail: "port \(port)", iosPort: port,
                                          androidSerial: nil, iosUdid: sim.udid, wired: sim.wired)
            }
            return DeviceRuntimeState(target: target, state: "booted",
                                      detail: "\(sim.name) \(sim.os)",
                                      iosPort: nil, androidSerial: nil, iosUdid: sim.udid,
                                      wired: sim.wired)
        }
        // /status には UDID が無いため、ブリッジの帰属はデバイス名でしか判定できない。
        // hybrid は同一シミュレータに inapp+xcuitest の2ブリッジが並ぶため、複数一致でも
        // 同名の起動中シミュレータが1台なら全ブリッジがそのシミュレータ帰属と確定できる。
        // その場合は全画面スクショが取れる xcuitest を優先する(in-app はアプリ外を撮れず、
        // アプリ終了で消える)。同名の起動中シミュレータが複数のときは特定不能 = connected にしない
        let matches = bridgeStatuses
            .filter { $0.value.device == sim.name }
            .sorted { $0.key < $1.key }
        let port: UInt16? = {
            if matches.count == 1 { return matches[0].key }
            guard !matches.isEmpty,
                  catalog.filter({ $0.booted && $0.name == sim.name }).count == 1 else { return nil }
            return (matches.first { ($0.value.engine ?? "xcuitest") == "xcuitest" } ?? matches[0]).key
        }()
        if let port {
            return DeviceRuntimeState(target: target, state: "connected",
                                      detail: "port \(port)", iosPort: port, androidSerial: nil,
                                      iosUdid: sim.udid)
        }
        if sim.booted {
            return DeviceRuntimeState(target: target, state: "booted",
                                      detail: "\(sim.name) \(sim.os)",
                                      iosPort: nil, androidSerial: nil, iosUdid: sim.udid)
        }
        return DeviceRuntimeState(target: target, state: "offline", detail: "",
                                  iosPort: nil, androidSerial: nil, iosUdid: sim.udid)
    }

    /// `bridgeRunning` を観測する対象か(Android 実機の connected のみ)。iOS 実機の既存規則
    /// (`deviceTiles.js` の `kind==='physical'` 限定)に揃える —— エミュレータは一括終了で
    /// 端末ごと消えるため「端末はあるがブリッジが無い」がほぼ起きない
    static func shouldProbeBridge(state: DeviceRuntimeState) -> Bool {
        state.state == "connected" && state.target.spec.isPhysical && state.target.platform == "android"
    }

    /// Android: AVD起動+ブート完了 → connected。AVD起動のみ(ブート未完了)→ booted
    /// (ブリッジAPKインストールを試みさせないため)。AVD未起動 → offline
    static func androidState(
        target: MonitorTarget, runningAVDs: [String: String],
        connectedSerials: Set<String>, bootCompleted: [String: Bool]
    ) -> DeviceRuntimeState {
        // 実機は AVD を持たない。serial 直指定を adb の接続一覧で確認する
        // (avd 前提のままだと実機が永久に「avd が未設定です」で offline になる)
        if target.spec.isPhysical {
            guard let serial = target.spec.serial, connectedSerials.contains(serial) else {
                return DeviceRuntimeState(
                    target: target, state: "offline",
                    detail: target.spec.serial == nil
                        ? "serial is not set"
                        : "not visible to adb (check the USB connection and USB debugging approval)",
                    iosPort: nil, androidSerial: nil)
            }
            guard bootCompleted[serial] == true else {
                return DeviceRuntimeState(target: target, state: "booted",
                                          detail: "waiting for boot to finish (\(serial))",
                                          iosPort: nil, androidSerial: nil)
            }
            return DeviceRuntimeState(target: target, state: "connected", detail: serial,
                                      iosPort: nil, androidSerial: serial)
        }
        guard let avd = target.spec.avd else {
            return DeviceRuntimeState(target: target, state: "offline",
                                      detail: "avd is not set",
                                      iosPort: nil, androidSerial: nil)
        }
        let canonical = AndroidDeviceCatalog.canonicalAVDID(avd)
        guard let serial = runningAVDs.first(where: { $0.value == canonical })?.key else {
            return DeviceRuntimeState(target: target, state: "offline", detail: "",
                                      iosPort: nil, androidSerial: nil)
        }
        guard bootCompleted[serial] == true else {
            return DeviceRuntimeState(target: target, state: "booted",
                                      detail: "waiting for boot to finish (\(serial))",
                                      iosPort: nil, androidSerial: nil)
        }
        return DeviceRuntimeState(target: target, state: "connected", detail: serial,
                                  iosPort: nil, androidSerial: serial)
    }

    /// 起動中(adb 上で device 表示されている)Android 対象の sys.boot_completed を一括スキャンする。
    /// serial 毎に並列で `adb shell getprop` を叩く(scanBridgeStatuses と同じ並行化方針)
    private static func scanBootCompleted(serials: Set<String>) async -> [String: Bool] {
        await withTaskGroup(of: (String, Bool).self, returning: [String: Bool].self) { group in
            for serial in serials {
                group.addTask { (serial, await AndroidDeviceCatalog.bootCompleted(serial: serial)) }
            }
            var result: [String: Bool] = [:]
            for await (serial, completed) in group {
                result[serial] = completed
            }
            return result
        }
    }

    /// 起動中ブリッジの一括スキャン。ポート毎に短いタイムアウトで並列に /status を叩く
    /// (offline デバイスの判定でループが遅くならないよう既定 1 秒に抑える)
    private static func scanBridgeStatuses(
        timeout: TimeInterval = 1.0, repoRoot: URL? = nil
    ) async -> [UInt16: StatusResponse] {
        let portRange = BridgeAPI.defaultPort...(BridgeAPI.defaultPort + 31)
        return await withTaskGroup(
            of: (UInt16, StatusResponse)?.self, returning: [UInt16: StatusResponse].self
        ) { group in
            for port in portRange {
                group.addTask {
                    // 実機ブリッジは 127.0.0.1 に居ない(LAN)か、居ても token が要る(usb トンネル)。
                    // establish が残した記録を**丸ごと**使う —— host だけ取り出すと usb の token が
                    // 落ちて 401 になり、生きているブリッジが「未起動」に見える(iPhone SE3)。
                    // 記録が無ければループバック・token 無し = シミュレータ・Android の既定
                    let endpoint = repoRoot.map { BridgeEndpoint.load(port: port, repoRoot: $0) }
                        ?? BridgeEndpoint(port: port)
                    let client = BridgeClient(endpoint: endpoint, timeoutSeconds: timeout)
                    guard let status = try? await client.status(), status.ready else { return nil }
                    return (port, status)
                }
            }
            var result: [UInt16: StatusResponse] = [:]
            for await entry in group {
                if let (port, status) = entry { result[port] = status }
            }
            return result
        }
    }

    /// state==connected のデバイスのスクリーンショットを取得する(PNG。JPEG 変換は呼び出し側)
    static func fetchScreenshot(state: DeviceRuntimeState,
                                        repoRoot: URL?) async throws -> Data {
        if state.target.platform == "ios" {
            guard let port = state.iosPort else {
                // ブリッジを持たないシミュレータ(呼び出し側が simctlCapturePick で1台だけ選ぶ)
                guard let udid = state.iosUdid, !state.target.spec.isPhysical else {
                    throw MonitorError.noEndpoint
                }
                return try Self.simctlScreenshot(udid: udid)
            }
            // 宛先と token は scanBridgeStatuses と同じ引き方(記録を丸ごと)
            let endpoint = repoRoot.map { BridgeEndpoint.load(port: port, repoRoot: $0) }
                ?? BridgeEndpoint(port: port)
            return try await BridgeClient(endpoint: endpoint, timeoutSeconds: 5).screenshot()
        }
        guard let serial = state.androidSerial else { throw MonitorError.noEndpoint }
        return try Self.androidScreenshot(serial: serial)
    }

    /// ブリッジを持たないシミュレータの1枚。**実測 1.7 秒**(M2 Ultra・iPhone 17 Pro)なので、
    /// 混雑時の伸びを見て 15 秒で切る —— 1サイクル(既定 2 秒)を握り続けさせない。
    /// 切れた場合は呼び出し側が過渡的失敗として扱い、前回フレームがタイルに残る
    private static func simctlScreenshot(udid: String) throws -> Data {
        let path = NSTemporaryDirectory() + "ft-monitor-\(udid).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let result = try? Shell.run(["xcrun", "simctl", "io", udid, "screenshot", path],
                                          timeout: 15), result.status == 0 else {
            throw MonitorError.simctlScreenshotFailed(udid: udid)
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// adb 実行ファイルのパス。プロセス起動後の初回だけ解決し持ち回る(この関数は既定 2 秒周期で
    /// 呼ばれるので、毎サイクル `AndroidDriver.findADB()` を呼び直す理由が無い)。
    /// 見つからなければ以後ずっと Android 撮影を諦める(前回フレームがタイルに残る)
    private static let resolvedAndroidADBPath: String? = try? AndroidDriver.findADB()

    /// Android 静止画の締切(秒)。`adb exec-out screencap -p` は通常1秒未満で返るが、
    /// adb が刺さる(端末のスリープ復帰・USB 切断)と延々と待つ。simctl 撮影と同じ 15 秒で切り、
    /// 1サイクル(既定 2 秒)を握り続けさせない
    static let androidScreencapTimeoutSeconds: TimeInterval = 15

    /// **`AndroidDriver.screenshot()`(ブリッジ経由)へ戻さない** —— あちらは `ensureBridge()` を
    /// 通るので、ブリッジを終了させた実機でも観測のたびに建ててしまう(利用者が「全て終了」を
    /// 押した実機のブリッジが監視のポーリングだけで復活する副作用があった)。
    /// `AndroidScreencap`(adb 直叩き)は WebView の CDP 合成を持たないが、配信/ポーリングヘルパー
    /// (fleetest-devicepoll)も同じ adb 直叩きで合成していないので、タイルの見え方としては後退しない
    private static func androidScreenshot(serial: String) throws -> Data {
        guard let adb = resolvedAndroidADBPath else { throw MonitorError.adbNotFound }
        guard let png = AndroidScreencap.capturePNG(
            adb: adb, serial: serial, timeout: androidScreencapTimeoutSeconds) else {
            throw MonitorError.androidScreencapFailed(serial: serial)
        }
        return png
    }

    /// SIGTERM/SIGINT/EOF を最大 0.1 秒粒度で検知しながら interval 秒待つ
    /// (待ち時間いっぱい固まって終了が遅れないようにするため)
    static func sleepInterruptible(seconds: Double, stop: StopFlag) async {
        var remaining = seconds
        while remaining > 0, !stop.isSet {
            try? await Task.sleep(nanoseconds: 100_000_000)
            remaining -= 0.1
        }
    }
}
