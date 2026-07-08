// DeviceMonitorCenter.swift
// モニター全体の管理: ウィンドウの再列挙(5秒毎)、ストリーマの増減、
// ポート⇔ウィンドウの照合、ウィンドウが見つからないブリッジのフォールバックポーリング。

import AppKit
import Foundation
import FTAndroid
import FTBridgeClient
import FTCore
import Observation

/// SCK でウィンドウが見つからないデバイス用のフォールバックタイル。
/// iOS = ブリッジの /screenshot、Android = adb 経由スクリーンショットを低頻度ポーリング
/// (ヘッドレス起動のエミュレータ(-no-window)はウィンドウ自体が無いためこちらで表示する)
@MainActor
@Observable
final class FallbackTile: Identifiable {
    enum Source: Hashable, Sendable {
        case iosBridge(port: UInt16)
        case androidDevice(serial: String)
    }

    nonisolated let source: Source
    let deviceName: String
    private(set) var latestImage: NSImage?
    private(set) var lastFrameAt: Date?
    private var task: Task<Void, Never>?
    /// Android 用ドライバ(初回ポーリング時に生成して使い回す)
    private var androidDriver: AppDriver?

    nonisolated var id: String { label }

    /// ワーカーバッジ表示("ios:8123" / "android:emulator-5556")
    nonisolated var label: String {
        switch source {
        case .iosBridge(let port): return "ios:\(port)"
        case .androidDevice(let serial): return "android:\(serial)"
        }
    }

    init(source: Source, deviceName: String) {
        self.source = source
        self.deviceName = deviceName
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                if let data = try? await self.fetchScreenshot(),
                   let image = NSImage(data: data) {
                    self.latestImage = image
                    self.lastFrameAt = Date()
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func fetchScreenshot() async throws -> Data {
        switch source {
        case .iosBridge(let port):
            return try await BridgeClient(port: port).screenshot()
        case .androidDevice(let serial):
            if androidDriver == nil {
                androidDriver = try AndroidDriver(serial: serial)
            }
            guard let driver = androidDriver else { throw CancellationError() }
            return try await driver.screenshot()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// 画面が取得できないデバイス用のプレースホルダーカード
/// (マシンプロファイルに定義されているが、未起動 or ブリッジ未接続で画面が無いもの)
struct PlaceholderTile: Identifiable, Hashable, Sendable {
    let name: String       // 論理名(シミュ1 等)
    let platform: String   // "ios" / "android"
    let detail: String     // iPhone 17 Pro 27.0 / AVD 名
    /// SCK ストリームのウィンドウタイトル照合用(一致するストリームがあればカード不要)
    let windowMatch: String?
    var id: String { "\(platform):\(name)" }

    /// ユーザーに見せる状態は「未起動」か「起動して接続済み(=タイル表示)」の 2 つのみ。
    /// 起動済みでも画面が取れない中間状態はここに含めず「未起動」として扱う
    var status: String { "未起動" }
}

/// プレースホルダー計算の材料(AppModel が非同期に用意する)。
/// どのカードを消すか(抑制)の判定は行わない — 抑制はタイル更新と同一ターンで
/// DeviceMonitorCenter が行う(別ターンだと一瞬タイルとカードが重複表示されるため)
struct PlaceholderSnapshot: Sendable {
    /// マシンプロファイルの全デバイス分の候補カード
    let candidates: [PlaceholderTile]
    /// serial → AVD ID(キャッシュ込み。Android の抑制判定用)
    let serialToAVD: [String: String]

    static let empty = PlaceholderSnapshot(candidates: [], serialToAVD: [:])
}

/// モニターグリッドの1エントリ。タイル(SCK/フォールバック)とプレースホルダーカードを
/// 単一のリストへ統合し、マシンプロファイルの各デバイスがどれか一つの表現で
/// 1回だけ現れることを構造的に保証する(別コンテナ描画だった頃の一瞬の重複を排除)。
/// 並びはプロファイル定義順で固定=起動・終了でデバイスの位置が動かない。
/// プロファイル外のタイル(手動起動のデバイス等)は末尾に付く
struct MonitorEntry: Identifiable {
    enum Kind {
        case stream(WindowStreamer)
        case fallback(FallbackTile)
        case placeholder(PlaceholderTile)
    }

    let kind: Kind
    /// クリック選択の識別子。プロファイルデバイスは論理ID("ios:シミュ1" 等)なので、
    /// 起動・終了によるカード⇔タイルの遷移をまたいで選択が維持される。
    /// プロファイル外のタイルはワーカーラベル(照合不能ならウィンドウID)
    let deviceKey: String
    /// 選択時のログレーン見出しに使う表示名(論理名 or ウィンドウタイトル)
    let deviceName: String

    var id: String {
        switch kind {
        case .stream(let streamer): return "stream:\(streamer.id)"
        case .fallback(let tile): return "fallback:\(tile.id)"
        case .placeholder(let tile): return "card:\(tile.id)"
        }
    }

    /// 実行ログレーンとの対応に使うワーカーラベル("ios:8123" 等)。未起動カードは nil
    @MainActor var workerLabel: String? {
        switch kind {
        case .stream(let streamer): return streamer.portLabel
        case .fallback(let tile): return tile.label
        case .placeholder: return nil
        }
    }
}

@MainActor
@Observable
final class DeviceMonitorCenter {
    private var streamers: [WindowStreamer] = []
    private var fallbacks: [FallbackTile] = []
    /// グリッドが描画する統合リスト。更新は composeEntries の同一 MainActor ターンのみ
    private(set) var entries: [MonitorEntry] = []
    private(set) var monitoring = false
    var permissionGranted = true
    var lastError: String?
    /// ユーザーのモニター ON/OFF(OFF ならタブ表示中もストリームを止める)
    var userEnabled = true
    /// 選択中デバイス(MonitorEntry.deviceKey)。クリック=単独選択、Shift+クリック=追加/解除、
    /// ドラッグ矩形=範囲選択(操作はグリッドビュー側)。実行ログの表示レーン絞り込みに使う
    var selectedDeviceKeys: Set<String> = []

    /// 選択中デバイスのエントリ(グリッドの表示順)
    var selectedEntries: [MonitorEntry] {
        entries.filter { selectedDeviceKeys.contains($0.deviceKey) }
    }

    /// ポート照合・フォールバック生成に使う接続状態の供給元(AppModel が注入)
    var statusProvider: () -> [UInt16: StatusResponse] = { [:] }
    /// Android デバイス(serial・表示名)の供給元(AppModel が注入。refreshTargets の結果)
    var androidDevicesProvider: () -> [(serial: String, name: String)] = { [] }
    /// プレースホルダー計算の材料の供給元(AppModel が注入)
    var placeholderProvider: () async -> PlaceholderSnapshot = { .empty }
    /// デバイス再スキャン(AppModel.refreshTargets)。照合の前に毎サイクル呼び、
    /// タイルの元データ(portStatuses / targets)を最新化する — CLI や外部での
    /// デバイス起動・終了も 5 秒以内にモニターへ反映される
    var targetsRefresher: () async -> Void = {}

    private var lastDebugComposition = ""

    private var loopTask: Task<Void, Never>?

    var tileCount: Int { streamers.count + fallbacks.count }

    func start() {
        guard !monitoring, userEnabled else { return }
        guard WindowDiscovery.preflightPermission() else {
            permissionGranted = false
            return
        }
        permissionGranted = true
        monitoring = true
        loopTask = Task { [weak self] in
            while let self, self.monitoring, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stop() async {
        monitoring = false
        loopTask?.cancel()
        loopTask = nil
        for streamer in streamers { await streamer.stop() }
        streamers = []
        for tile in fallbacks { tile.stop() }
        fallbacks = []
        entries = []
    }

    func requestPermission() {
        // 未許可ならシステムプロンプト(または設定画面)が開く。付与後は要再起動のことがある
        if WindowDiscovery.requestPermission() {
            permissionGranted = true
            start()
        }
    }

    /// 実行開始時などに即時再照合したいときに呼ぶ
    func rematch() {
        Task { await refreshMatching() }
    }

    /// 実行中の再照合フラグと追走要求。5 秒ループと rematch()(実行開始・デバイス操作直後)が
    /// 重なると、途中の await を挟んで鮮度の異なるデータによる適用が交錯し
    /// 一瞬の重複が出るため、適用は常に 1 本へ直列化する(重なった要求は 1 回だけ追走)
    private var refreshingMatching = false
    private var rematchQueued = false

    /// 再スキャン → スナップショット取得(非同期)→ タイルと統合リストを同一ターンで更新。
    /// タイル追加とカード除去の間に描画フレームを挟ませない(一瞬の重複表示防止)
    private func refreshMatching() async {
        if refreshingMatching {
            rematchQueued = true
            return
        }
        refreshingMatching = true
        defer { refreshingMatching = false }
        repeat {
            rematchQueued = false
            guard monitoring else { break }
            await targetsRefresher()
            let snapshot = await placeholderProvider()
            matchPorts()
            syncFallbacks()
            composeEntries(snapshot)
            debugLogComposition()
        } while rematchQueued
    }

    /// FT_MONITOR_DEBUG=1 のとき、表示構成が変わるたびに stdout へ記録する(診断用)
    private func debugLogComposition() {
        guard ProcessInfo.processInfo.environment["FT_MONITOR_DEBUG"] == "1" else { return }
        let composition = entries.map { entry -> String in
            switch entry.kind {
            case .stream(let streamer): return "tile(\(streamer.portLabel ?? streamer.window.title))"
            case .fallback(let tile): return "tile(\(tile.label))"
            case .placeholder(let tile): return "card(\(tile.name))"
            }
        }.joined(separator: " ")
        guard composition != lastDebugComposition else { return }
        lastDebugComposition = composition
        // stdout はリダイレクト時にバッファリングされるため stderr(無バッファ)へ
        fputs("[monitor] count=\(entries.count) \(composition)\n", stderr)
    }

    // MARK: - 内部

    private func refresh() async {
        do {
            let windows = try await WindowDiscovery.findDeviceWindows()
            let currentIDs = Set(windows.map(\.id))

            // 閉じた/消えたウィンドウのストリーマを除去
            for streamer in streamers where !currentIDs.contains(streamer.window.id) {
                await streamer.stop()
            }
            streamers.removeAll { !currentIDs.contains($0.window.id) }

            // 新規ウィンドウのストリーマを開始
            let knownIDs = Set(streamers.map(\.window.id))
            for window in windows where !knownIDs.contains(window.id) {
                let streamer = WindowStreamer(window: window)
                streamers.append(streamer)
                await streamer.start()
            }

            await refreshMatching()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            if !WindowDiscovery.preflightPermission() {
                permissionGranted = false
                monitoring = false
                loopTask?.cancel()
            }
        }
    }

    /// /status のデバイス名とウィンドウタイトルの contains 照合。
    /// 同名デバイスが複数などで一意に決まらない場合はラベル無し(タイトルのみ表示)
    private func matchPorts() {
        let statuses = statusProvider()
        for streamer in streamers {
            switch streamer.window.kind {
            case .androidEmulator:
                // タイトル "Android Emulator - <AVD>:<コンソールポート>" → serial "emulator-<port>"
                let title = streamer.window.title
                if let colon = title.lastIndex(of: ":"),
                   let consolePort = Int(title[title.index(after: colon)...]) {
                    streamer.portLabel = "android:emulator-\(consolePort)"
                } else {
                    streamer.portLabel = "android"
                }
            case .iosSimulator:
                let matches = statuses.filter { streamer.window.title.contains($0.value.device) }
                streamer.portLabel = matches.count == 1 ? "ios:\(matches.keys.first!)" : nil
            }
        }
    }

    /// ウィンドウに照合できなかったデバイスへフォールバックタイルを用意する。
    /// iOS = 接続済みブリッジのポート、Android = adb 接続中デバイス
    /// (ヘッドレス起動のエミュレータはウィンドウが無いので常にこちら)
    private func syncFallbacks() {
        let statuses = statusProvider()
        let androidDevices = androidDevicesProvider()

        let coveredPorts = Set(streamers.compactMap { streamer -> UInt16? in
            guard let label = streamer.portLabel, label.hasPrefix("ios:") else { return nil }
            return UInt16(label.dropFirst("ios:".count))
        })
        let coveredSerials = Set(streamers.compactMap { streamer -> String? in
            guard let label = streamer.portLabel, label.hasPrefix("android:") else { return nil }
            return String(label.dropFirst("android:".count))
        })

        fallbacks.removeAll { tile in
            let stale: Bool
            switch tile.source {
            case .iosBridge(let port):
                stale = coveredPorts.contains(port) || statuses[port] == nil
            case .androidDevice(let serial):
                // 表示名が変わった場合(論理名の解決が後から届いた等)も作り直す
                stale = coveredSerials.contains(serial)
                    || !androidDevices.contains {
                        $0.serial == serial && $0.name == tile.deviceName
                    }
            }
            if stale { tile.stop() }
            return stale
        }
        for (port, status) in statuses.sorted(by: { $0.key < $1.key })
        where !coveredPorts.contains(port)
            && !fallbacks.contains(where: { $0.source == .iosBridge(port: port) }) {
            let tile = FallbackTile(source: .iosBridge(port: port), deviceName: status.device)
            fallbacks.append(tile)
            tile.start()
        }
        for device in androidDevices.sorted(by: { $0.serial < $1.serial })
        where !coveredSerials.contains(device.serial)
            && !fallbacks.contains(where: { $0.source == .androidDevice(serial: device.serial) }) {
            let tile = FallbackTile(source: .androidDevice(serial: device.serial),
                                    deviceName: device.name)
            fallbacks.append(tile)
            tile.start()
        }
    }

    /// タイルとカードを単一リストへ合成する。マシンプロファイルの各デバイスは
    /// 「SCK ストリーム > フォールバック > プレースホルダー」の優先で必ず 1 エントリだけ選ばれ、
    /// どのデバイスにも帰属しないタイル(手動起動など)は末尾に付く。
    /// 帰属判定はタイルの元データ(statusProvider / snapshot)を「今」読んで行う —
    /// syncFallbacks と同一ターンで呼ぶこと
    private func composeEntries(_ snapshot: PlaceholderSnapshot) {
        let statuses = statusProvider()
        var remainingStreamers = streamers
        var remainingFallbacks = fallbacks
        var composed: [MonitorEntry] = []

        for candidate in snapshot.candidates {
            // このデバイスに帰属するフォールバックを先に回収しておく
            // (ストリームで映る場合は重複表示になるため出さない。
            //  ポーリング自体は次サイクルの syncFallbacks が整理する)
            var claimedFallbacks: [FallbackTile] = []
            remainingFallbacks.removeAll { tile in
                guard matches(candidate, fallback: tile, statuses: statuses,
                              snapshot: snapshot) else { return false }
                claimedFallbacks.append(tile)
                return true
            }
            let kind: MonitorEntry.Kind
            if let index = remainingStreamers.firstIndex(where: {
                matches(candidate, streamer: $0, snapshot: snapshot)
            }) {
                kind = .stream(remainingStreamers.remove(at: index))
            } else if let tile = claimedFallbacks.first {
                kind = .fallback(tile)
            } else {
                kind = .placeholder(candidate)
            }
            composed.append(MonitorEntry(kind: kind, deviceKey: candidate.id,
                                         deviceName: candidate.name))
        }
        composed += remainingStreamers.map {
            MonitorEntry(kind: .stream($0),
                         deviceKey: $0.portLabel ?? "window:\($0.id)",
                         deviceName: $0.window.title)
        }
        composed += remainingFallbacks.map {
            MonitorEntry(kind: .fallback($0), deviceKey: $0.label,
                         deviceName: $0.deviceName)
        }
        entries = composed

        // 消えたデバイス(プロファイル外タイルの終了など)は選択からも落とす
        let validKeys = Set(composed.map(\.deviceKey))
        let pruned = selectedDeviceKeys.intersection(validKeys)
        if pruned != selectedDeviceKeys { selectedDeviceKeys = pruned }
    }

    /// SCK ストリームがマシンプロファイルのデバイスに帰属するか
    private func matches(_ candidate: PlaceholderTile, streamer: WindowStreamer,
                         snapshot: PlaceholderSnapshot) -> Bool {
        guard let match = candidate.windowMatch else { return false }
        switch (candidate.platform, streamer.window.kind) {
        case ("ios", .iosSimulator):
            return streamer.window.title.localizedCaseInsensitiveContains(match)
        case ("android", .androidEmulator):
            // serial → AVD の対応が引ければそれで、無ければタイトル照合
            // (エミュレータのタイトルは "Android Emulator - <AVD>:<ポート>")
            if let label = streamer.portLabel, label.hasPrefix("android:"),
               snapshot.serialToAVD[String(label.dropFirst("android:".count))] == match {
                return true
            }
            return streamer.window.title.localizedCaseInsensitiveContains(match)
        default:
            return false
        }
    }

    /// フォールバックタイルがマシンプロファイルのデバイスに帰属するか
    private func matches(_ candidate: PlaceholderTile, fallback: FallbackTile,
                         statuses: [UInt16: StatusResponse],
                         snapshot: PlaceholderSnapshot) -> Bool {
        switch fallback.source {
        case .iosBridge(let port):
            return candidate.platform == "ios"
                && statuses[port]?.device == candidate.windowMatch
        case .androidDevice(let serial):
            guard candidate.platform == "android" else { return false }
            // AVD 対応が引ければそれで、シャットダウン中などで対応が消えている間は
            // 論理名(タイル表示名)でも帰属させる(タイルだけ残ってカードと重複するのを防ぐ)
            return snapshot.serialToAVD[serial] == candidate.windowMatch
                || fallback.deviceName == candidate.name
        }
    }
}
