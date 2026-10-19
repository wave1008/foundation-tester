import XCTest
@testable import FTCore

/// 描画崩壊の判定(`RenderCollapse`)を失敗レポートの画面写真と要素一覧の全数へ当てる集計(閾値を決める材料)。
/// `FT_RENDER_COLLAPSE_CORPUS`(レポートの .md のパスを1行1件で並べたファイル)と `FT_RENDER_COLLAPSE_OUT`(TSV)を
/// 渡したときだけ動く。レポートの要素一覧はキーボードの枠を載せないので、キーボードは無いものとして判定する
final class RenderCollapseCorpusSweep: XCTestCase {

    func testSweepFailureReports() throws {
        let env = ProcessInfo.processInfo.environment
        guard let listPath = env["FT_RENDER_COLLAPSE_CORPUS"], let outPath = env["FT_RENDER_COLLAPSE_OUT"] else {
            throw XCTSkip("FT_RENDER_COLLAPSE_CORPUS / FT_RENDER_COLLAPSE_OUT が無い")
        }
        let paths = try String(contentsOfFile: listPath, encoding: .utf8).split(separator: "\n").map(String.init)
        var rows = ["md\tscene\tscreen\ttexts\tinkless\tuniform\tminInk\tfinding"]
        for md in paths {
            guard let text = try? String(contentsOfFile: md, encoding: .utf8) else { continue }
            for (scene, block) in Self.sceneBlocks(text) {
                guard let (screen, elements) = Self.parseElements(block) else { continue }
                // Android(px)は対象外(Simulator の iOS だけ)。pt の画面は短辺が 600 未満
                guard min(screen.width, screen.height) < 600 else { continue }
                let png = URL(fileURLWithPath: md).deletingPathExtension().path + "-scene\(scene).png"
                guard let data = FileManager.default.contents(atPath: png) else { continue }
                guard let area = RenderCollapse.appArea(elements: elements, screen: screen, keyboard: nil) else { continue }
                let texts = RenderCollapse.textElements(in: elements, screen: screen, appArea: area)
                let inks = texts.compactMap { RegionInk.luminanceStdDev(pngData: data, frame: $0.frame, screen: screen) }
                let inkless = inks.filter { $0 < 12 }.count
                let uniform = RenderCollapse.isUniform(pngData: data, region: area, screen: screen).map { $0 ? "1" : "0" } ?? "-"
                let finding = RenderCollapse.judge(pngData: data, elements: elements, screen: screen, keyboard: nil,
                                                   inkThreshold: 12, minimumTextElements: RenderCollapse.minimumTextElements)
                let minInk: String = inks.min().map { String(format: "%.1f", $0) } ?? "-"
                let fields: [String] = [md, String(scene), "\(Int(screen.width))x\(Int(screen.height))", String(inks.count),
                                        String(inkless), uniform, minInk, finding.map { "\($0)" } ?? "-"]
                rows.append(fields.joined(separator: "\t"))
            }
        }
        try rows.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
    }

    /// `## scene N` ごとの本文
    static func sceneBlocks(_ text: String) -> [(Int, String)] {
        var result: [(Int, String)] = []
        var current: (Int, [Substring])?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## scene "), let n = Int(line.dropFirst(9).prefix { $0.isNumber }) {
                if let c = current { result.append((c.0, c.1.joined(separator: "\n"))) }
                current = (n, [])
            } else {
                current?.1.append(line)
            }
        }
        if let c = current { result.append((c.0, c.1.joined(separator: "\n"))) }
        return result
    }

    /// 「Element list at the moment of failure」の塊(`SnapshotRenderer.render` の書式)
    static func parseElements(_ block: String) -> (FTRect, [ElementInfo])? {
        guard let start = block.range(of: "Element list at the moment of failure") else { return nil }
        var screen: FTRect?
        var elements: [ElementInfo] = []
        let pattern = try! NSRegularExpression(
            pattern: #"^\[(\d+)\] (\S+)(?: "((?:[^"\\]|\\.)*)")?(.*) \((-?\d+),(-?\d+) (\d+)x(\d+)\)$"#)
        for raw in block[start.upperBound...].split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "</details>" { break }
            if line.hasPrefix("screen: ") {
                let dims = line.dropFirst(8).split(separator: " ").first?.split(separator: "x").compactMap { Double($0) } ?? []
                if dims.count == 2 { screen = FTRect(x: 0, y: 0, width: dims[0], height: dims[1]) }
                continue
            }
            let ns = line as NSString
            guard let m = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            func group(_ i: Int) -> String? {
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            let rest = group(4) ?? ""
            let id = rest.range(of: #"id=(\S+)"#, options: .regularExpression)
                .map { String(rest[$0].dropFirst(3)) }
            elements.append(ElementInfo(
                ref: Int(group(1)!)!, type: group(2)!, identifier: id, label: group(3), value: nil, placeholder: nil,
                enabled: true,
                frame: FTRect(x: Double(group(5)!)!, y: Double(group(6)!)!, width: Double(group(7)!)!,
                              height: Double(group(8)!)!),
                depth: 0))
        }
        guard let screen, !elements.isEmpty else { return nil }
        return (screen, elements)
    }
}
