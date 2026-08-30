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
/// **事実(どれが欠けているか)は言い、手順は書かない**(手順は Xcode も macOS も版ごとに
/// 変わり、書いたものは必ず古くなる。事実を言わないと切り分けのたびに生ログを読むことになる)。
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
    /// アカウントはあるが、設定(developmentTeam)のチームのものが無い
    /// (2026-08-31 に M1Ultra で実測: チームを切り替えたのに config が旧チームのままだった)
    case noAccountForTeam
    /// 開発用証明書が失効/期限切れ
    case invalidCertificate
    /// その端末がチームに未登録。**登録(ポータル通信)は ssh からはできない** ——
    /// その Mac の GUI セッションで一度ビルドが要る(2026-08-31 に M1Ultra の iPhone snb で実測)
    case deviceNotRegistered
    /// provisioning profile が署名証明書を含まない(証明書を作り直した直後に出る。
    /// プロファイルの取り直しにはポータル通信 = GUI セッションが要る)
    case certificateNotInProfile
    /// その端末が provisioning profile に入っていない
    case deviceNotInProfile
    /// キーチェーンがロックされていて署名鍵に触れない。**ssh 越しのビルドで出る**
    /// (remote exec 経由の実機ビルド。2026-08-29 に M1Ultra で実測)
    case keychainLocked

    /// この問題の事実の1文(英語 = CLI の言語。拡張は raw 値から自分の言語で組み立て直す)
    var fact: String {
        switch self {
        case .noAccount: return "Xcode has no signed-in account"
        case .noAccountForTeam:
            return "Xcode has no account for the configured team (fleetest's developmentTeam)"
        case .invalidCertificate: return "the development certificate is revoked or expired"
        case .deviceNotRegistered: return "the device is not registered to the team"
        case .certificateNotInProfile:
            return "the provisioning profile does not include the signing certificate"
        case .deviceNotInProfile: return "the provisioning profile does not include this device"
        case .keychainLocked:
            return "the login keychain is not available (typical of builds started over ssh)"
        }
    }

    /// 直すのにポータル通信(端末登録・プロファイルの取り直し)が要るか。
    /// **ポータル通信は ssh からはできない**(アカウントセッションは GUI 限定)ので、
    /// これが1つでもあれば「GUI セッションで一度」の1行を添える
    var needsProvisioningUpdate: Bool {
        switch self {
        case .deviceNotRegistered, .certificateNotInProfile, .deviceNotInProfile: return true
        case .noAccount, .noAccountForTeam, .invalidCertificate, .keychainLocked: return false
        }
    }
}

public enum XcodeSigningDiagnosis {

    /// ログに現れた署名の問題(重複は畳み、上の宣言順で返す = 直す順序)。
    public static func problems(inBuildLog log: String) -> [XcodeSigningProblem] {
        // 部分一致でよい: xcodebuild はこれらを "<project>: error: <文>" の形で出す
        let signatures: [(XcodeSigningProblem, String)] = [
            (.noAccount, "No Accounts: Add a new account in Accounts settings"),
            (.noAccountForTeam, "No Account for Team"),
            (.invalidCertificate, "Signing certificate is invalid"),
            (.deviceNotRegistered, "isn't registered in your developer account"),
            (.certificateNotInProfile, "doesn't include signing certificate"),
            (.deviceNotInProfile, "doesn't include the currently selected device"),
            (.keychainLocked, "User interaction is not allowed"),
        ]
        return signatures.filter { log.contains($0.1) }.map(\.0)
    }

    /// 見出し + 事実(どれが欠けているか)+ 生ログの在り処。problems が空なら nil
    /// (呼び手は生の出力をそのまま出す)。
    ///
    /// **事実は言い、手順は書かない**(理由は XcodeSigningProblem の doc)。
    /// 例外は「ポータル通信は ssh からはできない」の1行 —— これは Xcode の手順ではなく
    /// このツールの実行経路(remote exec)の制約で、知らないと ssh から何度でも同じ失敗を繰り返す。
    /// **「この Mac」と書く** —— リモート機で走っていても、直すのは端末が繋がっている
    /// その機械の Xcode。手元とどちらの話かは呼び手(拡張)が機械名を添えて示す。
    public static func guidance(problems: [XcodeSigningProblem], fullLogPath: String?) -> String? {
        guard !problems.isEmpty else { return nil }
        var lines = [
            "Cannot code-sign the bridge runner for a physical device on this Mac."
                + " Fix Xcode's signing setup there, then start the bridge again.",
            "Detected: " + problems.map(\.fact).joined(separator: "; ") + ".",
        ]
        if problems.contains(where: \.needsProvisioningUpdate) {
            lines.append(
                "Registering a device or refreshing a profile talks to Apple's portal, which a build"
                + " started over ssh cannot do — run the bridge once from a GUI session on that Mac"
                + " (the first attempt may fail once right after registering; run it again).")
        }
        if let fullLogPath {
            lines.append("Full xcodebuild output: \(fullLogPath)")
        }
        return lines.joined(separator: "\n")
    }
}
