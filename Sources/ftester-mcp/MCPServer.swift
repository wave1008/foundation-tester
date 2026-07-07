// MCPServer.swift
// ftester の MCP サーバ(stdio / JSON-RPC 2.0、依存ゼロの自前実装)。
// Claude Code などの MCP クライアントに、シミュレータ/エミュレータの操作と
// フロー実行をツールとして公開する。
//
// 役割分担の思想:
// - エージェント(クライアント側)が「知能」: 探索・判断・テスト作成
// - このサーバと Flow DSL が「決定性」: 操作・再生・検証
// explore 相当はツールとして提供しない — スナップショットと操作プリミティブがあれば
// クライアントのエージェント自身が探索できるため。

import Foundation
import FTAgent
import FTAndroid
import FTBridgeClient
import FTCore

@main
struct FTesterMCP {
    static func main() async {
        let server = MCPServer()
        await server.run()
    }
}

final class MCPServer {

    private var drivers: [String: AppDriver] = [:]
    private let out = FileHandle.standardOutput

    // MARK: - メインループ(stdio: 改行区切り JSON-RPC)

    func run() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            await handle(message)
        }
    }

    private func handle(_ message: [String: Any]) async {
        let method = message["method"] as? String ?? ""
        let id = message["id"]

        // id なしは notification(initialized 等)— 応答しない
        guard id != nil else { return }

        switch method {
        case "initialize":
            reply(id: id, result: [
                "protocolVersion": (message["params"] as? [String: Any])?["protocolVersion"] ?? "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "ftester", "version": "0.1.0"],
            ])
        case "ping":
            reply(id: id, result: [String: Any]())
        case "tools/list":
            reply(id: id, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let content = try await call(tool: name, args: args)
                reply(id: id, result: ["content": content, "isError": false])
            } catch {
                reply(id: id, result: [
                    "content": [["type": "text", "text": "エラー: \(error.localizedDescription)"]],
                    "isError": true,
                ])
            }
        default:
            reply(id: id, error: ["code": -32601, "message": "method not found: \(method)"])
        }
    }

    private func reply(id: Any?, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func reply(id: Any?, error: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": error])
    }

    private func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        out.write(data)
    }

    // MARK: - ドライバ

    private func driver(_ args: [String: Any]) throws -> AppDriver {
        let platform = (args["platform"] as? String)
            ?? ProcessInfo.processInfo.environment["FTESTER_PLATFORM"]
            ?? "ios"
        if let cached = drivers[platform] { return cached }
        let created: AppDriver
        switch platform {
        case "ios":
            created = BridgeClient()
        case "android":
            created = try AndroidDriver(serial: args["serial"] as? String)
        default:
            throw MCPError("platform は ios / android のいずれかです: \(platform)")
        }
        drivers[platform] = created
        return created
    }

    // MARK: - ツール実装

    private func call(tool: String, args: [String: Any]) async throws -> [[String: Any]] {
        switch tool {
        case "ft_status":
            let status = try await driver(args).status()
            return text("ready: \(status.ready) / \(status.device) (\(status.osVersion)) / session: \(status.sessionBundleID ?? "なし")")

        case "ft_launch":
            guard let bundleID = args["bundleId"] as? String else { throw MCPError("bundleId が必要です") }
            try await driver(args).launch(bundleID: bundleID)
            return text("起動しました: \(bundleID)")

        case "ft_snapshot":
            let snapshot = try await driver(args).snapshot()
            return text(SnapshotRenderer.render(snapshot))

        case "ft_tap":
            let d = try driver(args)
            if let ref = args["ref"] as? Int {
                try await d.tap(ref: ref)
                return text("tap [\(ref)] 完了。画面が変わった可能性があるため ft_snapshot で再取得してください")
            }
            if let x = args["x"] as? Double, let y = args["y"] as? Double {
                try await d.tap(x: x, y: y)
                return text("tap (\(x), \(y)) 完了")
            }
            throw MCPError("ref か x/y が必要です")

        case "ft_type":
            guard let content = args["text"] as? String else { throw MCPError("text が必要です") }
            try await driver(args).type(ref: args["ref"] as? Int, text: content)
            return text("入力しました: \"\(content)\"")

        case "ft_swipe":
            guard let direction = FTSwipeDirection(rawValue: args["direction"] as? String ?? "") else {
                throw MCPError("direction は up/down/left/right のいずれかです")
            }
            try await driver(args).swipe(direction)
            return text("swipe \(direction.rawValue) 完了")

        case "ft_press":
            guard let ref = args["ref"] as? Int else { throw MCPError("ref が必要です") }
            try await driver(args).press(ref: ref, duration: args["duration"] as? Double ?? 1.0)
            return text("press [\(ref)] 完了")

        case "ft_screenshot":
            let png = try await driver(args).screenshot()
            return [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]]

        case "ft_terminate":
            try await driver(args).terminate()
            return text("アプリを終了しました")

        case "ft_list_flows":
            return try listFlows(dir: args["dir"] as? String ?? "flows")

        case "ft_run_flow":
            return try await runFlow(args)

        case "ft_doctor":
            let fm = FMDoctor.check()
            return text((fm.available ? "✅ " : "❌ ") + fm.detail)

        default:
            throw MCPError("未知のツール: \(tool)")
        }
    }

    private func text(_ string: String) -> [[String: Any]] {
        [["type": "text", "text": string]]
    }

    private func listFlows(dir: String) throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: dir)
        let files = (try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "yaml" || $0.pathExtension == "yml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var lines: [String] = []
        for file in files {
            if let flow = try? FlowIO.load(from: file) {
                let dirty = flow.dirty == true ? " [dirty]" : ""
                lines.append("\(file.path) — \(flow.name) (\(flow.platform ?? "?"), \(flow.steps.count) steps)\(dirty)")
            } else {
                lines.append("\(file.path) — (読み込み失敗)")
            }
        }
        return text(lines.isEmpty ? "フローがありません: \(dir)" : lines.joined(separator: "\n"))
    }

    private func runFlow(_ args: [String: Any]) async throws -> [[String: Any]] {
        guard let path = args["path"] as? String else { throw MCPError("path が必要です") }
        let heal = args["heal"] as? Bool ?? false
        let url = URL(fileURLWithPath: path)
        let flow = try FlowIO.load(from: url)
        let flowDriver = try driver(["platform": flow.platform as Any])

        let delegate: FMReplayDelegate? = FMDoctor.check().available ? FMReplayDelegate() : nil
        let replayer = Replayer(driver: flowDriver, delegate: delegate, healingEnabled: heal)

        var lines: [String] = ["▶ \(flow.name) [\(flow.platform ?? "ios")]"]
        replayer.onStep = { step in
            switch step.status {
            case .passed:
                lines.append("✅ \(step.index). \(step.description)")
            case .passedViaFallback(let locator):
                lines.append("✅ \(step.index). \(step.description)(フォールバック \(locator.summary))")
            case .healed(let locator):
                lines.append("🔧 \(step.index). \(step.description) → 自己修復: \(locator.summary)")
            case .failed(let reason):
                lines.append("❌ \(step.index). \(step.description) — \(reason)")
            case .skipped(let reason):
                lines.append("⚠️ \(step.index). \(step.description)(スキップ: \(reason))")
            }
        }

        let result = await replayer.run(flow: flow)

        if let healedFlow = result.healedFlow, heal {
            try FlowIO.save(healedFlow, to: url)
            lines.append("🔧 修復したロケータでフローを更新(dirty: true — 要レビュー)")
        }
        if result.passed {
            lines.append("結果: ✅ 成功")
        } else {
            if let triage = result.triage {
                lines.append("トリアージ: [\(triage.failureClass)] \(triage.summary) / 修正案: \(triage.suggestedFix)")
            }
            let reportURL = try ReportWriter.write(result: result, to: URL(fileURLWithPath: "reports"))
            lines.append("結果: ❌ 失敗 — レポート: \(reportURL.path)")
        }
        return text(lines.joined(separator: "\n"))
    }

    // MARK: - ツール定義

    static let platformProperty: [String: Any] = [
        "type": "string", "enum": ["ios", "android"],
        "description": "対象プラットフォーム(省略時 ios)",
    ]

    static let toolDefinitions: [[String: Any]] = [
        tool("ft_status", "デバイス/ブリッジの接続状態を確認する", [:]),
        tool("ft_launch", "アプリを起動する(起動済みなら先頭画面から再起動)", [
            "bundleId": ["type": "string", "description": "bundle ID(iOS)/ パッケージ名(Android)"],
        ], required: ["bundleId"]),
        tool("ft_snapshot", "現在画面の要素一覧を取得する。各行 [ref] Type \"label\" id=... (x,y WxH)。tap/type はこの ref を使う", [:]),
        tool("ft_tap", "要素または座標をタップする", [
            "ref": ["type": "integer", "description": "ft_snapshot の参照番号"],
            "x": ["type": "number"], "y": ["type": "number"],
        ]),
        tool("ft_type", "テキストを入力する(ref 指定時はその入力欄をタップしてから入力)", [
            "text": ["type": "string"],
            "ref": ["type": "integer", "description": "入力欄の参照番号(省略時はフォーカス中の要素)"],
        ], required: ["text"]),
        tool("ft_swipe", "スワイプする(up=下へスクロール)", [
            "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
        ], required: ["direction"]),
        tool("ft_press", "要素を長押しする", [
            "ref": ["type": "integer"],
            "duration": ["type": "number", "description": "秒(既定 1.0)"],
        ], required: ["ref"]),
        tool("ft_screenshot", "スクリーンショットを撮る(画像を返す)。視覚検証に使う", [:]),
        tool("ft_terminate", "起動中のアプリを終了する", [:]),
        tool("ft_list_flows", "保存済みテストフロー(YAML)の一覧を返す", [
            "dir": ["type": "string", "description": "フローのディレクトリ(既定 flows)"],
        ]),
        tool("ft_run_flow", "テストフローを決定的に再生する。失敗時はトリアージとレポートパスを返す", [
            "path": ["type": "string", "description": "フローファイル(.yaml)のパス"],
            "heal": ["type": "boolean", "description": "ロケータ自己修復を許可(既定 false)"],
        ], required: ["path"]),
        tool("ft_doctor", "Foundation Models の可用性を確認する", [:]),
    ]

    static func tool(_ name: String, _ description: String,
                     _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var props = properties
        // ドライバ選択は全ツール共通
        props["platform"] = platformProperty
        var schema: [String: Any] = ["type": "object", "properties": props]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }
}

struct MCPError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
