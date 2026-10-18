// `xcrun xctrace export --xpath '…/table[@schema="…"]'` の XML を行と列に直す純粋な読み手。
// 形式: 値は最初に現れた要素が `id="N"`(本文 = 生の値・属性 fmt = 表示用)を持ち、以後の同じ値は
// `ref="N"` だけの要素で参照される。`<sentinel/>` = null。行の直下の子が1列で、`<schema>` の `<col><mnemonic>` と同じ順に並ぶ。
// 入れ子の要素(複合値)の id も参照されうるので、入れ子の中の id も登録する。

import Foundation

public struct XctraceTable: Equatable, Sendable {
    public struct Cell: Equatable, Sendable {
        /// 要素の本文(前後の空白を除く)。複合値は子の本文を含まない
        public var raw: String
        public var fmt: String?
        public init(raw: String, fmt: String?) {
            self.raw = raw
            self.fmt = fmt
        }
    }

    public var columns: [String]
    /// 列の mnemonic → 値。null(sentinel)の列と、列の数を超えた余りは入れない
    public var rows: [[String: Cell]]

    public init(columns: [String], rows: [[String: Cell]]) {
        self.columns = columns
        self.rows = rows
    }

    /// 壊れた XML は nil(空の表と区別する = 読めなかったことを「行が無い」にしない)
    public static func parse(xml: Data) -> XctraceTable? {
        let parser = XMLParser(data: xml)
        let reader = Reader()
        parser.delegate = reader
        guard parser.parse(), !reader.failed else { return nil }
        return XctraceTable(columns: reader.columns, rows: reader.rows)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        struct Frame {
            var name: String
            var id: String?
            var fmt: String?
            var ref: String?
            var text = ""
        }

        var columns: [String] = []
        var rows: [[String: Cell]] = []
        var failed = false

        private var known: [String: Cell?] = [:]
        private var stack: [Frame] = []
        private var inRow = false
        private var cells: [Cell?] = []
        private var inCol = false
        private var mnemonicText: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if inRow {
                stack.append(Frame(name: elementName, id: attributeDict["id"], fmt: attributeDict["fmt"],
                                   ref: attributeDict["ref"]))
                return
            }
            switch elementName {
            case "schema": columns = []
            case "col": inCol = true
            case "mnemonic" where inCol: mnemonicText = ""
            case "row":
                inRow = true
                cells = []
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inRow {
                if !stack.isEmpty { stack[stack.count - 1].text += string }
            } else if mnemonicText != nil {
                mnemonicText! += string
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if inRow, stack.isEmpty, elementName == "row" {
                // 行の終わり(行の中の値の要素は全部閉じた後)。ここで確定しないと行が1つも残らない
                inRow = false
                var row: [String: Cell] = [:]
                for (index, cell) in cells.enumerated() where index < columns.count {
                    if let cell { row[columns[index]] = cell }
                }
                rows.append(row)
                return
            }
            if inRow {
                guard let frame = stack.popLast() else { return }
                let cell: Cell?
                if frame.name == "sentinel" {
                    cell = nil
                } else if let ref = frame.ref {
                    guard let resolved = known[ref] else {
                        // 参照先が先に現れていない = 読めない表。黙って null にしない
                        failed = true
                        parser.abortParsing()
                        return
                    }
                    cell = resolved
                } else {
                    cell = Cell(raw: frame.text.trimmingCharacters(in: .whitespacesAndNewlines), fmt: frame.fmt)
                }
                if let id = frame.id { known[id] = cell }
                if stack.isEmpty { cells.append(cell) }
                return
            }
            switch elementName {
            case "mnemonic":
                if let text = mnemonicText {
                    columns.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    mnemonicText = nil
                }
            case "col": inCol = false
            default: break
            }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { failed = true }
    }
}

/// `xctrace export --toc` から記録の長さ(秒)を読む。形が違えば nil(呼び手は表の最後の行で代用する)
public enum XctraceToc {
    public static func durationSeconds(xml: Data) -> Double? {
        let parser = XMLParser(data: xml)
        let reader = DurationReader()
        parser.delegate = reader
        _ = parser.parse()
        guard let text = reader.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Double(text), value.isFinite, value >= 0 else { return nil }
        return value
    }

    private final class DurationReader: NSObject, XMLParserDelegate {
        var first: String?
        private var collecting: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if elementName == "duration", first == nil { collecting = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { collecting? += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if elementName == "duration", let text = collecting {
                first = text
                collecting = nil
                parser.abortParsing()
            }
        }
    }
}
