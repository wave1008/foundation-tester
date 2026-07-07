// ContentView.swift
// メイン画面: サイドバー(フロー一覧)+ 3タブ(フロー実行 / ライブ操作 / FM探索)

import SwiftUI
import FTCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    // FT_TAB=3 などで初期タブを指定可(検証・デモ用)
    @State private var tab = Int(ProcessInfo.processInfo.environment["FT_TAB"] ?? "0") ?? 0

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("フロー実行").tag(0)
                    Text("ライブ操作").tag(1)
                    Text("FM探索").tag(2)
                    Text("設定").tag(3)
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])

                switch tab {
                case 0: RunView()
                case 1: LiveView()
                case 2: ExploreView()
                default: SettingsView()
                }
            }
        }
        .toolbar { toolbarContent }
        .task {
            model.refreshFlows()
            await model.refreshTargets()
            // 起動時に全実行(スモークテスト・デモ用): FT_AUTORUN=1 swift run ftester-gui
            if ProcessInfo.processInfo.environment["FT_AUTORUN"] == "1" {
                await model.runAll()
            }
        }
    }

    private var sidebar: some View {
        @Bindable var model = model
        return List(selection: $model.selectedFlowID) {
            Section("フロー(flows/)") {
                ForEach(model.flows) { entry in
                    HStack(spacing: 8) {
                        stateIcon(entry.state)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.flow.name)
                                .lineLimit(1)
                            Text("\(entry.flow.platform ?? "ios") ・ \(entry.flow.steps.count) steps"
                                 + (entry.flow.dirty == true ? " ・ dirty" : ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(entry.url)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.refreshFlows()
                } label: {
                    Label("再読込", systemImage: "arrow.clockwise")
                }
                Button {
                    Task { await model.runAll() }
                } label: {
                    Label("全実行", systemImage: "play.square.stack")
                }
                .disabled(model.runningFlow || model.flows.isEmpty)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup {
            // ライブ操作・FM探索の対象デバイス(発見済みの iOS ブリッジ + Android デバイス)
            Picker("対象", selection: $model.selectedTargetID) {
                if model.targets.isEmpty {
                    Text("デバイスなし").tag(String?.none)
                }
                ForEach(model.targets) { target in
                    Text(target.label).tag(Optional(target.id))
                }
            }
            .help("ライブ操作・FM探索の対象デバイス(全実行は稼働中の全デバイスを自動で使います)")

            Button {
                Task { await model.refreshTargets() }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.connected ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(model.connectionStatus)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            .help("クリックで再スキャン(設定ペインのポート範囲 + adb devices)")
        }
    }

    @ViewBuilder
    func stateIcon(_ state: AppModel.RunState) -> some View {
        switch state {
        case .idle:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .running:
            Image(systemName: "play.circle.fill").foregroundStyle(.blue)
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

// MARK: - フロー実行タブ

struct RunView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VSplitView {
            HSplitView {
                flowPane
                    .frame(minWidth: 280)
                DeviceMonitorGridView()
                    .frame(minWidth: 220)
            }
            .frame(minHeight: 220)

            logView
                .frame(minHeight: 140)
        }
    }

    private var flowPane: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            if let entry = model.selectedEntry {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.flow.name).font(.headline).lineLimit(2)
                        Text("\(entry.flow.app) [\(entry.flow.platform ?? "ios")]")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("自己修復(--heal)", isOn: $model.heal)
                        .toggleStyle(.checkbox)
                    Button {
                        Task { await model.runSelected() }
                    } label: {
                        Label("実行", systemImage: "play.fill")
                    }
                    .keyboardShortcut("r")
                    .disabled(model.runningFlow)
                }
                List(Array(entry.flow.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step.summary)")
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                }
            } else {
                ContentUnavailableView("フローを選択してください",
                                       systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("実行ログ").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("クリア") { model.clearLanes() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.lanes.isEmpty {
                ScrollView {
                    Text("")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(.background.secondary)
            } else {
                // ワーカー毎のログレーン(並列実行時の混線防止。1ワーカーなら従来同様の1列)
                HStack(alignment: .top, spacing: 8) {
                    ForEach(model.lanes) { lane in
                        LaneLogView(lane: lane)
                    }
                }
            }
        }
        .padding([.horizontal, .bottom])
    }
}

/// 1ワーカー分のログ列(自動スクロール付き)
struct LaneLogView: View {
    let lane: AppModel.WorkerLane

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle()
                    .fill(lane.running ? .blue : .secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(lane.title)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(lane.log.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .background(.background.secondary)
                .onChange(of: lane.log.count) {
                    proxy.scrollTo("bottom")
                }
            }
        }
    }
}
