// DeviceMonitorCenter.swift
// モニター全体の管理: ウィンドウの再列挙(5秒毎)、ストリーマの増減、
// ポート⇔ウィンドウの照合、ウィンドウが見つからないブリッジのフォールバックポーリング。

import AppKit
import Foundation
import FTBridgeClient
import FTCore
import Observation

/// SCK でウィンドウが見つからないポート用のフォールバックタイル
/// (ブリッジの /screenshot を低頻度ポーリング)
@MainActor
@Observable
final class FallbackTile: Identifiable {
    nonisolated let port: UInt16
    let deviceName: String
    private(set) var latestImage: NSImage?
    private(set) var lastFrameAt: Date?
    private var task: Task<Void, Never>?

    nonisolated var id: UInt16 { port }

    init(port: UInt16, deviceName: String) {
        self.port = port
        self.deviceName = deviceName
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                if let data = try? await BridgeClient(port: self.port).screenshot(),
                   let image = NSImage(data: data) {
                    self.latestImage = image
                    self.lastFrameAt = Date()
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

@MainActor
@Observable
final class DeviceMonitorCenter {
    private(set) var streamers: [WindowStreamer] = []
    private(set) var fallbacks: [FallbackTile] = []
    private(set) var monitoring = false
    var permissionGranted = true
    var lastError: String?
    /// ユーザーのモニター ON/OFF(OFF ならタブ表示中もストリームを止める)
    var userEnabled = true

    /// ポート照合・フォールバック生成に使う接続状態の供給元(AppModel が注入)
    var statusProvider: () -> [UInt16: StatusResponse] = { [:] }

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
        matchPorts()
        syncFallbacks()
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

            matchPorts()
            syncFallbacks()
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

    /// 接続済みブリッジのうちウィンドウに照合できなかったポートへフォールバックタイルを用意する
    private func syncFallbacks() {
        let statuses = statusProvider()
        let coveredPorts = Set(streamers.compactMap { streamer -> UInt16? in
            guard let label = streamer.portLabel, label.hasPrefix("ios:") else { return nil }
            return UInt16(label.dropFirst("ios:".count))
        })

        fallbacks.removeAll { tile in
            let stale = coveredPorts.contains(tile.port) || statuses[tile.port] == nil
            if stale { tile.stop() }
            return stale
        }
        for (port, status) in statuses.sorted(by: { $0.key < $1.key })
        where !coveredPorts.contains(port) && !fallbacks.contains(where: { $0.port == port }) {
            let tile = FallbackTile(port: port, deviceName: status.device)
            fallbacks.append(tile)
            tile.start()
        }
    }
}
