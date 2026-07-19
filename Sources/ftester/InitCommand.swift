// ftester init: 受け手のパッケージを scaffold する(Tier 2)。
// カレントディレクトリに、ftester を SPM 依存として引く Package.swift(空マーカー区間つき)を書き、
// 直後に最初のテストプロジェクトを createAndRegister(external 自動判定で .product 参照スタンザ)する。
// 対向: Sources/FTCore/ProjectScaffold.externalManifest / PackageManifestEditor(external モード)。

import ArgumentParser
import Foundation
import FTCore

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "受け手のパッケージを作成する"
            + "(ftester を SPM 依存として引く Package.swift + 最初のテストプロジェクト)")

    @Option(help: "プロジェクト名(SPM ターゲット名。省略時: カレントディレクトリ名から生成)")
    var name: String?

    @Option(help: "対象アプリの bundle ID / パッケージ名")
    var app: String = "com.example.myapp"

    @Option(name: .customLong("ftester-path"),
            help: "ローカルの foundation-tester へのパス(.package(path:) で依存。PoC 向け)")
    var ftesterPath: String?

    @Option(name: .customLong("ftester-url"),
            help: "foundation-tester の git URL(.package(url:from:) で依存。--ftester-path と排他)")
    var ftesterURL: String?

    @Option(name: .customLong("ftester-version"),
            help: "git 依存時の最小バージョン(--ftester-url と併用。--ftester-branch 指定時は無視)")
    var ftesterVersion: String = "0.0.1"

    @Option(name: .customLong("ftester-branch"),
            help: "git 依存をタグではなくブランチで引く(--ftester-url と併用。タグ未発行時・検証用)")
    var ftesterBranch: String?

    func run() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let manifest = cwd.appendingPathComponent("Package.swift")
        guard !FileManager.default.fileExists(atPath: manifest.path) else {
            throw ValidationError("Package.swift が既に存在します: \(manifest.path)"
                + "(空のディレクトリで実行してください)")
        }

        let packageName = cwd.lastPathComponent
        let projectName = name ?? Self.sanitizedName(packageName)
        guard ProjectStore.isValidName(projectName) else {
            throw ValidationError("プロジェクト名が不正です: \(projectName)"
                + "(英数字・_・- のみ。--name で明示指定してください)")
        }

        let dependencyLine: String
        if let ftesterPath {
            let abs = URL(fileURLWithPath: ftesterPath, relativeTo: cwd).standardizedFileURL.path
            dependencyLine = #".package(path: "\#(abs)"),"#
        } else if let ftesterURL {
            dependencyLine = ftesterBranch.map {
                #".package(url: "\#(ftesterURL)", branch: "\#($0)"),"#
            } ?? #".package(url: "\#(ftesterURL)", from: "\#(ftesterVersion)"),"#
        } else {
            throw ValidationError("--ftester-path か --ftester-url のいずれかを指定してください")
        }

        try ProjectScaffold.externalManifest(packageName: packageName, dependencyLine: dependencyLine)
            .write(to: manifest, atomically: true, encoding: .utf8)

        do {
            let project = try ProjectScaffold.createAndRegister(
                name: projectName, app: app, repoRoot: cwd,
                machineName: LocalConfig.currentMachineName())
            print("✅ 受け手パッケージを作成しました: \(packageName)")
            print("   依存:         \(dependencyLine)")
            print("   プロジェクト: Projects/\(projectName)/(Scenarios/ に @TestClass の .swift を追加)")
            print("   アプリ設定:   Projects/\(projectName)/profiles/apps/ の appPath を自分のビルドへ")
            print("   ビルド:       swift build --product \(project.productName)")
            print("   実行:         ftester run --project \(projectName) --profile ios")
        } catch {
            // マニフェストだけ書いて scaffold に失敗したら、中途半端な Package.swift を残さない
            try? FileManager.default.removeItem(at: manifest)
            throw error
        }
    }

    /// ディレクトリ名を SPM ターゲット名(`^[A-Za-z0-9_][A-Za-z0-9_-]*$`)へ寄せる
    static func sanitizedName(_ raw: String) -> String {
        var s = String(raw.map { ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" })
        if let first = s.first, !(first.isLetter || first.isNumber || first == "_") {
            s = "_" + s
        }
        return s.isEmpty ? "App" : s
    }
}
