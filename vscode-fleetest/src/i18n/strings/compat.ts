// 辞書。namespace: compat.
// 対象ソース: compatCheck.ts(起動時プレフライト。fleetest CLI ↔ 拡張のプロトコル版照合)。
// キーは "compat." 始まり。ja は元の日本語と byte-identical(既存テスト互換)。
import type { MessageDict } from "../core";

export const compatStrings = {
  "compat.mismatch.cliOld": {
    ja: "fleetest CLI が拡張より古い可能性があります(プロトコル {cli} < {ext})。fleetest を再ビルドしてください(swift build または /fleetest-update)。",
    en: "The fleetest CLI may be older than the extension (protocol {cli} < {ext}). Rebuild fleetest (swift build or /fleetest-update).",
  },
  "compat.mismatch.extOld": {
    ja: "拡張が fleetest CLI より古い可能性があります(プロトコル {ext} < {cli})。拡張を再インストールしてください(npm run install-local → Reload Window)。",
    en: "The extension may be older than the fleetest CLI (protocol {ext} < {cli}). Reinstall the extension (npm run install-local, then Reload Window).",
  },
  "compat.mismatch.cliUnknown": {
    ja: "fleetest CLI が古く互換情報(api version)を返しません。fleetest を再ビルドしてください(swift build または /fleetest-update)。",
    en: "The fleetest CLI is too old to report compatibility (api version). Rebuild fleetest (swift build or /fleetest-update).",
  },
  "compat.check.spawnFailedLog": {
    ja: "[fleetest] 互換性チェックの起動に失敗しました(未ビルドの可能性): {error}",
    en: "[fleetest] Failed to launch the compatibility check (possibly not built): {error}",
  },
} satisfies MessageDict;
