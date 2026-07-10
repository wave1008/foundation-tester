// ApiValidateProfileCommand.swift
// VSCode拡張向け: プロファイルJSON(profiles/apps・machines・runs)を検証し、結果をJSONで
// stdoutに出力する(ftester api validate-profile)。
// 検証は GUI の保存時チェック(ftester-gui/ProfilesView.swift の validate(_:))と同じ基準:
// ProfileResolver.validate(kind:data:context:) に加え、runs は現在マシンでの参照解決チェック
// (ProfileResolver.resolve)も行う。検証エラーがあっても結果は JSON で運ぶため exit 0。
// ファイル I/O 等の運用エラーのみ非 0(診断は stderr のみ。ApiCommands.swift と同じ流儀)。

import ArgumentParser
import Foundation
import FTCore

struct ApiValidateProfile: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate-profile",
        abstract: "プロファイルJSON(apps/machines/runs)を検証し、結果をJSONでstdoutに出力する"
            + "(検証エラーがあってもexit 0。ファイルI/O等の運用エラーのみ非0。診断はstderrのみ)")

    @Option(help: "テストプロジェクト名(省略時: Projects/ が 1 つならそれ / 既定プロジェクト)")
    var project: String?

    @Option(help: "絞り込む種別: apps / machines / runs(省略時は全種別)")
    var kind: String?

    @Option(help: "絞り込むプロファイル名(拡張子なし。--kind 省略時は全種別から同名を探す)")
    var name: String?

    func run() async throws {
        let testProject = try ScenarioHost.project(named: project)

        let kinds: [ProfileFileKind]
        if let kind {
            guard let matched = ProfileFileKind.allCases.first(where: { $0.directoryName == kind })
            else {
                throw ValidationError("--kind は apps/machines/runs のいずれかを指定してください: \(kind)")
            }
            kinds = [matched]
        } else {
            kinds = ProfileFileKind.allCases
        }

        // runs の参照解決チェックに使う現在マシン名(未決定でも致命的エラーにはしない。
        // 該当ファイルの warnings にその旨を積むだけ)
        var machineName: String?
        do {
            machineName = try ProfileResolver.determineMachine(
                project: testProject, registered: LocalConfig.currentMachineName()).name
        } catch {
            logStderr("⚠️ マシン名を決定できません(runs の参照解決チェックをスキップします): "
                + error.localizedDescription)
        }

        var results: [ApiValidateProfileResult] = []
        for fileKind in kinds {
            let dir = testProject.profilesDir.appendingPathComponent(fileKind.directoryName)
            for file in Self.jsonFiles(in: dir) {
                let fileName = file.deletingPathExtension().lastPathComponent
                if let name, fileName != name { continue }
                results.append(Self.validate(
                    file: file, fileName: fileName, kind: fileKind,
                    project: testProject, machineName: machineName))
            }
        }

        if results.isEmpty {
            logStderr("⚠️ 検証対象のプロファイルが見つかりませんでした"
                + "(--kind/--name の指定を確認してください)")
        }

        let output = ApiValidateProfileOutput(
            project: testProject.name, machine: machineName, results: results)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output)
        print(String(data: data, encoding: .utf8)!)
    }

    /// 1 ファイル分の検証(ProfilesView.validate(_:) と同じ基準)
    private static func validate(
        file: URL, fileName: String, kind: ProfileFileKind,
        project: TestProject, machineName: String?
    ) -> ApiValidateProfileResult {
        guard let data = try? Data(contentsOf: file) else {
            return ApiValidateProfileResult(
                kind: kind.directoryName, name: fileName, path: file.path,
                errors: ["ファイルを読み込めません"], warnings: [])
        }

        var (errors, warnings) = ProfileResolver.validate(
            kind: kind, data: data, context: "\(kind.directoryName)/\(fileName).json")

        // 実行プロファイルは参照(app / デバイス name)も現在マシンで解決チェックする
        // (ProfilesView.validate(_:) と同方針。他の検証エラーがある場合は解決を試みない)
        if kind == .run, errors.isEmpty {
            if let machineName {
                do {
                    let resolved = try ProfileResolver.resolve(
                        project: project, runName: fileName, machineName: machineName)
                    warnings += resolved.warnings
                } catch {
                    errors.append(error.localizedDescription)
                }
            } else {
                warnings.append("マシン名が未決定のため参照チェックをスキップしました")
            }
        }

        return ApiValidateProfileResult(
            kind: kind.directoryName, name: fileName, path: file.path,
            errors: errors, warnings: warnings)
    }

    private static func jsonFiles(in dir: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func logStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// ftester api validate-profile の 1 ファイル分の検証結果
private struct ApiValidateProfileResult: Encodable {
    let kind: String
    let name: String
    let path: String
    let errors: [String]
    let warnings: [String]
}

/// ftester api validate-profile の出力全体。machine は省略可能フィールドとして
/// 明示的に null を encode する(ApiScenarioInfo と同方針)
private struct ApiValidateProfileOutput: Encodable {
    let project: String
    let machine: String?
    let results: [ApiValidateProfileResult]

    private enum CodingKeys: String, CodingKey {
        case project, machine, results
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(project, forKey: .project)
        try container.encode(machine, forKey: .machine)
        try container.encode(results, forKey: .results)
    }
}
