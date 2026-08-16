// StaleFrameDetector.swift
// 「木は変わったのに絵が前回とバイト同一 = 表示が凍結した古いフレームを返し続けている」の検知。
// 元は MCP(ft_screenshot)専用の実装だったが、DSL の occlusion-guard(FM 照合前のスクショ)にも
// 同じ穴があるため FTCore へ切り出し、両者で共有する(MCPServer+Driver.swift は転送、
// StepExecutor+Assert.swift の occlusionFlip が配線元)。

import Foundation

public enum StaleFrameDetector {
    /// 1回分の観測(画像ハッシュ×木指紋)。呼び出し側が次回比較用に保持する
    public struct Record: Equatable, Sendable {
        public let imageHash: Int
        public let treeFingerprint: Int

        public init(imageHash: Int, treeFingerprint: Int) {
            self.imageHash = imageHash
            self.treeFingerprint = treeFingerprint
        }
    }

    /// PNG 生バイトのハッシュ。**縮小前のバイト列**を渡すこと —— JPEG 再エンコードは決定的でない
    /// 可能性があるため、比較は常に生 PNG で行う
    public static func hashBytes(_ data: Data) -> Int {
        var hasher = Hasher()
        hasher.combine(data)
        return hasher.finalize()
    }

    /// 要素木の軽量指紋。要素数 + 各要素の (type, identifier, label, frame の整数丸め) を畳む。
    /// **ref は含めない**: MCP 層が snapshot ごとに ref へオフセットを掛けて世代管理するため、
    /// 同じ木でも取得経路(native のまま/セッション ref に振り直し済み)で番号が変わり得る。
    /// 含めると同じ木を「別物」と誤検知して鮮度警告が偽陽性になる。
    /// **単独では「木が安定したまま絵だけ古い」形を拾えない**(木を比べる方法の限界)。
    /// judge はこれを画像ハッシュとの併用で補う
    public static func treeFingerprint(of elements: [ElementInfo]) -> Int {
        var hasher = Hasher()
        hasher.combine(elements.count)
        for element in elements {
            hasher.combine(element.type)
            hasher.combine(element.identifier)
            hasher.combine(element.label)
            hasher.combine(Int(element.frame.x.rounded()))
            hasher.combine(Int(element.frame.y.rounded()))
            hasher.combine(Int(element.frame.width.rounded()))
            hasher.combine(Int(element.frame.height.rounded()))
        }
        return hasher.finalize()
    }

    /// 判定+記録更新を1関数に閉じる。isStale = previous があり、画像がバイト同一なのに
    /// 木指紋が変化したとき。**呼び出し側は返った record を必ず保存すること** —— ここで指紋を
    /// 新しい木へ更新するため、同じ凍結フレームへの注記は最初の1回だけになる(意図した設計。
    /// 記録を更新しない案は、静止画面の連写で木の自然な揺れを拾い偽陽性を積む)
    public static func judge(png: Data, elements: [ElementInfo],
                             previous: Record?) -> (record: Record, isStale: Bool) {
        let record = Record(imageHash: hashBytes(png), treeFingerprint: treeFingerprint(of: elements))
        let isStale = previous.map {
            $0.imageHash == record.imageHash && $0.treeFingerprint != record.treeFingerprint
        } ?? false
        return (record, isStale)
    }
}
