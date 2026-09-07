// occlusion-guard Tier-2(Vision OCR)の計測用コーパス書き出し。`measure` モードのときだけ、
// OCR が読んだ内容と FM の判定を並べて記録し、OCR を素通りゲートへ昇格させてよいか(可視側の
// 見逃しを作らないか)を後から確かめられるようにする。run の成否には影響させない
// (書き出しの失敗は握りつぶす)。

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum OcclusionCorpusDump {
    public struct Entry: Sendable, Codable {
        public let expectedText: String
        /// "geo"(幾何疑いで FM 直行) / "ink"(低インクで Tier-1 を通過)
        public let tier: String
        /// Tier-1 で計算済みなら再利用。幾何疑い(tier="geo")の回は未計算のため nil
        public let inkStdDev: Double?
        public let ocrLines: [String]
        public let ocrReadable: Bool
        public let ocrMs: Double
        /// FM が判定を返さなかった回は nil(訊いたのに答えが無い、と区別する)
        public let fmVisible: Bool?
        public let fmState: String?
        public let fmObserved: String?

        public init(expectedText: String, tier: String, inkStdDev: Double?, ocrLines: [String],
                    ocrReadable: Bool, ocrMs: Double, fmVisible: Bool?, fmState: String?,
                    fmObserved: String?) {
            self.expectedText = expectedText
            self.tier = tier
            self.inkStdDev = inkStdDev
            self.ocrLines = ocrLines
            self.ocrReadable = ocrReadable
            self.ocrMs = ocrMs
            self.fmVisible = fmVisible
            self.fmState = fmState
            self.fmObserved = fmObserved
        }
    }

    /// `<stamp>.png`(FM に渡したものと同じ crop。`OcclusionCrop.rect` で切る)+ `<stamp>.json`
    /// を書く。**書くのは `measure` のときだけ** —— 既定(on)で書くと、ガードが撃たれるたびに
    /// PNG を1枚落として run を遅くする。失敗は握りつぶす。
    public static func write(pngData: Data, frame: FTRect, screen: FTRect, cropPadding: CGFloat = 24,
                             entry: Entry,
                             environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard RegionText.mode(environment: environment) == .measure else { return }
        guard let dir = directory(environment: environment) else { return }
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        guard let rect = OcclusionCrop.rect(frame: frame, screen: screen, imageWidth: full.width,
                                            imageHeight: full.height, cropPadding: cropPadding),
              let crop = full.cropping(to: rect) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        pruneOldDumps(in: dir)

        let stamp = Self.stamp()
        let pngURL = dir.appendingPathComponent("\(Self.filePrefix)\(stamp).png")
        guard let dst = CGImageDestinationCreateWithURL(
            pngURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dst, crop, nil)
        guard CGImageDestinationFinalize(dst) else { return }

        guard let json = try? JSONEncoder().encode(entry) else { return }
        try? json.write(to: dir.appendingPathComponent("\(Self.filePrefix)\(stamp).json"))
    }

    /// 自分が書いたファイルの目印。**掃除はこの接頭辞のものだけ**を対象にする
    /// (置き場を環境変数で差し替えられるので、他人のファイルを消さないため)
    static let filePrefix = "crop-"

    private static func directory(environment: [String: String]) -> URL? {
        if let dir = environment["FT_OCCLUSION_CORPUS_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/fleetest/occlusion-corpus")
    }

    private static func stamp() -> String {
        // **pid を入れる** —— 並列レーンは別プロセスで同じミリ秒に書き得る。時刻だけだと
        // 片方の PNG ともう片方の JSON が対になり、コーパスが静かに嘘をつく
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let time = fmt.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return "\(time)-\(getpid())"
    }

    private static func pruneOldDumps(in dir: URL) {
        DumpRetention.prune(in: dir, prefix: filePrefix, extensions: ["png", "json"])
    }
}
