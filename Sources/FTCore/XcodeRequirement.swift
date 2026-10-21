// 最低限の Xcode の版(唯一の定義元)。ブリッジの project.xcproj(JSON プロジェクト形式)は 27.2 未満の xcodebuild では開けない。
// 同じ判定を持つ bash 側 Scripts/preflight.sh・Scripts/install.sh と同期する(片方だけ変えない)。

import Foundation

public enum XcodeRequirement {
    public static let minimumMajor = 27
    public static let minimumMinor = 2

    public static var display: String { "Xcode \(minimumMajor).\(minimumMinor)" }

    /// `xcodebuild -version` の出力(1行目 `Xcode 27.2` / `Xcode 27.2.1`)が最低版以上か。読めなければ nil(❌ にしない)。
    public static func isSupported(versionOutput: String) -> Bool? {
        guard let line = versionOutput.split(separator: "\n").first else { return nil }
        let words = line.split(separator: " ")
        guard words.count >= 2, words[0] == "Xcode" else { return nil }
        let parts = words[1].split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        return (major, minor) >= (minimumMajor, minimumMinor)
    }
}
