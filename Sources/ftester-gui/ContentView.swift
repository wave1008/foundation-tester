// ContentView.swift
// メイン画面: サイドバー(フロー一覧)+ 3タブ(フロー実行 / ライブ操作 / FM探索)

import SwiftUI
import FTCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    // FT_TAB=3 などで初期タブを指定可(検証・デモ用)
    @State private var tab = Int(ProcessInfo.processInfo.environment["FT_TAB"] ?? "0") ?? 0
    @State private var showNewProjectSheet = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("フロー実行").tag(0)
                    Text("ライブ操作").tag(1)
                    Text("FM探索").tag(2)
                    Text("プロファイル").tag(4)  // FT_TAB 互換のため設定(3)の番号は据え置き
                    Text("設定").tag(3)
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])

                switch tab {
                case 0: RunView()
                case 1: LiveView()
                case 2: ExploreView()
                case 4: ProfilesView()
                default: SettingsView()
                }
            }
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showNewProjectSheet) {
            NewProjectSheet()
        }
        .task {
            await model.refreshScenarios()
            await model.refreshTargets()
            // 起動時に全実行(スモークテスト・デモ用): FT_AUTORUN=1 swift run ftester-gui
            if ProcessInfo.processInfo.environment["FT_AUTORUN"] == "1" {
                await model.runAll()
            }
        }
    }

    private var sidebar: some View {
        @Bindable var model = model
        return List(selection: $model.selectedScenarioID) {
            Section("プロジェクト") {
                HStack(spacing: 6) {
                    Picker("プロジェクト", selection: $model.selectedProjectName) {
                        if model.projects.isEmpty {
                            Text("なし").tag(String?.none)
                        }
                        ForEach(model.projects) { project in
                            Text(project.name).tag(Optional(project.name))
                        }
                    }
                    .labelsHidden()
                    .onChange(of: model.selectedProjectName) {
                        Task { await model.refreshScenarios() }
                    }
                    Button {
                        showNewProjectSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("新規テストプロジェクトを作成(Projects/<名前>/ の雛形生成と Package.swift への登録)")
                }
            }
            Section("シナリオ(Projects/\(model.selectedProjectName ?? "?")/Scenarios)") {
                ForEach(model.scenarios) { entry in
                    HStack(spacing: 8) {
                        stateIcon(entry.state)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.info.id)
                                .lineLimit(1)
                            Text("\(entry.info.platform ?? "ios/android")"
                                 + (entry.info.title.isEmpty ? "" : " ・ \(entry.info.title)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .tag(entry.id)
                }
            }
            if let status = model.scenarioListStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.refreshScenarios() }
                } label: {
                    Label("再読込(ビルド)", systemImage: "arrow.clockwise")
                }
                Button {
                    Task { await model.runAll() }
                } label: {
                    Label("全実行", systemImage: "play.square.stack")
                }
                .disabled(model.runningFlow || model.scenarios.isEmpty)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup {
            // 実行プロファイル(profiles/runs/)。選択時はブリッジ供給・自動インストール込みで実行
            Picker("プロファイル", selection: $model.selectedRunProfile) {
                Text("プロファイルなし").tag(String?.none)
                ForEach(model.runProfiles, id: \.self) { name in
                    Text("📋 \(name)").tag(Optional(name))
                }
            }
            .help("実行プロファイル(profiles/runs/)。選択時はデバイス供給・自動インストール込みで実行。"
                  + "「プロファイルなし」は稼働中デバイスへの自動割当")

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
                        Text(entry.info.id).font(.headline).lineLimit(2)
                        Text("\(entry.info.app) [\(entry.info.platform ?? "ios/android")]")
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
                if !entry.info.title.isEmpty {
                    Text(entry.info.title)
                        .font(.system(.body))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("ステップの内容は Projects/<プロジェクト>/Scenarios/ のソースと実行ログで確認できます")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ContentUnavailableView("シナリオを選択してください",
                                       systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
    }

    private var logView: some View {
        // モニターでデバイスを選択中はその台数分のレーンに絞る(未選択なら全ワーカー)
        let lanes = model.displayedLanes
        let selectionCount = model.monitor.selectedEntries.count
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("実行ログ").font(.caption).foregroundStyle(.secondary)
                if selectionCount > 0 {
                    Text("モニターで選択中の \(selectionCount) 台を表示")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Button("選択解除") { model.monitor.selectedDeviceKeys = [] }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("クリア") { model.clearLanes() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if lanes.isEmpty {
                ScrollView {
                    Text("")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(.background.secondary)
            } else {
                // ワーカー毎のログレーン(並列実行時の混線防止。1ワーカーなら従来同様の1列)
                HStack(alignment: .top, spacing: 8) {
                    ForEach(lanes) { lane in
                        LaneLogView(lane: lane)
                    }
                }
            }
        }
        .padding([.horizontal, .bottom])
    }
}

/// 新規テストプロジェクト作成シート(CLI の `ftester project create` と同じ処理)
struct NewProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var app = "com.example.myapp"
    @State private var errorMessage: String?

    private var nameIsValid: Bool { ProjectStore.isValidName(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新規テストプロジェクト")
                .font(.headline)

            Form {
                TextField("プロジェクト名", text: $name, prompt: Text("MyApp"))
                if !name.isEmpty && !nameIsValid {
                    Text("英数字・_・- のみ(先頭は英数字か _)。SPM のターゲット名になるため日本語は使えません")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                TextField("対象アプリ(bundle ID / パッケージ名)", text: $app)
            }
            .textFieldStyle(.roundedBorder)

            Text("Projects/<名前>/ に Scenarios/・profiles/(apps / machines / runs)・reports/ の雛形を生成し、Package.swift に SPM ターゲットを登録します。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Text("❌ \(errorMessage)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        errorMessage = await model.createProject(
                            name: name, app: app.trimmingCharacters(in: .whitespaces))
                        if errorMessage == nil { dismiss() }
                    }
                } label: {
                    if model.creatingProject {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("作成")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!nameIsValid || model.creatingProject)
            }
        }
        .padding(20)
        .frame(width: 420)
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
