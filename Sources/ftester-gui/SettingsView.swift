// SettingsView.swift
// 設定ペイン: ポート範囲(ブリッジの動的割り当て)とブリッジ管理を集約する。
// 今後増える設定はこのペインにセクションとして足していく。

import SwiftUI
import FTCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let manager = model.bridgeManager
        Form {
            Section {
                HStack(spacing: 8) {
                    Text("開始ポート番号")
                    TextField("8123", text: $model.portRangeStartText)
                        .labelsHidden()
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                    Spacer().frame(width: 20)
                    Text("最大並列数")
                    Stepper("\(model.maxParallel)", value: $model.maxParallel, in: 1...32)
                        .frame(width: 76)
                    Spacer().frame(width: 20)
                    Text("使用ポート: \(String(model.portRange.first ?? 0))〜\(String(model.portRange.last ?? 0))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } header: {
                Text("並列実行(iOS ブリッジ専用)")
            } footer: {
                Text("開始ポートから最大並列数ぶんのポートをスキャンし、稼働中の iOS ブリッジへフローを動的に分配します。ブリッジの追加時もこの中の空きポートが自動で割り当てられます。Android にポートの概念はありません(adb 接続デバイスを自動検出し、デバイス毎のワーカーで並列実行)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if manager.slots.isEmpty {
                    Text("稼働中のブリッジはありません。「ブリッジを追加」で空きポートを割り当ててください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(manager.slots) { slot in
                    slotRow(slot)
                }
                HStack {
                    Button {
                        manager.addSlot(range: model.portRange)
                    } label: {
                        Label("ブリッジを追加", systemImage: "plus")
                    }
                    Spacer()
                    Button {
                        Task { await refreshAll() }
                    } label: {
                        Label("再スキャン", systemImage: "arrow.clockwise")
                    }
                }
            } header: {
                Text("ブリッジ(iOS シミュレータ)")
            } footer: {
                Text("並列実行にはポート毎に別のシミュレータでブリッジを起動します。初回のみ build-for-testing で数分かかります。Android はブリッジ不要(adb 接続デバイスが自動で対象になります)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("ログ") {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(manager.log.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(minHeight: 60, maxHeight: 120)
                    .onChange(of: manager.log.count) {
                        proxy.scrollTo("bottom")
                    }
                }
            }

            Section("環境") {
                LabeledContent("Foundation Models") {
                    Text(model.fmReport.detail).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await refreshAll()
        }
    }

    private func refreshAll() async {
        await model.refreshTargets()
        await model.bridgeManager.refresh(range: model.portRange, statuses: model.portStatuses)
    }

    @ViewBuilder
    private func slotRow(_ slot: BridgeManagerModel.BridgeSlot) -> some View {
        let manager = model.bridgeManager
        HStack(spacing: 8) {
            Circle()
                .fill(color(for: slot.state))
                .frame(width: 9, height: 9)
            Text(String(slot.port))
                .font(.system(.body, design: .monospaced).bold())
                .frame(width: 46, alignment: .leading)

            Picker("", selection: Binding(
                get: { slot.deviceUDID },
                set: { udid in
                    if let index = manager.slots.firstIndex(where: { $0.port == slot.port }) {
                        manager.slots[index].deviceUDID = udid
                    }
                })) {
                ForEach(manager.devices) { device in
                    Text(device.label).tag(device.udid)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280)
            .disabled(slot.busy || slot.state == .ready)

            Text(slot.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if slot.busy {
                ProgressView().controlSize(.small)
            } else if slot.state == .ready {
                Button("停止") {
                    Task {
                        await manager.down(port: slot.port)
                        await model.refreshTargets()
                    }
                }
            } else {
                Button("起動") {
                    Task {
                        await manager.up(port: slot.port)
                        await model.refreshTargets()
                    }
                }
                .disabled(slot.deviceUDID.isEmpty)
            }

            if !slot.busy {
                Button {
                    Task {
                        await manager.removeSlot(port: slot.port)
                        await model.refreshTargets()
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("ブリッジ削除 \(slot.port)")
                .help(slot.state == .ready
                      ? "ブリッジを停止して一覧から削除"
                      : "一覧から削除")
            }
        }
    }

    private func color(for state: BridgeManagerModel.SlotState) -> Color {
        switch state {
        case .ready: return .green
        case .starting: return .yellow
        case .error: return .red
        case .stopped, .unknown: return .secondary.opacity(0.4)
        }
    }
}
