// CLI の英語エラー文言 → 日本語訳(辞書は strings/cliMessages.ts)。vscode 非依存(webview バンドルが使う)。
import { cliMessagesStrings } from "./strings/cliMessages";

// 補間の値の形。数値・udid は形で縛る(緩い `.+?` が先頭の別の文まで呑み込まないように)。
// 他は非貪欲で、型の末尾に来たときだけ行末まで取る
const PLACEHOLDER_PATTERN: Record<string, string> = {
  port: "\\d+",
  pid: "\\d+",
  seconds: "\\d+",
  lower: "\\d+",
  upper: "\\d+",
  udid: "[0-9A-Fa-f-]+",
  bundleID: "[\\w.-]+",
};

interface Rule {
  readonly pattern: RegExp;
  /** キャプチャ群の番号 → プレースホルダ名 */
  readonly names: readonly string[];
  readonly ja: string;
}

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function compile(en: string, ja: string): Rule {
  const names: string[] = [];
  let source = "";
  let last = 0;
  const matches = [...en.matchAll(/\{(\w+)\}/g)];
  matches.forEach((m, i) => {
    const index = m.index ?? 0;
    source += escapeRegExp(en.slice(last, index));
    const name = m[1] ?? "";
    const seen = names.indexOf(name);
    if (seen >= 0) {
      source += `\\${seen + 1}`;
    } else {
      names.push(name);
      const atEnd = i === matches.length - 1 && index + m[0].length === en.length;
      source += `(${PLACEHOLDER_PATTERN[name] ?? (atEnd ? "[^\\n]+" : "[^\\n]+?")})`;
    }
    last = index + m[0].length;
  });
  source += escapeRegExp(en.slice(last));
  return { pattern: new RegExp(source, "g"), names, ja };
}

let rules: readonly Rule[] | undefined;

function allRules(): readonly Rule[] {
  // 長い型から当てる(短い型が長い型の一部を先に訳すと長い型が当たらなくなる)
  rules ??= Object.values(cliMessagesStrings)
    .map((entry) => compile(entry.en, entry.ja))
    .sort((a, b) => b.pattern.source.length - a.pattern.source.length);
  return rules;
}

/** 辞書の型に1つでも当たれば訳文(当たらない部分は原文のまま)、1つも当たらなければ null。 */
export function translateCliMessage(text: string): string | null {
  let out = text;
  let matched = false;
  for (const rule of allRules()) {
    out = out.replace(rule.pattern, (...args) => {
      matched = true;
      const groups = args.slice(1, rule.names.length + 1) as string[];
      return rule.ja.replace(/\{(\w+)\}/g, (whole, name: string) => {
        const index = rule.names.indexOf(name);
        return index >= 0 ? (groups[index] ?? whole) : whole;
      });
    });
  }
  return matched ? out : null;
}
