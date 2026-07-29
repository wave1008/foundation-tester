// Android SDK Command-line Tools(avdmanager/sdkmanager)の導入。
//
// ブートストラップ問題: cmdline-tools を入れる sdkmanager 自体が cmdline-tools の中にあり、
// Android Studio.app にも同梱されていない。よって Google のリポジトリ XML から
// 当ホスト向けアーカイブを直接引いて $ANDROID_SDK/cmdline-tools/latest へ展開する
// (Studio の SDK Manager が置くのと同じ場所。以後 Studio 側からも導入済みに見える)。
//
// 配置先の規約は AndroidSDKLocator.findAVDManager() の探索順と対。片方だけ変えない。

import CryptoKit
import Foundation
import FTCore

public enum CmdlineToolsInstaller {

    public struct InstallError: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// sdkmanager が参照するのと同じ公開リポジトリ定義(cmdline-tools は channel-0/安定版のみ)
    public static let repositoryURL = URL(
        string: "https://dl.google.com/android/repository/repository2-3.xml")!

    /// XML の 1 <archive>。url はリポジトリ相対なので absoluteURL で絶対化して使う
    public struct Archive: Equatable {
        public let url: String
        public let sha1: String
        public let size: Int
        /// remotePackage の revision(例 "22.0")。表示専用
        public let revision: String

        public var absoluteURL: URL {
            URL(string: url, relativeTo: repositoryURL)?.absoluteURL
                ?? repositoryURL.deletingLastPathComponent().appendingPathComponent(url)
        }
    }

    /// 現ホストの host-arch 値(XML の表記に合わせる)。x86_64 macOS では "x64"
    public static var hostArch: String {
        #if arch(arm64)
        return "aarch64"
        #else
        return "x64"
        #endif
    }

    /// repository2-3.xml から `cmdline-tools;latest` の macosx アーカイブを選ぶ。
    /// host-arch 一致を優先し、無ければ host-arch を持たない古い形式(単一 mac アーカイブ)を使う。
    public static func selectArchive(xml: Data, hostArch: String = hostArch) throws -> Archive {
        let document: XMLDocument
        do {
            document = try XMLDocument(data: xml)
        } catch {
            throw InstallError("リポジトリ定義(XML)を解析できません: \(error.localizedDescription)")
        }
        guard let package = try document.nodes(
            forXPath: "//remotePackage[@path='cmdline-tools;latest']").first as? XMLElement else {
            throw InstallError("リポジトリ定義に cmdline-tools;latest がありません")
        }
        let revision = (package.elements(forName: "revision").first?.children ?? [])
            .compactMap { $0.stringValue }.joined(separator: ".")

        var fallback: Archive?
        for archive in package.elements(forName: "archives").flatMap({ $0.elements(forName: "archive") }) {
            guard text(archive, "host-os") == "macosx" else { continue }
            guard let complete = archive.elements(forName: "complete").first,
                  let url = text(complete, "url"),
                  let sha1 = complete.elements(forName: "checksum").first?.stringValue,
                  let size = Int(text(complete, "size") ?? "") else { continue }
            let candidate = Archive(url: url, sha1: sha1, size: size, revision: revision)
            switch text(archive, "host-arch") {
            case hostArch: return candidate
            case nil: fallback = candidate
            default: continue
            }
        }
        guard let fallback else {
            throw InstallError("cmdline-tools;latest に macOS(\(hostArch))向けアーカイブがありません")
        }
        return fallback
    }

    private static func text(_ element: XMLElement, _ name: String) -> String? {
        element.elements(forName: name).first?.stringValue
    }

    // MARK: - 導入

    public struct InstallResult {
        /// 既に入っていて何もしなかったなら true(ダウンロードは走らない)
        public let alreadyInstalled: Bool
        public let avdmanagerPath: String
        public let revision: String
    }

    /// $ANDROID_SDK/cmdline-tools/latest へ導入する。progress は人間向けの1行進捗
    /// (呼び出し側が stderr / OUTPUT へ流す)。既に avdmanager があれば何もしない。
    public static func install(progress: @escaping (String) -> Void) async throws -> InstallResult {
        guard let sdkRoot = AndroidSDKLocator.findSDKRoot() else {
            throw InstallError("Android SDK が見つかりません"
                + "(ANDROID_HOME / ANDROID_SDK_ROOT を確認してください)")
        }
        if let existing = AndroidSDKLocator.findAVDManager() {
            return InstallResult(alreadyInstalled: true, avdmanagerPath: existing.path, revision: "")
        }

        progress("==> リポジトリ定義を取得: \(repositoryURL.absoluteString)")
        let (xml, xmlResponse) = try await URLSession.shared.data(from: repositoryURL)
        try checkHTTP(xmlResponse, what: "リポジトリ定義")
        let archive = try selectArchive(xml: xml)
        progress("==> cmdline-tools \(archive.revision) "
            + "(\(archive.size / 1_048_576) MB): \(archive.absoluteURL.lastPathComponent)")

        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ftester-cmdline-tools-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let zip = work.appendingPathComponent("cmdline-tools.zip")
        try await download(archive: archive, to: zip, progress: progress)

        progress("==> sha1 を検証")
        try verifySHA1(of: zip, expected: archive.sha1)

        progress("==> 展開")
        let extracted = work.appendingPathComponent("extracted")
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path], what: "展開")
        // zip の最上位は "cmdline-tools/"(bin/ lib/ source.properties を含む)
        let payload = extracted.appendingPathComponent("cmdline-tools")
        guard FileManager.default.fileExists(atPath: payload.appendingPathComponent("bin").path) else {
            throw InstallError("展開結果に cmdline-tools/bin がありません(アーカイブ形式が変わった可能性)")
        }

        let destination = sdkRoot.appendingPathComponent("cmdline-tools/latest")
        progress("==> 配置: \(destination.path)")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // ここに来る = avdmanager が無い。壊れた latest が残っている場合だけ退避してから置き換える
        if FileManager.default.fileExists(atPath: destination.path) {
            let backup = destination.appendingPathExtension("broken")
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.moveItem(at: destination, to: backup)
            progress("    既存の latest を \(backup.lastPathComponent) へ退避しました")
        }
        try FileManager.default.moveItem(at: payload, to: destination)

        guard let avdmanager = AndroidSDKLocator.findAVDManager() else {
            throw InstallError("配置後も avdmanager を解決できません: \(destination.path)")
        }
        progress("==> 動作確認: avdmanager list device")
        try verifyAVDManager(at: avdmanager)
        return InstallResult(alreadyInstalled: false, avdmanagerPath: avdmanager.path,
                             revision: archive.revision)
    }

    /// 進捗を出しながらファイルへ落とす。URLSession.bytes の逐次 await は 156MB では遅すぎるため
    /// downloadTask + デリゲートを使う(進捗は 5% ごと = 20 行程度に間引く。OUTPUT を埋めないため)
    private static func download(
        archive: Archive, to destination: URL, progress: @escaping (String) -> Void
    ) async throws {
        let delegate = DownloadDelegate(total: archive.size, destination: destination,
                                        report: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await delegate.run(session: session, url: archive.absoluteURL)
        let written = (try? FileManager.default.attributesOfItem(atPath: destination.path))
            .flatMap { $0[.size] as? Int } ?? -1
        guard written == archive.size else {
            throw InstallError("ダウンロードが不完全です(\(written)/\(archive.size) バイト)")
        }
    }

    /// downloadTask の進捗通知と完了待ち。didFinishDownloadingTo の location はデリゲートから
    /// 戻ると消えるため、その場で移動しきる
    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        private let total: Int
        private let destination: URL
        private let report: (String) -> Void
        private var nextReport: Int
        private var continuation: CheckedContinuation<Void, Error>?
        private var moveError: Error?
        private var finished = false

        init(total: Int, destination: URL, report: @escaping (String) -> Void) {
            self.total = total
            self.destination = destination
            self.report = report
            self.nextReport = max(total / 20, 1)
        }

        func run(session: URLSession, url: URL) async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                continuation = cont
                session.downloadTask(with: url).resume()
            }
        }

        /// 成功系(didFinishDownloadingTo → didCompleteWithError(nil))で2回呼ばれるので1回に潰す
        private func finish(_ result: Result<Void, Error>) {
            guard !finished else { return }
            finished = true
            continuation?.resume(with: result)
            continuation = nil
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard total > 0, totalBytesWritten >= Int64(nextReport) else { return }
            report("    \(Int(totalBytesWritten) * 100 / total)% "
                + "(\(Int(totalBytesWritten) / 1_048_576)/\(total / 1_048_576) MB)")
            nextReport += max(total / 20, 1)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            if let response = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                moveError = InstallError("アーカイブの取得に失敗しました(HTTP \(response.statusCode))")
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                moveError = error
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                finish(.failure(error))
            } else if let moveError {
                finish(.failure(moveError))
            } else {
                finish(.success(()))
            }
        }
    }

    private static func verifySHA1(of file: URL, expected: String) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw InstallError("sha1 が一致しません(期待 \(expected) / 実際 \(actual))")
        }
    }

    /// 導入直後に1回だけ実際に動かす。avdmanager は java を要求するため、
    /// 「置けたが動かない」を導入成功として返さない
    private static func verifyAVDManager(at avdmanager: URL) throws {
        let result = try Shell.run([avdmanager.path, "list", "device"])
        guard result.status == 0 else {
            let java = (try? Shell.run(["/usr/bin/which", "java"]))?.status == 0
            throw InstallError("avdmanager を実行できません: \(result.tail)"
                + (java ? "" : "(java が PATH にありません。JDK を導入してください)"))
        }
    }

    private static func checkHTTP(_ response: URLResponse, what: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw InstallError("\(what)の取得に失敗しました(HTTP \(http.statusCode))")
        }
    }

    private static func run(_ path: String, _ arguments: [String], what: String) throws {
        let result = try Shell.run([path] + arguments)
        guard result.status == 0 else {
            throw InstallError("\(what)に失敗しました: \(result.tail)")
        }
    }
}
