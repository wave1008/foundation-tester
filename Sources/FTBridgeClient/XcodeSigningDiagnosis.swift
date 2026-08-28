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
/// **この判定は「署名で止まった」と言い切るためだけに使う** —— 直し方は案内しない
/// (ユーザー決定 2026-08-29。Xcode も macOS も版ごとに手順が変わり、書いた手順は必ず古くなる)。
/// 種別を分けて持つのは、どれか1つでも当たれば畳んでよいと判断するため。
///
/// 直すときに要る知識(この案内には書かないが、忘れると調べ直しになる):
///   - 証明書は**作り直しではなく失効ぶんの削除**で足りることがある —— 自動署名
///     (-allowProvisioningUpdates)は有効な証明書があればそれを使うが、失効した証明書が
///     残っているとそちらを掴んで落ちる(M1Ultra で実測: 両方あった)
///   - **プロジェクトの Signing & Capabilities では直せない** —— ランナーの .xcodeproj は
///     xcodegen が生成し(generateProjectIfNeeded)、ビルドのたびに DEVELOPMENT_TEAM を
///     コマンドラインで上書きする(codeSigningArguments)。**Team の正は fleetest の設定**
///   - keychainLocked は **ssh 越しのビルド固有** —— GUI セッションでは出ない
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

    /// 「どこを直すか」と生ログの在り処。problems が空なら nil(呼び手は生の出力をそのまま出す)。
    ///
    /// **個別の手順は書かない**(ユーザー決定 2026-08-29)—— アカウント・証明書・端末登録・
    /// キーチェーンのどれも直し方が Xcode と macOS の版で変わり、書いた手順は必ず古くなる。
    /// **どこを見ればよいか(その Mac の Xcode の署名設定)と、生ログの在り処**だけを出し、
    /// 中身の判断は読み手に委ねる。**判定そのものは残す** —— 「署名で止まった」と言い切れる
    /// ときだけ畳み、当てはまらないログには触らないため(problems の呼び出し元を参照)。
    /// **「この Mac」と書く** —— リモート機で走っていても、直すのは端末が繋がっている
    /// その機械の Xcode。手元とどちらの話かは呼び手(拡張)が機械名を添えて示す。
    public static func guidance(problems: [XcodeSigningProblem], fullLogPath: String?) -> String? {
        guard !problems.isEmpty else { return nil }
        var lines = [
            "Cannot code-sign the bridge runner for a physical device on this Mac."
                + " Fix Xcode's signing setup there, then start the bridge again.",
        ]
        if let fullLogPath {
            lines.append("Full xcodebuild output: \(fullLogPath)")
        }
        return lines.joined(separator: "\n")
    }
}
