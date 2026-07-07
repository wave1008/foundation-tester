// AndroidDriver.swift
// M4: AppDriver の Android 実装。adb 直叩き(依存ゼロ)。
// - スナップショット: uiautomator dump の XML を解析し、iOS と同じ圧縮形式に変換
// - 操作: input tap / input text / input swipe
// - スクリーンショット: screencap -p
// FTAgent(探索・修復・トリアージ)と FTCore(再生器)は無変更でそのまま動く。

import Foundation
import FTCore

public final class AndroidDriver: AppDriver {

    public let adbPath: String
    let serial: String?

    // 直近スナップショットの ref → 中心座標(iOS ランナーと同じ方式)。
    // iOS と違い CLI プロセス内に住むため、呼び出しをまたぐ手動駆動用に
    // 一時ファイルへも永続化する(explore/run は単一プロセスなので不要だが無害)
    private var refCenters: [Int: (x: Double, y: Double)] = [:]
    private var screen: FTRect = FTRect(x: 0, y: 0, width: 0, height: 0)
    private var currentPackage: String?

    private struct PersistedState: Codable {
        var centers: [Int: [Double]]
        var screen: FTRect
        var package: String?
    }

    private var stateFileURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ftester-android-\(serial ?? "default").json")
    }

    private func persistState() {
        let state = PersistedState(
            centers: refCenters.mapValues { [$0.x, $0.y] },
            screen: screen, package: currentPackage)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateFileURL)
        }
    }

    private func restoreStateIfNeeded() {
        guard refCenters.isEmpty,
              let data = try? Data(contentsOf: stateFileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        refCenters = state.centers.compactMapValues { $0.count == 2 ? (x: $0[0], y: $0[1]) : nil }
        screen = state.screen
        if currentPackage == nil { currentPackage = state.package }
    }

    public init(serial: String? = nil) throws {
        self.adbPath = try Self.findADB()
        self.serial = serial
    }

    static func findADB() throws -> String {
        let candidates = [
            ProcessInfo.processInfo.environment["ANDROID_HOME"].map { $0 + "/platform-tools/adb" },
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            "/usr/local/bin/adb",
            "/opt/homebrew/bin/adb",
        ].compactMap { $0 }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw DriverError.bridgeUnreachable("adb が見つかりません(ANDROID_HOME を設定してください)")
    }

    // MARK: - adb helpers

    func adb(_ args: [String]) throws -> Shell.Result {
        var full = [adbPath]
        if let serial { full += ["-s", serial] }
        return try Shell.run(full + args)
    }

    func adbData(_ args: [String]) throws -> Data {
        var full = [adbPath]
        if let serial { full += ["-s", serial] }
        let (status, data) = try Shell.runData(full + args)
        guard status == 0 else {
            throw DriverError.badResponse(status: Int(status), body: "adb \(args.joined(separator: " "))")
        }
        return data
    }

    // MARK: - AppDriver

    public func status() async throws -> StatusResponse {
        let boot = try adb(["shell", "getprop", "sys.boot_completed"])
        let ready = boot.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        let model = (try? adb(["shell", "getprop", "ro.product.model"]))?.output
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Android"
        let version = (try? adb(["shell", "getprop", "ro.build.version.release"]))?.output
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        return StatusResponse(ready: ready, device: model,
                              osVersion: "Android \(version)",
                              sessionBundleID: currentPackage)
    }

    public func launch(bundleID: String) async throws {
        // 起動中でも先頭画面に戻すため一度止めてから起動する(iOS launch() と同じ意味論)
        _ = try adb(["shell", "am", "force-stop", bundleID])
        let result = try adb(["shell", "monkey", "-p", bundleID,
                              "-c", "android.intent.category.LAUNCHER", "1"])
        guard result.output.contains("Events injected: 1") else {
            throw DriverError.badResponse(status: 1,
                body: "アプリを起動できません: \(bundleID)(インストール済みか確認してください)\n\(result.tail)")
        }
        currentPackage = bundleID
        try await Task.sleep(nanoseconds: 1_500_000_000)
    }

    public func snapshot() async throws -> SnapshotResponse {
        let xml = try dumpHierarchy()
        let parser = UIAutomatorXMLParser()
        var nodes = try parser.parse(xml)

        // Android のリスト行は「クリック可能な無名コンテナ+テキストを持つ非クリック子」
        // の構造が多い。クリック可能ノードに最初の子孫テキストを昇格させ、
        // FM が「Cell 「Network & internet」」として直接選べるようにする
        for i in nodes.indices where nodes[i].clickable
            && nodes[i].text.isEmpty && nodes[i].contentDesc.isEmpty {
            var j = i + 1
            while j < nodes.count, nodes[j].depth > nodes[i].depth {
                if !nodes[j].text.isEmpty {
                    nodes[i].text = nodes[j].text
                    break
                }
                j += 1
            }
        }

        // ルート(最初のノード)の bounds を画面サイズとして使う
        if let root = nodes.first {
            screen = root.frame
        }

        var elements: [ElementInfo] = []
        var centers: [Int: (Double, Double)] = [:]
        var truncated = 0
        for node in nodes {
            guard shouldInclude(node) else { continue }
            if elements.count >= BridgeAPI.maxSnapshotElements {
                truncated += 1
                continue
            }
            let ref = elements.count + 1
            centers[ref] = (node.frame.centerX, node.frame.centerY)
            elements.append(makeInfo(node, ref: ref))
        }
        refCenters = centers
        persistState()
        return SnapshotResponse(sessionBundleID: currentPackage, screen: screen,
                                elements: elements, truncatedCount: truncated)
    }

    public func tap(ref: Int) async throws {
        restoreStateIfNeeded()
        guard let center = refCenters[ref] else {
            throw DriverError.badResponse(status: 404, body: "参照番号 [\(ref)] は未知です。先に snapshot を実行してください")
        }
        try await tap(x: center.0, y: center.1)
    }

    public func tap(x: Double, y: Double) async throws {
        _ = try adb(["shell", "input", "tap", String(Int(x)), String(Int(y))])
    }

    public func type(ref: Int?, text: String) async throws {
        if let ref {
            try await tap(ref: ref)
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        // adb input text の制約: 空白は %s、ASCII 以外は入らないことがある(既知の制限)
        let escaped = text
            .replacingOccurrences(of: " ", with: "%s")
            .replacingOccurrences(of: "'", with: "\\'")
        _ = try adb(["shell", "input", "text", escaped])
    }

    public func swipe(_ direction: FTSwipeDirection) async throws {
        let w = screen.width > 0 ? screen.width : 1080
        let h = screen.height > 0 ? screen.height : 2400
        let cx = w / 2, cy = h / 2
        let (from, to): ((Double, Double), (Double, Double))
        switch direction {
        case .up: (from, to) = ((cx, h * 0.7), (cx, h * 0.3))
        case .down: (from, to) = ((cx, h * 0.3), (cx, h * 0.7))
        case .left: (from, to) = ((w * 0.8, cy), (w * 0.2, cy))
        case .right: (from, to) = ((w * 0.2, cy), (w * 0.8, cy))
        }
        _ = try adb(["shell", "input", "swipe",
                     String(Int(from.0)), String(Int(from.1)),
                     String(Int(to.0)), String(Int(to.1)), "300"])
    }

    public func press(ref: Int, duration: Double) async throws {
        restoreStateIfNeeded()
        guard let center = refCenters[ref] else {
            throw DriverError.badResponse(status: 404, body: "参照番号 [\(ref)] は未知です")
        }
        let x = String(Int(center.0)), y = String(Int(center.1))
        _ = try adb(["shell", "input", "swipe", x, y, x, y, String(Int(duration * 1000))])
    }

    public func screenshot() async throws -> Data {
        try adbData(["exec-out", "screencap", "-p"])
    }

    public func terminate() async throws {
        if let package = currentPackage {
            _ = try adb(["shell", "am", "force-stop", package])
            currentPackage = nil
        }
    }

    // MARK: - hierarchy dump

    func dumpHierarchy() throws -> String {
        // まず /dev/tty への直接ダンプ(1コマンドで速い)、だめならファイル経由
        if let direct = try? adb(["exec-out", "uiautomator", "dump", "/dev/tty"]),
           direct.output.contains("<hierarchy") {
            return Self.stripDumpFooter(direct.output)
        }
        let path = "/sdcard/ftester_dump.xml"
        let dump = try adb(["shell", "uiautomator", "dump", path])
        guard dump.output.contains("dumped") || dump.status == 0 else {
            throw DriverError.badResponse(status: Int(dump.status), body: "uiautomator dump 失敗: \(dump.tail)")
        }
        let cat = try adb(["exec-out", "cat", path])
        guard cat.output.contains("<hierarchy") else {
            throw DriverError.badResponse(status: 1, body: "ダンプ XML を取得できません")
        }
        return cat.output
    }

    static func stripDumpFooter(_ output: String) -> String {
        // 末尾に "UI hierchary dumped to: /dev/tty" が付くことがある
        if let range = output.range(of: "</hierarchy>") {
            return String(output[..<range.upperBound])
        }
        return output
    }

    // MARK: - フィルタと変換(iOS ランナーと同じ思想)

    func shouldInclude(_ node: UINode) -> Bool {
        let f = node.frame
        guard f.width >= 2, f.height >= 2 else { return false }

        // 画面の大半を覆うコンテナは除外(FM の誤タップ誘発対策)
        if !node.clickable, screen.width > 0 {
            let ratio = (f.width * f.height) / (screen.width * screen.height)
            if ratio > 0.85 { return false }
        }

        let hasText = !node.text.isEmpty || !node.contentDesc.isEmpty || !node.resourceID.isEmpty
        if node.clickable || node.checkable { return true }
        switch node.mappedType {
        case "TextField", "SecureTextField": return true
        case "StaticText", "Image": return hasText
        default: return !node.resourceID.isEmpty
        }
    }

    func makeInfo(_ node: UINode, ref: Int) -> ElementInfo {
        let type = node.mappedType
        let isInput = type == "TextField" || type == "SecureTextField"

        var label: String?
        var value: String?
        if isInput {
            value = node.text.isEmpty ? nil : node.text
            label = node.contentDesc.isEmpty ? nil : node.contentDesc
        } else {
            label = !node.text.isEmpty ? node.text
                : (!node.contentDesc.isEmpty ? node.contentDesc : nil)
        }
        if node.checkable {
            value = node.checked ? "1" : "0"
        }

        // resource-id は "com.example:id/foo" 形式 → "foo" に短縮
        var identifier: String?
        if !node.resourceID.isEmpty {
            identifier = node.resourceID.components(separatedBy: "id/").last ?? node.resourceID
        }

        return ElementInfo(ref: ref, type: type, identifier: identifier, label: label,
                           value: value, placeholder: nil, enabled: node.enabled,
                           frame: node.frame, depth: node.depth)
    }
}

// MARK: - uiautomator XML

struct UINode {
    var className = ""
    var text = ""
    var contentDesc = ""
    var resourceID = ""
    var clickable = false
    var checkable = false
    var checked = false
    var enabled = true
    var password = false
    var frame = FTRect(x: 0, y: 0, width: 0, height: 0)
    var depth = 0

    /// Android クラス名 → iOS 側と共通の型語彙へマップ(FM プロンプトの一貫性のため)
    var mappedType: String {
        let name = className.components(separatedBy: ".").last ?? className
        if password { return "SecureTextField" }
        switch name {
        case "Button", "ImageButton", "MaterialButton": return "Button"
        case "EditText", "AutoCompleteTextView", "MultiAutoCompleteTextView": return "TextField"
        case "TextView", "CheckedTextView": return "StaticText"
        case "ImageView": return "Image"
        case "Switch", "SwitchCompat", "ToggleButton": return "Switch"
        case "CheckBox": return "CheckBox"
        case "RadioButton": return "CheckBox"
        case "SeekBar": return "Slider"
        case "RecyclerView", "ListView", "GridView": return "CollectionView"
        case "ScrollView", "NestedScrollView", "HorizontalScrollView": return "ScrollView"
        case "WebView": return "WebView"
        default:
            // クリック可能な無名コンテナは実質ボタン/セルとして扱う
            if clickable { return "Cell" }
            return "Other"
        }
    }
}

final class UIAutomatorXMLParser: NSObject, XMLParserDelegate {
    private var nodes: [UINode] = []
    private var depth = 0
    private var parseError: Error?

    func parse(_ xml: String) throws -> [UINode] {
        nodes = []
        depth = 0
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() || !nodes.isEmpty else {
            throw DriverError.badResponse(status: 1,
                body: "uiautomator XML の解析に失敗: \(parser.parserError?.localizedDescription ?? "?")")
        }
        return nodes
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes: [String: String]) {
        guard elementName == "node" || elementName == "hierarchy" else { return }
        depth += 1
        guard elementName == "node" else { return }

        var node = UINode()
        node.className = attributes["class"] ?? ""
        node.text = attributes["text"] ?? ""
        node.contentDesc = attributes["content-desc"] ?? ""
        node.resourceID = attributes["resource-id"] ?? ""
        node.clickable = attributes["clickable"] == "true"
        node.checkable = attributes["checkable"] == "true"
        node.checked = attributes["checked"] == "true"
        node.enabled = attributes["enabled"] != "false"
        node.password = attributes["password"] == "true"
        node.depth = depth
        node.frame = Self.parseBounds(attributes["bounds"] ?? "")
        nodes.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "node" || elementName == "hierarchy" { depth -= 1 }
    }

    /// "[x1,y1][x2,y2]" → FTRect
    static func parseBounds(_ bounds: String) -> FTRect {
        let numbers = bounds
            .components(separatedBy: CharacterSet(charactersIn: "[],"))
            .compactMap { Double($0) }
        guard numbers.count == 4 else { return FTRect(x: 0, y: 0, width: 0, height: 0) }
        return FTRect(x: numbers[0], y: numbers[1],
                      width: numbers[2] - numbers[0], height: numbers[3] - numbers[1])
    }
}
