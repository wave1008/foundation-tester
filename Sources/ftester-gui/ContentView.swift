// ContentView.swift
// メイン画面: サイドバー(フロー一覧)+ 3タブ(フロー実行 / ライブ操作 / FM探索)

import SwiftUI
import FTCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    // FT_TAB=3 などで初期タブを指定可(検証・デモ用)
    @State private var tab = Int(ProcessInfo.processInfo.environment["FT_TAB"] ?? "0") ?? 0
    @State private var showNewProjectSheet = false

    // シナリオのフォルダ操作(閉じているフォルダ・各アラートの入力)
    @State private var collapsedFolders: Set<String> = []
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var folderToRename: String?
    @State private var renameFolderName = ""
    @State private var folderErrorMessage: String?
    @State private var rootDropTargeted = false
    @State private var bottomAreaTargeted = false

    var body: some View {
        // NavigationSplitView はウィンドウリサイズ時に列を勝手に畳む・幅を戻す挙動を
        // 制御できない(2026-07-08 ユーザー報告)ため、RunView と同じ HSplitView で
        // 決定的にレイアウトする。シナリオペインは 240〜600pt でリサイズでき、消えない。
        // ウィンドウツールバー(.toolbar)はプレーンウィンドウではアイテムが収集されない
        // ため使わず、コントロールバーを通常のビューとして最上段に置く
        VStack(spacing: 0) {
            controlBar
            Divider()
            HSplitView {
                sidebar
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 600)
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
                .frame(minWidth: 520, maxWidth: .infinity)
            }
        }
        .frame(minWidth: 800, minHeight: 460)
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
        return List(selection: $model.selectedScenarioIDs) {
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
            Section {
                // フォルダ(Scenarios/ のサブディレクトリ、1 階層のみ)→ 直下のシナリオ の順
                ForEach(model.scenarioFolders, id: \.self) { folder in
                    DisclosureGroup(isExpanded: folderExpansion(folder)) {
                        let entries = model.scenarioEntries(inFolder: folder)
                        if entries.isEmpty {
                            Text("シナリオをここへドラッグ")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(entries) { entry in
                            scenarioRow(entry)
                        }
                    } label: {
                        ScenarioFolderLabel(
                            folder: folder,
                            count: model.scenarioEntries(inFolder: folder).count,
                            onRename: {
                                renameFolderName = folder
                                folderToRename = folder
                            },
                            onDelete: {
                                folderErrorMessage = model.deleteScenarioFolder(folder)
                            })
                    }
                }
                ForEach(model.scenarioEntries(inFolder: nil)) { entry in
                    scenarioRow(entry)
                }
            } header: {
                HStack {
                    Text("シナリオ(Projects/\(model.selectedProjectName ?? "?")/Scenarios)")
                    Spacer()
                    Button {
                        newFolderName = ""
                        showNewFolderAlert = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .help("新規フォルダを作成(Scenarios/ 直下、1 階層のみ)。シナリオは行をドラッグで移動")
                }
                .contentShape(Rectangle())
                .background(rootDropTargeted ? Color.accentColor.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
                // ヘッダへのドロップ = フォルダから Scenarios/ 直下へ戻す
                .dropDestination(for: String.self) { ids, _ in
                    moveScenarios(ids, toFolder: nil)
                } isTargeted: { rootDropTargeted = $0 }
            }
            if let status = model.scenarioListStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            // 最下段の「余白」行。List(NSTableView)は行のある領域しか右クリックを
            // 受け取らないため、アイテムの下の空きエリアとして振る舞う透明な行を置く
            // (右クリック = フォルダ追加、ドロップ = Scenarios/ 直下へ戻す)
            Color.clear
                .frame(maxWidth: .infinity, minHeight: 240)
                .contentShape(Rectangle())
                .listRowSeparator(.hidden)
                .overlay(alignment: .top) {
                    if bottomAreaTargeted {
                        Text("Scenarios/ 直下へ移動")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(4)
                    }
                }
                .background(bottomAreaTargeted ? Color.accentColor.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
                .contextMenu {
                    Button("フォルダを追加...") {
                        newFolderName = ""
                        showNewFolderAlert = true
                    }
                }
                .dropDestination(for: String.self) { ids, _ in
                    moveScenarios(ids, toFolder: nil)
                } isTargeted: { bottomAreaTargeted = $0 }
        }
        .listStyle(.sidebar)
        // (再読込・全実行ボタンは controlBar にある。プレーンウィンドウでは
        //  List への .toolbar がウィンドウツールバーに収集されないため置かないこと)
        // 空きエリアの右クリック(items が空)= フォルダ追加。
        // シナリオ行の右クリックにはフォルダへの移動も出す(ドラッグの代替)。
        // フォルダ行は ScenarioFolderLabel 自身の contextMenu が優先される
        .contextMenu(forSelectionType: URL.self) { items in
            let targets = model.scenarios.filter { items.contains($0.id) }
            if !targets.isEmpty {
                Button(targets.count == 1
                       ? "実行" : "選択した \(targets.count) 件を実行") {
                    Task { await model.runScenarios(targets) }
                }
                .disabled(model.runningFlow)
                Divider()
            }
            if !targets.isEmpty,
               !model.scenarioFolders.isEmpty || targets.contains(where: { $0.folder != nil }) {
                Menu("フォルダへ移動") {
                    ForEach(model.scenarioFolders, id: \.self) { folder in
                        Button(folder) {
                            for target in targets {
                                model.moveScenario(id: target.info.id, toFolder: folder)
                            }
                        }
                    }
                    if targets.contains(where: { $0.folder != nil }) {
                        if !model.scenarioFolders.isEmpty {
                            Divider()
                        }
                        Button("Scenarios 直下へ戻す") {
                            for target in targets {
                                model.moveScenario(id: target.info.id, toFolder: nil)
                            }
                        }
                    }
                }
            }
            Button("フォルダを追加...") {
                newFolderName = ""
                showNewFolderAlert = true
            }
        }
        .alert("新規フォルダ", isPresented: $showNewFolderAlert) {
            TextField("フォルダ名", text: $newFolderName)
            Button("作成") {
                folderErrorMessage = model.createScenarioFolder(newFolderName)
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("Scenarios/ 直下にフォルダを作成します(階層は 1 段まで)。"
                 + "シナリオは行をフォルダへドラッグして移動できます")
        }
        .alert("フォルダ名を変更", isPresented: Binding(
            get: { folderToRename != nil },
            set: { if !$0 { folderToRename = nil } })) {
            TextField("フォルダ名", text: $renameFolderName)
            Button("変更") {
                guard let folder = folderToRename else { return }
                let error = model.renameScenarioFolder(folder, to: renameFolderName)
                folderErrorMessage = error
                if error == nil, collapsedFolders.remove(folder) != nil {
                    collapsedFolders.insert(
                        renameFolderName.trimmingCharacters(in: .whitespaces))
                }
            }
            Button("キャンセル", role: .cancel) {}
        }
        .alert("フォルダ操作を完了できません", isPresented: Binding(
            get: { folderErrorMessage != nil },
            set: { if !$0 { folderErrorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(folderErrorMessage ?? "")
        }
    }

    /// シナリオ 1 行(選択タグ+フォルダ移動用のドラッグ元。ペイロードはシナリオ ID)
    private func scenarioRow(_ entry: AppModel.ScenarioEntry) -> some View {
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
        .draggable(entry.info.id)
        .tag(entry.id)
    }

    /// フォルダの開閉状態(既定は開。閉じたものだけ記録する)
    private func folderExpansion(_ folder: String) -> Binding<Bool> {
        Binding(get: { !collapsedFolders.contains(folder) },
                set: { expanded in
                    if expanded {
                        collapsedFolders.remove(folder)
                    } else {
                        collapsedFolders.insert(folder)
                    }
                })
    }

    /// ドロップされたシナリオ ID 群を移動する。戻り値: 1 つでも受理したか
    private func moveScenarios(_ ids: [String], toFolder folder: String?) -> Bool {
        var handled = false
        for id in ids {
            if model.moveScenario(id: id, toFolder: folder) {
                handled = true
            }
        }
        return handled
    }

    /// 旧ウィンドウツールバー相当のコントロールバー。プレーンウィンドウ(HSplitView 直下)
    /// では .toolbar のアイテムがタイトルバーに収集されないため、通常のビューとして置く
    private var controlBar: some View {
        @Bindable var model = model
        return HStack(spacing: 10) {
            Button {
                Task { await model.refreshScenarios() }
            } label: {
                Label("再読込", systemImage: "arrow.clockwise")
            }
            .help("シナリオを再ビルドして一覧を更新")

            Button {
                Task { await model.runAll() }
            } label: {
                Label("全実行", systemImage: "play.square.stack")
            }
            .disabled(model.runningFlow || model.scenarios.isEmpty)
            .help("全シナリオを稼働中デバイスへ振り分けて並列実行")

            Spacer()

            // 実行プロファイル(profiles/runs/)。選択時はブリッジ供給・自動インストール込みで実行
            Picker("プロファイル", selection: $model.selectedRunProfile) {
                Text("プロファイルなし").tag(String?.none)
                ForEach(model.runProfiles, id: \.self) { name in
                    Text("📋 \(name)").tag(Optional(name))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
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
            .labelsHidden()
            .frame(maxWidth: 280)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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

/// シナリオフォルダの行ラベル(ドロップ先+右クリックメニュー)。
/// ドロップ中はハイライトして受け入れ可能なことを示す
private struct ScenarioFolderLabel: View {
    @Environment(AppModel.self) private var model
    let folder: String
    let count: Int
    let onRename: () -> Void
    let onDelete: () -> Void
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: targeted ? "folder.fill" : "folder")
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
            Text(folder)
                .lineLimit(1)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .background(targeted ? Color.accentColor.opacity(0.15) : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .dropDestination(for: String.self) { ids, _ in
            var handled = false
            for id in ids {
                if model.moveScenario(id: id, toFolder: folder) {
                    handled = true
                }
            }
            return handled
        } isTargeted: { targeted = $0 }
        .contextMenu {
            Button("このフォルダを実行") {
                Task { await model.runScenarios(model.scenarioEntries(inFolder: folder)) }
            }
            .disabled(count == 0 || model.runningFlow)
            Divider()
            Button("名前を変更...") { onRename() }
            Divider()
            Button("削除", role: .destructive) { onDelete() }
                .disabled(count > 0)
        }
        .help("シナリオをここへドラッグで移動。右クリックで実行・名前変更・削除(削除は空のみ)")
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
        let selected = model.selectedEntries
        return VStack(alignment: .leading, spacing: 8) {
            if selected.isEmpty {
                ContentUnavailableView("シナリオを選択してください",
                                       systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        if let entry = selected.first, selected.count == 1 {
                            Text(entry.info.id).font(.headline).lineLimit(2)
                            Text("\(entry.info.app) [\(entry.info.platform ?? "ios/android")]")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(selected.count) 件のシナリオを選択中").font(.headline)
                            Text("Cmd+クリックで追加・解除、Shift+クリックで範囲選択")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Toggle("自己修復(--heal)", isOn: $model.heal)
                        .toggleStyle(.checkbox)
                    Button {
                        Task { await model.runSelected() }
                    } label: {
                        Label(selected.count == 1 ? "実行" : "選択した \(selected.count) 件を実行",
                              systemImage: "play.fill")
                    }
                    .keyboardShortcut("r")
                    .disabled(model.runningFlow)
                }
                if let entry = selected.first, selected.count == 1 {
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
                    // 複数選択中: 実行対象の一覧(一覧順 = 実行順)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(selected) { entry in
                                Text("・ \(entry.info.id)"
                                     + (entry.folder.map { "(\($0))" } ?? ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
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
