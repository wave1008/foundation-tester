// waitForSettle の判定(純粋関数)。実行機(StepExecutor+WaitForSettle.swift)は呼んで写すだけ —— 判定を
// StepExecutor の static に置かない(判定の型が実行機に依存する)。
// 既定値は `WaitForSettleDefaults`、受け付け範囲・範囲の縮め方は `BridgeAPI` が定義元。

import Foundation

/// quietSeconds / waitSeconds の検査(デバイスに触る前に呼ぶ)
enum WaitForSettleArguments {

    /// 検証済みの実効値(ms)
    struct Plan: Equatable {
        let quietMs: Int
        let timeoutMs: Int
    }

    struct Violation: Error, Equatable {
        let message: String
    }

    /// 範囲は `BridgeAPI` が唯一の定義元で、ブリッジも同じ範囲で丸める。ms への換算は非有限・桁あふれを先に断る
    /// (`Int(_:)` は trap する)
    static func plan(quietSeconds: Double, waitSeconds: Double) -> Result<Plan, Violation> {
        func milliseconds(_ seconds: Double) -> Int? {
            guard seconds.isFinite, abs(seconds) < 1e6 else { return nil }
            return Int((seconds * 1000).rounded())
        }
        func rangeText(_ range: ClosedRange<Int>) -> String {
            "\(FTSeconds.format(Double(range.lowerBound) / 1000)) and \(FTSeconds.format(Double(range.upperBound) / 1000))"
        }
        let quietRange = BridgeAPI.waitForSettleQuietRangeMs
        let timeoutRange = BridgeAPI.waitForSettleTimeoutRangeMs
        guard let quietMs = milliseconds(quietSeconds), quietRange.contains(quietMs) else {
            return .failure(Violation(message:
                "waitForSettle: quietSeconds must be between \(rangeText(quietRange)) seconds"
                + " (got \(FTSeconds.format(quietSeconds)))"))
        }
        guard let timeoutMs = milliseconds(waitSeconds), timeoutRange.contains(timeoutMs) else {
            return .failure(Violation(message:
                "waitForSettle: waitSeconds must be between \(rangeText(timeoutRange)) seconds"
                + " (got \(FTSeconds.format(waitSeconds)))"))
        }
        return .success(Plan(quietMs: quietMs, timeoutMs: timeoutMs))
    }
}

/// 段2(木が追いついたか)の比較用の署名と、2枚の差の呼び名
enum TreeSyncSignature {

    /// 署名の1要素。key = 比較に使う文字列(型・id・ラベル・枠)。name = 失敗文言に出す呼び名
    struct Entry: Hashable {
        let key: String
        let name: String
    }

    /// 失敗文言に載せる要素名の上限(個)と、1つの名前の長さの上限(文字)。長い本文のラベルで報告を膨らませないため
    static let namesInMessage = 3
    static let nameLength = 40

    /// 範囲(nil = 画面)と交差する要素の署名。**範囲の外を見ない**: 画面外の行はラベルが取得のたびに揺れる
    /// (`StepExecutor.settledSignature` の doc)ので、全体の木を比べると静止した画面でも一致しない。
    /// value・enabled は入れない(見えるものの変化は段1が見ている。ここは枠と名前が追いついたかだけ)。
    /// 枠は誤差の丸めをしない(`settledSignature` と同じ完全一致)。順序に依らない(key で並べる)
    static func entries(_ snapshot: SnapshotResponse, region: FTRect?) -> [Entry] {
        let area = region ?? snapshot.screen
        return snapshot.elements.compactMap { element -> Entry? in
            guard ScrollGeometry.intersection(element.frame, area) != nil else { return nil }
            let frame = element.frame
            let key = "\(element.type)|\(element.identifier ?? "")|\(element.label ?? "")"
                + "|\(frame.x),\(frame.y),\(frame.width),\(frame.height)"
            return Entry(key: key, name: name(of: element))
        }
        .sorted { $0.key < $1.key }
    }

    /// 2枚の署名の差(片方にだけ、または個数が違う要素)の呼び名。新しい側を先に、重複は畳む
    static func difference(_ older: [Entry], _ newer: [Entry]) -> [String] {
        var balance: [String: Int] = [:]
        for entry in older { balance[entry.key, default: 0] += 1 }
        for entry in newer { balance[entry.key, default: 0] -= 1 }
        var names: [String] = []
        for entry in newer + older where balance[entry.key, default: 0] != 0 && !names.contains(entry.name) {
            names.append(entry.name)
        }
        return names
    }

    private static func name(of element: ElementInfo) -> String {
        let text: String
        if let id = element.identifier, !id.isEmpty {
            text = "#\(id)"
        } else if let label = element.label, !label.isEmpty {
            text = "\"\(label)\""
        } else {
            text = ".\(element.type)"
        }
        return String(text.prefix(nameLength))
    }
}
