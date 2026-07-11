// ApiValidateProfileCommand.swift
// VSCode拡張向け: プロファイルJSON(profiles/apps・machines・runs)を検証し、結果をJSONで
// stdoutに出力する(ftester api validate-profile)。
// 検証基準: ProfileResolver.validate(kind:data:context:project:) に加え、runs は machine 指定
// (無ければ現在マシン)での参照解決チェック(ProfileResolver.resolve)も行う。
// 検証エラーがあっても結果は JSON で運ぶため exit 0。
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

        // 出力の "machine" フィールド(参考情報)に使う現在マシン名。runs 個々の参照解決チェックは
        // determineMachine(runProfileName:) で各ファイル自身の machine 指定を優先するため、
        // ここで未決定でも各ファイルのチェックには影響しない(machine 未指定のファイルだけ
        // このマシン決定に相当する処理へフォールバックする)
        var machineName: String?
        do {
            machineName = try ProfileResolver.determineMachine(
                project: testProject, registered: LocalConfig.currentMachineName()).name
        } catch {
            logStderr("⚠️ マシン名を決定できません(出力の machine フィールドは null になります): "
                + error.localizedDescription)
        }

        var results: [ApiValidateProfileResult] = []
        for fileKind in kinds {
            let dir = testProject.profilesDir.appendingPathComponent(fileKind.directoryName)
            for file in Self.jsonFiles(in: dir) {
                let fileName = file.deletingPathExtension().lastPathComponent
                if let name, fileName != name { continue }
                results.append(Self.validate(
                    file: file, fileName: fileName, kind: fileKind, project: testProject))
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
        file: URL, fileName: String, kind: ProfileFileKind, project: TestProject
    ) -> ApiValidateProfileResult {
        guard let data = try? Data(contentsOf: file) else {
            return ApiValidateProfileResult(
                kind: kind.directoryName, name: fileName, path: file.path,
                errors: ["ファイルを読み込めません"], warnings: [])
        }

        var (errors, warnings) = ProfileResolver.validate(
            kind: kind, data: data, context: "\(kind.directoryName)/\(fileName).json",
            project: project)

        // 実行プロファイルは参照(app / デバイス name)も解決チェックする(ProfilesView.validate(_:)
        // と同方針。他の検証エラーがある場合は解決を試みない)。マシン決定は
        // determineMachine(runProfileName:) に委ねる: このファイル自身が machine を明示指定して
        // いればそれを最優先するため、FT_MACHINE/登録名が未設定・machines/ が複数ある環境でも
        // 参照チェックが行える(machineUndetermined だけは既存プロファイルとの後方互換のため
        // 警告に留めてスキップする。それ以外の解決失敗は通常どおりエラーにする)
        if kind == .run, errors.isEmpty {
            do {
                let machine = try ProfileResolver.determineMachine(
                    project: project, registered: LocalConfig.currentMachineName(),
                    runProfileName: fileName)
                let resolved = try ProfileResolver.resolve(
                    project: project, runName: fileName, machineName: machine.name)
                warnings += resolved.warnings
            } catch ProfileError.machineUndetermined {
                warnings.append("マシン名が未決定のため参照チェックをスキップしました")
            } catch {
                errors.append(error.localizedDescription)
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
