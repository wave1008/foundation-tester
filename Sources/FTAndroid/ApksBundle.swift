// Android App Bundle 由来の .apks(スプリット APK を束ねた zip)の取り扱い。
// 利用側: AndroidDriver.install(packagePath:) と installedPackageIsCurrent(packageID:apkPath:)。
//
// **インストールは bundletool へ委譲する**(スプリットの選別を自前でやらない)。選別の正は
// zip 内の `toc.pb`(variant / ABI / 密度 / 言語 / SDK の targeting)で、ファイル名からは決まらない —
// 実測(2026-08-19、79MB の実物): `splits/base-master.apk` と `splits/base-master_2.apk` の
// **2つの master** があり、bundletool が API 36 の端末へ入れたのは後者(variant 2)だった。
// 名前規約だけの選別は master を取り違え、入るが動かない組み合わせを作る。
//
// 差分判定は逆に bundletool を要らない: **端末に入っている各ファイルの md5 が .apks の
// エントリのどれかと一致するか**だけを見る(選別を再現しなくても「この .apks 由来か」は決まる)。

import CryptoKit
import Foundation
import FTCore

public enum ApksBundle {

    public static func isApks(path: String) -> Bool {
        path.lowercased().hasSuffix(".apks")
    }

    // MARK: - bundletool の解決

    /// 実行コマンド(argv の先頭部分)。`FT_BUNDLETOOL` は実行ファイルでも `.jar` でもよい
    /// (jar なら `java -jar`)。PATH に頼り切らず既知の場所も見るのは、ssh 越しの非対話シェルが
    /// /opt/homebrew を PATH に持たないため(RemoteShell.remoteRunCommand と同じ理由)。
    public static func findBundletool(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> [String]? {
        if let override = environment["FT_BUNDLETOOL"], !override.isEmpty {
            if override.lowercased().hasSuffix(".jar") { return ["java", "-jar", override] }
            return isExecutable(override) ? [override] : nil
        }
        let pathDirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in pathDirs + ["/opt/homebrew/bin", "/usr/local/bin"] where !dir.isEmpty {
            let candidate = dir.hasSuffix("/") ? dir + "bundletool" : dir + "/bundletool"
            if isExecutable(candidate) { return [candidate] }
        }
        return nil
    }

    /// `--adb` は必ず渡す: bundletool は adb を ANDROID_HOME か PATH からしか探さず、ssh 越しの
    /// 非対話シェル(~/.zshrc を読まない)では "Unable to determine the location of ADB" で落ちる。
    /// ツール側は AndroidDriver.findADB が既定パスも見て解決済みなので、それを渡せば
    /// ランナー機のシェル設定に依存しない(受け手の --host ディスパッチで実際に踏んだ)
    public static func installArgs(bundletool: [String], apksPath: String, serial: String?,
                                   adb: String) -> [String] {
        var args = bundletool + ["install-apks", "--apks=\(apksPath)", "--adb=\(adb)"]
        if let serial { args.append("--device-id=\(serial)") }
        return args
    }

    /// bundletool が見つからないときの説明。**やることを1行で言う**(受け手はここで詰まる)
    public static func missingBundletoolMessage(apksPath: String) -> String {
        "\(apksPath) is a split-APK bundle (.apks) and needs bundletool to install:"
            + " run `brew install bundletool`, or point FT_BUNDLETOOL at the executable or the"
            + " bundletool .jar. A single .apk needs none of this."
    }

    // MARK: - 差分判定

    public struct Entry: Equatable, Sendable {
        public let name: String
        public let size: Int

        public init(name: String, size: Int) {
            self.name = name
            self.size = size
        }
    }

    public struct InstalledFile: Equatable, Sendable {
        public let size: Int
        public let md5: String

        public init(size: Int, md5: String) {
            self.size = size
            self.md5 = md5
        }
    }

    /// 端末側で1発で撃つ(`pm path` の各行 → 大きさと md5)。分けて撃つと adb の往復が本数分増える
    public static func installedFilesScript(packageID: String) -> String {
        "for p in $(pm path \(packageID) | sed 's/^package://'); do"
            + " echo \"$(stat -c %s $p) $(md5sum $p | cut -d' ' -f1)\"; done"
    }

    /// installedFilesScript の出力。1行でも読めなければ nil(=判定不能。呼び手は再インストール側へ)
    public static func parseInstalledFiles(_ output: String) -> [InstalledFile]? {
        var files: [InstalledFile] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2, let size = Int(fields[0]), fields[1].count == 32 else { continue }
            files.append(InstalledFile(size: size, md5: String(fields[1]).lowercased()))
        }
        return files.isEmpty ? nil : files
    }

    /// `unzip -l` の一覧(先頭3行と末尾2行の飾りは無視。名前に空白があっても列位置で切らない)
    public static func parseZipListing(_ output: String) -> [Entry] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let size = Int(fields[0]) else { return nil }
            let name = fields[3].trimmingCharacters(in: .whitespaces)
            guard name.lowercased().hasSuffix(".apk") else { return nil }
            return Entry(name: name, size: size)
        }
    }

    /// 端末のファイルが全部この .apks 由来か。**大きさで候補を絞ってから md5 を取る** ——
    /// 一致し得ないエントリを展開しないため(実物は 88 エントリ・79MB。候補は1つずつになる)。
    /// hashOfEntry は entry 名 → md5(取れなければ nil)。
    /// 限界: 端末に**足りない** split は見つけられない(何が入るべきかは toc.pb の targeting =
    /// bundletool にしか決められない)。足りない側の取りこぼしは feature module の追加時のみ。
    public static func installedIsFromBundle(installed: [InstalledFile], entries: [Entry],
                                             hashOfEntry: (String) -> String?) -> Bool {
        guard !installed.isEmpty, !entries.isEmpty else { return false }
        var hashCache: [String: String] = [:]
        for file in installed {
            let candidates = entries.filter { $0.size == file.size }
            guard !candidates.isEmpty else { return false }
            var matched = false
            for candidate in candidates {
                let hash: String?
                if let cached = hashCache[candidate.name] {
                    hash = cached
                } else {
                    hash = hashOfEntry(candidate.name)
                    if let hash { hashCache[candidate.name] = hash }
                }
                if hash?.lowercased() == file.md5 { matched = true; break }
            }
            guard matched else { return false }
        }
        return true
    }

    /// zip の1エントリを展開して md5(展開先を作らずストリームで受ける)
    public static func entryMD5(apksPath: String, entry: String) -> String? {
        guard let (status, data) = try? Shell.runData(["unzip", "-p", apksPath, entry]),
              status == 0, !data.isEmpty else { return nil }
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func listEntries(apksPath: String) -> [Entry] {
        guard let result = try? Shell.run(["unzip", "-l", apksPath]), result.status == 0 else { return [] }
        return parseZipListing(result.output)
    }
}
