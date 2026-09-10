// iOS シミュレータのランタイムの指紋(`fleetest remote status` の RUNTIME 欄。手元と違えば ⚠️)。
//
// なぜ要るか: TOOLCHAIN(Xcode + SDK)が一致していても、**起動に使えるランタイムが無い**機械がある。
// 2026-09-10 実害: M1Max にベータ版の 24A5423a しか無く、正式版の macOS 27.0 + Xcode 27 RC ではこれで
// 起動できず、4台とも "runtime path not found" で落ちた。**simctl の一覧は isAvailable=true のまま**
// なので一覧からは使えないことが見えず、align の検証も ✅ で通した。
//
// **TOOLCHAIN の指紋(ToolchainFingerprint)には混ぜない** —— あちらはブリッジの成果物の建て直し
// 判定に使われ、ランタイムを足すとランタイムを入れ替えただけで全ランナーが建て直しになる。
// **警告だけ**(remote status の exit code・ディスパッチの適合判定には入れない)。
//
// 指紋 = SDK と同じ版の iOS ランタイムのビルド番号。**正式版があれば正式版だけ**を並べる ——
// 正式版とベータが同居していても起動に使われるのは正式版(実測 2026-09-10: ベータ4つ + 24A434 の
// 機械で、起動中の6台すべてが 24A434)。正式版が無ければベータを `(beta)` 付きで並べる。
// ベータの見分けはビルド番号の末尾が小文字であること(実物: 24A5423a / 23A5260l / 22A5346a)。
// 正式版は数字で終わる(24A434 / 22A3351 —— 4桁でも末尾が数字なら正式版)。

import Foundation

public enum SimulatorRuntimeFingerprint {

    /// ランナーでも同じ2つを撃つ(`RemoteStatusProbe.command`)。片方だけ変えない
    public static let sdkVersionCommand = "xcrun --sdk iphonesimulator --show-sdk-version"
    public static let runtimeListCommand = "xcrun simctl list runtimes"

    /// simctl の期限(秒)。simctl は CoreSimulatorService に XPC で訊くので、サービスが刺さると
    /// **返らない**(ssh 側の期限は ConnectTimeout だけで、remote status ごと止まる)。
    /// 根拠: 定常の所要は 0.4〜1 秒(2026-09-10 実測)。その10倍を超えたらサービスの詰まりと見なす。
    /// 尽きたら**不明**(欄は `-`・警告は鳴らない)—— 警告だけの欄なので短すぎても誤った赤は作らない
    public static let runtimeListTimeoutSeconds = 10

    /// ランナーで撃つ形。macOS に `timeout` は無いので perl の alarm を使う —— xcrun は exec で
    /// simctl に置き換わる(pid が同じ)ので、alarm は simctl 本体に届く(実測: 1 秒で exit 142)。
    /// perl が無い機械では失敗 → 空 → 不明
    public static var remoteRuntimeListCommand: String {
        "perl -e 'alarm shift; exec @ARGV' \(runtimeListTimeoutSeconds) \(runtimeListCommand)"
    }

    /// simctl の一覧の見出し。**これが無い出力は「答えなかった」**(期限切れ・Xcode 無し)であって
    /// 「ランタイムが1つも無い」ではない —— 取り違えると期限切れのたびに `none` = ⚠️ が鳴る
    static let runtimeListHeader = "== Runtimes =="

    /// `sdkVersion` = `--show-sdk-version` の出力("27.0")、`runtimeList` = `simctl list runtimes` の出力。
    /// SDK の版が読めない・一覧が答えていなければ nil(= 不明。比べない)
    public static func compose(sdkVersion: String, runtimeList: String) -> String? {
        let version = sdkVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, runtimeList.contains(runtimeListHeader) else { return nil }
        let builds = runtimeList.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard let entry = parse(String(line)), entry.version == version else { return nil }
            return entry.build
        }
        let releases = builds.filter { !isBeta(build: $0) }.sorted()
        let betas = builds.filter(isBeta(build:)).sorted()
        let shown: String
        if !releases.isEmpty {
            shown = releases.joined(separator: ", ")
        } else if !betas.isEmpty {
            shown = betas.joined(separator: ", ") + " (beta)"
        } else {
            shown = "none"
        }
        return "iOS \(version): \(shown)"
    }

    /// 手元の指紋(`remote status` 1回につき1度だけ呼ばれる)
    public static func current() -> String? {
        guard let sdk = run(sdkVersionCommand),
              let list = run(runtimeListCommand, timeout: Double(runtimeListTimeoutSeconds)) else { return nil }
        return compose(sdkVersion: sdk, runtimeList: list)
    }

    /// `iOS 27.0 (27.0 - 24A434) - com.apple.CoreSimulator.SimRuntime.iOS-27-0` の版とビルド。
    /// **版は括弧の外のラベルから採る** —— 括弧の中はポイントリリースの版で、SDK の版(常に major.minor)
    /// と一致しない(実物: `iOS 18.3 (18.3.1 - 22D8075)`。中を採ると SDK 18.3 に対して `none` になる)。
    /// 使えないと申告された行(`(unavailable, …)`)は数えない
    static func parse(_ line: String) -> (version: String, build: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("iOS "), !trimmed.contains("unavailable"),
              let open = trimmed.range(of: " ("),
              let close = trimmed[open.upperBound...].firstIndex(of: ")") else { return nil }
        let version = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<open.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        let parts = trimmed[open.upperBound..<close].components(separatedBy: " - ")
        guard parts.count == 2 else { return nil }
        let build = parts[1].trimmingCharacters(in: .whitespaces)
        guard !version.isEmpty, !build.isEmpty else { return nil }
        return (version, build)
    }

    static func isBeta(build: String) -> Bool {
        build.last.map { $0.isLowercase } ?? false
    }

    private static func run(_ command: String, timeout: Double? = nil) -> String? {
        guard let result = try? Shell.run(command.components(separatedBy: " "), timeout: timeout),
              result.status == 0 else {
            return nil
        }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }
}
