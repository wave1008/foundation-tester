// JUnitMerge.swift
// `fleetest run --fleet <name> --junit <path>` が、各エントリ(子プロセス)が別々に書いた
// JUnit XML を1本へ結合するための純粋ロジック。呼び手(Sources/fleetest/FleetRunner.swift)は
// エントリごとの一時ファイルを読んでここへ渡すだけで、ファイル I/O やプロセス起動は持たない。
//
// 入力の xml は `JUnitReportWriter.xml` が書いた形(<testsuites> > <testsuite> > <testcase>)を
// 前提とする。<testsuite> の属性はそのまま転記し(既存の属性は保つ)、hostname だけを足す。
// <testsuites> の集計(tests/failures/skipped/time)は、その転記した <testsuite> 属性を
// 結合後に数え直す(取りこぼしがあれば合計に反映される。エントリ自身が書いた外側の合計は信用しない)。

import Foundation

public enum JUnitMerge {

    /// project = testsuites の name(集約後のプロジェクト名)。host = フリートエントリ名
    /// (--host に渡す名前。"local" も含む)。xml = そのエントリの --junit 出力(nil = 出力が無かった)
    public struct Entry {
        public let host: String
        public let xml: String?
        public init(host: String, xml: String?) {
            self.host = host
            self.xml = xml
        }
    }

    /// 壊れた XML(整形不正・想定外のルート・testsuite に必須属性が無い)は握りつぶさず、
    /// どのホストのものかを名指しして throw する
    public enum MergeError: Error, LocalizedError, Equatable {
        case invalidXML(host: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case let .invalidXML(host, reason):
                return "fleet entry \"\(host)\": invalid JUnit XML (\(reason))"
            }
        }
    }

    /// **エントリ単位の問題では throw しない**。出力が無い/壊れているエントリは合成した
    /// 失敗にして**結合結果に必ず残す**。throw して1件も書かないと、CI からは
    /// 「JUnit が無い」= 設定次第で緑にも見える —— **赤いテストが1件あるほうが確実に伝わる**
    /// (壊れた XML を黙って捨てないという目的は、失敗として残すことで満たす)
    public static func merge(_ entries: [Entry], project: String) -> String {
        var blocks: [String] = []
        var totals = Totals()
        for entry in entries {
            guard let xml = entry.xml, !xml.isEmpty else {
                let (block, entryTotals) = syntheticFailureSuite(
                    host: entry.host, name: "fleet-entry-missing",
                    message: "entry \"\(entry.host)\" produced no JUnit report")
                blocks.append(block)
                totals.add(entryTotals)
                continue
            }
            do {
                let (entryBlocks, entryTotals) = try suites(fromXML: xml, host: entry.host)
                blocks += entryBlocks
                totals.add(entryTotals)
            } catch {
                let (block, entryTotals) = syntheticFailureSuite(
                    host: entry.host, name: "fleet-entry-unreadable",
                    message: (error as? MergeError)?.errorDescription ?? "\(error)")
                blocks.append(block)
                totals.add(entryTotals)
            }
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuites name="\(JUnitReportWriter.escape(project))" tests="\(totals.tests)" failures="\(totals.failures)"\
         errors="0" skipped="\(totals.skipped)" time="\(seconds(totals.totalMs))">
        \(blocks.joined(separator: "\n"))
        </testsuites>
        """ + "\n"
    }

    // MARK: - 1エントリぶんの <testsuite> 抽出

    private static func suites(fromXML xml: String, host: String) throws -> ([String], Totals) {
        let doc: XMLDocument
        do {
            doc = try XMLDocument(data: Data(xml.utf8), options: [])
        } catch {
            throw MergeError.invalidXML(host: host, reason: "not well-formed XML (\(error.localizedDescription))")
        }
        guard let root = doc.rootElement() else {
            throw MergeError.invalidXML(host: host, reason: "document has no root element")
        }
        let suiteElements: [XMLElement]
        switch root.name ?? "" {
        case "testsuites":
            suiteElements = (root.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.name == "testsuite" }
        case "testsuite":
            suiteElements = [root]
        default:
            throw MergeError.invalidXML(
                host: host, reason: "root element is <\(root.name ?? "?")>, expected <testsuites>")
        }

        var blocks: [String] = []
        var totals = Totals()
        for suite in suiteElements {
            totals.add(try totalsFromAttributes(of: suite, host: host))
            // hostname を末尾に足す(既存の属性・並びはそのまま = suite.attributes の順序を保持)
            suite.removeAttribute(forName: "hostname")
            let hostnameAttr = XMLNode(kind: .attribute)
            hostnameAttr.name = "hostname"
            hostnameAttr.stringValue = host
            suite.addAttribute(hostnameAttr)
            blocks.append(serialize(suite, indent: "  "))
        }
        return (blocks, totals)
    }

    /// <testsuite> 自身の tests/failures/skipped/time 属性を数値化するだけ(値は書き換えない。
    /// 結合後の外側合計にだけ使う)。必須属性の欠落・非数値は壊れた XML として throw する
    private static func totalsFromAttributes(of suite: XMLElement, host: String) throws -> Totals {
        func attr(_ name: String) throws -> String {
            guard let value = suite.attribute(forName: name)?.stringValue else {
                throw MergeError.invalidXML(host: host, reason: "<testsuite> is missing the \"\(name)\" attribute")
            }
            return value
        }
        guard let tests = Int(try attr("tests")) else {
            throw MergeError.invalidXML(host: host, reason: "<testsuite> \"tests\" attribute is not an integer")
        }
        guard let failures = Int(try attr("failures")) else {
            throw MergeError.invalidXML(host: host, reason: "<testsuite> \"failures\" attribute is not an integer")
        }
        guard let skipped = Int(try attr("skipped")) else {
            throw MergeError.invalidXML(host: host, reason: "<testsuite> \"skipped\" attribute is not an integer")
        }
        guard let time = Double(try attr("time")) else {
            throw MergeError.invalidXML(host: host, reason: "<testsuite> \"time\" attribute is not a number")
        }
        return Totals(tests: tests, failures: failures, skipped: skipped, totalMs: Int((time * 1000).rounded()))
    }

    /// エントリが --junit を書かなかった(プロセスが落ちた・出力が空)場合の合成失敗。
    /// 黙って省くと CI からは「そのホストのぶんは全部通った」に見えるため、必ず1件の失敗として入れる
    /// 出力が無い/読めないエントリを**失敗1件のスイート**にする。省いてはいけない ——
    /// 省くと CI からは「そのホストのぶんは全部通った」に見える
    private static func syntheticFailureSuite(host: String, name: String,
                                              message: String) -> (String, Totals) {
        let escapedHost = JUnitReportWriter.escape(host)
        let escapedMessage = JUnitReportWriter.escape(message)
        let block = """
          <testsuite name="\(name)" tests="1" failures="1" errors="0" skipped="0" time="0.000" hostname="\(escapedHost)">
            <testcase classname="\(name)" name="\(escapedHost)" time="0.000">
              <failure message="\(escapedMessage)">\(escapedMessage)</failure>
            </testcase>
          </testsuite>
        """
        return (block, Totals(tests: 1, failures: 1, skipped: 0, totalMs: 0))
    }

    // MARK: - 汎用の再シリアライズ(JUnitReportWriter.xml と同じインデント規則: 要素1段=2スペース)

    /// XMLElement をそのまま `.xmlString` で出すと Foundation 独自の書式(entity 表記・
    /// インデント無し)になり JUnitReportWriter.xml と体裁が揃わないため、手書きで再構築する。
    /// 属性値・テキストは JUnitReportWriter.escape で再エスケープする(XMLNode.stringValue は
    /// 常にデコード済みの値を返すので、これで元と同じ表記に戻る)
    private static func serialize(_ element: XMLElement, indent: String) -> String {
        let attrText = (element.attributes ?? [])
            .map { "\($0.name ?? "")=\"\(JUnitReportWriter.escape($0.stringValue ?? ""))\"" }
            .joined(separator: " ")
        let tag = element.name ?? ""
        let openTag = attrText.isEmpty ? "<\(tag)>" : "<\(tag) \(attrText)>"
        let selfClosed = attrText.isEmpty ? "<\(tag)/>" : "<\(tag) \(attrText)/>"

        let children = element.children ?? []
        guard !children.isEmpty else {
            return indent + selfClosed
        }
        if children.count == 1, children[0].kind == .text {
            let text = children[0].stringValue ?? ""
            return indent + openTag + JUnitReportWriter.escape(text) + "</\(tag)>"
        }
        var lines = [indent + openTag]
        for child in children {
            if let el = child as? XMLElement {
                lines.append(serialize(el, indent: indent + "  "))
            } else if child.kind == .text, let text = child.stringValue,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(indent + "  " + JUnitReportWriter.escape(text))
            }
        }
        lines.append(indent + "</\(tag)>")
        return lines.joined(separator: "\n")
    }

    private struct Totals {
        var tests = 0
        var failures = 0
        var skipped = 0
        var totalMs = 0

        init() {}
        init(tests: Int, failures: Int, skipped: Int, totalMs: Int) {
            self.tests = tests
            self.failures = failures
            self.skipped = skipped
            self.totalMs = totalMs
        }
        mutating func add(_ other: Totals) {
            tests += other.tests
            failures += other.failures
            skipped += other.skipped
            totalMs += other.totalMs
        }
    }

    private static func seconds(_ ms: Int) -> String {
        String(format: "%.3f", Double(ms) / 1000)
    }
}
