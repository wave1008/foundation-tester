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
                                         machineName: String? = nil) throws -> TestProject {
        guard ProjectStore.isValidName(name) else {
            throw ProjectStoreError.invalidName(name)
        }
        let project = TestProject(
            name: name,
            rootURL: ProjectStore.projectsDir(repoRoot: repoRoot).appendingPathComponent(name))
        guard !FileManager.default.fileExists(atPath: project.rootURL.path) else {
            throw ProjectScaffoldError.alreadyExists(project.rootURL)
        }
        try create(project: project, app: app, machineName: machineName)
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
                .macOS("27.0"),  // Foundation Models(ftester のランタイム要件)
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

    static func recipientSetupSkill(projectName name: String) -> String {
        let appRef = name.lowercased()
        return """
        ---
        name: ftester-setup
        description: この ftester テストパッケージのセットアップを仕上げて実行できる状態にする。環境検証(doctor)・この Mac のデバイス定義(マシンプロファイル)・対象アプリのパス設定・最初のシナリオ実行までを、検証ゲートと人間チェックポイント付きで行う。「セットアップして」「動かせるようにして」「テストを実行できるようにして」等の依頼で使う。
        ---

        # ftester セットアップ(このパッケージ)

        このパッケージは `ftester init` で作られた ftester テストプロジェクト。ftester は mint 導入済みが前提
        (未導入なら `mint install wave1008/foundation-tester@<version>` を実行し `~/.mint/bin` を PATH に入れる)。
        自分のアプリのシナリオを書いて実行できる状態まで仕上げる。

        ## 原則
        - 各ステップの後に検証ゲート(exit code / doctor)を通す。緑になるまで次へ進まない。
        - 人間チェックポイント(🧑)では**停止して依頼・確認する**(エージェントでは代行不可)。
        - 失敗は握りつぶさず、doctor 出力や stderr をそのままユーザーに見せて相談する。

        ## 手順

        ### 0. 🧑 前提の確認
        次を人間に確認する。未達なら停止して依頼(代行不可):
        - macOS 27+ / Apple Intelligence 有効(System 設定)/ Xcode 27+ 導入済み / iOS シミュレータ runtime を1つ以上
        - ビルド済みの対象アプリ(.app / .apk)のパス、使うシミュレータ名、マシン名

        ### 1. 環境検証
        `ftester doctor` を実行し、結果を要約して見せる。赤(未導入・無効)が残る項目は 0 に戻って対処を依頼。

        ### 2. マシンプロファイル(この Mac のデバイス定義)
        - `ftester machine set "<マシン名>"`(machines/ に .json が1つだけなら自動採用で省略可)
        - `xcrun simctl list devices available` で使えるシミュレータ名を採取
        - 🧑 `Projects/\(name)/profiles/machines/<マシン名>.json` に使うデバイスを列挙(雛形は同ディレクトリの README.md):

        ```json
        { "ios": { "devices": [ { "name": "メイン機", "simulator": "iPhone 17 Pro", "os": "27.0" } ] } }
        ```

        ### 3. 対象アプリのパス
        🧑 `Projects/\(name)/profiles/apps/\(appRef).json` を、あなたのビルド済みアプリへ向ける
        (`appName`/`autoInstall` は common、bundle ID(`app`)と `appPath` は ios/android セクション):

        ```json
        { "common": { "appName": "\(name)", "autoInstall": true },
          "ios":    { "app": "<bundle id>", "appPath": "~/builds/\(name).app" } }
        ```

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

        ### 6. 🧑 実機で実行
        対象シミュレータを起動してから:
        ```bash
        ftester run --project \(name) --profile ios
        ```

        ## 更新(新しい版が出たとき)
        `mint install wave1008/foundation-tester@<新version> --force` を実行し、Package.swift の依存
        (`.package(... from:)` の版)も同じ版へ上げてから `swift build`。CLI と依存の版は揃える。
        """
    }

    /// プロジェクト雛形を生成する(ディレクトリは存在しない前提。Package.swift の更新は呼び出し側)
    public static func create(project: TestProject, app: String,
                              machineName: String? = nil) throws {
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
        if let machineName {
            try machineProfileTemplate.write(
                to: project.machinesDir.appendingPathComponent("\(machineName).json"),
                atomically: true, encoding: .utf8)
        }
        try runProfileTemplate(app: appRef, deviceNames: ["メイン機"]).write(
            to: project.runsDir.appendingPathComponent("ios.json"),
            atomically: true, encoding: .utf8)
        try runProfileTemplate(app: appRef, deviceNames: ["エミュ1"]).write(
            to: project.runsDir.appendingPathComponent("android.json"),
            atomically: true, encoding: .utf8)
        try runProfileTemplate(app: appRef, deviceNames: ["メイン機", "エミュ1"]).write(
            to: project.runsDir.appendingPathComponent("all.json"),
            atomically: true, encoding: .utf8)
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

    ```json
    {
      "ios": {
        "devices": [
          { "name": "メイン機", "simulator": "iPhone 17 Pro", "os": "27.0" },
          { "name": "サブ機", "simulator": "iPhone Air", "udid": "XXXX-XXXX" }
        ]
      },
      "android": {
        "devices": [
          { "name": "エミュ1", "avd": "Pixel 9(Android 16)" },
          { "name": "エミュ2", "avd": "Pixel_8_Android_14" }
        ]
      }
    }
    ```
    """

    // common で有効なのは appName(表示名)のみ。app/appPath/autoInstall は廃止済みのため
    // platform(ios/android)セクションに書く(AppProfileSection.merging 参照)
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

    public static let machineProfileTemplate = """
    {
      "ios": {
        "devices": [
          { "name": "メイン機", "simulator": "iPhone 17 Pro", "os": "27.0" }
        ]
      },
      "android": {
        "devices": [
          { "name": "エミュ1", "avd": "Pixel_9" }
        ]
      }
    }
    """

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
