// ProjectScaffold.swift
// fleetest project create のテストプロジェクト雛形生成。
// scenarios/(_Main.swift・Generated/・_disabled/)、profiles/(apps/runs)、reports/ を作る。

import Foundation

public enum ProjectScaffoldError: Error, LocalizedError {
    case alreadyExists(URL)

    public var errorDescription: String? {
        switch self {
        case .alreadyExists(let url):
            return "the project already exists: \(url.path)"
        }
    }
}

public enum ProjectScaffold {

    /// 名前検証 → 雛形生成 → Package.swift マーカー区間更新までを一括で行う
    /// (fleetest project create から使う)
    @discardableResult
    public static func createAndRegister(name: String, repoRoot: URL) throws -> TestProject {
        guard ProjectStore.isValidName(name) else {
            throw ProjectStoreError.invalidName(name)
        }
        let project = TestProject(
            name: name,
            rootURL: ProjectStore.projectsDir(repoRoot: repoRoot).appendingPathComponent(name))
        guard canScaffold(into: project.rootURL) else {
            throw ProjectScaffoldError.alreadyExists(project.rootURL)
        }
        try create(project: project)
        try PackageManifestEditor.updateProjects(
            manifestURL: repoRoot.appendingPathComponent("Package.swift"),
            projectNames: ProjectStore.all(repoRoot: repoRoot).map(\.name),
            external: isExternalPackage(repoRoot: repoRoot))
        return project
    }

    /// 雛形を置いてよい場所か。無い、または**空のディレクトリ**なら可(受け手や拡張が先に
    /// `mkdir` しただけの器を「既にある」で断らない)。中身が1つでもあれば不可 —— 上書きは
    /// 受け手の資産を消す側に倒れる。`.DS_Store` だけは中身に数えない
    public static func canScaffold(into rootURL: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            return true
        }
        guard isDirectory.boolValue,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: rootURL.path) else {
            return false
        }
        return entries.allSatisfy { $0 == ".DS_Store" }
    }

    /// 受け手のパッケージ(fleetest を SPM 依存として引く)か、fleetest 本体リポジトリかを判定する。
    /// 本体だけが Sources/FTScenarioRunner を持つ。project create/sync がマーカー区間を
    /// 内部ターゲット参照(本体)/ .product 参照(受け手)のどちらで生成するかの分岐に使う。
    public static func isExternalPackage(repoRoot: URL) -> Bool {
        !FileManager.default.fileExists(
            atPath: repoRoot.appendingPathComponent("Sources/FTScenarioRunner").path)
    }

    /// fleetest init が生成する受け手の Package.swift。空のマーカー区間を持ち、直後に
    /// createAndRegister(external 自動判定)が最初のプロジェクトを登録する。
    /// dependencyLine は `.package(path: "...")` か `.package(url: "...", branch: "...")`。
    public static func externalManifest(packageName: String, dependencyLine: String) -> String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        \(PackageManifestEditor.extraDependenciesDeclaration)let package = Package(
            name: "\(packageName)",
            platforms: [
                // fleetest 本体の Package.swift と一致させる(本体より低いと解決に失敗する)。
                // Foundation Models の視覚検証だけは macOS 27+ で有効になる
                .macOS("26.0"),
            ],
            dependencies: [
                \(dependencyLine)
            ],
            targets: [
                \(PackageManifestEditor.beginMarker)
                \(PackageManifestEditor.endMarker)
            ]
        )
        """
    }

    /// `fleetest init --no-project` が置く空の `TestProjects/`。VSCode 拡張はこのディレクトリが
    /// 無いと何も登録しない(あれば `project1` プロジェクトを自動作成する)ので、器だけは必ず作る。
    public static func ensureEmptyProjectsDirectory(repoRoot: URL) throws {
        try FileManager.default.createDirectory(
            at: ProjectStore.projectsDir(repoRoot: repoRoot), withIntermediateDirectories: true)
    }

    /// 受け手のパッケージにセットアップスキル `.claude/skills/fleetest-setup/SKILL.md` を書く
    /// (fleetest init から呼ぶ)。受け手が自分のプロジェクトをエージェントで開いて
    /// `/fleetest-setup` で残りのセットアップ(デバイス定義・アプリパス・実行)を駆動できる
    /// ようにする。clone 構成の foundation-tester 同梱スキルは受け手のパッケージには
    /// 届かないため、init で scaffold する。
    ///
    /// 置き場所は `AgentIntegration.skillsDirectory`。**シンボリックリンクにしない** ——
    /// 受け手のワークスペースは git に入ることがあり、リンクは配布経路(zip・アーカイブ)で壊れる。
    /// 戻り値は書いた相対パス。
    @discardableResult
    public static func writeRecipientSkill(
        packageRoot: URL, projectName: String?
    ) throws -> [String] {
        let body = projectName.map { recipientSetupSkill(projectName: $0) }
            ?? recipientSetupSkillWithoutProject()
        let relative = "\(AgentIntegration.skillsDirectory)/fleetest-setup"
        let dir = packageRoot.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try body.write(to: dir.appendingPathComponent("SKILL.md"),
                       atomically: true, encoding: .utf8)
        return ["\(relative)/SKILL.md"]
    }

    /// MCP サーバの登録名は install.sh が `.mcp.json` に書く `fleetest`(Claude Code のツール名の接頭辞)
    static let mcpToolsPermission = "mcp__fleetest"
    static let mcpStartRunPermission = "mcp__fleetest__ft_start_run"

    /// 受け手のパッケージに `.claude/settings.json` を書く(fleetest init から呼ぶ)。
    /// **fleetest の CLI とスクリプトだけ**を許可リストに載せ、セットアップ〜実行のたびに
    /// Bash の承認を求められる状態を避ける(承認回数を減らしたいという受け手の要望)。
    /// 既存の設定は温存し、重複しないエントリだけ足す(他ツールの許可を消さない)。
    /// 追加するのはこのツール由来のコマンドに限る — 汎用の `Bash(*)` は絶対に書かない
    /// (例外はクローンの Read の allow だけ。対になる Edit の deny と組で書く)。
    /// **MCP は fleetest のツールを丸ごと許可し、本番の実行 `ft_start_run` だけ ask に置く**(ask が allow に
    /// 勝つ = Claude Code で実測)。setup/teardown スクリプトと別の機械への送り出しはこのツールに
    /// しか無いので、人の確認を残す(Codex の推奨設定と同じ線引き。docs の MCP サーバ §サンドボックスと承認)。
    /// **ask は allow を初めて足すときだけ書く** —— 毎回補修すると、利用者が外した確認を更新のたびに戻す
    @discardableResult
    public static func writeClaudeSettings(packageRoot: URL, toolRoot: String?) throws -> [String] {
        let fleetest = (toolRoot.map { "\($0)/.build/debug/fleetest" }) ?? "fleetest"
        var entries = [
            "Bash(\(fleetest):*)",
            "Bash(xcrun simctl list:*)",
        ]
        if let toolRoot {
            // 更新系も載せる。**更新のたびに承認を求められると、更新1回で承認が数回に膨らむ**
            // (受け手実測で6回)。補修は install.sh が毎回 `api ensure-settings` で行う
            for script in ["preflight.sh", "install.sh", "update.sh", "update-check.sh"] {
                entries.append("Bash(bash \(toolRoot)/Scripts/\(script):*)")
            }
        }

        let dir = packageRoot.appendingPathComponent(".claude")
        let url = dir.appendingPathComponent("settings.json")
        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                ConsoleOut.err("⚠️ Could not parse \(url.path) as JSON — "
                    + "skipped appending the Bash permission list")
                return []
            }
            settings = parsed
        }
        var permissions = (settings["permissions"] as? [String: Any]) ?? [:]
        var allow = (permissions["allow"] as? [String]) ?? []
        let firstMCPGrant = !allow.contains(mcpToolsPermission)
        var added = (entries + [mcpToolsPermission]).filter { !allow.contains($0) }
        if firstMCPGrant {
            var ask = (permissions["ask"] as? [String]) ?? []
            if !ask.contains(mcpStartRunPermission) {
                ask.append(mcpStartRunPermission)
                added.append(mcpStartRunPermission)
            }
            permissions["ask"] = ask
        }
        // クローンを読み取り専用にする(maintainer-notes §2.5)。Read の allow = 外を初めて読むときの確認を省く・
        // Edit の deny = 編集ツールと Claude Code が認識する Bash のファイル操作を止める。
        // **クローン構成(作業フォルダがクローンの内側)では書かない**(自分の作業ツリーを読み取り専用にする)。
        // deny は Read の allow を初めて足すときだけ書く(ask と同じ: 利用者が外した deny を補修で戻さない)
        // マシン側の設定(`~/.config/fleetest/`)も同じ組で閉じる —— シナリオのサンドボックスを外す口
        // (`sandbox.disabled`)がそこにある(`ScenarioSandbox.MachineSettings`)
        if let rules = cloneReadOnlyRules(packageRoot: packageRoot, toolRoot: toolRoot),
           !allow.contains(rules.read) {
            added.append(rules.read)
            var deny = (permissions["deny"] as? [String]) ?? []
            for rule in [rules.edit, machineConfigEditDeny] where !deny.contains(rule) {
                deny.append(rule)
                added.append(rule)
            }
            permissions["deny"] = deny
        }
        guard !added.isEmpty else { return [] }
        let denied = Set((permissions["deny"] as? [String]) ?? [])
        allow.append(contentsOf: added.filter { $0 != mcpStartRunPermission && !denied.contains($0) })
        permissions["allow"] = allow
        settings["permissions"] = permissions

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        return added
    }

    /// マシン側の設定の編集を止める規則(`~/` は Claude Code のホーム相対の形)
    static let machineConfigEditDeny = "Edit(~/.config/fleetest/**)"

    /// クローンを読み取り専用にする規則の組。パスは Claude Code の `//` 始まり = 絶対パスの形
    /// (`/` 1つだと settings.json の置き場所からの相対になる)。toolRoot が無い・相対・作業フォルダを含むなら nil
    static func cloneReadOnlyRules(packageRoot: URL, toolRoot: String?) -> (read: String, edit: String)? {
        guard let toolRoot, toolRoot.hasPrefix("/") else { return nil }
        let clone = URL(fileURLWithPath: toolRoot).resolvingSymlinksInPath().standardizedFileURL.path
        let work = packageRoot.resolvingSymlinksInPath().standardizedFileURL.path
        if work == clone || work.hasPrefix(clone + "/") { return nil }
        let root = toolRoot.hasSuffix("/") ? String(toolRoot.dropLast()) : toolRoot
        return ("Read(/\(root)/**)", "Edit(/\(root)/**)")
    }

    /// 受け手のパッケージに `.vscode/settings.json` を書く(fleetest init から呼ぶ)。
    /// `fleetest.project`/`fleetest.binaryPath` を自動設定し、受け手の手動設定を不要にする。
    /// projectName が nil なら `fleetest.project` は書かない(拡張が単一/既定プロジェクトを自分で解決する。
    /// 既存の値も消さない)。
    /// 既存ファイルが JSON としてパースできない(VSCode の settings.json は JSONC のことがある)場合は
    /// 触らず警告のみ出して false を返す(init 全体を失敗させない)
    public static func writeVSCodeSettings(
        packageRoot: URL, fleetestPath: String?, projectName: String?
    ) throws -> Bool {
        let dir = packageRoot.appendingPathComponent(".vscode")
        let url = dir.appendingPathComponent("settings.json")

        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let warning = "⚠️ Could not parse \(url.path) as JSON — "
                    + "skipped the automatic fleetest.project/fleetest.binaryPath setup (set them by hand)"
                ConsoleOut.err(warning)
                return false
            }
            settings = parsed
        }

        if let projectName {
            settings["fleetest.project"] = projectName
        }
        if let fleetestPath {
            settings["fleetest.binaryPath"] = "\(fleetestPath)/.build/debug/fleetest"
        }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url)
        return true
    }

    /// 受け手のパッケージの .gitignore に SwiftPM ビルド成果物と実行レポートの ignore を冪等に足す
    /// (fleetest init から呼ぶ)。無ければ作成、あれば欠けている行だけ追記。戻り値は追記した行(全部揃って
    /// いれば空 = 何も書かない)
    @discardableResult
    public static func ensureGitignore(packageRoot: URL) throws -> [String] {
        let entries = [".build/", ".fleetest/", "TestProjects/*/reports/"]
        let url = packageRoot.appendingPathComponent(".gitignore")

        // 先頭の "/"・"./"、末尾の "/" を無視して同一視する(.build / /.build/ / .build/ はどれも同じ扱い)
        func normalize(_ line: String) -> String {
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("./") {
                s.removeFirst(2)
            } else if s.hasPrefix("/") {
                s.removeFirst()
            }
            if s.hasSuffix("/") {
                s.removeLast()
            }
            return s
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            try (entries.joined(separator: "\n") + "\n").write(
                to: url, atomically: true, encoding: .utf8)
            return entries
        }

        let existing = try String(contentsOf: url, encoding: .utf8)
        let existingNormalized = Set(existing.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
                return normalize(trimmed)
            })

        let missing = entries.filter { !existingNormalized.contains(normalize($0)) }
        guard !missing.isEmpty else { return [] }

        var content = existing
        if !content.hasSuffix("\n") {
            content += "\n"
        }
        content += "# fleetest\n" + missing.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
        return missing
    }

    static func recipientSetupSkill(projectName name: String) -> String {
        return """
        ---
        name: fleetest-setup
        description: この fleetest テストパッケージのセットアップを仕上げて実行できる状態にする。環境検証(doctor)・使うデバイスの定義(実行プロファイル)・デバイス不要の動作確認までを、検証ゲートと人間チェックポイント付きで行う。「セットアップして」「動かせるようにして」「テストを実行できるようにして」等の依頼で使う。
        ---

        # fleetest セットアップ(このパッケージ)

        このパッケージは `fleetest init` で作られた fleetest テストプロジェクト。fleetest CLI は foundation-tester
        を clone して `swift build` 済みであることが前提(未ビルドなら
        `git clone https://github.com/wave1008/foundation-tester.git ../foundation-tester` して
        `swift build`。clone 先は任意 — 既定はこのパッケージの**隣**で、パッケージの下にネストさせない)。
        TOOL_ROOT = Package.swift の `.package(path:)` が指す clone。以降 `fleetest ...` は
        `<TOOL_ROOT>/.build/debug/fleetest ...`(既定 `../foundation-tester/.build/debug/fleetest ...`)を
        指す(PATH 登録は不要)。
        自分のアプリのシナリオを書いて実行できる状態まで仕上げる。

        ## 原則
        - 各ステップの後に検証ゲート(exit code / doctor)を通す。緑になるまで次へ進まない。
        - 人間チェックポイント(🧑)では**停止して依頼・確認する**(エージェントでは代行不可)。
        - **Bundle ID・アプリの `.app`/`.apk` パス等のセットアップ値は、兄弟ディレクトリや別リポジトリを
          勝手に `find`/`grep` で探索して確定してはならない。値は人間から得る**(`appPath` のように
          **聞かない**値は、人間が自発的に示すまで未設定のままにする。探索で見つけた候補を
          既定値として提示するのも避ける)。
        - 失敗は握りつぶさず、doctor 出力や stderr をそのままユーザーに見せて相談する。

        ## 手順

        ### 0. 前提の機械判定と一括質問
        環境は機械判定する(人間に「入っているか」を聞かない)。失敗した項目だけ 🧑 停止して対処を依頼(代行不可):
        - macOS 26+: `sw_vers -productVersion` / Xcode 26+: `xcodebuild -version`(license 未同意エラーで
          落ちたら 🧑 に `sudo xcodebuild -license accept` を依頼)
        - Apple Intelligence: `fleetest doctor --fm-only`(exit 0 で可。**exit 1 でも中断せず続行** —
          FM は視覚検証・シナリオ生成にだけ必要な任意機能。使いたくなったら System 設定で
          有効化して本コマンドが ✅ になればそのまま使える。完了報告に要有効化の旨を残す)
          なお **macOS 26 では FM の視覚検証(occlusion-guard / screenLooksLike)だけが使えない**
          (画像入力は macOS 27+)。他の機能は制限なく動く

        **デバイスは聞かない**(ステップ2の `--auto-device` が選ぶ。使うデバイスを人間が自発的に指定したときだけ
        その名前を使う)。bundle ID が分からなければ 🧑 に冒頭の1回だけ聞く(他リポジトリを勝手に探索して埋めない)。

        **対象アプリ(.app / .apk)のパスは聞かない**(→ステップ3。後から設定できる)。

        ### 1. 環境検証
        `fleetest doctor` を実行し、結果を要約して見せる。赤(未導入・無効)が残る項目は 0 に戻って対処を依頼。

        ### 2. 実行プロファイルのデバイス
        - `fleetest profile setup --project \(name) --platform ios --app-id <bundle id> --auto-device` で
          使えるデバイスを選んで書く(Android は `--platform android`、両方は `hybrid`。手で書くときは下の形)
        - 🧑 `TestProjects/\(name)/profiles/runs/<名前>.json` の `devices` に列挙(書式は同ディレクトリの README.md):

        ```json
        { "devices": [ { "platform": "ios", "machine": "local", "name": "iPhone 17 Pro(iOS 27.0)-01", "osVersion": "iOS 27.0" } ] }
        ```

        ### 3. 対象アプリのパス(appPath)は設定しない
        bundle ID がプレースホルダ(`com.example.myapp`)のままなら、実IDが判明した時点で
        `profiles/apps/<対象 OS 名>-app.json` の `app` を差し替える(アプリの起動(launch)に必須。
        それまでのビルド・dry-run はプレースホルダで完走できる)。
        `appPath` はセットアップでは**聞かない・書かない**(未設定なら自動インストールは無効 =
        インストール済みのアプリをそのまま使う)。自動インストールが必要になったら、後から
        `TestProjects/\(name)/profiles/apps/<対象 OS 名>-app.json` の `appPath` をビルド済みアプリへ向ける
        (`appName`・bundle ID(`app`)・`appPath` は ios/android セクション、`autoInstall` は最上位キー)。
        **ユーザーが自発的にパスを伝えてきた場合のみ書く。別リポジトリを覗いて確定値を書き込まない**:

        ```json
        { "autoInstall": true,
          "ios":    { "appName": "\(name)", "app": "<bundle id>", "appPath": "~/builds/\(name).app" } }
        ```
        `appPath` の相対パスはリポジトリルート基準(`builds/x.app` → `<repoRoot>/builds/x.app`)。`~`・絶対パスも可。

        ### 4. シナリオを1本用意
        - まず `TestProjects/\(name)/docs/testbases/` にテストの元資料(仕様・観点・元ネタ)を置き、
          それを根拠にシナリオを書く(何をなぜテストするかの拠り所。任意だが推奨)。
        - `TestProjects/\(name)/scenarios/` に `@TestClass` の .swift を置く(`import FTDSL`)、
          または VSCode 拡張のライブ操作パネルで操作を録画して生成する。

        ### 5. デバイス不要の動作確認(まずここまで)
        ```bash
        swift build --product fleetest-scenarios-\(name)
        fleetest api list-scenarios --project \(name)
        fleetest api run --project \(name) --scenario <クラス名> --dry-run --skip-build
        ```

        ### 5.5 git 管理(このパッケージを自分のリポジトリで管理する場合)
        `.gitignore` は init が整備済み(`.build/`・`.fleetest/`・`TestProjects/*/reports/`)。コミットするのは
        Package.swift・TestProjects/(シナリオ・プロファイル)・.claude/・.gitignore。Package.resolved は
        コミット推奨(依存の版固定)。.vscode/settings.json は binaryPath が相対ならコミット可。
        .mcp.json は絶対パスを含むためマシン固有(コミットするならチームでパス規約を揃える)。

        ### 6. MCP サーバの登録(Claude Code から ft_* ツールを使う。任意)
        Claude Code がアプリを直接操作してシナリオを生成したいとき登録する(VSCode 拡張とは別の消費面)。
        このパッケージのルートに `.mcp.json` を書く(claude CLI 不要・ただの JSON)。`<CLONE_ABS>` は
        clone した foundation-tester の**絶対パス**(`cd <clone> && pwd` で得る)に置換。既存 `.mcp.json` が
        あれば `mcpServers.fleetest` キーだけマージする:

        ```json
        {
          "mcpServers": {
            "fleetest": {
              "command": "bash",
              "args": ["-c", "exec \\"<CLONE_ABS>/Scripts/mcp-server.sh\\""],
              "env": { "FT_TOOL_ROOT": "<CLONE_ABS>" }
            }
          }
        }
        ```

        ビルド・PATH の補正・ログの向き先は clone の `Scripts/mcp-server.sh` が持つ(ソースが実行ファイルより
        新しいときだけビルドし直す・stdout は JSON-RPC 専用・cwd は変えない)。**シェル式を直書きしない**・
        **`-l` を付けない**(ログインシェルの出力が JSON-RPC に混ざる)。Claude Code はプロジェクトスコープの
        MCP を初回に承認確認する → 許可すると `ft_*` ツールが使え、`/fleetest-scenario` が MCP 経由で動く。

        ## 更新(新しい版が出たとき)
        clone した foundation-tester で `git pull` して `swift build` し直す(配布口は main の1本。
        Package.swift の依存は clone のパスか main 追従なので、版を書き換える作業は無い)。
        """
    }

    /// `init --no-project` 用。プロジェクト名・アプリ参照を焼き込まない(プロジェクトは
    /// `/fleetest-profiles` が `project1` で作る)。
    static func recipientSetupSkillWithoutProject() -> String {
        return """
        ---
        name: fleetest-setup
        description: この fleetest テストパッケージのセットアップを仕上げて実行できる状態にする。環境検証(doctor)・テストプロジェクトと実行プロファイルの作成(/fleetest-profiles)・デバイス不要の動作確認までを、検証ゲートと人間チェックポイント付きで行う。「セットアップして」「動かせるようにして」「テストを実行できるようにして」等の依頼で使う。
        ---

        # fleetest セットアップ(このパッケージ)

        このパッケージは `fleetest init --no-project` で作られた fleetest テストパッケージ。**テストプロジェクトはまだ無い**
        (`TestProjects/` は空)。fleetest CLI は foundation-tester を clone して `swift build` 済みであることが前提
        (未ビルドなら `git clone https://github.com/wave1008/foundation-tester.git ../foundation-tester` して
        `swift build`。clone 先は任意 — 既定はこのパッケージの**隣**で、パッケージの下にネストさせない)。
        TOOL_ROOT = Package.swift の `.package(path:)` が指す clone。以降 `fleetest ...` は
        `<TOOL_ROOT>/.build/debug/fleetest ...`(既定 `../foundation-tester/.build/debug/fleetest ...`)を
        指す(PATH 登録は不要)。

        ## 原則
        - 各ステップの後に検証ゲート(exit code / doctor)を通す。緑になるまで次へ進まない。
        - 人間チェックポイント(🧑)では**停止して依頼・確認する**(エージェントでは代行不可)。
        - **Bundle ID・アプリの `.app`/`.apk` パス等のセットアップ値は、兄弟ディレクトリや別リポジトリを
          勝手に `find`/`grep` で探索して確定してはならない。値は人間から得る**(`appPath` は聞かない)。
        - 失敗は握りつぶさず、doctor 出力や stderr をそのままユーザーに見せて相談する。

        ## 手順

        ### 0. 前提の機械判定
        環境は機械判定する(人間に「入っているか」を聞かない)。失敗した項目だけ 🧑 停止して対処を依頼(代行不可):
        - macOS 26+: `sw_vers -productVersion` / Xcode 26+: `xcodebuild -version`(license 未同意エラーで
          落ちたら 🧑 に `sudo xcodebuild -license accept` を依頼)
        - Apple Intelligence: `fleetest doctor --fm-only`(exit 0 で可。**exit 1 でも中断せず続行** —
          FM は視覚検証・シナリオ生成にだけ必要な任意機能。完了報告に要有効化の旨を残す)

        ### 1. 環境検証
        `fleetest doctor` を実行し、結果を要約して見せる。赤(未導入・無効)が残る項目は 0 に戻って対処を依頼。

        ### 2. テストプロジェクトと実行プロファイルを作る
        `/fleetest-profiles` を実行する。`TestProjects/` にプロジェクトが無ければ、名前 `project1` で作ったうえで
        アプリプロファイルと実行プロファイル(デバイス)まで作る(名前は聞かない)。

        ### 3. シナリオを1本用意
        - `TestProjects/project1/docs/testbases/` にテストの元資料(仕様・観点)を置き、それを根拠にシナリオを書く(任意だが推奨)。
        - `/fleetest-scenario` で書く、または `TestProjects/project1/scenarios/` に `@TestClass` の .swift を置く(`import FTDSL`)。

        ### 4. デバイス不要の動作確認
        ```bash
        swift build --product fleetest-scenarios-project1
        fleetest api list-scenarios --project project1
        fleetest api run --project project1 --scenario <クラス名> --dry-run --skip-build
        ```

        ## 更新(新しい版が出たとき)
        clone した foundation-tester で `git pull` して `swift build` し直す(配布口は main の1本)。
        """
    }

    /// プロジェクト雛形を生成する(ディレクトリは存在しない前提。Package.swift の更新は呼び出し側)
    /// **apps/・runs/ にプロファイル JSON は書かない**(中身の無い雛形は最初の `profile list` を赤くする。
    /// 実体は /fleetest-profiles = `profile setup` が作る)。シナリオは置かない(_Main.swift だけ)
    public static func create(project: TestProject) throws {
        let fm = FileManager.default
        for dir in [project.generatedDir, project.disabledDir,
                    project.appsDir, project.runsDir,
                    project.reportsDir, project.testbasesDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // 既定ワークスペースの規約フォルダ(apps/scripts/data)も導入時から置く。
        // run 時の ensure だけに任せると、初回実行まで scripts/(setup.sh の置き場所)が
        // 見えず、受け手がどこに置けばよいか分からない
        try WorkspaceScaffold.ensureDefault(projectRoot: project.rootURL)

        try mainSwift.write(to: project.scenariosDir.appendingPathComponent("_Main.swift"),
                            atomically: true, encoding: .utf8)
        try disabledReadme.write(
            to: project.disabledDir.appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8)
        try runsReadme.write(
            to: project.runsDir.appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8)
        try testbasesReadme.write(
            to: project.testbasesDir.appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8)
    }

    static let mainSwift = """
    // _Main.swift
    // fleetest-scenarios のエントリポイント(編集不要)。
    // このディレクトリ(scenarios/)に .swift を置いて swift build すればシナリオが認識される。

    import FTScenarioRunner

    @main
    struct ScenariosMain {
        static func main() async {
            await ScenarioRunnerMain.main()
        }
    }
    """

    static let disabledReadme = """
    # scenarios/_disabled

    コンパイル対象外の退避場所(Package.swift の `exclude` 指定)。

    - 並列デモなど普段の「全実行」に含めたくないシナリオはここに置く(有効化は scenarios/ 直下へ移動)
    - gen-scenario の生成コードがビルドに失敗した場合もここに隔離される
    """

    static let testbasesReadme = """
    # docs/testbases

    テスト設計の元になる資料(仕様・テスト観点・元ネタ)を置く場所。
    ここのドキュメントを根拠に scenarios/ のシナリオを書く。
    """

    public static let runsReadme = """
    # profiles/runs

    実行プロファイル(ファイル名 = プロファイル名)。使うアプリ(`app` = apps/ のファイル名)と、
    走らせるデバイスの実体(`devices`)と、実行時の設定を持つ。
    **ここに置く実行プロファイルは `/fleetest-profiles`(`fleetest profile setup`)が作る**(雛形は作らない)。

    `devices` の1要素:
    - `platform`(必須): `"ios"` / `"android"`
    - `machine`: **そのデバイスがある機械**(ホスト名ではなく `fleetest remote machines` の
      マシン名 = このマシンだけのエイリアス)。手元は `"local"`(ツールは常に明示して書く)。
      書けるのはマシン名だけ(ssh の宛先は書けない)
    - `name`(必須): デバイスの名前。**一意なのは (machine, name)** なので、別の機械に同名の
      デバイスが居てよく、1つの実行プロファイルで手元とリモートを同時に回せる
    - `enabled`: `false` なら一覧に残すが走らせない(拡張のチェックボックス)。省略 = 走らせる
    - 実体: iOS シミュレータは `name` をシミュレータ自身の名前(Xcode の Name)にし、`osVersion`(OS Version)・
      `udid`・`model`(Model。表示専用)を書く。Android は `avd` / 実機なら `kind: "physical"` と `serial`

    **同じデバイスは複数の実行プロファイルに載る**。拡張で名前などを直すと、同じ
    (platform, machine, name) を持つ全ての実行プロファイルへ反映される。手で直すときは全部を揃える。
    Android の `avd` は AVD の ID("Pixel_9_Android_16")と表示名("Pixel 9(Android 16)")の
    どちらでも書ける。iOS の `osVersion`(例 `"iOS 27.0"`)は任意で、**書かなければ名前一致の最新ランタイム**に
    解決される(このマシンに無い版を書くと解決不能になる)。

    ```json
    {
      "app": "myapp",
      "devices": [
        { "platform": "ios", "machine": "local", "name": "iPhone 17 Pro(iOS 27.0)-01", "osVersion": "iOS 27.0", "model": "iPhone 17 Pro" },
        { "platform": "android", "machine": "local", "name": "Pixel 9(Android 16, API 36, APIs)-01", "avd": "Pixel_9_Android_16_API_36_APIs_-01" },
        { "platform": "android", "machine": "local", "name": "Pixel 8(Android 14, API 34, APIs)-01", "enabled": false, "avd": "Pixel_8_Android_14_API_34_APIs_-01" }
      ],
      "heal": true
    }
    ```
    """
}
