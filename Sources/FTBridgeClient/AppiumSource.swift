// AppiumDriver の WDA(/session/:id/source, iOS)・UiAutomator2(同, Android) XML パーサ。
// 方針は Runner/FTesterRunnerUITests/BridgeRouter.swift(iOS)・
// AndroidRunner/.../SnapshotBuilder.java(Android)のポリシーを XML 属性ベースに翻訳したもの
// (コードそのものの移植ではない)。

import Foundation
import FTCore

enum AppiumSourceParser {
    struct ParsedSource {
        var screen: FTRect
        var elements: [ElementInfo]
        var truncatedCount: Int
    }

    static func parseIOS(xml: String) -> ParsedSource {
        let parser = WDASourceParser()
        return parser.parse(xml: xml)
    }

    static func parseAndroid(xml: String) -> ParsedSource {
        let parser = UiAutomator2SourceParser()
        return parser.parse(xml: xml)
    }

    // MARK: - 共有ヘルパー

    static func shortTypeName(_ type: String) -> String {
        let prefix = "XCUIElementType"
        guard type.hasPrefix(prefix) else { return type }
        let stripped = String(type.dropFirst(prefix.count))
        return stripped.isEmpty ? type : stripped
    }

    static func parseFrame(_ attrs: [String: String]) -> FTRect {
        func d(_ key: String) -> Double {
            guard let raw = attrs[key], let value = Double(raw) else { return 0 }
            return value
        }
        return FTRect(x: d("x"), y: d("y"), width: d("width"), height: d("height"))
    }

    /// UiAutomator2 の "[x1,y1][x2,y2]" 形式
    static func parseAndroidBounds(_ raw: String) -> FTRect {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let parts = trimmed.components(separatedBy: "][")
        guard parts.count == 2 else { return FTRect(x: 0, y: 0, width: 0, height: 0) }
        let p1 = parts[0].components(separatedBy: ",")
        let p2 = parts[1].components(separatedBy: ",")
        guard p1.count == 2, p2.count == 2,
              let x1 = Double(p1[0]), let y1 = Double(p1[1]),
              let x2 = Double(p2[0]), let y2 = Double(p2[1]) else {
            return FTRect(x: 0, y: 0, width: 0, height: 0)
        }
        return FTRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

    static func boundingBox(_ frames: [FTRect]) -> FTRect {
        guard let first = frames.first else { return FTRect(x: 0, y: 0, width: 0, height: 0) }
        var minX = first.x, minY = first.y, maxX = first.x + first.width, maxY = first.y + first.height
        for f in frames.dropFirst() {
            minX = min(minX, f.x)
            minY = min(minY, f.y)
            maxX = max(maxX, f.x + f.width)
            maxY = max(maxY, f.y + f.height)
        }
        return FTRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// BridgeRouter.shouldInclude(iOS)の移植。要素集合が既存ブリッジと揃わないと
    /// 120件上限の切り捨て位置とセレクタ解決が変わり、公平比較にならない
    static let interactiveTypes: Set<String> = [
        "Button", "TextField", "SecureTextField", "TextView", "Switch", "Toggle", "Slider",
        "Cell", "Link", "SearchField", "SegmentedControl", "PickerWheel", "Stepper",
        "DatePicker", "CheckBox", "MenuItem",
    ]
    static let structuralTypes: Set<String> = ["NavigationBar", "TabBar", "Alert", "Sheet"]

    static func shouldIncludeIOS(type: String, identifier: String?, label: String?, value: String?,
                                 frame: FTRect, screen: FTRect?) -> Bool {
        if frame.width < 2 || frame.height < 2 { return false }
        if interactiveTypes.contains(type) { return true }
        if structuralTypes.contains(type) { return true }
        if type == "StaticText" || type == "Image" { return label != nil || value != nil }
        guard identifier != nil else { return false }
        if type == "Other", let screen, screen.width > 0, screen.height > 0,
           frame.width * frame.height > 0.85 * screen.width * screen.height {
            return false  // 巨大コンテナ除外(識別子付きでも)
        }
        return true
    }

    /// class 名の最終コンポーネントで判定。password 属性は UiAutomator2 が常に出すとは限らないため
    /// 存在すれば SecureTextField に倒すだけで、無くても TextField 側にフォールバックする
    static func mapAndroidType(className: String, clickable: Bool, attributes: [String: String]) -> String {
        let short = String(className.split(separator: ".").last ?? Substring(className))
        switch short {
        case "Button", "ImageButton", "MaterialButton": return "Button"
        case "EditText", "AutoCompleteTextView", "MultiAutoCompleteTextView":
            return attributes["password"] == "true" ? "SecureTextField" : "TextField"
        case "TextView", "CheckedTextView": return "StaticText"
        case "ImageView": return "Image"
        case "Switch", "SwitchCompat", "ToggleButton": return "Switch"
        case "CheckBox", "RadioButton": return "CheckBox"
        case "SeekBar": return "Slider"
        case "RecyclerView", "ListView", "GridView": return "CollectionView"
        case "ScrollView", "NestedScrollView", "HorizontalScrollView": return "ScrollView"
        case "WebView": return "WebView"
        default: return clickable ? "Cell" : "Other"
        }
    }
}

/// WDA /source(iOS)の XML → ElementInfo 変換。didStartElement で同期的に処理し、depth/exclusion は
/// 開いている要素ごとにスタックへ積んで didEndElement で降ろす(SAX なので木を作らず1パスで済ませる)。
private final class WDASourceParser: NSObject, XMLParserDelegate {
    private var elements: [ElementInfo] = []
    private var truncated = 0
    private var refCounter = 0
    private var depthCounter = 0
    /// 要素(type 属性あり)として depth をカウントしたら true。ラッパー要素(AppiumAUT 等)は false
    private var typeStack: [Bool] = []
    /// 自身またはいずれかの祖先が type=Keyboard によるサブツリー除外中なら true
    private var excludeStack: [Bool] = []
    private var screenRect: FTRect?
    private var allFrames: [FTRect] = []

    func parse(xml: String) -> AppiumSourceParser.ParsedSource {
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = self
        parser.parse()
        let screen = screenRect ?? AppiumSourceParser.boundingBox(allFrames)
        return .init(screen: screen, elements: elements, truncatedCount: truncated)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
               qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let type = attributeDict["type"]
        let parentExcluded = excludeStack.last ?? false
        // キーボードはサブツリーごと除外(4Kトークン対策。/type はキーイベント合成で行うため情報として不要)。
        // ここで探索自体は止めない(子要素の didStartElement は呼ばれ続ける)が、除外フラグが子へ伝播するため
        // 誰も elements に積まれない
        let excludedHere = parentExcluded || (type == "XCUIElementTypeKeyboard")
        excludeStack.append(excludedHere)

        let currentDepth = depthCounter
        let hasType = type != nil
        if hasType { depthCounter += 1 }
        typeStack.append(hasType)

        guard let type, !excludedHere else { return }

        let frame = AppiumSourceParser.parseFrame(attributeDict)
        if screenRect == nil && type == "XCUIElementTypeApplication" {
            screenRect = frame
        }

        let visible = attributeDict["visible"].map { $0 == "true" } ?? true
        guard visible else { return }
        allFrames.append(frame)

        let shortType = AppiumSourceParser.shortTypeName(type)
        let identifier = attributeDict["name"].flatMap { $0.isEmpty ? nil : $0 }
        let label = attributeDict["label"].flatMap { $0.isEmpty ? nil : $0 }
        let value = attributeDict["value"].flatMap { $0.isEmpty ? nil : $0 }
        guard AppiumSourceParser.shouldIncludeIOS(type: shortType, identifier: identifier,
                                                  label: label, value: value,
                                                  frame: frame, screen: screenRect) else { return }

        // 上限超過後も走査は続ける(切り捨て要素の子孫が含まれうるため。BridgeRouter.collect と同じ挙動)
        guard elements.count < BridgeAPI.maxSnapshotElements else {
            truncated += 1
            return
        }
        refCounter += 1
        elements.append(ElementInfo(
            ref: refCounter,
            type: shortType,
            identifier: identifier,
            label: label,
            value: value,
            placeholder: nil,
            enabled: attributeDict["enabled"] == "true",
            frame: frame,
            depth: currentDepth))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
               qualifiedName qName: String?) {
        excludeStack.removeLast()
        if typeStack.removeLast() { depthCounter -= 1 }
    }
}

/// UiAutomator2 /source(Android)の XML(<hierarchy><node>...</node></hierarchy>)→ ElementInfo 変換
private final class UiAutomator2SourceParser: NSObject, XMLParserDelegate {
    private var elements: [ElementInfo] = []
    private var truncated = 0
    private var refCounter = 0
    private var depthCounter = 0
    private var typeStack: [Bool] = []
    private var screenRect: FTRect?
    private var allFrames: [FTRect] = []
    private var sawFirstNode = false

    func parse(xml: String) -> AppiumSourceParser.ParsedSource {
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = self
        parser.parse()
        let screen = screenRect ?? AppiumSourceParser.boundingBox(allFrames)
        return .init(screen: screen, elements: elements, truncatedCount: truncated)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
               qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "node" else {
            typeStack.append(false)
            return
        }
        let currentDepth = depthCounter
        depthCounter += 1
        typeStack.append(true)

        let frame = AppiumSourceParser.parseAndroidBounds(attributeDict["bounds"] ?? "")
        if !sawFirstNode {
            screenRect = frame
            sawFirstNode = true
        }

        let displayed: Bool
        if let raw = attributeDict["displayed"] {
            displayed = raw == "true"
        } else if let raw = attributeDict["visible-to-user"] {
            displayed = raw == "true"
        } else {
            displayed = true
        }
        guard displayed else { return }
        allFrames.append(frame)

        let clickable = attributeDict["clickable"] == "true"
        let checkable = attributeDict["checkable"] == "true"
        let mappedType = AppiumSourceParser.mapAndroidType(
            className: attributeDict["class"] ?? "", clickable: clickable, attributes: attributeDict)

        // SnapshotBuilder.shouldInclude(Android)の移植(要素集合のパリティ維持)
        if frame.width < 2 || frame.height < 2 { return }
        if !clickable, let screen = screenRect, screen.width > 0, screen.height > 0,
           frame.width * frame.height > 0.85 * screen.width * screen.height { return }
        let resourceIdRaw = attributeDict["resource-id"] ?? ""
        let hasAnyText = !(attributeDict["text"] ?? "").isEmpty
            || !(attributeDict["content-desc"] ?? "").isEmpty || !resourceIdRaw.isEmpty
        let included: Bool
        if clickable || checkable {
            included = true
        } else {
            switch mappedType {
            case "TextField", "SecureTextField": included = true
            case "StaticText", "Image": included = hasAnyText
            default: included = !resourceIdRaw.isEmpty
            }
        }
        guard included else { return }

        guard elements.count < BridgeAPI.maxSnapshotElements else {
            truncated += 1
            return
        }

        let resourceId = attributeDict["resource-id"] ?? ""
        let identifier: String?
        if resourceId.isEmpty {
            identifier = nil
        } else if let range = resourceId.range(of: "id/") {
            identifier = String(resourceId[range.upperBound...])
        } else {
            identifier = resourceId
        }

        let text = attributeDict["text"].flatMap { $0.isEmpty ? nil : $0 }
        let contentDesc = attributeDict["content-desc"].flatMap { $0.isEmpty ? nil : $0 }
        var label: String?
        var value: String?
        if mappedType == "TextField" || mappedType == "SecureTextField" {
            value = text
            label = contentDesc
        } else {
            label = text ?? contentDesc
        }
        // checkable は text/content-desc ベースの value より優先(スイッチ/チェックボックスの状態表現)
        if attributeDict["checkable"] == "true" {
            value = attributeDict["checked"] == "true" ? "1" : "0"
        }

        refCounter += 1
        elements.append(ElementInfo(
            ref: refCounter,
            type: mappedType,
            identifier: identifier,
            label: label,
            value: value,
            placeholder: nil,
            enabled: attributeDict["enabled"] == "true",
            frame: frame,
            depth: currentDepth))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
               qualifiedName qName: String?) {
        if typeStack.removeLast() { depthCounter -= 1 }
    }
}
