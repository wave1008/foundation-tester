// ダウンロード可能な Android システムイメージの一覧(Google のリポジトリ XML から)。
// 拡張の「デバイスを追加」ダイアログが、ホストに1つもシステムイメージが無いときに
// 「入れられる版」を出す/選んで入れるために使う(fleetest api device-catalog の
// android.downloadableSystemImages / fleetest api install-system-image)。
//
// リポジトリは CmdlineToolsInstaller と同じ Google の repository2 系 XML だが、
// タグ(google_apis / google_apis_playstore / default)ごとに別ファイルに分かれている。
// apiLevel/tag/abi は type-details の子要素ではなく remotePackage の path 属性
// ("system-images;android-<N>;<tag>;<abi>")から取る —— 16kb ページサイズ版のような
// 変種は type-details に <tag> 要素が複数載り(例: google_apis + page_size_16kb)、
// 組み合わせタグ("google_apis_ps16k")は path でしか一意に取れない。
// この package 文字列はインストール後のディレクトリ名ともそのまま対応するので、
// 既存の systemImages(sdkRoot:)(ディレクトリ走査)が作る package 文字列と直接突き合わせられる。

import Foundation
import FTCore

public enum SystemImageRepository {

    public struct Entry: Equatable {
        public let abi: String
        public let apiLevel: Int
        public let license: String?
        public let package: String
        public let sizeBytes: Int?
        public let tag: String
        public let versionName: String

        public init(abi: String, apiLevel: Int, license: String?, package: String,
                    sizeBytes: Int?, tag: String, versionName: String) {
            self.abi = abi
            self.apiLevel = apiLevel
            self.license = license
            self.package = package
            self.sizeBytes = sizeBytes
            self.tag = tag
            self.versionName = versionName
        }
    }

    public struct ParseError: LocalizedError, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// タグごとの XML(Google の実レイアウト)。1ファイル約200KB
    public struct Source: Equatable {
        public let label: String
        public let url: URL
        public init(label: String, url: URL) { self.label = label; self.url = url }
    }

    public static let sources: [Source] = [
        Source(label: "default", url: URL(
            string: "https://dl.google.com/android/repository/sys-img/android/sys-img2-3.xml")!),
        Source(label: "google_apis", url: URL(
            string: "https://dl.google.com/android/repository/sys-img/google_apis/sys-img2-3.xml")!),
        Source(label: "google_apis_playstore", url: URL(
            string: "https://dl.google.com/android/repository/sys-img/google_apis_playstore/sys-img2-3.xml")!),
    ]

    /// device-catalog が候補として出すタグ。ページサイズ違い等の合成タグ(例 "google_apis_ps16k")は
    /// 対象外 —— 候補に出すと avdmanager の models(id)に無い組み合わせを選べてしまう
    public static let allowedTags: Set<String> = ["google_apis", "google_apis_playstore", "default"]

    public static var hostABI: String {
        #if arch(arm64)
        return "arm64-v8a"
        #else
        return "x86_64"
        #endif
    }

    /// 3 XML それぞれの取得上限(秒)。各ファイル約200KBで、拡張のダイアログがこの応答を待つ。
    /// 尽きたらそのタグ分の一覧を空にし downloadableError に理由を残す
    /// (インストール済み一覧はディレクトリ走査だけなので影響を受けない)
    public static let fetchTimeoutSeconds: Double = 15

    // MARK: - 取得(不純)

    /// 3 タグの XML を並行取得しパースする。1つでも失敗したタグがあれば、取れたタグの分だけ
    /// entries に載せ error に理由を残す(全滅していない限り一覧を空にしない)
    public static func fetchDownloadable(
        installedPackages: Set<String>, hostABI: String = hostABI
    ) async -> (entries: [Entry], error: String?) {
        var entries: [Entry] = []
        var failures: [String] = []
        await withTaskGroup(of: (label: String, result: Result<[Entry], Error>).self) { group in
            for source in sources {
                group.addTask {
                    do {
                        let parsed = try await fetchOne(
                            source: source, installedPackages: installedPackages, hostABI: hostABI)
                        return (source.label, .success(parsed))
                    } catch {
                        return (source.label, .failure(error))
                    }
                }
            }
            for await outcome in group {
                switch outcome.result {
                case .success(let parsed):
                    entries.append(contentsOf: parsed)
                case .failure(let error):
                    failures.append("could not fetch the downloadable system image list "
                        + "(\(outcome.label)): \(describe(error))")
                }
            }
        }
        return (entries.sorted(by: sortsBefore), failures.isEmpty ? nil : failures.joined(separator: "; "))
    }

    private static func fetchOne(
        source: Source, installedPackages: Set<String>, hostABI: String
    ) async throws -> [Entry] {
        let request = URLRequest(url: source.url, timeoutInterval: fetchTimeoutSeconds)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ParseError("HTTP \(http.statusCode)")
        }
        return try parse(xml: data, installedPackages: installedPackages, hostABI: hostABI)
    }

    private static func describe(_ error: Error) -> String {
        (error as? ParseError)?.message ?? error.localizedDescription
    }

    // MARK: - パース(純粋)

    /// リポジトリ XML から、まだ入っていないダウンロード可能なイメージだけを返す。
    /// 個々の remotePackage の欠損(license/size 無し等)は該当欄を nil にするだけでスキップしない
    /// —— XML 全体が壊れていて解析できないときだけ throw する
    public static func parse(
        xml: Data, installedPackages: Set<String>, hostABI: String = hostABI
    ) throws -> [Entry] {
        let document: XMLDocument
        do {
            document = try XMLDocument(data: xml)
        } catch {
            throw ParseError("cannot parse the system image repository definition (XML): "
                + error.localizedDescription)
        }

        // stable の channel id は版で変わりうるので "channel-0" を決め打ちにせず本文から解決する。
        // 解決できなければ Google の慣例値のまま進める(取りこぼすより、後段のタグ/ABI/未導入判定で
        // 弾かれる方向に倒す方が安全)
        var stableChannelID = "channel-0"
        for case let channel as XMLElement in (try? document.nodes(forXPath: "//channel")) ?? [] {
            guard channel.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) == "stable",
                  let id = channel.attribute(forName: "id")?.stringValue else { continue }
            stableChannelID = id
            break
        }

        var entries: [Entry] = []
        for case let package as XMLElement in (try? document.nodes(forXPath: "//remotePackage")) ?? [] {
            guard let path = package.attribute(forName: "path")?.stringValue else { continue }
            // package(JSON の "package")は path をそのまま使う。分解して検証はするが再構成はしない
            // —— インストール済み一覧(ディレクトリ走査で同じ書式を作る)との突合の鍵を一致させるため
            let segments = path.components(separatedBy: ";")
            guard segments.count == 4, segments[0] == "system-images",
                  segments[1].hasPrefix("android-"),
                  let apiLevel = Int(segments[1].dropFirst("android-".count)) else { continue }
            let tag = segments[2]
            let abi = segments[3]
            guard allowedTags.contains(tag), abi == hostABI, !installedPackages.contains(path) else {
                continue
            }

            let channelRef = package.elements(forName: "channelRef").first?
                .attribute(forName: "ref")?.stringValue
            guard channelRef == stableChannelID else { continue }

            let license = package.elements(forName: "uses-license").first?
                .attribute(forName: "ref")?.stringValue
            let sizeBytes = package.elements(forName: "archives").first
                .flatMap { $0.elements(forName: "archive").first }
                .flatMap { $0.elements(forName: "complete").first }
                .flatMap { $0.elements(forName: "size").first }
                .flatMap { $0.stringValue }
                .flatMap { Int($0) }

            entries.append(Entry(
                abi: abi, apiLevel: apiLevel, license: license, package: path,
                sizeBytes: sizeBytes, tag: tag,
                versionName: MachineProfileEditor.androidVersionName(apiLevel: apiLevel)))
        }
        return entries
    }

    // MARK: - 整列

    /// インストール済みの systemImages と同じ並び順: apiLevel 降順 → tag 優先順
    /// (google_apis > google_apis_playstore > default) → 同一 tag 内は abi(arm64-v8a 優先)。
    /// ApiDeviceCatalogCommand.systemImageSortsBefore と同じ規則(型が別なので比較関数は2つ。
    /// tagRank はこちらを共有する。片方だけ変えない)
    public static func sortsBefore(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.apiLevel != rhs.apiLevel { return lhs.apiLevel > rhs.apiLevel }
        let lhsRank = tagRank(lhs.tag)
        let rhsRank = tagRank(rhs.tag)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        if lhs.tag != rhs.tag { return lhs.tag < rhs.tag }
        let lhsIsArm64 = lhs.abi == "arm64-v8a"
        let rhsIsArm64 = rhs.abi == "arm64-v8a"
        if lhsIsArm64 != rhsIsArm64 { return lhsIsArm64 }
        return lhs.abi < rhs.abi
    }

    public static func tagRank(_ tag: String) -> Int {
        switch tag {
        case "google_apis": return 0
        case "google_apis_playstore": return 1
        case "default": return 2
        default: return 3
        }
    }
}
