// RemoteHooksReap.swift
// **死んだ run が残した終了スクリプトを、発行者を跨いで代行実行する**1本のコマンド
// (docs/remote-runner.md §17・§18.1 #6)。
//
// 孤児が掴んでいるのは**ポート = ホスト全体の資源**(RunHooks.swift の doc)なので、他人の
// 死んだ run の残骸で自分の run が詰まる。発行者ネームスペース(§18.6)は work を分けるが、
// ポートは分けられない —— だから片付けだけは横断する。
//
// **1 ssh に収める**(発行者の数だけ往復を増やさない)。生存判定は各 work の中で
// `fleetest hooks reap` が pid だけで行う(mtime を見ない = RunHooks の規律)ので、
// **走っている run の hooks は触らない**。

import Foundation

public enum RemoteHooksReap {

    /// `<base>/users/*/work` と旧レイアウト `<base>/work` を順に回り、それぞれで
    /// `fleetest hooks reap` を撃つ1本の sh コマンド。
    /// - Package.swift が無いディレクトリは飛ばす(まだ setup していない発行者)
    /// - バイナリが無ければ何もしない(ランナー未整備。ここで落とさない)
    /// - PATH 補正は必須 —— 終了スクリプトは adb などを呼ぶ(RemoteShell.remoteRunCommand と同じ理由)
    /// - 失敗は無視する(`|| true`)。**片付けの失敗で run のディスパッチを止めない**
    public static func commandAcrossIssuers(layout: RemoteLayout, quiet: Bool) -> String {
        let binary = RemoteShell.quote(layout.binary)
        let args = quiet ? "'hooks' 'reap' '--quiet'" : "'hooks' 'reap'"
        // **グロブを使わない**。ssh の相手はログインシェル(macOS 既定は zsh)で、
        // **`for w in <マッチしないグロブ>` はシェルごと落とす**(`no matches found` で exit 1。
        // 後続の文も実行されない = まだ誰も setup していないランナーで旧 work の掃除まで消える。
        // 2026-08-31 に実機で確認)。find なら「1件も無い」が空の出力になるだけ。
        // **パスに空白は入らない**(RemoteLayout.validateBase / validateIssuerKey が入口で弾く)ので
        // コマンド置換の語分割で壊れない
        let users = RemoteShell.quote(layout.usersDir)
        let legacy = RemoteShell.quote(layout.base + "/work")
        let list = "$(find \(users) -mindepth 2 -maxdepth 2 -type d -name work 2>/dev/null) \(legacy)"
        return "for w in \(list); do [ -f \"$w/Package.swift\" ] || continue;"
            + " ( cd \"$w\" && export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\""
            + " && test -x \(binary) && \(binary) \(args) ) || true; done"
    }
}
