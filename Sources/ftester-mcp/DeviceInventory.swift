// ft_list_devices / ft_list_apps の本文を組み立てる材料。MCPServer+Dispatch.swift(配線は別担当)から呼ぶ。
//
// **マシンプロファイルを前提にできない**: .claude/skills/ftester-mcp/SKILL.md の導線(MCP だけ
// 入れる受け手)は machines/ を一つも持たない。devicesText はプロファイルが解決できないときも
// 素のカタログ(SimulatorCatalog / AndroidSerialResolver)へフォールバックし、**絶対に throw しない**
// (失敗も文章として本文に書く)。
//
// ApiListDevicesCommand.swift の ApiMonitorCommand.determineStates は ftester 実行ターゲットに
// 閉じていて ftester-mcp からは見えないため使わない。ここでは同種の判定を軽量に再実装する
// (登録デバイスの疎通は 1 台ずつ試し、1 台の失敗で他を落とさない)。

import Foundation
import FTAndroid
import FTBridgeClient
import FTCore

enum DeviceInventory {

    /// 整形前の 1 デバイス分。フィールドは line(_:) が文へ組む
    struct Row: Equatable {
        let name: String
        let platform: String   // "ios" / "android"
        let identifier: String?  // iOS=udid, Android=serial
        let running: Bool
        let physical: Bool
        let registered: Bool
        /// **同じ端末に in-app と XCUITest が同時に立つのが常態**(実測: 10台に稼働ブリッジ17本)。
        /// port 昇順。line(_:) がまとめて畳んで出す
        let bridges: [Bridge]
        /// **名前でしか当たらず、その名前が一意でないので捨てたブリッジの本数**
        /// (`resolveBridges` 参照)。0 なら何も出さない。黙って捨てると
        /// 「動いているのに一覧に出ない」になるので、本数だけは行に残す
        var unattributedByName: Int = 0

        struct Bridge: Equatable {
            let port: UInt16
            let engine: String?
        }
    }

    struct ResolvedMachine {
        let name: String
        let profile: MachineProfile
    }

    // MARK: - ft_list_devices

    /// `abbreviated`: マシンプロファイルを使えない見出しを短縮形で出すか、その回の理由(reason)を
    /// 渡して判定するクロージャ。**理由込みで判定させる** —— 呼び出し側の鍵を理由に依存させないと、
    /// 「同じ理由の繰り返しは畳む」が「理由が変わっても畳む」に化ける(欠陥⑥: 指示どおり原因を
    /// 直しても、直った証拠だけが畳まれて読めなくなる)。
    /// **見出しが実際に組まれる回だけ評価する** —— プロファイルが解決できた回や
    /// platform が不正な回で先に評価すると、呼び出し側の once 系の鍵をここで消費してしまい、
    /// 本当の初出が短縮形になる
    static func devicesText(project: String?, profile: String?, platform: String?,
                            abbreviated: (String) -> Bool = { _ in false }) async -> String {
        guard isSupportedPlatform(platform) else {
            return "unknown platform: \(platform ?? "") (expected \"ios\" or \"android\")"
        }
        let wantsIOS = platform == nil || platform == "ios"
        let wantsAndroid = platform == nil || platform == "android"

        let lookup = resolveMachine(project: project, profile: profile)
        if case .resolved(let machine) = lookup {
            var rows: [Row] = []
            if wantsIOS { rows += await iosMachineRows(specs: machine.profile.ios?.devices ?? []) }
            if wantsAndroid { rows += androidMachineRows(specs: machine.profile.android?.devices ?? []) }
            guard !rows.isEmpty else {
                return "machine profile \"\(machine.name)\" defines no \(platform ?? "ios/android") devices."
            }
            return (["machine profile: \(machine.name)"] + rows.map(line)).joined(separator: "\n")
        }

        var rows: [Row] = []
        if wantsIOS { rows += await iosFallbackRows() }
        if wantsAndroid { rows += androidFallbackRows() }
        let header = fallbackHeader(reason: lookup.reason, abbreviated: abbreviated(lookup.reason))
        guard !rows.isEmpty else { return header + "\nNone found." }
        return ([header] + rows.map(line)).joined(separator: "\n")
    }

    /// マシンプロファイルを使えないときの見出し(純粋関数・テスト用)。
    /// **理由を必ず載せる** —— 設定の壊れ(登録マシン名とプロファイル名の不一致など)を黙って
    /// フォールバックで隠すと、受け手は自分の profiles/ が死んでいることに気づけない
    ///
    /// **2回目以降は理由を畳む**(2026-08-12 の実アプリ監査): 理由は候補プロジェクトを
    /// 全部並べるので長く(実測 8 件)、探索中に ft_list_devices を繰り返すと同じ数行を
    /// 毎回読まされる。初回は従来どおり満額 —— **短縮形でも「使っていない」事実は残す**
    /// (ここを消すと受け手は自分の profiles/ が死んでいることに永久に気づけない)
    static func fallbackHeader(reason: String, abbreviated: Bool = false) -> String {
        guard !abbreviated else {
            return "Not using a machine profile (reason given in the first ft_list_devices)."
                + " Currently booted/connected:"
        }
        return "Not using a machine profile (\(reason))."
            + " Listing devices that are currently booted/connected instead:"
    }

    /// 1 デバイス分を 1 行へ組む(純粋関数・テスト用)
    static func line(_ row: Row) -> String {
        var parts = [row.platform, row.physical ? "physical" : "virtual",
                     row.registered ? "registered" : "unregistered",
                     row.running ? "running" : "not running"]
        if let identifier = row.identifier {
            parts.append((row.platform == "ios" ? "udid " : "serial ") + identifier)
        }
        if !row.bridges.isEmpty {
            // **1端末に複数エンジンが同時に立つのが常態**(in-app + XCUITest)。1行に畳んで
            // 両方出す — 片方しか出さないと「動いているのにもう一方が見えない」になる
            parts.append("bridge " + row.bridges.map(bridgeLabel).joined(separator: ", "))
        } else if row.running, row.platform == "ios" {
            // **「動いているのに MCP からは触れない」を行から読めるようにする**(H-3。2026-08-09)。
            // iOS の操作系はブリッジ越しなので、ブリッジが無い機は udid を渡しても port を渡しても
            // 動かない。行の見た目は他と同じなので、書かないと利用者は「なぜか効かない」を踏む
            parts.append("no bridge — not drivable from MCP until `ftester bridge up`")
        }
        // **捨てた本数は黙らない**(Row.unattributedByName)。同名の機が2台以上あると、
        // udid を申告しないブリッジはどちらのものか決められない
        if row.unattributedByName > 0 {
            parts.append("\(row.unattributedByName) more bridge(s) match this device's name but not"
                + " its udid, and another device shares that name — not listed here because they"
                + " cannot be attributed; pass port: explicitly, or rename the devices")
        }
        return "- \(row.name) (\(parts.joined(separator: ", ")))"
    }

    /// エンジンが分かるときだけ括弧で添える(分からないときに書かない = 嘘を書かない)
    private static func bridgeLabel(_ bridge: Row.Bridge) -> String {
        "port \(bridge.port)" + (bridge.engine.map { " (\($0))" } ?? "")
    }

    /// 受け付ける platform。**devicesText の門番**(private) —— `abbreviated` クロージャ経由の
    /// 遅延評価で、呼び出し側が同じ判定を先読みする必要は無くなった
    private static func isSupportedPlatform(_ platform: String?) -> Bool {
        platform == nil || platform == "ios" || platform == "android"
    }

    enum MachineLookup {
        case resolved(ResolvedMachine)
        case unavailable(String)

        var reason: String {
            if case .unavailable(let reason) = self { return reason }
            return ""
        }
    }

    /// machine profile の解決(private・2026-08-12)。走査は伴わない(プロファイルの読み直しだけ)
    private static func resolveMachine(project: String?, profile: String?) -> MachineLookup {
        let testProject: TestProject
        do {
            testProject = try ScenarioHost.project(named: project)
        } catch {
            return .unavailable(describe(error))
        }
        let machine: (name: String, auto: Bool)
        do {
            machine = try ProfileResolver.determineMachine(
                project: testProject,
                runProfileName: profile)
        } catch {
            return .unavailable(describe(error))
        }
        let url = testProject.machinesDir.appendingPathComponent("\(machine.name).json")
        guard let data = try? Data(contentsOf: url) else {
            return .unavailable("machine profile \"\(machine.name)\" is not in"
                + " \(testProject.name)/profiles/machines/")
        }
        guard let decoded = try? JSONDecoder().decode(MachineProfile.self, from: data) else {
            return .unavailable("machine profile \"\(machine.name)\" could not be decoded")
        }
        return .resolved(ResolvedMachine(name: machine.name, profile: decoded))
    }

    /// **CLI のフラグ表記のまま出さない**: この文は FTCore(CLI 向け)から来るので
    /// 「Pick one with --project」と書いてあるが、MCP の読み手が渡せるのは `project:` 引数
    private static func describe(_ error: Error) -> String {
        MCPMessageText.forMCP(((error as? LocalizedError)?.errorDescription ?? "\(error)")
            .replacingOccurrences(of: "\n", with: " "))
    }

    // MARK: - iOS

    private static func iosMachineRows(specs: [DeviceSpec]) async -> [Row] {
        guard !specs.isEmpty else { return [] }
        let simDevices = (try? SimulatorCatalog.devices()) ?? []
        let physicalDevices = specs.contains(where: \.isPhysical)
            ? ((try? IOSPhysicalDeviceCatalog.devices()) ?? []) : []
        let live = await liveIOSBridges()
        // **名前引きを無効にする条件は「機の名前が一意でないこと」**なので、材料は実測カタログ
        // (spec ではなく)。プロファイルの表示名が違っていても、指している機の名前が同じなら
        // 名前引きは両方に当たる
        let ambiguous = ambiguousDeviceNames(simDevices.filter(\.booted).map(\.name)
                                             + physicalDevices.filter(\.connected).map(\.name))
        return specs.map { iosRow(spec: $0, simDevices: simDevices, physicalDevices: physicalDevices,
                                  liveBridges: live, ambiguousNames: ambiguous) }
    }

    /// 生きているブリッジの引き方。**1つの辞書に名前と udid を混ぜない** —— どちらの鍵で
    /// 当たったか読めなくなる(取り違え診断に必要)
    struct LiveBridges {
        let byName: [String: [Row.Bridge]]
        let byUDID: [String: [Row.Bridge]]
        static let empty = LiveBridges(byName: [:], byUDID: [:])
    }

    /// 純粋関数(テスト用): spec と実測カタログから 1 行分を組む。`liveBridges` は
    /// **udid 一致と名前一致の和集合**(resolveBridges 参照。省略時はブリッジなし)。
    /// 実機の `/status.device` は機種名("iPhone")で返り、プロファイル名とは一致しないため、
    /// udid が唯一の安定鍵になる(欠陥①(a))
    static func iosRow(spec: DeviceSpec, simDevices: [SimDeviceInfo],
                       physicalDevices: [IOSPhysicalDeviceInfo],
                       liveBridges: LiveBridges = .empty,
                       ambiguousNames: Set<String> = []) -> Row {
        if spec.isPhysical {
            let udid = spec.udid ?? ""
            let match = physicalDevices.first { $0.udid == udid || $0.deviceCtlIdentifier == udid }
            let running = match?.connected ?? false
            let resolvedUDID = spec.udid ?? match?.udid
            let key = match?.name ?? spec.name
            let resolved = running
                ? resolveBridges(udid: resolvedUDID, name: key, in: liveBridges,
                                 ambiguousNames: ambiguousNames)
                : (bridges: [], droppedByName: 0)
            return Row(name: spec.name, platform: "ios", identifier: spec.udid ?? match?.udid,
                      running: running, physical: true, registered: true,
                      bridges: resolved.bridges, unattributedByName: resolved.droppedByName)
        }
        let match: SimDeviceInfo?
        if let udid = spec.udid, !udid.isEmpty {
            match = simDevices.first { $0.udid == udid }
        } else {
            let name = spec.simulator ?? "iPhone 17 Pro"
            let os = spec.os.map { $0.hasPrefix("iOS") ? $0 : "iOS \($0)" }
            match = simDevices.first { $0.name == name && (os == nil || $0.os == os) }
        }
        let running = match?.booted ?? false
        let resolvedUDID = match?.udid ?? spec.udid
        let key = match?.name ?? spec.name
        let resolved = running
            ? resolveBridges(udid: resolvedUDID, name: key, in: liveBridges,
                             ambiguousNames: ambiguousNames)
            : (bridges: [], droppedByName: 0)
        return Row(name: spec.name, platform: "ios", identifier: match?.udid ?? spec.udid,
                  running: running, physical: false, registered: true,
                  bridges: resolved.bridges, unattributedByName: resolved.droppedByName)
    }

    /// **udid で当たった行と名前で当たった行の和集合**(欠陥③)。`??` で片方だけを採ると、
    /// udid を申告するブリッジ(新版)と申告しないブリッジ(旧版。`Found.udid` の doc 参照)が
    /// 同じ端末に同居したとき、udid 側で1本でも当たった時点で名前側が丸ごと見えなくなる
    /// (Row.Bridge の doc の「同じ端末に in-app と XCUITest が同時に立つのが常態」参照)。
    /// port で重複を除き、line(_:) の契約どおり port 昇順を保つ
    ///
    /// **名前が一意でないときは名前引きを使わない**(2026-08-15 の外部評価の実害): 同じ機種で
    /// 2台作れば名前は既定で同じになる。そのとき和集合を取ると**2台とも同じポートを名乗り**、
    /// 読み手からは「ポートでは区別できない・必ず udid を渡すしかない」ように見える
    /// (報告された症状そのもの)。**どちらの機のものか決められない以上、どちらにも付けない** ——
    /// 片方に付けるのは当てずっぽうで、間違えたほうを操作させる。
    /// 捨てた本数は行に残す(`Row.unattributedByName`)
    private static func resolveBridges(udid: String?, name: String, in live: LiveBridges,
                                       ambiguousNames: Set<String> = [])
        -> (bridges: [Row.Bridge], droppedByName: Int) {
        let byUDID = udid.flatMap { live.byUDID[$0] } ?? []
        let named = live.byName[name] ?? []
        let byName = ambiguousNames.contains(name) ? [] : named
        var seenPorts = Set<UInt16>()
        let merged = (byUDID + byName).sorted { $0.port < $1.port }
            .filter { seenPorts.insert($0.port).inserted }
        // **udid で既に出ているものは「捨てた」に数えない**(同じ機の同じブリッジなので実害が無い)
        let dropped = ambiguousNames.contains(name)
            ? named.filter { bridge in !merged.contains(where: { $0.port == bridge.port }) }.count
            : 0
        return (merged, dropped)
    }

    /// **2台以上が名乗っている名前**。名前引きを無効にする条件(`resolveBridges` 参照)
    static func ambiguousDeviceNames(_ names: [String]) -> Set<String> {
        var seen: Set<String> = []
        var duplicated: Set<String> = []
        for name in names where !seen.insert(name).inserted { duplicated.insert(name) }
        return duplicated
    }

    /// **実機も並べる**(2026-08-14・実機+仮想デバイス混在の監査)。ここはマシンプロファイルが
    /// 解決しなかったときの**唯一の一覧**で、`androidFallbackRows` は最初から実機を含むのに
    /// iOS だけシミュレータしか数えていなかった。結果、繋がっている iPhone が
    /// **どの経路からも見えず**、`udid:` を要求するエラー文が「ft_list_devices を見ろ」と言うのと
    /// 相互参照して行き止まりになる(監査ラウンド1の欠陥②と同じ袋小路の別の入口)。
    /// machines/ に自分のホスト名が無い構成では、この fallback が常用経路になる
    private static func iosFallbackRows() async -> [Row] {
        let simulators = ((try? SimulatorCatalog.devices()) ?? [])
        let physical = ((try? IOSPhysicalDeviceCatalog.devices()) ?? [])
        guard simulators.contains(where: \.booted) || physical.contains(where: \.connected)
        else { return [] }
        return iosFallbackRows(simulators: simulators, physical: physical,
                               live: await liveIOSBridges())
    }

    /// 純粋関数(テスト用): 実測カタログ2本を fallback の行へ組む。**絞り込みもここに置く**
    /// (「いま booted/connected のもの」という見出しの約束を1箇所で守る)。
    /// 実機のブリッジは `/status` に udid を申告せず名前も汎用の "iPhone" なので、名前引きは
    /// 原理的に当たらない —— `.ftester/bridge-<port>.device` の記録から BridgeDiscovery が
    /// 補った udid 側で当てる(resolveBridges は udid 引きと名前引きの和集合を取る)
    static func iosFallbackRows(simulators: [SimDeviceInfo], physical: [IOSPhysicalDeviceInfo],
                                live: LiveBridges) -> [Row] {
        let ambiguous = ambiguousDeviceNames(simulators.filter(\.booted).map(\.name)
                                             + physical.filter(\.connected).map(\.name))
        return simulators.filter(\.booted).map { device in
            let resolved = resolveBridges(udid: device.udid, name: device.name, in: live,
                                          ambiguousNames: ambiguous)
            return Row(name: device.name, platform: "ios", identifier: device.udid, running: true,
                       physical: false, registered: false,
                       bridges: resolved.bridges, unattributedByName: resolved.droppedByName)
        } + physical.filter(\.connected).map { device in
            let resolved = resolveBridges(udid: device.udid, name: device.name, in: live,
                                          ambiguousNames: ambiguous)
            return Row(name: device.name, platform: "ios", identifier: device.udid, running: true,
                       physical: true, registered: false,
                       bridges: resolved.bridges, unattributedByName: resolved.droppedByName)
        }
    }

    /// 生きている iOS ブリッジを udid と端末名の両方で引けるようにする(port 昇順)。1 台への
    /// 疎通失敗は BridgeDiscovery.scan が内部で握って次へ進む(呼び出し側は空を受け取るだけ)。
    /// **repoRoot を渡す**: nil だと lan トランスポート(実機を LAN IP で直叩き)のブリッジが
    /// BridgeEndpoint の記録を読めず一度も疎通できない(欠陥①(b))
    private static func liveIOSBridges() async -> LiveBridges {
        let found = await BridgeDiscovery.scan(excluding: 0, repoRoot: try? RepoRoot.find())
        var byName: [String: [BridgeDiscovery.Found]] = [:]
        var byUDID: [String: [BridgeDiscovery.Found]] = [:]
        for entry in found {
            byName[entry.device, default: []].append(entry)
            if let udid = entry.udid { byUDID[udid, default: []].append(entry) }
        }
        func rows(_ grouped: [String: [BridgeDiscovery.Found]]) -> [String: [Row.Bridge]] {
            grouped.mapValues { entries in
                entries.sorted { $0.port < $1.port }.map { Row.Bridge(port: $0.port, engine: $0.engine) }
            }
        }
        return LiveBridges(byName: rows(byName), byUDID: rows(byUDID))
    }

    // MARK: - Android

    private static func androidMachineRows(specs: [DeviceSpec]) -> [Row] {
        guard !specs.isEmpty else { return [] }
        let connectedSerials = AndroidSerialResolver.connectedSerials()
        let connectedDevices = AndroidSerialResolver.describe(serials: connectedSerials)
        return specs.map { androidRow(spec: $0, connectedDevices: connectedDevices) }
    }

    /// 純粋関数(テスト用): spec と接続中デバイス一覧から 1 行分を組む
    static func androidRow(spec: DeviceSpec, connectedDevices: [AndroidSerialResolver.Device]) -> Row {
        if spec.isPhysical {
            let serial = spec.serial ?? ""
            let running = connectedDevices.contains { $0.serial == serial }
            return Row(name: spec.name, platform: "android", identifier: serial.isEmpty ? nil : serial,
                      running: running, physical: true, registered: true, bridges: [])
        }
        if let avd = spec.avd, let match = connectedDevices.first(where: { $0.avd == avd }) {
            return Row(name: spec.name, platform: "android", identifier: match.serial, running: true,
                      physical: false, registered: true, bridges: [])
        }
        return Row(name: spec.name, platform: "android", identifier: nil, running: false,
                  physical: false, registered: true, bridges: [])
    }

    private static func androidFallbackRows() -> [Row] {
        let serials = AndroidSerialResolver.connectedSerials()
        guard !serials.isEmpty else { return [] }
        return AndroidSerialResolver.describe(serials: serials).map { device in
            Row(name: device.avd ?? device.serial, platform: "android", identifier: device.serial,
               running: true, physical: device.avd == nil, registered: false, bridges: [])
        }
    }

    // MARK: - ft_list_apps

    /// 整形前の1アプリ分。`name` はブリッジ/OS が表示名を出せるときだけ(iOS は
    /// `CFBundleDisplayName`、Android の `pm list packages` は id しか出さない)
    struct AppRow: Equatable {
        let id: String
        let name: String?
        let isUser: Bool
    }

    /// **宛先の解決はしない** —— どのデバイスを見るかは MCPServer の driver(_:) が一手に決める
    /// (ここで BridgeClient を建て直すと profile 指定が既定ポートへ逸れる)
    /// simctl は system も込みで返すので、除外した件数を数えられる
    static func appsText(apps: [SimulatorAppCatalog.App], includeSystem: Bool,
                         filter: String?) -> String {
        renderAppLines(apps.map { AppRow(id: $0.id, name: $0.name, isUser: $0.isUser) },
                       includeSystem: includeSystem, filter: filter, systemAppsCounted: true)
    }

    /// `pm list packages -3` は端末側で既に third-party へ絞られているので、
    /// **除外した system の件数は分からない**(数えるにはもう1回 adb を撃つことになる)
    static func appsText(packages: [AndroidDriver.InstalledPackage], includeSystem: Bool,
                         filter: String?) -> String {
        renderAppLines(packages.map { AppRow(id: $0.id, name: nil, isUser: $0.isUser) },
                       includeSystem: includeSystem, filter: filter, systemAppsCounted: false)
    }

    /// 純粋関数(テスト用)。
    ///
    /// **「system を見ていない」ことは必ず書く**(2026-08-09 の実測が動機): 既定は user だけで、
    /// 端末に載っている地図・ブラウザは system 側に居る。黙って空を返すと読み手は
    /// 「入っていない」と読み、MCP の外(adb / simctl)へ逃げることになる。
    /// `filter` を渡したときに system まで見るのは MCPServer 側の既定(そちらのコメント参照)
    /// `systemAppsCounted` = 渡された rows が system も含んでいるか。**false のときも案内は出す** ——
    /// 件数が分からないことと「system が無いこと」は別で、Android は前者。ここを黙ると
    /// Android でだけ案内が消え、いちばん詰まりやすい面(表示名が無く id を当てにいく面)で
    /// 逃げ道が見えなくなる(2026-08-09 の実地確認で発覚)
    static func renderAppLines(_ rows: [AppRow], includeSystem: Bool, filter: String?,
                               systemAppsCounted: Bool = true) -> String {
        let scoped = includeSystem ? rows : rows.filter(\.isUser)
        let omittedSystem = includeSystem ? 0 : rows.count - scoped.count
        let shown = filter.map { needle in scoped.filter { matches($0, needle: needle) } } ?? scoped
        let systemNote: String?
        if includeSystem {
            systemNote = nil
        } else if systemAppsCounted {
            systemNote = omittedSystem > 0
                ? "(\(omittedSystem) system app(s) not listed — pass includeSystem: true)" : nil
        } else {
            systemNote = "(system apps are not listed — pass includeSystem: true, or filter:"
                + " to search them too)"
        }

        guard !shown.isEmpty else {
            let head = filter.map { "no app matches \"\($0)\" among the \(scoped.count) listed." }
                ?? "0 app(s) installed."
            return ([head] + [systemNote].compactMap { $0 }).joined(separator: "\n")
        }
        let head = filter.map { "\(shown.count) app(s) matching \"\($0)\" (of \(scoped.count)):" }
            ?? "\(shown.count) app(s):"
        return ([head] + shown.map(line) + [systemNote].compactMap { $0 })
            .joined(separator: "\n")
    }

    /// id と表示名の**部分一致・大小無視**。読み手は "maps" のような当てずっぽうで撃つので
    /// 完全一致にはしない
    static func matches(_ row: AppRow, needle: String) -> Bool {
        let target = (row.id + " " + (row.name ?? "")).lowercased()
        return target.contains(needle.lowercased())
    }

    private static func line(_ row: AppRow) -> String {
        let name = row.name.map { "  \($0)" } ?? ""
        return row.id + name + (row.isUser ? "" : "  [system]")
    }
}
