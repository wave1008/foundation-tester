// ProfilesView.swift
// プロファイル編集タブ: 選択プロジェクトの profiles/(apps / machines / runs)を一覧し、
// - 実行プロファイル(runs/)は **フォーム UI** で編集(アプリ Picker・デバイスのチェック・オプション)
// - アプリ / マシンプロファイルは JSON をその場で編集
// 保存時の検証は FTCore の実際の Codable モデル(ProfileResolver.validate)+
// 実行プロファイルは現在マシンでの解決チェックまで行う(実行時と同じ基準)。

import SwiftUI
import FTCore

struct ProfilesView: View {
    @Environment(AppModel.self) private var model

    struct ProfileFile: Identifiable, Hashable {
        let kind: ProfileFileKind
        let url: URL
        var name: String { url.deletingPathExtension().lastPathComponent }
        var id: String { url.path }
        /// 表示用の相対パス(profiles/runs/ios.json)
        var displayName: String { "profiles/\(kind.directoryName)/\(url.lastPathComponent)" }
    }

    /// 実行プロファイルのフォーム編集状態
    struct RunDraft: Equatable {
        var app: String = ""
        var devices: [String] = []           // デバイス名(順序付き)
        var heal = false
        var reportDir = "reports"
        var defaultTimeoutText = ""          // "" = 既定値(5)

        init() {}

        init(from doc: RunProfileDocument) {
            app = doc.app ?? ""
            devices = (doc.devices ?? []).map(\.name)
            heal = doc.heal ?? false
            reportDir = doc.reportDir ?? "reports"
            defaultTimeoutText = doc.defaultTimeout.map(String.init) ?? ""
        }

        var timeoutIsValid: Bool {
            defaultTimeoutText.isEmpty || Int(defaultTimeoutText) != nil
        }
    }

    /// 現在マシンのマシンプロファイルに定義されたデバイス(フォームの選択肢)
    struct MachineDevice: Identifiable, Hashable {
        let name: String
        let platform: String
        let detail: String
        var id: String { name }
    }

    @State private var files: [ProfileFile] = []
    @State private var selectedID: String?
    @State private var editorText = ""
    @State private var originalText = ""
    @State private var statusLines: [String] = []
    // 実行プロファイルのフォーム編集(nil = JSON エディタ表示)
    @State private var runDraft: RunDraft?
    @State private var originalDraft: RunDraft?
    @State private var rawMode = false
    @State private var newDeviceName = ""
    @State private var machineDevices: [MachineDevice] = []
    @State private var machineNameForDevices: String?
    // 未保存変更の破棄確認(選択切替時)
    @State private var pendingSelection: String??
    @State private var showDiscardConfirm = false
    // 新規作成シート
    @State private var newFileKind: ProfileFileKind?
    // 削除確認
    @State private var pendingDelete: ProfileFile?
    // 名前変更シート
    @State private var pendingRename: ProfileFile?

    private var selectedFile: ProfileFile? {
        files.first { $0.id == selectedID }
    }

    private var formMode: Bool { runDraft != nil && !rawMode }

    private var isDirty: Bool {
        formMode ? runDraft != originalDraft : editorText != originalText
    }

    var body: some View {
        HSplitView {
            fileList
                .frame(minWidth: 230, maxWidth: 340)
            editorPane
                .frame(minWidth: 400)
        }
        .task { reloadFiles() }
        .onChange(of: model.selectedProjectName) {
            selectedID = nil
            resetEditorState()
            reloadFiles()
        }
        .sheet(item: $newFileKind) { kind in
            NewProfileSheet(kind: kind) { name in
                createProfile(kind: kind, name: name)
            }
        }
        .sheet(item: $pendingRename) { file in
            RenameProfileSheet(file: file,
                               existingNames: files.filter { $0.kind == file.kind }.map(\.name)) { newName in
                renameProfile(file, to: newName)
            }
        }
        .confirmationDialog("未保存の変更があります", isPresented: $showDiscardConfirm) {
            Button("変更を破棄して切り替える", role: .destructive) {
                if let pending = pendingSelection {
                    selectedID = pending
                    loadSelected()
                }
                pendingSelection = nil
            }
            Button("キャンセル", role: .cancel) { pendingSelection = nil }
        } message: {
            Text("「\(selectedFile?.displayName ?? "")」の編集内容は保存されていません")
        }
        .alert("プロファイルを削除しますか?", isPresented: .init(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } })) {
            Button("削除", role: .destructive) {
                if let file = pendingDelete { deleteProfile(file) }
                pendingDelete = nil
            }
            Button("キャンセル", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete.map { "\($0.displayName) を削除します(元に戻せません)" } ?? "")
        }
    }

    // MARK: - 左: ファイル一覧

    private var fileList: some View {
        List(selection: selectionBinding) {
            ForEach(ProfileFileKind.allCases, id: \.self) { kind in
                Section {
                    ForEach(files.filter { $0.kind == kind }) { file in
                        HStack {
                            Image(systemName: icon(for: kind))
                                .foregroundStyle(.secondary)
                            Text(file.name).lineLimit(1)
                            Spacer()
                            if file.id == selectedID && isDirty {
                                Circle().fill(.orange).frame(width: 7, height: 7)
                                    .help("未保存の変更あり")
                            }
                        }
                        .tag(file.id)
                        .contextMenu {
                            if file.kind == .run {
                                Button("名前を変更...") { pendingRename = file }
                            }
                            Button("Finder で表示") {
                                NSWorkspace.shared.activateFileViewerSelecting([file.url])
                            }
                            Button("削除...", role: .destructive) { pendingDelete = file }
                        }
                    }
                } header: {
                    HStack {
                        Text(sectionTitle(for: kind))
                        Spacer()
                        Button {
                            newFileKind = kind
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("新規\(kind.label)プロファイルを作成")
                    }
                }
            }
        }
    }

    /// 未保存変更があるときは確認を挟む選択バインディング
    private var selectionBinding: Binding<String?> {
        Binding(
            get: { selectedID },
            set: { newValue in
                guard newValue != selectedID else { return }
                if isDirty {
                    pendingSelection = newValue
                    showDiscardConfirm = true
                } else {
                    selectedID = newValue
                    loadSelected()
                }
            })
    }

    private func sectionTitle(for kind: ProfileFileKind) -> String {
        switch kind {
        case .app: return "アプリ(apps/)"
        case .machine: return "マシン(machines/)"
        case .run: return "実行(runs/)"
        }
    }

    private func icon(for kind: ProfileFileKind) -> String {
        switch kind {
        case .app: return "app.badge"
        case .machine: return "desktopcomputer"
        case .run: return "play.rectangle.on.rectangle"
        }
    }

    // MARK: - 右: エディタ

    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let file = selectedFile {
                HStack {
                    Text(file.displayName)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if file.kind == .run && runDraft != nil {
                        // フォーム ⇄ JSON の切替(同期ズレ防止のため未保存中は不可)
                        Button(rawMode ? "フォームで編集" : "JSONで編集") {
                            toggleRawMode()
                        }
                        .disabled(isDirty)
                        .help(isDirty ? "保存してから切り替えてください" : "編集モードを切り替える")
                    }
                    Button {
                        save()
                    } label: {
                        Label(isDirty ? "保存" : "保存済み", systemImage: "square.and.arrow.down")
                    }
                    .keyboardShortcut("s")
                    .disabled(!isDirty || (formMode && !(runDraft?.timeoutIsValid ?? true)))
                }
                if formMode, let file = selectedFile, file.kind == .run {
                    runForm
                } else {
                    TextEditor(text: $editorText)
                        .font(.system(size: 12, design: .monospaced))
                        .autocorrectionDisabled()
                        .scrollContentBackground(.hidden)
                        .background(.background.secondary)
                }
                if !statusLines.isEmpty {
                    ScrollView {
                        Text(statusLines.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 110)
                }
            } else {
                ContentUnavailableView(
                    "プロファイルを選択してください",
                    systemImage: "doc.badge.gearshape",
                    description: Text("左の一覧から選択して編集します。各セクションの + で新規作成できます"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(10)
    }

    // MARK: - 実行プロファイルのフォーム

    private var runForm: some View {
        let draft = Binding(
            get: { runDraft ?? RunDraft() },
            set: { runDraft = $0 })
        return Form {
            Section("対象アプリ") {
                appPicker(draft)
            }
            Section {
                deviceRows(draft)
                HStack {
                    TextField("他マシンで定義されたデバイス名を追加",
                              text: $newDeviceName)
                        .textFieldStyle(.roundedBorder)
                    Button("追加") {
                        let name = newDeviceName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty, !draft.wrappedValue.devices.contains(name) else { return }
                        draft.wrappedValue.devices.append(name)
                        newDeviceName = ""
                    }
                    .disabled(newDeviceName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("デバイス(マシン: \(machineNameForDevices ?? "未決定"))")
            } footer: {
                Text("チェックしたデバイスで並列実行します(並列数 = デバイス数)。iOS/Android を混在させると両OS同時実行になります。このマシンに定義のない名前は実行時にスキップされます(他マシンでは有効)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("オプション") {
                Toggle("FM によるロケータ自己修復(heal)", isOn: draft.heal)
                    .toggleStyle(.checkbox)
                HStack {
                    Text("レポート出力先")
                    TextField("reports", text: draft.reportDir)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Text("プロジェクトルート相対")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("既定タイムアウト(秒)")
                    TextField("既定(5)", text: draft.defaultTimeoutText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    if !draft.wrappedValue.timeoutIsValid {
                        Text("数値を入力してください(空欄 = 既定)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("exist / textIs 等の待ち時間。空欄 = 既定(5)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func appPicker(_ draft: Binding<RunDraft>) -> some View {
        let apps = (try? model.currentProject()).map(ProfileResolver.appProfileNames) ?? []
        HStack {
            Picker("アプリケーションプロファイル", selection: draft.app) {
                if draft.wrappedValue.app.isEmpty {
                    Text("未選択").tag("")
                }
                ForEach(apps, id: \.self) { name in
                    Text(name).tag(name)
                }
                if !draft.wrappedValue.app.isEmpty, !apps.contains(draft.wrappedValue.app) {
                    Text("⚠️ \(draft.wrappedValue.app)(apps/ に見つかりません)")
                        .tag(draft.wrappedValue.app)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)
            Text("apps/<名前>.json への参照")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func deviceRows(_ draft: Binding<RunDraft>) -> some View {
        // 現在マシンに定義されたデバイス(チェックで選択)
        ForEach(machineDevices) { device in
            Toggle(isOn: Binding(
                get: { draft.wrappedValue.devices.contains(device.name) },
                set: { include in
                    if include {
                        if !draft.wrappedValue.devices.contains(device.name) {
                            draft.wrappedValue.devices.append(device.name)
                        }
                    } else {
                        draft.wrappedValue.devices.removeAll { $0 == device.name }
                    }
                })) {
                HStack(spacing: 8) {
                    Text(device.name)
                    Text("\(device.platform) — \(device.detail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
        }
        // プロファイルに含まれるが、このマシンに定義のない名前
        let unknownNames = draft.wrappedValue.devices.filter { name in
            !machineDevices.contains { $0.name == name }
        }
        ForEach(unknownNames, id: \.self) { name in
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.orange)
                Text(name)
                Text("このマシンに定義なし(実行時スキップ)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer()
                Button {
                    draft.wrappedValue.devices.removeAll { $0 == name }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("この参照を外す")
            }
        }
        if machineDevices.isEmpty {
            Text("このマシンのマシンプロファイルにデバイス定義がありません"
                 + "(machines/\(machineNameForDevices ?? "<マシン名>").json を編集してください)")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - 読み込み・保存

    private func resetEditorState() {
        editorText = ""
        originalText = ""
        runDraft = nil
        originalDraft = nil
        rawMode = false
        newDeviceName = ""
        statusLines = []
    }

    private func reloadFiles() {
        guard let project = try? model.currentProject() else {
            files = []
            return
        }
        var found: [ProfileFile] = []
        for kind in ProfileFileKind.allCases {
            let dir = project.profilesDir.appendingPathComponent(kind.directoryName)
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            found += entries.filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { ProfileFile(kind: kind, url: $0.standardizedFileURL) }
        }
        files = found
        if selectedID != nil, !files.contains(where: { $0.id == selectedID }) {
            selectedID = nil
            resetEditorState()
        }
    }

    private func loadSelected() {
        resetEditorState()
        guard let file = selectedFile,
              let text = try? String(contentsOf: file.url, encoding: .utf8) else {
            return
        }
        editorText = text
        originalText = text
        if file.kind == .run {
            if let doc = try? JSONDecoder().decode(RunProfileDocument.self, from: Data(text.utf8)) {
                let draft = RunDraft(from: doc)
                runDraft = draft
                originalDraft = draft
                loadMachineDevices()
            } else {
                statusLines = ["⚠️ フォームで開けない内容のため JSON 編集モードで表示しています"]
            }
        }
    }

    /// 現在マシンのマシンプロファイルからデバイス一覧(フォームの選択肢)を読む
    private func loadMachineDevices() {
        machineDevices = []
        machineNameForDevices = nil
        guard let project = try? model.currentProject(),
              let machine = try? ProfileResolver.determineMachine(
                  project: project, registered: LocalConfig.currentMachineName()) else {
            return
        }
        machineNameForDevices = machine.name
        let url = project.machinesDir.appendingPathComponent("\(machine.name).json")
        guard let data = try? Data(contentsOf: url),
              let profile = try? JSONDecoder().decode(MachineProfile.self, from: data) else {
            return
        }
        var found: [MachineDevice] = []
        for (platform, list) in [("ios", profile.ios), ("android", profile.android)] {
            for spec in list?.devices ?? [] {
                let detail: String
                if platform == "ios" {
                    detail = [spec.simulator, spec.os, spec.udid.map { "udid=\($0)" }]
                        .compactMap { $0 }.joined(separator: " ")
                } else {
                    detail = spec.avd.map { "avd=\($0)" } ?? "-"
                }
                found.append(MachineDevice(name: spec.name, platform: platform,
                                           detail: detail.isEmpty ? "-" : detail))
            }
        }
        machineDevices = found
    }

    /// フォーム → JSON(キー順はテンプレートに合わせる)
    private func serialize(_ draft: RunDraft) -> String {
        var lines = ["{"]
        lines.append("  \"app\": \(jsonQuoted(draft.app)),")
        if draft.devices.isEmpty {
            lines.append("  \"devices\": [],")
        } else {
            lines.append("  \"devices\": [")
            lines.append(draft.devices
                .map { "    { \"name\": \(jsonQuoted($0)) }" }
                .joined(separator: ",\n"))
            lines.append("  ],")
        }
        lines.append("  \"heal\": \(draft.heal),")
        var reportLine = "  \"reportDir\": \(jsonQuoted(draft.reportDir.isEmpty ? "reports" : draft.reportDir))"
        if let timeout = Int(draft.defaultTimeoutText) {
            reportLine += ","
            lines.append(reportLine)
            lines.append("  \"defaultTimeout\": \(timeout)")
        } else {
            lines.append(reportLine)
        }
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    private func jsonQuoted(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode([value]),
              let text = String(data: data, encoding: .utf8) else {
            return "\"\(value)\""
        }
        return String(text.dropFirst().dropLast())
    }

    private func toggleRawMode() {
        guard !isDirty else { return }
        if rawMode {
            // JSON → フォーム(保存済みの内容を再パース)
            if let doc = try? JSONDecoder().decode(RunProfileDocument.self,
                                                   from: Data(editorText.utf8)) {
                let draft = RunDraft(from: doc)
                runDraft = draft
                originalDraft = draft
                loadMachineDevices()
                rawMode = false
            } else {
                statusLines = ["⚠️ JSON を解析できないためフォームに切り替えられません"]
            }
        } else {
            rawMode = true
        }
    }

    private func save() {
        guard let file = selectedFile else { return }
        if formMode, let draft = runDraft {
            guard draft.timeoutIsValid else { return }
            editorText = serialize(draft)
            originalDraft = draft
        }
        do {
            try editorText.write(to: file.url, atomically: true, encoding: .utf8)
            originalText = editorText
        } catch {
            statusLines = ["❌ 保存失敗: \(error.localizedDescription)"]
            return
        }
        statusLines = validate(file)
        // runs のファイル一覧・Picker を最新化(app/machine の変更も解決結果に効く)
        model.refreshRunProfiles()
        if file.kind == .machine {
            loadMachineDevices()
        }
    }

    /// 保存済みファイルを実行時と同じ基準で検証し、表示行を返す
    private func validate(_ file: ProfileFile) -> [String] {
        let (errors, warnings) = ProfileResolver.validate(
            kind: file.kind, data: Data(editorText.utf8), context: file.name)
        var lines = errors.map { "❌ \($0)" } + warnings.map { "⚠️ \($0)" }

        // 実行プロファイルは参照(app / デバイス name)も現在マシンで解決チェック
        if file.kind == .run, errors.isEmpty, let project = try? model.currentProject() {
            if let machine = try? ProfileResolver.determineMachine(
                project: project, registered: LocalConfig.currentMachineName()) {
                do {
                    let resolved = try ProfileResolver.resolve(
                        project: project, runName: file.name, machineName: machine.name)
                    lines += resolved.warnings.map { "⚠️ \($0)" }
                    let devices = resolved.devices
                        .map { "\($0.name)(\($0.platform))" }.joined(separator: ", ")
                    lines.append("✅ 解決OK(マシン \(machine.name)): \(resolved.appName) / \(devices)")
                } catch {
                    lines.append("❌ 参照チェック: \(error.localizedDescription)")
                }
            } else {
                lines.append("⚠️ マシン名が未決定のため参照チェックをスキップしました(設定タブで登録)")
            }
        }
        if lines.isEmpty { lines = ["✅ 保存しました(検証OK)"] }
        else { lines.insert("保存しました:", at: 0) }
        return lines
    }

    private func createProfile(kind: ProfileFileKind, name: String) {
        guard let project = try? model.currentProject() else { return }
        let dir = project.profilesDir.appendingPathComponent(kind.directoryName)
        let url = dir.appendingPathComponent("\(name).json")
        guard !FileManager.default.fileExists(atPath: url.path) else {
            statusLines = ["❌ 既に存在します: \(url.lastPathComponent)"]
            return
        }
        let template: String
        switch kind {
        case .app:
            template = ProjectScaffold.appProfileTemplate(appName: name, app: "com.example.myapp")
        case .machine:
            template = ProjectScaffold.machineProfileTemplate
        case .run:
            let firstApp = ProfileResolver.appProfileNames(project: project).first ?? "myapp"
            template = ProjectScaffold.runProfileTemplate(app: firstApp, deviceNames: ["メイン機"])
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try template.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            statusLines = ["❌ 作成失敗: \(error.localizedDescription)"]
            return
        }
        reloadFiles()
        selectedID = url.standardizedFileURL.path
        loadSelected()
        statusLines = ["✅ 作成しました: \(kind.directoryName)/\(name).json(編集して保存してください)"]
        model.refreshRunProfiles()
    }

    private func renameProfile(_ file: ProfileFile, to newName: String) {
        guard newName != file.name else { return }
        let newURL = file.url.deletingLastPathComponent()
            .appendingPathComponent("\(newName).json")
        guard !FileManager.default.fileExists(atPath: newURL.path) else {
            statusLines = ["❌ 既に存在します: \(newURL.lastPathComponent)"]
            return
        }
        do {
            try FileManager.default.moveItem(at: file.url, to: newURL)
        } catch {
            statusLines = ["❌ 名前の変更に失敗しました: \(error.localizedDescription)"]
            return
        }
        // 内容は不変なのでエディタ状態(未保存の編集含む)は保持したまま選択を追従させる。
        // reloadFiles() は「選択中ファイルが一覧から消えた」ときに状態をリセットするため、
        // 先に選択 ID を新パスへ切り替えてから一覧を再読込する
        if selectedID == file.id {
            selectedID = newURL.standardizedFileURL.path
        }
        reloadFiles()
        if file.kind == .run {
            // ツールバーの Picker 選択と LocalConfig(lastRunProfile)を追従
            if model.selectedRunProfile == file.name {
                model.selectedRunProfile = newName
            }
            model.refreshRunProfiles()
        }
        statusLines = ["✅ 名前を変更しました: \(file.name) → \(newName)"]
    }

    private func deleteProfile(_ file: ProfileFile) {
        do {
            try FileManager.default.removeItem(at: file.url)
        } catch {
            statusLines = ["❌ 削除失敗: \(error.localizedDescription)"]
            return
        }
        if selectedID == file.id {
            selectedID = nil
            resetEditorState()
        }
        reloadFiles()
        model.refreshRunProfiles()
    }
}

// MARK: - 名前変更シート

private struct RenameProfileSheet: View {
    let file: ProfilesView.ProfileFile
    let existingNames: [String]
    let onRename: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(file: ProfilesView.ProfileFile, existingNames: [String],
         onRename: @escaping (String) -> Void) {
        self.file = file
        self.existingNames = existingNames
        self.onRename = onRename
        _name = State(initialValue: file.name)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private var conflicts: Bool {
        trimmed != file.name && existingNames.contains(trimmed)
    }

    private var nameIsValid: Bool {
        !trimmed.isEmpty && trimmed != file.name && !conflicts
            && !trimmed.contains("/") && !trimmed.contains(":")
            && trimmed != "." && trimmed != ".."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(file.kind.label)プロファイルの名前を変更")
                .font(.headline)
            TextField("名前", text: $name)
                .textFieldStyle(.roundedBorder)
            if conflicts {
                Text("同名のプロファイルが既にあります")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("\(file.displayName) → profiles/\(file.kind.directoryName)/\(trimmed.isEmpty ? "…" : trimmed).json")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("変更") {
                    onRename(trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!nameIsValid)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - 新規作成シート

extension ProfileFileKind: Identifiable {
    public var id: String { rawValue }
}

private struct NewProfileSheet: View {
    let kind: ProfileFileKind
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var placeholder: String {
        switch kind {
        case .app: return "myapp"
        case .machine: return "M2 Ultra(192GB)"
        case .run: return "smoke"
        }
    }

    private var hint: String {
        switch kind {
        case .app:
            return "apps/<名前>.json を雛形から作成します(名前は runs の \"app\" で参照されます)"
        case .machine:
            return "machines/<マシン名>.json を雛形から作成します。ファイル名がマシン名になります"
        case .run:
            return "runs/<名前>.json を雛形から作成します(ツールバーの実行プロファイル Picker に並びます)"
        }
    }

    /// ファイル名として不正な文字(パス区切り等)を含まないか
    private var nameIsValid: Bool {
        !name.isEmpty && !name.contains("/") && !name.contains(":") && name != "." && name != ".."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新規\(kind.label)プロファイル")
                .font(.headline)
            TextField("名前", text: $name, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("作成") {
                    onCreate(name.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!nameIsValid)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
