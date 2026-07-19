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

    /// プロジェクト雛形を生成する(ディレクトリは存在しない前提。Package.swift の更新は呼び出し側)
    public static func create(project: TestProject, app: String,
                              machineName: String? = nil) throws {
        let fm = FileManager.default
        for dir in [project.generatedDir, project.disabledDir,
                    project.appsDir, project.machinesDir, project.runsDir,
                    project.reportsDir] {
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
