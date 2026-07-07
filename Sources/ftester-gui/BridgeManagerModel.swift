// BridgeManagerModel.swift
// ブリッジ管理パネルの状態: シミュレータ一覧(simctl)+ ポート毎の bridge up/down。
// 起動は既存の BridgeLauncher をそのまま使う(CLI の bridge up と同じ手順)。

import Foundation
import FTBridgeClient
import FTCore
import Observation

@MainActor
@Observable
final class BridgeManagerModel {

    struct SimDevice: Identifiable, Hashable {
        let udid: String
        let name: String
        let os: String
        let booted: Bool
        var id: String { udid }
        var label: String { "\(name)(\(os))" + (booted ? " ● 起動中" : "") }
    }

    enum SlotState {
        case unknown, stopped, starting, ready, error
    }

    struct BridgeSlot: Identifiable {
        let port: UInt16
        var deviceUDID: String = ""
        var state: SlotState = .unknown
        var busy = false
        var statusText = "未確認"
        var id: UInt16 { port }
    }

    var devices: [SimDevice] = []
    var slots: [BridgeSlot] = []
    var log: [String] = []
    /// 「追加」で割り当てた(まだ稼働していない)ポート。停止後のスロットもここに残して表示し続ける
    private var manualPorts: Set<UInt16> = []

    // MARK: - 更新

    /// 範囲内で「稼働中 / 起動中(pid あり)/ 手動追加済み」のポートだけをスロットとして表示する。
    /// statuses は AppModel.refreshTargets() のスキャン結果を渡す
    func refresh(range: [UInt16], statuses: [UInt16: StatusResponse]) async {
        loadDevices()
        manualPorts.formIntersection(range)  // 範囲変更で範囲外になった手動スロットは破棄
        let selections = Dictionary(uniqueKeysWithValues: slots.map { ($0.port, $0.deviceUDID) })
        let slotPorts = range.filter { port in
            statuses[port] != nil
                || FileManager.default.fileExists(atPath: ".ftester/bridge-\(port).pid")
                || manualPorts.contains(port)
        }
        slots = slotPorts.map { BridgeSlot(port: $0, deviceUDID: selections[$0] ?? "") }
        for port in slotPorts {
            await updateStatus(port: port)
            // 未選択スロットの初期値: 起動中シミュレータの先頭
            mutateSlot(port) { slot in
                if slot.deviceUDID.isEmpty {
                    slot.deviceUDID = devices.first(where: { $0.booted })?.udid
                        ?? devices.first?.udid ?? ""
                }
            }
        }
    }

    /// 範囲内の空きポートへ新しいブリッジ枠を割り当てる(動的割り当て)
    func addSlot(range: [UInt16]) {
        guard let free = range.first(where: { port in
            !slots.contains(where: { $0.port == port })
        }) else {
            append("⚠️ ポート範囲に空きがありません — 設定の範囲を広げてください")
            return
        }
        manualPorts.insert(free)
        var slot = BridgeSlot(port: free, deviceUDID: devices.first(where: { $0.booted })?.udid
                                              ?? devices.first?.udid ?? "")
        slot.state = .stopped
        slot.statusText = "停止中"
        slots.append(slot)
        slots.sort { $0.port < $1.port }
        append("→ port \(free) を割り当てました(デバイスを選んで起動してください)")
    }

    private func loadDevices() {
        guard let result = try? Shell.run(["xcrun", "simctl", "list", "devices", "-j"]),
              result.status == 0,
              let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = json["devices"] as? [String: [[String: Any]]] else {
            append("❌ simctl list devices に失敗しました")
            return
        }
        var found: [SimDevice] = []
        for (runtime, list) in runtimes {
            // "com.apple.CoreSimulator.SimRuntime.iOS-27-0" → "iOS 27.0"
            let os = runtime
                .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
                .replacingOccurrences(of: "-", with: ".")
                .replacingOccurrences(of: "iOS.", with: "iOS ")
            guard os.hasPrefix("iOS") else { continue }
            for device in list {
                guard (device["isAvailable"] as? Bool) == true,
                      let udid = device["udid"] as? String,
                      let name = device["name"] as? String else { continue }
                let booted = (device["state"] as? String) == "Booted"
                found.append(SimDevice(udid: udid, name: name, os: os, booted: booted))
            }
        }
        // 起動中 → OS 降順 → 名前順
        devices = found.sorted {
            if $0.booted != $1.booted { return $0.booted }
            if $0.os != $1.os { return $0.os > $1.os }
            return $0.name < $1.name
        }
    }

    private func updateStatus(port: UInt16) async {
        do {
            let status = try await BridgeClient(port: port).status()
            let booted = devices.first(where: { $0.name == status.device && $0.booted })
            mutateSlot(port) { slot in
                slot.state = .ready
                slot.statusText = "\(status.device)(\(status.osVersion))"
                // 接続済みならそのデバイスを選択状態に反映
                if let booted { slot.deviceUDID = booted.udid }
            }
        } catch {
            let pidFile = URL(fileURLWithPath: ".ftester/bridge-\(port).pid")
            let starting = FileManager.default.fileExists(atPath: pidFile.path)
            mutateSlot(port) { slot in
                slot.state = starting ? .starting : .stopped
                slot.statusText = starting ? "起動中(応答待ち)" : "停止中"
            }
        }
    }

    // MARK: - up / down

    /// await をまたぐと refresh() で slots が差し替わることがあるため、
    /// スロットの変更は常にポートで引き直してから行う
    private func mutateSlot(_ port: UInt16, _ body: (inout BridgeSlot) -> Void) {
        guard let index = slots.firstIndex(where: { $0.port == port }) else { return }
        body(&slots[index])
    }

    func up(port: UInt16) async {
        guard let slot = slots.first(where: { $0.port == port }), !slot.busy else { return }
        let udid = slot.deviceUDID
        guard !udid.isEmpty else {
            append("⚠️ port \(port): デバイスを選択してください")
            return
        }
        mutateSlot(port) {
            $0.busy = true
            $0.state = .starting
            $0.statusText = "起動中..."
        }
        append("→ port \(port): ブリッジ起動(device: \(deviceName(udid)))")

        do {
            let root = try RepoRoot.find()
            let launcher = BridgeLauncher(repoRoot: root, device: udid, port: port)
            // Shell 実行はブロッキングなので背景スレッドで(ビルドは初回のみ数分かかる)
            try await Task.detached(priority: .userInitiated) {
                try launcher.generateProjectIfNeeded()
                do {
                    try launcher.startDetached()
                } catch LauncherError.xctestrunNotFound {
                    // ビルド未実施の場合のみ build-for-testing(CLI の --skip-build 相当の挙動)
                    try launcher.buildForTesting()
                    try launcher.startDetached()
                }
            }.value
            append("→ port \(port): 起動待ち(/status ポーリング)...")
            try await launcher.waitUntilReady()
            // コールドブート直後の kAXErrorIPCTimeout 対策ウォームアップ
            if (try? await BridgeClient(port: port).snapshot()) == nil {
                _ = try? await BridgeClient(port: port).snapshot()
            }
            append("✅ port \(port): ブリッジ準備完了")
        } catch {
            mutateSlot(port) {
                $0.state = .error
                $0.statusText = "起動失敗"
            }
            append("❌ port \(port): \(error.localizedDescription)")
        }
        await updateStatus(port: port)
        mutateSlot(port) { $0.busy = false }
    }

    /// スロットを一覧から削除する(稼働中/起動中なら先に停止する)
    func removeSlot(port: UInt16) async {
        let hasPid = FileManager.default.fileExists(atPath: ".ftester/bridge-\(port).pid")
        let isReady = slots.first(where: { $0.port == port })?.state == .ready
        if hasPid {
            await down(port: port)
        } else if isReady {
            // pid ファイルなしで応答している(外部起動など)場合は停止できない —
            // 一覧からは外すが、再スキャンで稼働中として再検出される
            append("⚠️ port \(port): pid ファイルがないため停止できません(bridge down を確認)")
        }
        manualPorts.remove(port)
        slots.removeAll { $0.port == port }
        append("→ port \(port) をブリッジ一覧から削除しました")
    }

    func down(port: UInt16) async {
        manualPorts.insert(port)  // 停止後もスロットを残す(再起動できるように)
        do {
            let root = try RepoRoot.find()
            try BridgeLauncher(repoRoot: root, port: port).stop()
            append("✅ port \(port): ブリッジを停止しました")
        } catch {
            append("❌ port \(port): \(error.localizedDescription)")
        }
        // SIGTERM 直後は /status がまだ応答することがあるため少し待つ
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await updateStatus(port: port)
    }

    private func deviceName(_ udid: String) -> String {
        devices.first(where: { $0.udid == udid })?.name ?? udid
    }

    private func append(_ line: String) {
        log.append(line)
    }
}
