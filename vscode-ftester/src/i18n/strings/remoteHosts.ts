// 辞書。namespace: remoteHosts.
// 対象ソース: remoteHostsMigration.ts(ftester.remote.hosts → CLI LocalConfig への1回移行。
// docs/remote-runner.md §13「原則」・§15.2)。キーは "remoteHosts." 始まり。
// ja は元の日本語と byte-identical(既存テスト互換)。
import type { MessageDict } from "../core";

export const remoteHostsStrings = {
  "remoteHosts.migration.done": {
    ja: "リモートホストの登録簿({count} 件)を CLI 側の設定(~/.config/ftester/config.json)へ移行しました。以後はモニターパネルの設定タブから登録・削除してください。",
    en: "Migrated the remote host registry ({count} entries) to the CLI's config (~/.config/ftester/config.json). Manage hosts from the Monitor panel's Settings tab from now on.",
  },
} satisfies MessageDict;
