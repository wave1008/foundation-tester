// ContentView.swift
// メイン画面: サイドバー(フロー一覧)+ 3タブ(フロー実行 / ライブ操作 / FM探索)

import AppKit
import SwiftUI
import FTCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    // FT_TAB=3 などで初期タブを指定可(検証・デモ用)
    @State private var tab = Int(ProcessInfo.processInfo.environment["FT_TAB"] ?? "0") ?? 0
    @State private var showNewProjectSheet = false

    // シナリオのフォルダ操作(閉じているフォルダ・各アラートの入力)
    @State private var collapsedFolders: Set<String> = []
    // 閉じているテストクラス(既定は展開。クラス名はプロジェクト内で一意)
    @State private var collapsedClasses: Set<String> = []
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var folderToRename: String?
    @State private var renameFolderName = ""
    // ソースリネーム(class 宣言・@Test メソッド名・説明)のダイアログ状態
    @State private var classToRename: String?
    @State private var renameClassName = ""
    @State private var methodToRename: AppModel.ScenarioEntry?
    @State private var renameMethodName = ""
    @State private var titleToEdit: AppModel.ScenarioEntry?
    @State private var editTitleText = ""
    @State private var folderErrorMessage: String?
    @State private var rootDropTargeted = false
    @State private var bottomAreaTargeted = false
    // クラス行のダブルクリック(開閉トグル)検出用。行にタップジェスチャを付けると
    // .draggable のドラッグが開始されなくなる(2026-07-09 実測)ため、ジェスチャを
    // 使わず NSEvent のローカルモニタで検出する(1 クリック目のネイティブ選択を利用)
    @State private var doubleClickMonitor: Any?
    @State private var sidebarWindow: NSWindow?
    @State private var sidebarFrame: CGRect = .zero

    var body: some View {
        // NavigationSplitView はウィンドウリサイズ時に列を勝手に畳む・幅を戻す挙動を
        // 制御できない(2026-07-08 ユーザー報告)ため、RunView と同じ HSplitView で
        // 決定的にレイアウトする。シナリオペインは 240〜600pt でリサイズでき、消えない。
        // ウィンドウツールバー(.toolbar)はプレーンウィンドウではアイテムが収集されない
        // ため使わず、コントロールバーを通常のビューとして最上段に置く
        @Bindable var model = model
        return VStack(spacing: 0) {
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
        .sheet(isPresented: $model.healReviewPresented) {
            HealReviewSheet()
        }
        .task {
            await model.refreshScenarios()
            await model.refreshTargets()
            // 起動時に全実行(スモークテスト・デモ用): FT_AUTORUN=1 swift run ftester-gui
            if ProcessInfo.processInfo.environment["FT_AUTORUN"] == "1" {
                await model.runAll()
            }
            // 自己修復の確認シートの表示検証用: FT_HEAL_REVIEW_DEMO=1 swift run ftester-gui
            model.setupHealReviewDemoIfNeeded()
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
                hideDeletedRow
                // フォルダ(Scenarios/ のサブディレクトリ、1 階層のみ)→ 直下のシナリオ の順
                ForEach(model.scenarioFolders, id: \.self) { folder in
                    DisclosureGroup(isExpanded: folderExpansion(folder)) {
                        let groups = model.scenarioClassGroups(inFolder: folder)
                        if groups.isEmpty {
                            Text("シナリオをここへドラッグ")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(groups) { group in
                            scenarioClassGroup(group)
                        }
                    } label: {
                        ScenarioFolderLabel(
                            folder: folder,
                            count: model.scenarioEntries(inFolder: folder).count,
                            onFocus: {
                                model.selectedScenarioIDs = [AppModel.folderSelectionID(folder)]
                            },
                            onToggle: { folderExpansion(folder).wrappedValue.toggle() },
                            onRename: { beginRenameFolder(folder) },
                            onDelete: {
                                folderErrorMessage = model.deleteScenarioFolder(folder)
                            })
                    }
                    .tag(AppModel.folderSelectionID(folder))
                }
                ForEach(model.scenarioClassGroups(inFolder: nil)) { group in
                    scenarioClassGroup(group)
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
        // クラス行のダブルクリック検出(NSEvent モニタ)用: リストの領域と属するウィンドウ
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sidebarFrame = $0 }
        .background(HostWindowReader { sidebarWindow = $0 })
        // ステップ表と同じホバー行ハイライト(List も NSTableView バックエンドなので共用できる)
        .background(TableRowHoverHighlighter())
        .onAppear { installClassDoubleClickMonitor() }
        .onDisappear { removeClassDoubleClickMonitor() }
        // (再読込・全実行ボタンは controlBar にある。プレーンウィンドウでは
        //  List への .toolbar がウィンドウツールバーに収集されないため置かないこと)
        // 空きエリアの右クリック(items が空)= フォルダ追加。
        // シナリオ行の右クリックにはフォルダへの移動も出す(ドラッグの代替)。
        // フォルダ行はラベル上なら ScenarioFolderLabel 自身の contextMenu が優先されるが、
        // ラベル外(開閉 chevron・行の余白)はこちらに来るため、フォルダ操作をここにも出す
        .contextMenu(forSelectionType: URL.self) { items in
            let targets = model.scenarios.filter { items.contains($0.id) }
            let folders = items.compactMap(AppModel.folderName(fromSelectionID:))
            let classNames = items.compactMap(AppModel.className(fromSelectionID:))
            // クラス行(ラベル外を右クリックしたときも同じ操作を出す。フォルダ行と同じ理由)
            if targets.isEmpty, folders.isEmpty, classNames.count == 1,
               let className = classNames.first {
                let members = model.scenarios.filter { $0.className == className }
                Button("このクラスを実行") {
                    Task {
                        await model.runScenarios(members.filter { !$0.info.deleted })
                    }
                }
                .disabled(members.allSatisfy(\.info.deleted) || model.runningFlow)
                Divider()
                Button("クラス名を変更...") { beginRenameClass(className) }
                    .disabled(model.runningFlow)
                Divider()
            }
            if targets.isEmpty, folders.count == 1, let folder = folders.first {
                let count = model.scenarioEntries(inFolder: folder).count
                Button("このフォルダを実行") {
                    Task {
                        await model.runScenarios(
                            model.scenarioEntries(inFolder: folder).filter { !$0.info.deleted })
                    }
                }
                .disabled(count == 0 || model.runningFlow)
                Divider()
                Button("名前を変更...") { beginRenameFolder(folder) }
                Divider()
                Button("削除", role: .destructive) {
                    folderErrorMessage = model.deleteScenarioFolder(folder)
                }
                .disabled(count > 0)
                Divider()
            }
            if !targets.isEmpty {
                Button(targets.count == 1
                       ? "実行" : "選択した \(targets.count) 件を実行") {
                    Task { await model.runScenarios(targets) }
                }
                .disabled(model.runningFlow)
                Divider()
            }
            // 単一のテスト関数行: ソースの func 宣言と @Test の説明のリネーム
            if targets.count == 1, let target = targets.first {
                Button("関数名を変更...") { beginRenameMethod(target) }
                    .disabled(model.runningFlow)
                Button("説明を変更...") { beginEditTitle(target) }
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
        .alert("クラス名を変更", isPresented: Binding(
            get: { classToRename != nil },
            set: { if !$0 { classToRename = nil } })) {
            TextField("クラス名", text: $renameClassName)
            Button("変更") {
                guard let className = classToRename else { return }
                Task {
                    folderErrorMessage = await model.renameScenarioClass(
                        className, to: renameClassName)
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("ソースの class 宣言を書き換えます(ファイル名がクラス名と同じなら追従)。"
                 + "シナリオ ID が変わるため再ビルドして一覧を更新します")
        }
        .alert("関数名を変更", isPresented: Binding(
            get: { methodToRename != nil },
            set: { if !$0 { methodToRename = nil } })) {
            TextField("関数名", text: $renameMethodName)
            Button("変更") {
                guard let entry = methodToRename else { return }
                Task {
                    folderErrorMessage = await model.renameScenarioMethod(
                        entry, to: renameMethodName)
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("ソースの func 宣言を書き換えます。"
                 + "シナリオ ID が変わるため再ビルドして一覧を更新します")
        }
        .alert("説明を変更", isPresented: Binding(
            get: { titleToEdit != nil },
            set: { if !$0 { titleToEdit = nil } })) {
            TextField("説明", text: $editTitleText)
            Button("変更") {
                guard let entry = titleToEdit else { return }
                Task {
                    folderErrorMessage = await model.updateScenarioTitle(
                        entry, to: editTitleText)
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("@Test(\"説明\") の文字列を書き換えて再ビルドします(空にすると説明なし)")
        }
        .alert("操作を完了できません", isPresented: Binding(
            get: { folderErrorMessage != nil },
            set: { if !$0 { folderErrorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(folderErrorMessage ?? "")
        }
    }

    /// 「シナリオ」ラベル直下の表示オプション行(Shirates の @Deleted = 論理削除の表示切替)
    private var hideDeletedRow: some View {
        @Bindable var model = model
        let deletedCount = model.scenarios.filter { $0.info.deleted }.count
        return HStack(spacing: 4) {
            Toggle("削除済みを非表示にする", isOn: $model.hideDeleted)
                .toggleStyle(.checkbox)
                .font(.caption)
            if model.hideDeleted, deletedCount > 0 {
                Text("(\(deletedCount) 件)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .help("@Deleted を付与したシナリオ(削除済み)を一覧から隠します。"
              + "削除済みは表示中でも全実行・フォルダ実行から除外されます(選択しての実行は可能)")
    }

    /// テストクラス 1 つ分(クラス行+展開時はその下の階層にテスト関数の行)。
    /// DisclosureGroup の入れ子は初回挿入時に展開状態(binding = true)が反映されず
    /// 閉じて描画されることがある(2026-07-08 実測: 最初のクラスだけ閉じた)ため、
    /// クラスの開閉は自前の chevron+条件表示で決定的に描画する
    @ViewBuilder
    private func scenarioClassGroup(_ group: AppModel.ScenarioClassGroup) -> some View {
        let collapsed = collapsedClasses.contains(group.className)
        ScenarioClassLabel(
            group: group,
            collapsed: collapsed,
            onToggle: { toggleClass(group.className) },
            onRename: { beginRenameClass(group.className) })
        // .draggable はラベル内部ではなく行(.tag)の直下に置くこと。内側に置くと
        // 「選択中の行」をドラッグしたときにセッションが開始されない(2026-07-09 実測。
        // 関数行 scenarioRow と同じ構成 = draggable が最外周なら選択中でも動く)
        .draggable(group.entries.first?.info.id ?? group.className)
        .tag(AppModel.classSelectionID(group.className))
        if !collapsed {
            ForEach(group.entries) { entry in
                scenarioRow(entry)
                    .padding(.leading, 22)
            }
        }
    }

    /// テスト関数(@Test メソッド)1 行(選択タグ+フォルダ移動用のドラッグ元。
    /// ペイロードはシナリオ ID)。@Deleted(削除済み)は取り消し線+バッジ+淡色で示す
    private func scenarioRow(_ entry: AppModel.ScenarioEntry) -> some View {
        let deleted = entry.info.deleted
        return HStack(spacing: 8) {
            RunStateIcon(state: entry.state)
            Text(entry.methodName)
                .strikethrough(deleted)
                .lineLimit(1)
                .layoutPriority(1)  // タイトルが長くてもメソッド名は省略しない
            if deleted {
                DeletedBadge()
            }
            if !entry.info.title.isEmpty {
                Text(entry.info.title)
                    .strikethrough(deleted)
                    .lineLimit(1)
            }
        }
        .opacity(deleted ? 0.55 : 1)
        .draggable(entry.info.id)
        .tag(entry.id)
    }

    /// フォルダ名変更ダイアログを開く。アラートの TextField は表示トランザクション時点の
    /// 文字列を初期値として取り込むため、renameFolderName と folderToRename を同時に
    /// セットすると空のまま表示されることがある(2026-07-09 ユーザー報告)。
    /// 名前を先に確定し、表示トリガは次のランループで立てる
    private func beginRenameFolder(_ folder: String) {
        renameFolderName = folder
        DispatchQueue.main.async { folderToRename = folder }
    }

    /// クラス名変更ダイアログを開く(遅延理由は beginRenameFolder と同じ)
    private func beginRenameClass(_ className: String) {
        renameClassName = className
        DispatchQueue.main.async { classToRename = className }
    }

    /// 関数名変更ダイアログを開く
    private func beginRenameMethod(_ entry: AppModel.ScenarioEntry) {
        renameMethodName = entry.methodName
        DispatchQueue.main.async { methodToRename = entry }
    }

    /// 説明(@Test の文字列)変更ダイアログを開く
    private func beginEditTitle(_ entry: AppModel.ScenarioEntry) {
        editTitleText = entry.info.title
        DispatchQueue.main.async { titleToEdit = entry }
    }

    /// テストクラスの開閉を切り替える(既定は開。閉じたものだけ記録する)
    private func toggleClass(_ className: String) {
        if collapsedClasses.contains(className) {
            collapsedClasses.remove(className)
        } else {
            collapsedClasses.insert(className)
        }
    }

    /// クラス行のダブルクリック = 開閉トグル。行にタップジェスチャ
    /// (.onTapGesture / .simultaneousGesture(TapGesture) / contextMenu(primaryAction:)
    /// のいずれも)を付けると .draggable のドラッグセッションが開始されなくなる
    /// (2026-07-09 実測)ため、ジェスチャを使わず NSEvent のローカルモニタで
    /// ダブルクリックを検出する。1 クリック目で List のネイティブ選択が
    /// クラス行(擬似 URL)に入るので、2 クリック目はサイドバー内のダブルクリック
    /// かつ選択が単一クラス行のときにトグルする。イベントはそのまま流す
    /// (選択・ドラッグ・chevron ボタンに干渉しない)。
    /// フォルダ行は自前の TapGesture で開閉する(ドラッグ元でないため)ので対象外
    private func installClassDoubleClickMonitor() {
        guard doubleClickMonitor == nil else { return }
        // List 行上の mouseUp は NSTableView のトラッキングループに消費されて
        // ローカルモニタに届かない(2026-07-09 実測)ため、mouseDown 側で判定する
        doubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            guard event.clickCount == 2,
                  let window = sidebarWindow, event.window === window,
                  let contentView = window.contentView else { return event }
            // NSHostingView は flipped なので convert 結果は SwiftUI の .global 座標と一致
            let point = contentView.convert(event.locationInWindow, from: nil)
            guard sidebarFrame.contains(point),
                  model.selectedScenarioIDs.count == 1,
                  let selected = model.selectedScenarioIDs.first,
                  let className = AppModel.className(fromSelectionID: selected) else {
                return event
            }
            toggleClass(className)
            return event
        }
    }

    private func removeClassDoubleClickMonitor() {
        if let monitor = doubleClickMonitor {
            NSEvent.removeMonitor(monitor)
            doubleClickMonitor = nil
        }
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
            .disabled(model.runningFlow || model.scenarios.allSatisfy { $0.info.deleted })
            .help("全シナリオを稼働中デバイスへ振り分けて並列実行(削除済み @Deleted は除外)")

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

}

/// 実行状態のアイコン(テスト関数行の先頭に表示)
struct RunStateIcon: View {
    let state: AppModel.RunState

    var body: some View {
        switch state {
        case .idle:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .running:
            // 実行中は静止アイコンだと idle と見分けづらいので、スピナー風の
            // 可変カラーアニメーション(セグメントが順に点灯)で回転して見せる
            Image(systemName: "progress.indicator")
                .foregroundStyle(.green)
                .symbolEffect(.variableColor.iterative, options: .repeat(.continuous))
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

/// 「削除済み」カプセルバッジ(@Deleted の表示。クラス行・関数行で共用)
struct DeletedBadge: View {
    var body: some View {
        Text("削除済み")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.18), in: Capsule())
    }
}

/// ビューの属する NSWindow を捕捉する(NSEvent モニタのウィンドウ判定用)。
/// makeNSView 時点では window 未接続のことがあるため viewDidMoveToWindow で解決する
private struct HostWindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.onWindowChange = onResolve
        return view
    }

    func updateNSView(_ nsView: WindowProbeView, context: Context) {}

    final class WindowProbeView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            // ビュー更新中の状態変更を避けるため次のランループで通知する
            DispatchQueue.main.async { [weak self] in self?.onWindowChange?(window) }
        }
    }
}

/// テストクラスの行(配下のテスト関数の親。クリックで開閉、ドラッグ元+右クリックメニュー)。
/// クラスの移動 = クラスを定義する .swift の移動なのでドラッグはクラス行が主
/// (関数行のドラッグも同じファイル移動になる)。実行状態は関数行のみに出す
private struct ScenarioClassLabel: View {
    @Environment(AppModel.self) private var model
    let group: AppModel.ScenarioClassGroup
    let collapsed: Bool
    let onToggle: () -> Void
    let onRename: () -> Void

    /// 配下がすべて @Deleted(≒ クラスに @Deleted)なら行全体を削除済み表示にする
    private var allDeleted: Bool {
        group.entries.allSatisfy { $0.info.deleted }
    }

    var body: some View {
        HStack(spacing: 6) {
            // chevron はフォルダの開閉三角と同じくシングルクリックで開閉できるボタン
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            Image(systemName: "curlybraces")
                .foregroundStyle(.blue.gradient)  // フォルダアイコンと同じ青系統に揃える
                .frame(width: 20, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(group.className)
                        .strikethrough(allDeleted)
                        .lineLimit(1)
                    if allDeleted {
                        DeletedBadge()
                    }
                }
                Text(group.entries.first?.info.platform ?? "ios/android")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(group.entries.count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .opacity(allDeleted ? 0.55 : 1)
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        // クラス行はセクション見出しなので、ごく薄い明色バンドで配下の関数行と区別する
        // (.primary ベース = ダークでは白っぽく、ライトでは黒っぽく、どちらでも一段浮く)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        // クラス行はドラッグ元(フォルダへの移動)だが、.draggable は呼び出し側
        // (.tag の直下)に付ける。またタップジェスチャを行に付けると種類を問わず
        // (.onTapGesture / simultaneousGesture(TapGesture) / contextMenu(primaryAction:))
        // ドラッグセッションが開始されなくなる(2026-07-09 実測)ため、ここには置かない。
        // シングルクリック = フォーカスは List のネイティブ選択(.tag)、
        // ダブルクリック = 開閉トグルは NSEvent モニタ(installClassDoubleClickMonitor)が担う
        .contextMenu {
            Button("このクラスを実行") {
                // クラス実行も一括実行の一種: 削除済み(@Deleted)は除外する
                Task {
                    await model.runScenarios(group.entries.filter { !$0.info.deleted })
                }
            }
            .disabled(allDeleted || model.runningFlow)
            Divider()
            Button("クラス名を変更...") { onRename() }
                .disabled(model.runningFlow)
            if !model.scenarioFolders.isEmpty || group.entries.first?.folder != nil {
                Divider()
                Menu("フォルダへ移動") {
                    ForEach(model.scenarioFolders, id: \.self) { folder in
                        Button(folder) {
                            if let id = group.entries.first?.info.id {
                                model.moveScenario(id: id, toFolder: folder)
                            }
                        }
                    }
                    if group.entries.first?.folder != nil {
                        if !model.scenarioFolders.isEmpty {
                            Divider()
                        }
                        Button("Scenarios 直下へ戻す") {
                            if let id = group.entries.first?.info.id {
                                model.moveScenario(id: id, toFolder: nil)
                            }
                        }
                    }
                }
            }
        }
        .help("テストクラス(配下は @Test メソッド)。フォルダへドラッグで .swift ごと移動。"
              + "右クリックでクラス単位の実行・フォルダ移動")
    }
}

/// シナリオフォルダの行ラベル(ドロップ先+右クリックメニュー)。
/// ドロップ中はハイライトして受け入れ可能なことを示す
private struct ScenarioFolderLabel: View {
    @Environment(AppModel.self) private var model
    let folder: String
    let count: Int
    let onFocus: () -> Void
    let onToggle: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: targeted ? "folder.fill.badge.plus" : "folder.fill")
                .foregroundStyle(.green.gradient)
                .frame(width: 20, alignment: .leading)
            Text(folder)
                .lineLimit(1)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        // シングルクリック = フォーカス、ダブルクリック = 開閉トグル
        // (simultaneousGesture なのでダブルクリック時は 1 クリック目のフォーカスも効く)
        .onTapGesture { onFocus() }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onToggle() })
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
                // フォルダ実行も一括実行の一種: 削除済み(@Deleted)は除外する
                Task {
                    await model.runScenarios(
                        model.scenarioEntries(inFolder: folder).filter { !$0.info.deleted })
                }
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
                    if let entry = selected.first, selected.count == 1,
                       model.runningFlow, model.debugScenarioID == entry.info.id {
                        // デバッグ実行中(単一シナリオ): 一時停止・続行・ステップ・停止
                        debugControls
                    } else {
                        Toggle("自己修復(--heal)", isOn: $model.heal)
                            .toggleStyle(.checkbox)
                        if selected.count == 1 {
                            Button {
                                Task { await model.runSelectedStepwise() }
                            } label: {
                                Label("ステップ実行", systemImage: "arrow.right.to.line")
                            }
                            .help("最初のステップの手前で一時停止して開始します"
                                  + "(ブレークポイントはステップ表の行頭クリックで設定・解除)")
                            .disabled(model.runningFlow)
                        }
                        Button {
                            Task { await model.runSelected() }
                        } label: {
                            Label(selected.count == 1 ? "実行" : "選択した \(selected.count) 件を実行",
                                  systemImage: "play.fill")
                        }
                        .keyboardShortcut("r")
                        .help(selected.count == 1
                              ? "実行(ブレークポイントがあればその手前で一時停止します)" : "")
                        .disabled(model.runningFlow)
                    }
                }
                if let entry = selected.first, selected.count == 1 {
                    if entry.info.deleted {
                        Label("@Deleted(削除済み)— 全実行・フォルダ実行からは除外されます。"
                              + "ここからの実行は可能です",
                              systemImage: "trash")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if !entry.info.title.isEmpty {
                        Text(entry.info.title)
                            .font(.system(.body))
                            .foregroundStyle(.secondary)
                    }
                    ScenarioStepTable(entry: entry)
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

    /// デバッグ実行中の操作ボタン群。一時停止中は 続行 / ステップ / 停止、
    /// 実行中は 一時停止 / 停止(停止条件は paused イベントで反映される)
    @ViewBuilder private var debugControls: some View {
        if model.debugPaused {
            Text("⏸ ステップ \(model.debugPausedIndex ?? 0) の手前で停止中")
                .font(.caption)
                .foregroundStyle(.orange)
                .help(model.debugPausedDescription ?? "")
            Button {
                model.debugContinue()
            } label: {
                Label("続行", systemImage: "play.fill")
            }
            .help("次のブレークポイント(なければ最後)まで実行")
            Button {
                model.debugStepOver()
            } label: {
                Label("ステップ", systemImage: "arrow.right.to.line")
            }
            .help("1 ステップだけ実行して次のステップの手前で停止")
            Button {
                model.debugStop()
            } label: {
                Label("停止", systemImage: "stop.fill")
            }
            .help("シナリオを中断(残りのステップはスキップ)")
        } else {
            Text("▶ デバッグ実行中")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                model.debugPauseRequest()
            } label: {
                Label("一時停止", systemImage: "pause.fill")
            }
            .help("次のステップの手前で一時停止")
            Button {
                model.debugStop()
            } label: {
                Label("停止", systemImage: "stop.fill")
            }
            .help("シナリオを中断(残りのステップはスキップ)")
        }
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

/// 1 シナリオのステップ表(dry-run 列挙+ソースの行末コメント)。
/// 選択の切替と一覧再読込(世代更新)に .task(id:) で追従する
private struct ScenarioStepTable: View {
    @Environment(AppModel.self) private var model
    let entry: AppModel.ScenarioEntry
    @State private var result: AppModel.StepLoadResult?
    /// テーブルへのキーフォーカス要求カウンタ(TableFocusRequester が変化を検知して実行)
    @State private var focusRequest = 0
    /// セル編集・ペイン編集で出たエラー(表示表現の解釈・ビルド失敗)。編集ペイン内に表示
    @State private var editError: String?
    /// エラー表示を選択シナリオの切替でだけ消すための、最後に表示したシナリオ ID
    @State private var lastScenarioID: String?
    // 行選択と編集中の行は model(Observable)側に置く: Table のセルは親 View の
    // @State 変更では再描画されないことがあり、セルの表示切替が追従しない(実測)
    @FocusState private var commandEditorFocused: Bool

    /// ロードのトリガ: シナリオが変わるか、一覧が再読込されたら取り直す
    private struct LoadKey: Equatable {
        let scenarioID: String
        let generation: Int
    }

    var body: some View {
        Group {
            switch result {
            case nil:
                loadingLabel("ステップを取得中(dry-run)...")
            case .building:
                loadingLabel("シナリオ一覧を更新中...")
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text("⚠️ \(message)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    Spacer()
                    Text("ステップの内容は Projects/<プロジェクト>/Scenarios/ のソースと実行ログで確認できます")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            case .steps(let rows) where rows.isEmpty:
                VStack(alignment: .leading, spacing: 6) {
                    Text("ステップがありません(scenario { } にコマンドを追加してください)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            case .steps(let rows):
                StepEditPane(entry: entry, rows: rows, editError: $editError)
                stepTable(rows)
                Text("dry-run による列挙。行頭クリックでブレークポイント設定・解除。"
                     + "選択中の行のコマンドはもう一度クリックすると編集できます。"
                     + "procedure { } 内のステップは実行時のログで確認できます。"
                     + "行を選択すると上の編集ペインでパラメーターの確認・編集ができます")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .task(id: LoadKey(scenarioID: entry.info.id,
                          generation: model.scenarioListGeneration)) {
            result = nil  // 前のシナリオの表を残さない
            // id は行の通し番号(Int)にすぎず新シナリオでも再利用されるため、
            // 古いシナリオの選択が別の行を指したまま残らないようにリセットする
            model.stepTableSelection = nil
            model.stepEditingRow = nil
            // 編集エラーはシナリオを切り替えたときだけ消す(編集失敗後の世代更新の
            // 再読込で消えると、メッセージが読めないまま流れてしまう)
            if lastScenarioID != entry.info.id {
                lastScenarioID = entry.info.id
                editError = nil
            }
            let loaded = await model.loadSteps(for: entry)
            // 選択の高速切替で古いタスクの結果が新しい表を上書きしないように
            if !Task.isCancelled {
                result = loaded
                // 編集ペインの適用・行移動で再読込した後、選択していた行を復元する
                // (再読込直後は行番号が変わりうるため、存在確認してから選択する)
                if case .steps(let rows) = loaded, let pending = model.pendingStepReselection {
                    model.pendingStepReselection = nil
                    if pending.scenarioID == entry.info.id,
                       rows.contains(where: { $0.index == pending.index }) {
                        model.stepTableSelection = pending.index
                        focusRequest += 1
                    }
                }
            }
        }
        // フォーカスが外れたら確定(Finder のリネームと同じ。Esc は onExitCommand で
        // 先に stepEditingRow が nil になるため確定されない)
        .onChange(of: commandEditorFocused) { _, focused in
            if !focused { commitEdit() }
        }
    }

    /// 編集対象にできる行(単一選択・編集可能なコマンド・実行中でない)。nil = 編集不可
    private func editableRow(_ ids: Set<AppModel.ScenarioStepRow.ID>,
                             in rows: [AppModel.ScenarioStepRow])
        -> AppModel.ScenarioStepRow? {
        guard !model.runningFlow, ids.count == 1,
              let row = rows.first(where: { $0.id == ids.first }),
              AppModel.stepCommandEditable(row) else { return nil }
        return row
    }

    /// ソース位置のある行(単一選択)。ダブルクリック・「VSCode で開く」の対象判定
    private func sourceRow(_ ids: Set<AppModel.ScenarioStepRow.ID>,
                           in rows: [AppModel.ScenarioStepRow])
        -> AppModel.ScenarioStepRow? {
        guard ids.count == 1,
              let row = rows.first(where: { $0.id == ids.first }),
              row.file != nil else { return nil }
        return row
    }

    /// ステップのソース位置を VSCode で開く(失敗は表の下にエラー表示)
    private func openInVSCode(_ row: AppModel.ScenarioStepRow) {
        if let message = model.openStepSourceInVSCode(row) {
            editError = message
        }
    }

    /// コマンドセルのインライン編集を開始する(選択済み行のセルクリック・右クリックメニュー)
    private func beginEdit(_ row: AppModel.ScenarioStepRow) {
        editError = nil
        model.stepEditText = row.command
        model.stepTableSelection = row.id
        model.stepEditingRow = row
    }

    /// インライン編集の確定。変更があればソースへ反映(失敗は表の下にエラー表示)
    private func commitEdit() {
        guard let row = model.stepEditingRow else { return }
        model.stepEditingRow = nil
        let text = model.stepEditText
        guard text.trimmingCharacters(in: .whitespaces) != row.command else { return }
        Task {
            if let message = await model.updateStepCommand(row: row, display: text) {
                editError = message
            }
        }
    }

    private func stepTable(_ rows: [AppModel.ScenarioStepRow]) -> some View {
        // 列幅は内容の最大幅に合わせる(省略「…」を出さない)。
        // 表示幅を超えた分は横スクロール(常時バー+中ボタンパン)で見る
        let commandFont = NSFont.monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        let commentFont = NSFont.preferredFont(forTextStyle: .body)
        let commandWidth = Self.fittingWidth(rows.map(\.command), font: commandFont, atLeast: 160)
        let commentWidth = Self.fittingWidth(
            rows.compactMap { $0.comment ?? $0.generatedComment },
            font: commentFont, atLeast: 120)
        // selection を渡すことでクリックした行がハイライトされる(既定では選択が効かない)
        @Bindable var model = model
        return Table(rows, selection: $model.stepTableSelection) {
            TableColumn("") { row in
                breakpointCell(row)
            }
            .width(20)
            TableColumn("#") { row in
                Text("\(row.index)").monospacedDigit()
            }
            .width(28)
            TableColumn("scene") { row in
                Text(row.scene.map(String.init) ?? "")
                    .monospacedDigit()
                    .help(row.sceneTitle ?? "")
            }
            .width(44)
            TableColumn("区分") { row in
                Text(row.sectionLabel)
                    .foregroundStyle(.secondary)
            }
            .width(40)
            TableColumn("コマンド") { row in
                commandCell(row)
            }
            .width(min: 160, ideal: commandWidth)
            TableColumn("説明") { row in
                // ソースの行末コメントを優先、無い行は生成文で補完(淡色で区別)
                Text(row.comment ?? row.generatedComment ?? "")
                    .foregroundStyle(row.comment != nil ? AnyShapeStyle(.secondary)
                                                        : AnyShapeStyle(.tertiary))
                    .help(row.comment ?? row.generatedComment ?? "")
            }
            .width(min: 120, ideal: commentWidth)
        }
        // 右クリック=インライン編集(セルクリックと同じ)+ ソース位置を VSCode で開く
        .contextMenu(forSelectionType: AppModel.ScenarioStepRow.ID.self) { ids in
            if let row = editableRow(ids, in: rows) {
                Button("コマンドを編集") { beginEdit(row) }
            }
            if let row = sourceRow(ids, in: rows) {
                Button("Visual Studio Codeで開く") { openInVSCode(row) }
            }
        }
        // idealWidth を固定しないと長いコマンド/コメントが Table の理想幅
        // → ウィンドウの自動リサイズまで波及する(実測: 選択でウィンドウが画面幅まで拡大)
        .frame(minWidth: 280, idealWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        .background(LegacyScrollerEnforcer())
        .background(TableRowHoverHighlighter())
        .background(TableFocusRequester(request: focusRequest))
    }

    /// コマンド列のセル。選択済みの行はもう一度のクリックでその場で編集モードになる
    /// (Finder のリネームと同じ操作感)。編集は表示表現のまま行い、確定でソースへ反映する。
    /// タップジェスチャは選択済み行だけに付ける(未選択行に付けるとクリックを消費して
    /// NSTableView ネイティブの行選択が効かなくなる)
    @ViewBuilder
    private func commandCell(_ row: AppModel.ScenarioStepRow) -> some View {
        @Bindable var model = model
        if model.stepEditingRow?.id == row.id {
            TextField("", text: $model.stepEditText)
                .textFieldStyle(.plain)
                .font(.system(.callout, design: .monospaced))
                .padding(.horizontal, 2)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 3))
                .focused($commandEditorFocused)
                .onSubmit { commitEdit() }
                .onExitCommand { model.stepEditingRow = nil }  // Esc = 変更を破棄
                .onAppear { commandEditorFocused = true }
        } else if model.stepTableSelection == row.id, !model.runningFlow,
                  AppModel.stepCommandEditable(row) {
            commandLabel(row)
                .onTapGesture { beginEdit(row) }
        } else {
            commandLabel(row)
        }
    }

    private func commandLabel(_ row: AppModel.ScenarioStepRow) -> some View {
        Text(row.command)
            .font(.system(.callout, design: .monospaced))
            .help(row.command)
            // クリック領域をセル全体に広げる(テキストの右の余白でも編集に入れる)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    /// 行頭のブレークポイントセル。クリックで設定・解除(赤丸 = 設定済み)。
    /// デバッグ実行の一時停止中は「次に実行するステップ」に緑の矢印を重ねる
    private func breakpointCell(_ row: AppModel.ScenarioStepRow) -> some View {
        let isSet = model.hasBreakpoint(scenarioID: entry.info.id, row: row)
        let isCurrent = model.debugPaused && model.debugScenarioID == entry.info.id
            && model.debugPausedIndex == row.index
        return Button {
            model.toggleBreakpoint(scenarioID: entry.info.id, row: row)
            // Button がクリックを消費して NSTableView ネイティブの行選択まで
            // 届かないため、ブレークポイント操作でもここで行を選択状態にする。
            // さらにテーブルが一度もファーストレスポンダになっていないと選択の
            // プログラム設定が視覚的に反映されない(実測)ため、フォーカスも要求する
            model.stepTableSelection = row.id
            focusRequest += 1
        } label: {
            ZStack {
                Image(systemName: isSet ? "circle.fill" : "circle")
                    .font(.system(size: 10))
                    .foregroundStyle(isSet ? AnyShapeStyle(.red) : AnyShapeStyle(.quaternary))
                if isCurrent {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.green)
                }
            }
            // クリック領域をセル全体に広げる(丸だけだと当てにくい)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.breakpointKey == nil)
        .opacity(row.breakpointKey == nil ? 0 : 1)
        .help(isSet ? "クリックでブレークポイントを解除" : "クリックでブレークポイントを設定")
    }

    /// 文字列群を font で描いたときの最大幅(+セル内余白)。列の ideal 幅に使う
    private static func fittingWidth(_ strings: [String], font: NSFont, atLeast: CGFloat) -> CGFloat {
        let textWidth = strings
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return max(atLeast, ceil(textWidth) + 16)
    }

    private func loadingLabel(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

/// Table 内部の NSScrollView をレガシースクローラーに切り替えて
/// スクロールバーを常時表示にする(オーバーレイだとスクロール中しか出ず掴めない)。
/// あわせて中ボタンドラッグでのパンスクロール(掴んで動かす)も提供する。
/// .background に置くと Table の NSScrollView は兄弟側の階層にあるため、
/// 祖先を数段のぼりながら子孫から探す
private struct LegacyScrollerEnforcer: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        // SwiftUI の更新でスクロールビューが差し替わることがあるため毎回適用し直す
        DispatchQueue.main.async { nsView.applyToNearbyScrollView() }
    }

    final class ProbeView: NSView {
        private var styleObserver: NSObjectProtocol?
        private var retriesLeft = 0
        private var panMonitors: [Any] = []
        private weak var panScrollView: NSScrollView?
        private var panning = false
        private var panLastLocation: NSPoint = .zero

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                removePanMonitors()
                return
            }
            // 初回表示では Table の NSScrollView 生成がプローブの window 接続より
            // 遅れることがあるため、見つかるまで短い間隔でリトライする
            retriesLeft = 40  // 50ms × 40 = 最大 2 秒
            DispatchQueue.main.async { [weak self] in self?.applyToNearbyScrollView() }
            // システム設定変更(マウス接続など)で preferredScrollerStyle に戻されるため再適用する
            if styleObserver == nil {
                styleObserver = NotificationCenter.default.addObserver(
                    forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    self?.applyToNearbyScrollView()
                }
            }
            installPanMonitors()
        }

        override func layout() {
            super.layout()
            // レイアウトのたびに再適用(スクロールビュー差し替えへの保険。適用済みなら実質 no-op)
            applyToNearbyScrollView()
        }

        deinit {
            if let styleObserver { NotificationCenter.default.removeObserver(styleObserver) }
            removePanMonitors()
        }

        /// 中ボタン(buttonNumber == 2)ドラッグで Table をパンスクロールする。
        /// NSTableView は otherMouse 系を扱わないため、ローカルモニタで
        /// 表の上のイベントだけ拾って消費する(他のビューには影響しない)
        private func installPanMonitors() {
            guard panMonitors.isEmpty else { return }
            let down = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown]) { [weak self] event in
                guard let self, event.buttonNumber == 2, event.window === self.window,
                      let scrollView = self.findNearbyTableScrollView(),
                      scrollView.bounds.contains(scrollView.convert(event.locationInWindow, from: nil))
                else { return event }
                self.panScrollView = scrollView
                self.panning = true
                self.panLastLocation = event.locationInWindow
                NSCursor.closedHand.push()
                return nil
            }
            let dragged = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDragged]) { [weak self] event in
                guard let self, self.panning else { return event }
                let location = event.locationInWindow
                let dx = location.x - self.panLastLocation.x
                let dy = location.y - self.panLastLocation.y
                self.panLastLocation = location
                if let scrollView = self.panScrollView { self.pan(scrollView, dx: dx, dy: dy) }
                return nil
            }
            let up = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseUp]) { [weak self] event in
                guard let self, self.panning else { return event }
                self.panning = false
                self.panScrollView = nil
                NSCursor.pop()
                return nil
            }
            panMonitors = [down, dragged, up].compactMap { $0 }
        }

        private func removePanMonitors() {
            for monitor in panMonitors { NSEvent.removeMonitor(monitor) }
            panMonitors.removeAll()
        }

        /// ドラッグ量を「内容を掴んで動かす」向きのスクロールホイールイベントに変換して
        /// NSScrollView に通常スクロールとして処理させる。クリップビューの bounds を
        /// 直接動かすと浮動ヘッダと SwiftUI 側のスクロール位置追跡が同期しない
        /// (実測: 列だけ動いてヘッダが残る・コンテンツインセット分の縦ずれ)
        private func pan(_ scrollView: NSScrollView, dx: CGFloat, dy: CGFloat) {
            guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                        wheelCount: 2,
                                        wheel1: Int32(-dy), wheel2: Int32(dx), wheel3: 0),
                  let event = NSEvent(cgEvent: cgEvent) else { return }
            scrollView.scrollWheel(with: event)
        }

        func applyToNearbyScrollView() {
            // キャッシュせず毎回探し直す。Table 生成前に別ペインのスクロールビューを
            // 拾って固定してしまわないように、documentView が NSTableView(SwiftUI の
            // Table/List の実体)のものだけを対象にする(Table 生成後は level=1 で即ヒット)
            guard let scrollView = findNearbyTableScrollView() else {
                if retriesLeft > 0, window != nil {
                    retriesLeft -= 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.applyToNearbyScrollView()
                    }
                }
                return
            }
            // 同値でも代入すると再タイルが走るため変更時のみ設定する
            if scrollView.scrollerStyle != .legacy { scrollView.scrollerStyle = .legacy }
            if scrollView.autohidesScrollers { scrollView.autohidesScrollers = false }
            if !scrollView.hasHorizontalScroller { scrollView.hasHorizontalScroller = true }
            if !scrollView.hasVerticalScroller { scrollView.hasVerticalScroller = true }
        }

        private func findNearbyTableScrollView() -> NSScrollView? {
            var ancestor = superview
            for _ in 0..<4 {
                guard let root = ancestor else { return nil }
                if let found = Self.firstTableScrollView(in: root) { return found }
                ancestor = root.superview
            }
            return nil
        }

        private static func firstTableScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView, scrollView.documentView is NSTableView {
                return scrollView
            }
            for subview in view.subviews {
                if let found = firstTableScrollView(in: subview) { return found }
            }
            return nil
        }
    }
}

/// NSTableView バックエンドの Table/List のホバー行に薄い背景ハイライトを塗る
/// (ステップ表とシナリオペインのサイドバーで共用)。
/// SwiftUI の onHover + 親 View の @State では NSTableView バックエンドのセルが
/// state 変更で再描画されず影も背景色も反映されない(実測)。さらにセル側で
/// ヒット領域を広げるとクリックを SwiftUI が飲み込んで行選択まで壊れたため、
/// SwiftUI 側での表現は諦めて AppKit 層(NSTrackingArea +
/// NSTableRowView.backgroundColor)で直接塗る。
/// NSTableView の探索は LegacyScrollerEnforcer と同じ方式(.background に置き、
/// 祖先を数段のぼりながら子孫から documentView が NSTableView のものを探す)
private struct TableRowHoverHighlighter: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        // SwiftUI の更新でテーブルが差し替わることがあるため毎回適用し直す
        // (attach 側で適用済みなら no-op)
        DispatchQueue.main.async { nsView.attachToNearbyTableView() }
    }

    final class ProbeView: NSView {
        private var retriesLeft = 0
        private let helper = HoverHelper()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                // ウィンドウから外れたら tracking area と通知監視を残さない
                helper.detach()
                return
            }
            // 初回表示では Table の NSTableView 生成がプローブの window 接続より
            // 遅れることがあるため、見つかるまで短い間隔でリトライする
            retriesLeft = 40  // 50ms × 40 = 最大 2 秒
            DispatchQueue.main.async { [weak self] in self?.attachToNearbyTableView() }
        }

        override func layout() {
            super.layout()
            // レイアウトのたびに再適用(テーブル差し替えへの保険。適用済みなら no-op)
            attachToNearbyTableView()
        }

        deinit {
            helper.detach()
        }

        func attachToNearbyTableView() {
            guard let scrollView = findNearbyTableScrollView(),
                  let tableView = scrollView.documentView as? NSTableView else {
                if retriesLeft > 0, window != nil {
                    retriesLeft -= 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.attachToNearbyTableView()
                    }
                }
                return
            }
            helper.attach(to: tableView)
        }

        private func findNearbyTableScrollView() -> NSScrollView? {
            var ancestor = superview
            for _ in 0..<4 {
                guard let root = ancestor else { return nil }
                if let found = Self.firstTableScrollView(in: root) { return found }
                ancestor = root.superview
            }
            return nil
        }

        private static func firstTableScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView, scrollView.documentView is NSTableView {
                return scrollView
            }
            for subview in view.subviews {
                if let found = firstTableScrollView(in: subview) { return found }
            }
            return nil
        }
    }

    /// NSTrackingArea の owner としてマウス移動を受け、ホバー行の
    /// NSTableRowView.backgroundColor を塗り替えるヘルパー
    final class HoverHelper: NSResponder {
        private weak var tableView: NSTableView?
        private var trackingArea: NSTrackingArea?
        private var boundsObserver: NSObjectProtocol?
        private var hoveredRow = -1

        /// tracking area とスクロール監視を張る。同じテーブルに適用済みなら no-op
        /// (updateNSView / layout から繰り返し呼ばれるため、重複追加をここで防ぐ)
        func attach(to tableView: NSTableView) {
            if self.tableView === tableView, trackingArea != nil { return }
            detach()  // テーブルが差し替わった場合は古い方から確実に外す
            self.tableView = tableView
            // .inVisibleRect で rect 指定不要のまま可視領域全体を追跡する
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil)
            tableView.addTrackingArea(area)
            trackingArea = area
            // NSTableRowView は再利用されるため、ホバー中にスクロールすると
            // 別の行に色が残り得る。スクロール(クリップビューの bounds 変化)で
            // ハイライトを消して事故を防ぐ
            if let clipView = tableView.enclosingScrollView?.contentView {
                clipView.postsBoundsChangedNotifications = true
                boundsObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clipView, queue: .main
                ) { [weak self] _ in
                    self?.clearHighlight()
                }
            }
        }

        func detach() {
            clearHighlight()
            if let trackingArea, let tableView { tableView.removeTrackingArea(trackingArea) }
            trackingArea = nil
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            boundsObserver = nil
            tableView = nil
        }

        deinit {
            detach()
        }

        override func mouseMoved(with event: NSEvent) {
            guard let tableView else { return }
            let point = tableView.convert(event.locationInWindow, from: nil)
            let row = tableView.row(at: point)
            guard row != hoveredRow else { return }
            clearHighlight()
            guard row >= 0,
                  let rowView = tableView.rowView(atRow: row, makeIfNecessary: false),
                  // 選択中の行はシステムの選択ハイライトに任せる(重ねて濁らせない)
                  !rowView.isSelected,
                  // セクションヘッダ(サイドバーの「プロジェクト」「シナリオ」等)は
                  // アイテムではないので光らせない
                  !rowView.isGroupRowStyle,
                  // サイドバー最下段の透明な「余白」行(右クリック受け付け用、
                  // minHeight 240)を除外する。行の中身(SwiftUI ホスティングビュー)
                  // からは種別を判定できないため、通常行ではあり得ない高さ(100pt 超)
                  // をスペーサー行とみなすヒューリスティックで弾く
                  rowView.bounds.height <= 100
            else { return }
            // labelColor ベースなのでダークでは白系・ライトでは黒系の淡いハイライトになる
            rowView.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07)
            hoveredRow = row
        }

        override func mouseExited(with event: NSEvent) {
            clearHighlight()
        }

        private func clearHighlight() {
            guard hoveredRow >= 0 else { return }
            if let tableView,
               let rowView = tableView.rowView(atRow: hoveredRow, makeIfNecessary: false) {
                rowView.backgroundColor = .clear
            }
            hoveredRow = -1
        }
    }
}

/// 近傍の NSTableView(Table/List の実体)へキーフォーカスを移す(要求カウンタ方式)。
/// ステップ表のブレークポイント Button はクリックを消費するためテーブルにキー
/// フォーカスが移らず、テーブルが一度もファーストレスポンダになっていない状態では
/// selection バインディングをプログラムから設定しても選択の強調表示が視覚的に
/// 反映されない(実測)。そこで Button アクションで request を進めてもらい、
/// 変化を検知したときだけ makeFirstResponder でフォーカスを移す。
/// NSTableView の探索は TableRowHoverHighlighter と同じ方式(.background に置き、
/// 祖先を数段のぼりながら子孫から documentView が NSTableView のものを探す)
private struct TableFocusRequester: NSViewRepresentable {
    /// フォーカス要求カウンタ。呼び出し側がインクリメントするたびに 1 回だけ実行する
    let request: Int

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        // SwiftUI の更新サイクル中にレスポンダを動かさないよう次のループで実行する
        DispatchQueue.main.async { nsView.apply(request: request) }
    }

    final class ProbeView: NSView {
        /// 適用済みの request 値。初期値 0 と一致する間(=まだ要求されていない)は
        /// 何もしない(表示直後の update で勝手にフォーカスを奪わないため)
        private var appliedRequest = 0

        func apply(request: Int) {
            guard request != appliedRequest else { return }
            appliedRequest = request
            // ユーザーのクリック起点で呼ばれるのでテーブルは生成済みのはず。
            // 万一見つからなければ何もしない(リトライ不要)
            guard let scrollView = findNearbyTableScrollView(),
                  let tableView = scrollView.documentView as? NSTableView else { return }
            tableView.window?.makeFirstResponder(tableView)
        }

        private func findNearbyTableScrollView() -> NSScrollView? {
            var ancestor = superview
            for _ in 0..<4 {
                guard let root = ancestor else { return nil }
                if let found = Self.firstTableScrollView(in: root) { return found }
                ancestor = root.superview
            }
            return nil
        }

        private static func firstTableScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView, scrollView.documentView is NSTableView {
                return scrollView
            }
            for subview in view.subviews {
                if let found = firstTableScrollView(in: subview) { return found }
            }
            return nil
        }
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
