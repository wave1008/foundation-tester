// BridgeSourceSet.swift
// 3つのブリッジ実装それぞれの「これが変わったら別物」の入力集合と、その内容指紋。
//
// 用途は2つ:
//   1. BridgeContractTests が指紋を照合し、版数の引き上げ忘れ(実害2回)を検出する
//   2. InAppLauncher が dylib の再ビルド要否を判定する入力一覧として使う
// 一覧を2箇所に書くと必ずズレるため、定義はここ1箇所だけに置く。
//
// 各集合の出典(**片方だけ変えない**):
//   inApp    → InAppBridge/build.sh の SWIFT_SOURCES と clang 行
//   xcuitest → Runner/project.yml の FTesterRunnerUITests.sources
//   android  → AndroidRunner/build.sh の javac / aapt2 の入力

import CryptoKit
import Foundation

public enum BridgeSourceSet: String, CaseIterable, Sendable {
    case inApp
    case xcuitest
    case android

    /// 版数定数の在り処(失敗メッセージ用)
    public var versionConstantHint: String {
        switch self {
        case .inApp, .xcuitest:
            return "Sources/FTCore/BridgeDTO.swift の bridgeProtocolVersion"
        case .android:
            return "AndroidRunner/build.sh の VERSION_CODE と "
                + "Sources/FTAndroid/AndroidBridge.swift の expectedBridgeVersionCode"
        }
    }

    /// 個別に列挙するファイル(リポジトリルートからの相対パス)
    private var explicitFiles: [String] {
        switch self {
        case .inApp:
            return [
                "InAppBridge/build.sh",
                "Sources/FTCore/BridgeDTO.swift",
                "Sources/FTCore/WebViewDOMSnapshot.swift",
            ]
        case .xcuitest:
            // Runner/project.yml は含めない: UITests の設定はブリッジ挙動に効くが、同ファイルは
            // SampleApp / FTesterRunnerApp の都合でも編集されるためノイズが勝つ
            return ["Sources/FTCore/BridgeDTO.swift", "Sources/FTCore/SnapshotDedupe.swift",
                    "Sources/FTCore/TypeReadback.swift"]
        case .android:
            return ["AndroidRunner/build.sh", "AndroidRunner/AndroidManifest.xml"]
        }
    }

    /// 中身を丸ごと入力とみなすディレクトリ(相対パス, 対象拡張子)。拡張子 nil = 全ファイル
    private var sourceDirectory: (path: String, extensions: Set<String>?) {
        switch self {
        case .inApp:
            return ("InAppBridge/Sources", nil)
        case .xcuitest:
            return ("Runner/FTesterRunnerUITests", nil)
        case .android:
            return ("AndroidRunner/src/com/example/ftbridge", ["java"])
        }
    }

    /// 入力ファイルの相対パス一覧(ソート済み)。ディレクトリを読めない場合は throw
    public func files(repoRoot: URL) throws -> [String] {
        let (directory, extensions) = sourceDirectory
        let directoryURL = repoRoot.appendingPathComponent(directory)
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directoryURL, includingPropertiesForKeys: nil)
        } catch {
            throw BridgeSourceSetError.directoryUnreadable(directory, error.localizedDescription)
        }
        // ドットファイルは除く: .DS_Store が紛れ込むと「入力が増えた」として偽陽性で落ちる
        // (このリポジトリには実際 InAppBridge/.DS_Store・Runner/.DS_Store がある)
        let found = entries
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .filter { extensions?.contains($0.pathExtension) ?? true }
            .map { "\(directory)/\($0.lastPathComponent)" }
        return (explicitFiles + found).sorted()
    }

    /// 相対パス → 内容の SHA256(hex)。
    /// **生バイトで取る**(コメント除去はしない): 文字列リテラル中の `//` を素朴に削ると
    /// 変更を見逃す側に倒れるため、誤検出(コメント編集での再ピン)を選ぶ。
    /// 例外は android の build.sh で、VERSION_CODE 行だけマスクする(版を上げたこと自体で
    /// 指紋が動くと「ソースが変わった」信号が濁るため)。
    public func fingerprints(repoRoot: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for relativePath in try files(repoRoot: repoRoot) {
            let url = repoRoot.appendingPathComponent(relativePath)
            guard let data = FileManager.default.contents(atPath: url.path) else {
                throw BridgeSourceSetError.fileUnreadable(relativePath)
            }
            result[relativePath] = Self.hex(Self.normalize(data, relativePath: relativePath))
        }
        return result
    }

    /// AndroidRunner/build.sh の `VERSION_CODE=<n>` を固定文字列へ潰す。他ファイルは素通し
    private static func normalize(_ data: Data, relativePath: String) -> Data {
        guard relativePath == "AndroidRunner/build.sh",
              let text = String(data: data, encoding: .utf8) else { return data }
        let masked = text.replacingOccurrences(
            of: #"(?m)^VERSION_CODE=\d+$"#, with: "VERSION_CODE=<masked>",
            options: .regularExpression)
        return Data(masked.utf8)
    }

    private static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum BridgeSourceSetError: Error, CustomStringConvertible {
    case directoryUnreadable(String, String)
    case fileUnreadable(String)

    public var description: String {
        switch self {
        case .directoryUnreadable(let path, let reason):
            return "\(path) を列挙できません(\(reason))"
        case .fileUnreadable(let path):
            return "\(path) を読めません(BridgeSourceSet の一覧が実態とズレている可能性)"
        }
    }
}
