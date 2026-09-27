// 辞書。namespace: dyld.
// 対象ソース: dyldLaunchNotice.ts(fleetest バイナリの dyld 起動失敗 = macOS/Xcode 版ずれの案内)。
import type { MessageDict } from "../core";

export const dyldStrings = {
  "dyld.launchFailure.message": {
    ja: "fleetest を起動できませんでした(dyld が読み込みに失敗しました: {line})。macOS と Xcode の版がずれている可能性が高いです(例: macOS を新しいベータに上げたのに、Xcode が古いまま)。Xcode を macOS と同じ世代にそろえてから、fleetest のクローンと作業フォルダの .build を消し、`bash {clone}/Scripts/update.sh --force` を実行してください。",
    en: "fleetest could not start (dyld failed to load it: {line}). macOS and Xcode are most likely out of step (for example, macOS was updated to a newer beta but Xcode was not). Update Xcode to the same generation as macOS, then delete .build in the fleetest clone and in your work folder, and run `bash {clone}/Scripts/update.sh --force`.",
  },
  "dyld.launchFailure.detailsButton": {
    ja: "詳しく",
    en: "Details",
  },
  // クローンのパスが解決できないときに {clone} へ渡すプレースホルダ(dyldLaunchNotice.ts)。
  "dyld.launchFailure.clonePlaceholder": {
    ja: "<クローン>",
    en: "<clone>",
  },
} satisfies MessageDict;
