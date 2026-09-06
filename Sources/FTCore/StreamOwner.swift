// StreamOwner.swift
// 画面配信の「所有者の印」。同じ台の配信を誰が持っているかを、監視(`api monitor`)が
// ヘルパーの環境から読み取るための鍵(判定は LocalStreamHolder)。
//
// 手元では `FT_PARENT_PID`(拡張ホストの pid)で足りるが、**ssh 越しには運べない** ——
// 向こうで `FT_PARENT_PID` を立てると ParentDeathWatch が実在しない pid の死を即座に検知して
// 子が終わる。さらに手元でも fan-out の子(`remote exec … api monitor`)は起こした側の
// `api monitor` の pid で `FT_PARENT_PID` を上書きされるので、拡張ホストの同一性は別の変数で運ぶ。
//
// 規律:
//   ① **拡張ホストが1回立てる**(`<hostname>:<pid>`。vscode-fleetest/src/childEnv.ts)。以後は
//      環境の継承で子孫へ届き、`RemoteShell` の run / exec が ssh 越しに export する
//   ② **読む側の優先順位は FT_STREAM_OWNER > FT_PARENT_PID > nil**。CLI から起こした
//      ヘルパー(印は FT_PARENT_PID だけ)も同じ規則で比較できる
//   ③ 値は同一性の比較にだけ使う(意味を読まない)

import Foundation

public enum StreamOwner {

    public static let environmentKey = "FT_STREAM_OWNER"

    /// 自分の所有者の印(規律②)
    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let explicit = environment[environmentKey], !explicit.isEmpty { return explicit }
        if let parent = environment[ParentDeathWatch.environmentKey], !parent.isEmpty { return parent }
        return nil
    }

    /// `ps -E` のトークン列(command の後ろに `KEY=VALUE` が並ぶ)から読む(規律②と同じ優先順位)
    public static func owner(inTokens tokens: [String]) -> String? {
        var parent: String?
        for token in tokens {
            if token.hasPrefix(environmentKey + "=") {
                let value = String(token.dropFirst(environmentKey.count + 1))
                if !value.isEmpty { return value }
            } else if token.hasPrefix(ParentDeathWatch.environmentKey + "="), parent == nil {
                let value = String(token.dropFirst(ParentDeathWatch.environmentKey.count + 1))
                if !value.isEmpty { parent = value }
            }
        }
        return parent
    }
}
