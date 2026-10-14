// MCPServer+Services.swift
// ft_services: `fleetest services up|down|status` を本物の CLI で同期に実行する。
//
// **`swift run fleetest` 経由**: MCP のランチャーが作るのは fleetest-mcp だけで、隣の fleetest は古いことがある(ft_start_run と同じ)。
// **子の出力はパイプで読まない**(一時ファイルへ直接書き、終了後に末尾だけ読む。readDataToEndOfFile の走査対象外にする)。
// **非0終了も MCPError にしない**(利用者が出力を読んで判断する)。承認は `ProjectScaffold.mcpServicesPermission`(ask)。

import Foundation
import FTBridgeClient
import FTCore

enum MCPServices {
    static let actions = ["up", "down", "status"]

    /// 出力の末尾の行数(応答を膨らませない)
    static let outputTailLines = 200
    /// 末尾を読む窓(バイト)。ビルドの出力で長くなっても有限にする
    static let outputWindowBytes: UInt64 = 256 * 1024

    /// `physical` / `serials` は `up` だけが受ける(CLI の `services up --physical --serial`。他の動詞には渡さない)
    static func arguments(action: String, project: String?, profile: String?,
                          physical: Bool = false, serials: [String] = []) -> [String] {
        var args = ["swift", "run", "fleetest", "services", action]
        if let project { args += ["--project", project] }
        if let profile { args += ["--profile", profile] }
        if action == "up" {
            if physical { args.append("--physical") }
            for serial in serials { args += ["--serial", serial] }
        }
        return args
    }

    /// `-` で始まる値を断る。**`arguments` へ渡す前に必ず呼ぶ** —— 子の `fleetest services` でフラグとして読まれる
    /// (`optionLikeValueRefusal` と同じ理由。プロファイル名・プロジェクト名に `-` 始まりの正当な値は無い)
    static func optionLikeValueRefusal(project: String?, profile: String?, serials: [String] = []) -> String? {
        let named: [(String, String)] = (project.map { [("project", $0)] } ?? [])
            + (profile.map { [("profile", $0)] } ?? [])
            + serials.map { ("androidSerials", $0) }
        guard let (key, value) = named.first(where: {
            $0.1.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-")
        }) else { return nil }
        return "\(key) must not start with \"-\" (got \(value.debugDescription)): it would be read as an"
            + " option of the spawned `fleetest services`"
    }

    static func tail(_ text: String, lines: Int = outputTailLines) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
    }

    static func responseText(action: String, status: Int32, output: String) -> String {
        let body = tail(output)
        return "fleetest services \(action): exit \(status)" + (body.isEmpty ? "" : "\n" + body)
    }
}

extension MCPServer {

    func ftServices(_ args: [String: Any]) throws -> [[String: Any]] {
        let action = try Self.requiredStringArgument(args, "action")
        guard MCPServices.actions.contains(action) else {
            throw MCPError("action must be one of \(MCPServices.actions.joined(separator: ", ")) (got \(action.debugDescription))")
        }
        let project = try Self.stringArgument(args, "project")
        let profile = try Self.stringArgument(args, "profile")
        if action != "status", profile == nil {
            throw MCPError("profile is required for action \(action)")
        }
        let physical = try Self.flagArgument(args, "physical")
        let serials = try Self.stringListArgument(args, "androidSerials")
        if let refusal = MCPServices.optionLikeValueRefusal(project: project, profile: profile, serials: serials) {
            throw MCPError(refusal)
        }
        guard let packageRoot = ScenarioHost.packageRoot() else {
            throw MCPError("Package.swift not found (run this inside the repository)")
        }
        let resolvedProject = try ScenarioHost.project(named: project).name
        let arguments = MCPServices.arguments(action: action, project: resolvedProject, profile: profile,
                                              physical: physical, serials: serials)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-mcp-services-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: outputURL) else {
            throw MCPError("cannot create a temporary output file at \(outputURL.path)")
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = packageRoot
        process.environment = MCPRunJobs.childEnvironment(packageRoot: packageRoot, toolRoot: try? RepoRoot.find())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        let exited = ProcessExitWait.prepareBlocking(process)   // run() より前に設定する契約(ProcessWaitSourceScanTests)
        do {
            try process.run()
        } catch {
            try? handle.close()
            throw MCPError("cannot start `fleetest services \(action)`: \(error.localizedDescription)")
        }
        try? handle.close()
        exited()

        var output = ""
        if let reader = try? FileHandle(forReadingFrom: outputURL) {
            defer { try? reader.close() }
            let size = (try? reader.seekToEnd()) ?? 0
            try? reader.seek(toOffset: size > MCPServices.outputWindowBytes ? size - MCPServices.outputWindowBytes : 0)
            output = String(decoding: (try? reader.readToEnd()) ?? Data(), as: UTF8.self)
        }
        return text(MCPServices.responseText(action: action, status: process.terminationStatus, output: output))
    }
}
