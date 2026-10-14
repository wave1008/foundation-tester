// `fleetest services status` が出す「fleetest が作ったイメージ・名前付きボリュームの大きさ」の読み取り(純粋。実行は呼び手)。
// ランタイムごとの出力の形(実データで固定):
//   Docker: `image ls --format "{{.Repository}}:{{.Tag}}\t{{.Size}}"` = 1 行 1 イメージ・大きさは人向けの文字列("15.6MB")/
//           `system df -v --format "{{json .}}"` = 1 つの JSON で `Volumes: [{Name, Size: "3.146MB", …}]`
//   Apple:  `image ls --format json` = `[{configuration: {name: "<参照>", …}, variants: [{size: <bytes>, …}]}]` /
//           `volume inspect <名前>` = `[{configuration: {source: "<volume.img の実体パス>", sizeInBytes: <名目の上限>}}]`
//           (名目は 512 GiB のスパース = 実際の使用量はファイルの割り当て済みブロック。読むのは呼び手)
// ボリュームは消さない(`services reset` だけ)ので、大きくなっていることを人が見る口。

import Foundation

public enum RuntimeSizes {
    public struct ImageSize: Equatable, Sendable {
        public let reference: String
        /// 人向けの表記(Docker はランタイムの文字列のまま・Apple は `formatBytes`)
        public let size: String
        public init(reference: String, size: String) {
            self.reference = reference
            self.size = size
        }
    }

    /// fleetest が作ったイメージか: この接頭辞の build(`<接頭辞>-<service>:build`)と中継(`fleetest-relay:*`)。
    /// 宣言した公開イメージ(postgres:16 等)は他のワークスペースと共有なので数えない。
    public static func isFleetestImage(_ reference: String, prefix: String, relayRepository: String) -> Bool {
        reference.hasPrefix(prefix + "-") || reference == relayRepository || reference.hasPrefix(relayRepository + ":")
    }

    public static func dockerImageSizes(listOutput: String) -> [ImageSize] {
        listOutput.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return ImageSize(reference: parts[0], size: parts[1])
        }
    }

    /// `system df -v --format "{{json .}}"` の `Volumes` から 名前 → 大きさ(文字列)。
    public static func dockerVolumeSizes(dfJSON: String) -> [String: String] {
        guard let data = dfJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let volumes = object["Volumes"] as? [[String: Any]] else { return [:] }
        var sizes: [String: String] = [:]
        for volume in volumes {
            if let name = volume["Name"] as? String, let size = volume["Size"] as? String { sizes[name] = size }
        }
        return sizes
    }

    /// `image ls --format json` から (参照, バイト数)。バイト数は variants の size の和(複数アーキテクチャなら全部)。
    public static func appleImageSizes(listJSON: String) -> [(reference: String, bytes: Int64)] {
        guard let data = listJSON.data(using: .utf8),
              let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let configuration = item["configuration"] as? [String: Any],
                  let name = configuration["name"] as? String else { return nil }
            let variants = item["variants"] as? [[String: Any]] ?? []
            let bytes = variants.reduce(Int64(0)) { sum, variant in
                sum + ((variant["size"] as? NSNumber)?.int64Value ?? 0)
            }
            return (name, bytes)
        }
    }

    /// `volume inspect` から volume.img の実体パス。
    public static func appleVolumeSource(inspectJSON: String) -> String? {
        guard let data = inspectJSON.data(using: .utf8),
              let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              let configuration = items.first?["configuration"] as? [String: Any] else { return nil }
        return configuration["source"] as? String
    }

    /// SI(1000 進)で 1 桁。Docker の表記("15.6MB")に合わせて単位の前に空白を置かない。
    public static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "kB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        if index == 0 { return "\(bytes)B" }
        return String(format: "%.1f%@", value, units[index])
    }
}
