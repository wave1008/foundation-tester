// XcodeSelection.swift
// ランナー機に複数の Xcode が入っているとき、発行側の Xcode に一致するものを自動選択する
// (docs/remote-runner.md §7)。選択は `DEVELOPER_DIR` の export(プロセス単位・sudo 不要)で行う
// —— `xcode-select -s` は機械全体に効き sudo が要るため使わない(共有ランナーで他利用者の run を壊す)。
// プロセス起動・ssh は置かない(呼び出し側 = Sources/fleetest/RemoteRunDispatcher.swift・
// Sources/fleetest/RemoteCommands.swift)。

import FTCore
import Foundation

public enum XcodeSelection {

    /// ランナー上に入っている Xcode 1本ぶん。`developerDir` は `path` からの算出値
    /// (存在確認はしない —— 誤りは後段の toolchain 照合が blocking で捕まえる)
    public struct Installed: Equatable, Sendable {
        public let productVersion: String   // "27.0"
        public let build: String            // "27A266a"
        public let path: String             // "/Applications/Xcode_27.app"

        public init(productVersion: String, build: String, path: String) {
            self.productVersion = productVersion
            self.build = build
            self.path = path
        }

        public var developerDir: String { path + "/Contents/Developer" }
    }

    public enum Outcome: Equatable, Sendable {
        /// 登録簿の pin(`RemoteHostEntry.developerDir`)から算出した `DEVELOPER_DIR`。
        /// **存在確認はしない**
        case pinned(String)
        /// 手元の指紋と一意に一致した候補から自動選択
        case selected(Installed)
        /// 候補ゼロ(列挙できなかった・`/Applications` に Xcode が無い) = `DEVELOPER_DIR` を
        /// 1バイトも足さない(ambient のまま)
        case ambient
        /// 一致0個・複数のどちらか。**手近な Xcode へ黙って倒さない**
        case refused(String)

        /// `.pinned`/`.selected` のときだけ non-nil。呼び出し側はこれを `export DEVELOPER_DIR=` に使う
        public var developerDir: String? {
            switch self {
            case .pinned(let dir): return dir
            case .selected(let installed): return installed.developerDir
            case .ambient, .refused: return nil
            }
        }
    }

    /// `/Applications` 直下の `Xcode*.app` を列挙して `<版>|<build>|<path>` を1行ずつ出す。
    /// **グロブをシェルに書かない**(相手は zsh。マッチ無しの `for w in <glob>` はシェルごと落ちる —
    /// CLAUDE.md の既知の罠)ので `find` で一覧を作る
    public static let listCommand = """
        find /Applications -maxdepth 1 -name "Xcode*.app" 2>/dev/null | while read -r app; do \
        v=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/version.plist" 2>/dev/null); \
        b=$(plutil -extract ProductBuildVersion raw "$app/Contents/version.plist" 2>/dev/null); \
        echo "$v|$b|$app"; done
        """

    /// `listCommand` の出力を解析する。壊れた行(区切りが3個でない・いずれかが空)・空行は落とす
    /// (1本読めれば十分。全滅は呼び出し側が空配列として ambient に倒す)
    public static func parse(_ output: String) -> [Installed] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> Installed? in
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            let version = parts[0].trimmingCharacters(in: .whitespaces)
            let build = parts[1].trimmingCharacters(in: .whitespaces)
            let path = parts[2].trimmingCharacters(in: .whitespaces)
            guard !version.isEmpty, !build.isEmpty, !path.isEmpty else { return nil }
            return Installed(productVersion: version, build: build, path: path)
        }
    }

    /// 選択規則(この順。`LocatorFingerprint` の「ちょうど1件一致のときだけ採用」と同じ規律):
    /// 1. `pin` があればそれが勝つ 2. build 番号までちょうど1つ一致すれば選ぶ
    /// 3. 製品版(`Xcode X.Y`)がちょうど1つ一致すれば選ぶ 4. 候補が空なら ambient(運用を止めない)
    /// 5. それ以外(一致0個・複数)は refused(候補一覧つき。手近な Xcode へ黙って倒さない)
    public static func resolve(localFingerprint: String?, installed: [Installed], pin: String?) -> Outcome {
        if let pin = pin?.trimmingCharacters(in: .whitespacesAndNewlines), !pin.isEmpty {
            return .pinned(developerDir(fromPinnedPath: pin))
        }
        guard !installed.isEmpty else { return .ambient }

        if let localBuild = localFingerprint.flatMap(ToolchainFingerprint.buildVersion(of:)) {
            let matches = installed.filter { $0.build == localBuild }
            if matches.count == 1 { return .selected(matches[0]) }
        }
        let versionMatches = localFingerprint.flatMap(ToolchainFingerprint.productVersion(of:))
            .map { version in installed.filter { $0.productVersion == version } } ?? []
        if versionMatches.count == 1 { return .selected(versionMatches[0]) }
        // **一致0個と一致複数で文言を分ける** —— 複数のときに「どれも一致しない」と言うと、
        // 利用者は Xcode を入れ直しに行く(正しい対処は pin)
        return .refused(versionMatches.isEmpty
            ? noMatchMessage(installed: installed)
            : ambiguousMessage(matching: versionMatches))
    }

    /// pin は `.app` バンドルのパス(利用者向けの案内・例: "/Applications/Xcode_27.app")で受け付ける
    /// —— 自動選択(`Installed.developerDir`)と同じ入力の形にそろえる。既に
    /// "/Contents/Developer" で終わっていればそのまま使う(DEVELOPER_DIR そのものを渡した場合の保険)。
    /// 末尾スラッシュは剥がしてから判定する
    static func developerDir(fromPinnedPath raw: String) -> String {
        var path = raw
        while path.hasSuffix("/") { path.removeLast() }
        return path.hasSuffix("/Contents/Developer") ? path : path + "/Contents/Developer"
    }

    /// 一致が1つも無い。**対処は「その製品版の Xcode を入れる」**(pin しても指紋照合で止まる)
    private static func noMatchMessage(installed: [Installed]) -> String {
        "could not tell which installed Xcode to dispatch with: none of the \(installed.count)"
            + " installed Xcode(s) matches this Mac's toolchain by build or product version"
            + " (installed: \(list(installed))) — install the matching Xcode on that runner"
            + " (docs/remote-runner.md §7)"
    }

    /// 同じ製品版が複数ある。**対処は pin**(どれを使うかはツールには決められない)
    private static func ambiguousMessage(matching: [Installed]) -> String {
        "could not tell which installed Xcode to dispatch with: \(matching.count) installed Xcodes"
            + " match this Mac's product version (matching: \(list(matching)))"
            + " — pin one for this machine with `fleetest remote machines add <name> --host <host>"
            + " --developer-dir <path>` (docs/remote-runner.md §7)"
    }

    private static func list(_ installed: [Installed]) -> String {
        installed
            .map { "Xcode \($0.productVersion) (build \($0.build)) at \($0.path)" }
            .joined(separator: ", ")
    }
}
