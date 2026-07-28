// ProjectScaffold.swift
// ftester project create のテストプロジェクト雛形生成。
// Scenarios/(_Main.swift・Generated/・_disabled/)、profiles/(apps/machines/runs)、reports/ を作る。

import Foundation

public enum ProjectScaffoldError: Error, LocalizedError {
    case alreadyExists(URL)

    public var errorDescription: String? {
        switch self {
        case .alreadyExists(let url):
            return "プロジェクトは既に存在します: \(url.path)"
        }
    }
}

public enum ProjectScaffold {

    /// 名前検証 → 雛形生成 → Package.swift マーカー区間更新までを一括で行う
    /// (ftester project create から使う)
    @discardableResult
    public static func createAndRegister(name: String, app: String, repoRoot: URL,
                                         platforms: [String] = ["ios", "android"]) throws -> TestProject {
        guard ProjectStore.isValidName(name) else {
            throw ProjectStoreError.invalidName(name)
        }
        let project = TestProject(
            name: name,
            rootURL: ProjectStore.projectsDir(repoRoot: repoRoot).appendingPathComponent(name))
        guard !FileManager.default.fileExists(atPath: project.rootURL.path) else {
            throw ProjectScaffoldError.alreadyExists(project.rootURL)
        }
        try create(project: project, app: app, platforms: platforms)
        try PackageManifestEditor.updateProjects(
            manifestURL: repoRoot.appendingPathComponent("Package.swift"),
            projectNames: ProjectStore.all(repoRoot: repoRoot).map(\.name),
            external: isExternalPackage(repoRoot: repoRoot))
        return project
    }

    /// 受け手のパッケージ(ftester を SPM 依存として引く)か、ftester 本体リポジトリかを判定する。
    /// 本体だけが Sources/FTScenarioRunner を持つ。project create/sync がマーカー区間を
    /// 内部ターゲット参照(本体)/ .product 参照(受け手)のどちらで生成するかの分岐に使う。
    public static func isExternalPackage(repoRoot: URL) -> Bool {
        !FileManager.default.fileExists(
            atPath: repoRoot.appendingPathComponent("Sources/FTScenarioRunner").path)
    }

    /// ftester init が生成する受け手の Package.swift。空のマーカー区間を持ち、直後に
    /// createAndRegister(external 自動判定)が最初のプロジェクトを登録する。
    /// dependencyLine は `.package(path: "...")` か `.package(url: "...", from: "...")`。
    public static func externalManifest(packageName: String, dependencyLine: String) -> String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let swift5Mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

        let package = Package(
            name: "\(packageName)",
            platforms: [
                // ftester 本体の Package.swift と一致させる(本体より低いと解決に失敗する)。
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

    /// 受け手のパッケージに Claude Code スキル `.claude/skills/ftester-setup/SKILL.md` を書く
    /// (ftester init から呼ぶ)。受け手が自分のプロジェクトを Claude Code で開いて `/ftester-setup`
    /// で残りのセットアップ(デバイス定義・アプリパス・実行)を駆動できるようにする。clone 構成の
    /// foundation-tester 同梱スキルは受け手のパッケージには届かないため、init で scaffold する。
    public static func writeRecipientSkill(packageRoot: URL, projectName: String) throws {
        let dir = packageRoot.appendingPathComponent(".claude/skills/ftester-setup")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try recipientSetupSkill(projectName: projectName).write(
            to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    /// 受け手のパッケージに `.claude/settings.json` を書く(ftester init から呼ぶ)。
    /// **ftester の CLI とスクリプトだけ**を許可リストに載せ、セットアップ〜実行のたびに
    /// Bash の承認を求められる状態を避ける(承認回数を減らしたいという受け手の要望。2026-07-29)。
    /// 既存の設定は温存し、重複しないエントリだけ足す(他ツールの許可を消さない)。
    /// 追加するのはこのツール由来のコマンドに限る — 汎用の `Bash(*)` は絶対に書かない。
    @discardableResult
    public static func writeClaudeSettings(packageRoot: URL, toolRoot: String?) throws -> [String] {
        let ftester = (toolRoot.map { "\($0)/.build/debug/ftester" }) ?? "ftester"
        var entries = [
            "Bash(\(ftester):*)",
            "Bash(xcrun simctl list:*)",
        ]
        if let toolRoot {
            entries.append("Bash(bash \(toolRoot)/Scripts/preflight.sh:*)")
            entries.append("Bash(bash \(toolRoot)/Scripts/install.sh:*)")
        }

        let dir = packageRoot.appendingPathComponent(".claude")
        let url = dir.appendingPathComponent("settings.json")
        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                FileHandle.standardError.write(Data(("⚠️ \(url.path) を JSON として解析できなかったため、"
                    + "Bash 許可リストの追記をスキップしました\n").utf8))
                return []
            }
            settings = parsed
        }
        var permissions = (settings["permissions"] as? [String: Any]) ?? [:]
        var allow = (permissions["allow"] as? [String]) ?? []
        let added = entries.filter { !allow.contains($0) }
        guard !added.isEmpty else { return [] }
        allow.append(contentsOf: added)
        permissions["allow"] = allow
        settings["permissions"] = permissions

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        return added
    }

    /// 受け手のパッケージに `.vscode/settings.json` を書く(ftester init から呼ぶ)。
    /// `ftester.project`/`ftester.binaryPath` を自動設定し、受け手の手動設定を不要にする。
    /// 既存ファイルが JSON としてパースできない(VSCode の settings.json は JSONC のことがある)場合は
    /// 触らず警告のみ出して false を返す(init 全体を失敗させない)
    public static func writeVSCodeSettings(
        packageRoot: URL, ftesterPath: String?, projectName: String
    ) throws -> Bool {
        let dir = packageRoot.appendingPathComponent(".vscode")
        let url = dir.appendingPathComponent("settings.json")

        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let warning = "⚠️ \(url.path) を JSON として解析できなかったため、"
                    + "ftester.project/ftester.binaryPath の自動設定をスキップしました(手動で設定してください)\n"
                FileHandle.standardError.write(Data(warning.utf8))
                return false
            }
            settings = parsed
        }

        settings["ftester.project"] = projectName
        if let ftesterPath {
            settings["ftester.binaryPath"] = "\(ftesterPath)/.build/debug/ftester"
        }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url)
        return true
    }

    /// 受け手のパッケージの .gitignore に SwiftPM ビルド成果物と実行レポートの ignore を冪等に足す
    /// (ftester init から呼ぶ)。無ければ作成、あれば欠けている行だけ追記。戻り値は追記した行(全部揃って
    /// いれば空 = 何も書かない)
    @discardableResult
    public static func ensureGitignore(packageRoot: URL) throws -> [String] {
        let entries = [".build/", "Projects/*/reports/"]
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
        content += "# ftester\n" + missing.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
        return missing
    }

    static func recipientSetupSkill(projectName name: String) -> String {
        let appRef = name.lowercased()
        return """
        ---
        name: ftester-setup
        description: この ftester テストパッケージのセットアップを仕上げて実行できる状態にする。環境検証(doctor)・この Mac のデバイス定義(マシンプロファイル)・デバイス不要の動作確認までを、検証ゲートと人間チェックポイント付きで行う。「セットアップして」「動かせるようにして」「テストを実行できるようにして」等の依頼で使う。
        ---

        # ftester セットアップ(このパッケージ)

        このパッケージは `ftester init` で作られた ftester テストプロジェクト。ftester CLI は foundation-tester
        を clone して `swift build` 済みであることが前提(未ビルドなら
        `git clone https://github.com/wave1008/foundation-tester.git ../foundation-tester` して
        `swift build`。clone 先は任意 — 既定はこのパッケージの**隣**で、パッケージの下にネストさせない)。
        TOOL_ROOT = Package.swift の `.package(path:)` が指す clone。以降 `ftester ...` は
        `<TOOL_ROOT>/.build/debug/ftester ...`(既定 `../foundation-tester/.build/debug/ftester ...`)を
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
        - Apple Intelligence: `ftester doctor --fm-only`(exit 0 で可。**exit 1 でも中断せず続行** —
          FM は heal・視覚検証・シナリオ生成にだけ必要な任意機能。使いたくなったら System 設定で
          有効化して本コマンドが ✅ になればそのまま使える。完了報告に要有効化の旨を残す)
          なお **macOS 26 では FM の視覚検証(occlusion-guard / screenIs)だけが使えない**
          (画像入力は macOS 27+)。他の機能は制限なく動く

        セットアップ値は 🧑 に冒頭の1回でまとめて質問する(以降のステップで再質問しない):
        - 使うシミュレータ名、マシン名
          → **これらは人間に聞く。他リポジトリを勝手に探索して埋めない**(バージョン・パスの推測は事故のもと)。

        **対象アプリ(.app / .apk)のパスは聞かない**(→ステップ3。後から設定できる)。

        ### 1. 環境検証
        `ftester doctor` を実行し、結果を要約して見せる。赤(未導入・無効)が残る項目は 0 に戻って対処を依頼。

        ### 2. マシンプロファイル(この Mac のデバイス定義)
        - `ftester machine set "<マシン名>"`(machines/ に .json が1つだけなら自動採用で省略可)
        - `xcrun simctl list devices available` で使えるシミュレータ名を採取
        - 🧑 `Projects/\(name)/profiles/machines/<マシン名>.json` に使うデバイスを列挙(雛形は同ディレクトリの README.md):

        ```json
        { "ios": { "devices": [ { "name": "simulator1", "simulator": "iPhone 17 Pro" } ] } }
        ```

        ### 3. 対象アプリのパス(appPath)は設定しない
        bundle ID がプレースホルダ(`com.example.myapp`)のままなら、実IDが判明した時点で
        `profiles/apps/\(appRef).json` の `app` を差し替える(アプリの起動(launch)に必須。
        それまでのビルド・dry-run はプレースホルダで完走できる)。
        `appPath` はセットアップでは**聞かない・書かない**(未設定なら `autoInstall` は無効のまま =
        インストール済みのアプリをそのまま使う)。自動インストールが必要になったら、後から
        `Projects/\(name)/profiles/apps/\(appRef).json` の `appPath` をビルド済みアプリへ向ける
        (`appName`/`autoInstall` は common、bundle ID(`app`)と `appPath` は ios/android セクション)。
        **ユーザーが自発的にパスを伝えてきた場合のみ書く。別リポジトリを覗いて確定値を書き込まない**:

        ```json
        { "common": { "appName": "\(name)", "autoInstall": true },
          "ios":    { "app": "<bundle id>", "appPath": "~/builds/\(name).app" } }
        ```
        `appPath` の相対パスはリポジトリルート基準(`builds/x.app` → `<repoRoot>/builds/x.app`)。`~`・絶対パスも可。

        ### 4. シナリオを1本用意
        - まず `Projects/\(name)/docs/testbases/` にテストの元資料(仕様・観点・元ネタ)を置き、
          それを根拠にシナリオを書く(何をなぜテストするかの拠り所。任意だが推奨)。
        - `Projects/\(name)/Scenarios/` に `@TestClass` の .swift を置く(`import FTDSL`)、
          または VSCode 拡張のライブ操作パネルで操作を録画して生成する。

        ### 5. デバイス不要の動作確認(まずここまで)
        ```bash
        swift build --product ftester-scenarios-\(name)
        ftester api list-scenarios --project \(name)
        ftester api run --project \(name) --scenario <クラス名> --dry-run --skip-build
        ```

        ### 5.5 git 管理(このパッケージを自分のリポジトリで管理する場合)
        `.gitignore` は init が整備済み(`.build/`・`Projects/*/reports/`)。コミットするのは
        Package.swift・Projects/(シナリオ・プロファイル)・.claude/・.gitignore。Package.resolved は
        コミット推奨(依存の版固定)。.vscode/settings.json は binaryPath が相対ならコミット可。
        .mcp.json は絶対パスを含むためマシン固有(コミットするならチームでパス規約を揃える)。

        ### 6. MCP サーバの登録(Claude Code から ft_* ツールを使う。任意)
        Claude Code がアプリを直接操作してシナリオを生成したいとき登録する(VSCode 拡張とは別の消費面)。
        このパッケージのルートに `.mcp.json` を書く(claude CLI 不要・ただの JSON)。`<CLONE_ABS>` は
        clone した foundation-tester の**絶対パス**(`cd <clone> && pwd` で得る)に置換。既存 `.mcp.json` が
        あれば `mcpServers.ftester` キーだけマージする:

        ```json
        {
          "mcpServers": {
            "ftester": {
              "command": "bash",
              "args": ["-lc", "WD=\\"$PWD\\"; cd \\"<CLONE_ABS>\\" && swift build --product ftester-mcp >/dev/null 2>&1 && cd \\"$WD\\" && exec \\"<CLONE_ABS>/.build/debug/ftester-mcp\\""]
            }
          }
        }
        ```

        rebuild-on-start なので clone を `git pull` しても版ズレしない。build 出力は `/dev/null`
        (JSON-RPC は stdout 専用)。Claude Code はプロジェクトスコープの MCP を初回に承認確認する
        → 許可すると `ft_*` ツールが使え、`/ftester-scenario` が MCP 経由で動く。
        **ビルドのため clone へ `cd` した後、`exec` 前に元のパッケージルートへ戻す**(cwd は
        `ftester-mcp` がパッケージルートを特定する入力。cd したままだと `Projects/` が見えなくなる)。

        ## 更新(新しい版が出たとき)
        clone した foundation-tester で `git pull`(または `git checkout <新version>`)して `swift build`
        し直し、Package.swift の依存(`.package(... from:)` の版)も同じ版へ上げる。CLI と依存の版は揃える。
        """
    }

    /// プロジェクト雛形を生成する(ディレクトリは存在しない前提。Package.swift の更新は呼び出し側)
    /// platforms は雛形を作る実行プロファイル(runs/<plat>.json)の対象。指示していない
    /// プラットフォームの run を残すとデバイス名の不整合として現れるので、必要なものだけ作る
    public static func create(project: TestProject, app: String,
                              platforms: [String] = ["ios", "android"]) throws {
        let fm = FileManager.default
        for dir in [project.generatedDir, project.disabledDir,
                    project.appsDir, project.machinesDir, project.runsDir,
                    project.reportsDir, project.testbasesDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        try mainSwift.write(to: project.scenariosDir.appendingPathComponent("_Main.swift"),
                            atomically: true, encoding: .utf8)
        try disabledReadme.write(
            to: project.disabledDir.appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8)
        try machinesReadme.write(
            to: project.machinesDir.appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8)
        try testbasesReadme.write(
            to: project.testbasesDir.appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8)

        let appRef = project.name.lowercased()
        try appProfileTemplate(appName: project.name, app: app).write(
            to: project.appsDir.appendingPathComponent("\(appRef).json"),
            atomically: true, encoding: .utf8)
        let deviceName = ["ios": "simulator1", "android": "emulator1"]
        for platform in platforms {
            guard let device = deviceName[platform] else { continue }
            try runProfileTemplate(app: appRef, deviceNames: [device]).write(
                to: project.runsDir.appendingPathComponent("\(platform).json"),
                atomically: true, encoding: .utf8)
        }
        // all は両プラットフォームを作ったときだけ(片方しか無い all は解決できない)
        if platforms.contains("ios"), platforms.contains("android") {
            try runProfileTemplate(app: appRef, deviceNames: ["simulator1", "emulator1"]).write(
                to: project.runsDir.appendingPathComponent("all.json"),
                atomically: true, encoding: .utf8)
        }
    }

    static let mainSwift = """
    // _Main.swift
    // ftester-scenarios のエントリポイント(編集不要)。
    // このディレクトリ(Scenarios/)に .swift を置いて swift build すればシナリオが認識される。

    import FTScenarioRunner

    @main
    struct ScenariosMain {
        static func main() async {
            await ScenarioRunnerMain.main()
        }
    }
    """

    static let disabledReadme = """
    # Scenarios/_disabled

    コンパイル対象外の退避場所(Package.swift の `exclude` 指定)。

    - 並列デモなど普段の「全実行」に含めたくないシナリオはここに置く(有効化は Scenarios/ 直下へ移動)
    - gen-scenario の生成コードがビルドに失敗した場合もここに隔離される
    """

    static let testbasesReadme = """
    # docs/testbases

    テスト設計の元になる資料(仕様・テスト観点・元ネタ)を置く場所。
    ここのドキュメントを根拠に Scenarios/ のシナリオを書く。
    """

    public static let machinesReadme = """
    # profiles/machines

    マシンプロファイル(ファイル名 = マシン名。例: `M1 Max(64GB).json`)。
    このマシンで使えるデバイスを ios / android セクションに `name` 付きで列挙する。
    実行プロファイル(runs/)はデバイスを `name` で参照するため、name は ios/android 横断で一意にすること。
    Android の `avd` は AVD の ID("Pixel_9_Android_16")と表示名("Pixel 9(Android 16)")の
    どちらでも書ける。

    実行時のマシン選択: FT_MACHINE 環境変数 > `ftester machine set` の登録名 >
    ここに .json が 1 つだけならそれを自動採用。

    iOS の `os`(例 `"26.0"`)は任意。**書かなければ名前一致の最新ランタイム**に解決されるので、
    複数ランタイムを使い分けるとき以外は省略する(このマシンに無い版を書くと解決不能になる)。

    ```json
    {
      "ios": {
        "devices": [
          { "name": "simulator1", "simulator": "iPhone 17 Pro" },
          { "name": "サブ機", "simulator": "iPhone Air", "udid": "XXXX-XXXX" }
        ]
      },
      "android": {
        "devices": [
          { "name": "emulator1", "avd": "Pixel 9(Android 16)" },
          { "name": "エミュ2", "avd": "Pixel_8_Android_14" }
        ]
      }
    }
    ```
    """

    // 置き場所は固定: appName/autoInstall は common、app(ID)/appPath は platform セクション
    // (AppProfileSection.merging 参照)
    public static func appProfileTemplate(appName: String, app: String) -> String {
        """
        {
          "common": {
            "appName": "\(appName)"
          },
          "ios": {
            "app": "\(app)"
          },
          "android": {
            "app": "\(app)"
          }
        }
        """
    }

    // os は書かない(名前一致の最新ランタイムに解決される)。版を固定するとホストの Xcode に
    // 無いランタイムを指して解決不能になる(macOS/Xcode の世代差で実際に起きる)

    public static func runProfileTemplate(app: String, deviceNames: [String]) -> String {
        let devices = deviceNames
            .map { #"    { "name": "\#($0)" }"# }
            .joined(separator: ",\n")
        return """
        {
          "app": "\(app)",
          "devices": [
        \(devices)
          ],
          "heal": false,
          "reportDir": "reports"
        }
        """
    }
}
