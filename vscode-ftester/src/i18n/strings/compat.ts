// 辞書。namespace: compat.
// 対象ソース: compatCheck.ts(起動時プレフライト。ftester CLI ↔ 拡張のプロトコル版照合)。
// キーは "compat." 始まり。ja は元の日本語と byte-identical(既存テスト互換)。
import type { MessageDict } from "../core";

export const compatStrings = {
  "compat.mismatch.cliOld": {
    ja: "ftester CLI が拡張より古い可能性があります(プロトコル {cli} < {ext})。ftester を再ビルドしてください(swift build または /ftester-update)。",
    en: "The ftester CLI may be older than the extension (protocol {cli} < {ext}). Rebuild ftester (swift build or /ftester-update).",
  },
  "compat.mismatch.extOld": {
    ja: "拡張が ftester CLI より古い可能性があります(プロトコル {ext} < {cli})。拡張を再インストールしてください(npm run install-local → Reload Window)。",
    en: "The extension may be older than the ftester CLI (protocol {ext} < {cli}). Reinstall the extension (npm run install-local, then Reload Window).",
  },
  "compat.mismatch.cliUnknown": {
    ja: "ftester CLI が古く互換情報(api version)を返しません。ftester を再ビルドしてください(swift build または /ftester-update)。",
    en: "The ftester CLI is too old to report compatibility (api version). Rebuild ftester (swift build or /ftester-update).",
  },
  "compat.check.spawnFailedLog": {
    ja: "[ftester] 互換性チェックの起動に失敗しました(未ビルドの可能性): {error}",
    en: "[ftester] Failed to launch the compatibility check (possibly not built): {error}",
  },
} satisfies MessageDict;
