// XcodeSigningDiagnosis.swift
// **実機のブリッジが署名で建たないときに、xcodebuild の出力を「次にやること」へ畳む**。
//
// 実機のランナーはその機械でビルドして端末へ入れるので、Xcode の署名設定が要る
// (シミュレータは署名不要 —— だから「シミュレータは動くのに実機だけ建たない」が普通に起きる)。
// 失敗すると xcodebuild は数十行のビルドログを吐き、それがそのまま拡張のバナーへ流れていた:
// **読み手は何をすればいいのか分からない**(2026-08-29 の実害)。
//
// ここが持つのは2つ:
//   - **判定**(どの設定が欠けているか。ログの署名エラー行から拾う)
//   - **文言**(その設定を直す手順)。呼び手は1つ(BridgeLauncher)しかないので、
//     判定と文言を離して置く理由が無い。**呼び手が増えたら文言だけ呼び手側へ移す**
//     (CLAUDE.md「共有するのは判定であって文言ではない」)
//
// **当てはまらないログには触らない**(problems が空なら nil を返し、呼び手は生の出力を出す)。
// 畳んで良いのは「何をすればいいか言える」ときだけで、それ以外で生ログを捨てると
// 原因の分からない失敗になる。
//
// 純粋関数(I/O を持たない)。テストは Tests/FleetestTests/XcodeSigningDiagnosisTests.swift
// (**実際に踏んだビルドログ**を証人として持つ)。

import Foundation

/// 実機ビルドを止めている署名設定の欠け。**xcodebuild が実際に出す文言**から拾う
/// (Xcode が文言を変えたら拾えなくなる = 生ログへ落ちるだけで、誤った案内はしない)。
///
/// **画面の道順を書かない**(ユーザー決定 2026-08-29)。Xcode も iOS も版ごとに UI が変わり
/// (Xcode 26 で「Accounts」→「Apple Accounts」、証明書の管理もチームの下へ移った)、書いた
/// 道順は必ず古くなって「そんなメニューは無い」で詰まる。**何をするかだけを1行で書く**。
/// 証明書は**作り直しではなく失効ぶんの削除**: 自動署名(-allowProvisioningUpdates)は
/// 有効な証明書があればそれを使うが、失効した証明書が残っているとそちらを掴んで落ちる
/// (M1Ultra で実測: 有効なものと失効したものが両方あった)。
/// **プロジェクトの Signing & Capabilities では直せない** —— ランナーの .xcodeproj は xcodegen が
/// 生成し(BridgeLauncher.generateProjectIfNeeded)、ビルドのたびに DEVELOPMENT_TEAM を
/// コマンドラインで上書きする(codeSigningArguments)。**Team の正は fleetest の設定**
public enum XcodeSigningProblem: String, Sendable, CaseIterable {
    /// Xcode に Apple ID が1つも無い
    case noAccount
    /// 開発用証明書が失効/期限切れ
    case invalidCertificate
    /// その端末が provisioning profile に入っていない
    case deviceNotInProfile
    /// キーチェーンがロックされていて署名鍵に触れない。**ssh 越しのビルドで出る**
    /// (remote exec 経由の実機ビルド。2026-08-29 に M1Ultra で実測)
    case keychainLocked
}

public enum XcodeSigningDiagnosis {

    /// ログに現れた署名の問題(重複は畳み、上の宣言順で返す = 直す順序)。
    public static func problems(inBuildLog log: String) -> [XcodeSigningProblem] {
        // 部分一致でよい: xcodebuild はこれらを "<project>: error: <文>" の形で出す
        let signatures: [(XcodeSigningProblem, String)] = [
            (.noAccount, "No Accounts: Add a new account in Accounts settings"),
            (.invalidCertificate, "Signing certificate is invalid"),
            (.deviceNotInProfile, "doesn't include the currently selected device"),
            (.keychainLocked, "User interaction is not allowed"),
        ]
        return signatures.filter { log.contains($0.1) }.map(\.0)
    }

    /// 「次にやること」。problems が空なら nil(呼び手は生の出力をそのまま出す)。
    ///
    /// **1行目だけで用が足りるように書く**(2行目以降は手順)。**説明は書かない** ——
    /// 読み手が要るのは「何をすればいいか」だけで、状態の言い換え(「アカウントがありません」等)は
    /// 手順を読めば分かる(ユーザー決定 2026-08-29)。
    /// **「この Mac」と書く** —— リモート機で走っていても、直すのは端末が繋がっている
    /// その機械の Xcode。手元とどちらの話かは呼び手(拡張)が機械名を添えて示す。
    public static func guidance(problems: [XcodeSigningProblem], fullLogPath: String?) -> String? {
        guard !problems.isEmpty else { return nil }
        var lines = [
            "Cannot code-sign the bridge runner for a physical device on this Mac."
                + " Fix Xcode's signing setup there, then start the bridge again.",
        ]
        for (index, problem) in problems.enumerated() {
            lines.append("  \(index + 1). \(step(problem))")
        }
        if let fullLogPath {
            lines.append("Full xcodebuild output: \(fullLogPath)")
        }
        return lines.joined(separator: "\n")
    }

    private static func step(_ problem: XcodeSigningProblem) -> String {
        switch problem {
        case .noAccount:
            return "Add your Apple ID to Xcode"
                + " (its Team ID goes in developmentTeam in ~/.config/fleetest/config.json)."
        case .invalidCertificate:
            return "Delete the revoked Apple Development certificate from the keychain."
        case .deviceNotInProfile:
            return "Turn on Developer Mode on the device and connect it."
        case .keychainLocked:
            return "Unlock the login keychain (`security unlock-keychain`)."
        }
    }
}
