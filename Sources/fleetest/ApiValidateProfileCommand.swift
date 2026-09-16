// VSCode拡張向け: プロファイルJSON(profiles/apps・runs)を検証し、結果をJSONで
// stdoutに出力する(fleetest api validate-profile)。
// 検証基準: ProfileResolver.validate(kind:data:context:) に加え、runs は参照解決チェック
// (ProfileResolver.resolve)も行う。
// 検証エラーがあっても結果は JSON で運ぶため exit 0。
// ファイル I/O 等の運用エラーのみ非 0(診断は stderr のみ。ApiCommands.swift と同じ流儀)。

import ArgumentParser
import Foundation
import FTCore

struct ApiValidateProfile: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate-profile",
        abstract: "Validate the profile JSON (apps/runs) and print the result as JSON on stdout"
            + " (validation errors still exit 0; only operational errors such as file I/O exit non-zero; diagnostics on stderr only)")

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Kind to filter by: apps / runs (defaults to all kinds)")
    var kind: String?

    @Option(help: "Profile name to filter by, without the extension (without --kind, all kinds are searched for that name)")
    var name: String?

    func run() async throws {
        let testProject = try ScenarioHost.project(named: project)

        let kinds: [ProfileFileKind]
        if let kind {
            guard let matched = ProfileFileKind.allCases.first(where: { $0.directoryName == kind })
            else {
                throw ValidationError("--kind must be one of apps/runs: \(kind)")
            }
            kinds = [matched]
        } else {
            kinds = ProfileFileKind.allCases
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
            logStderr("⚠️ No profiles matched for validation"
                + " (check the --kind/--name arguments)")
        }

        let output = ApiValidateProfileOutput(
            project: testProject.name, results: results)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output)
        ConsoleOut.out(String(data: data, encoding: .utf8)!)
    }

    private static func validate(
        file: URL, fileName: String, kind: ProfileFileKind, project: TestProject
    ) -> ApiValidateProfileResult {
        guard let data = try? Data(contentsOf: file) else {
            return ApiValidateProfileResult(
                kind: kind.directoryName, name: fileName, path: file.path,
                errors: ["cannot read the file"], warnings: [])
        }

        var (errors, warnings) = ProfileResolver.validate(
            kind: kind, data: data, context: "\(kind.directoryName)/\(fileName).json")

        // 実行プロファイルは参照(app)も解決チェックする(他の検証エラーがある場合は解決を試みない)
        if kind == .run, errors.isEmpty {
            do {
                let resolved = try ProfileResolver.resolve(project: project, runName: fileName)
                warnings += resolved.warnings
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
        ConsoleOut.err(message)
    }
}

/// fleetest api validate-profile の 1 ファイル分の検証結果
private struct ApiValidateProfileResult: Encodable {
    let kind: String
    let name: String
    let path: String
    let errors: [String]
    let warnings: [String]
}

/// fleetest api validate-profile の出力全体(同期相手: vscode-fleetest/src/profileModel.ts)
private struct ApiValidateProfileOutput: Encodable {
    let project: String
    let results: [ApiValidateProfileResult]
}
