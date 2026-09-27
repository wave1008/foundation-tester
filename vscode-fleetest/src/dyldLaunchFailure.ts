// dyldLaunchFailure.ts
// macOS と Xcode の版ずれ(FoundationModels の ABI 不一致)で fleetest バイナリが起動直後に
// dyld エラーで落ちる事象の検出。vscode に依存しない(node --test から直接検証できる。
// debugAdapter.ts の「vscode 非依存」契約からもここだけは import してよい)。呼び出し元は
// src/dyldLaunchNotice.ts(vscode 側の通知)と src/debugAdapter.ts(検出だけ)。

/** dyld が吐く「読み込み失敗」の文言(macOS 自身の出力)。[pid] の有無どちらの版にも当たる。
 *  行頭でなくてもよい(ラベル付きの1行ログに混ざる呼び出し元がある)。exit のシグナル(SIGABRT 等)は
 *  見ない —— 環境で変わりうるため、判定は文言だけで決める。 */
const DYLD_FAILURE_PATTERN = /dyld(\[\d+\])?: (Symbol not found|Library not loaded)/;

/** 通知に添える行の上限(mangled symbol 名で通知が埋まらないように切る)。 */
const MAX_LINE_CHARS = 300;

/**
 * stderr の断片(1行 or 複数行)から dyld の読み込み失敗の行を探す。当たった最初の行
 * (MAX_LINE_CHARS で切り詰め)を返す。無ければ null。
 */
export function detectDyldLaunchFailure(stderrText: string): string | null {
  for (const rawLine of stderrText.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line.length > 0 && DYLD_FAILURE_PATTERN.test(line)) {
      return line.length > MAX_LINE_CHARS ? `${line.slice(0, MAX_LINE_CHARS)}…` : line;
    }
  }
  return null;
}

/**
 * 拡張のセッション中に1回だけ通知するための門(vscode 非依存)。モニターは常駐子プロセスの
 * 自動再起動を繰り返すため、同じ原因で通知が何十個も積み上がらないようにする。
 * 呼び出し元(dyldLaunchNotice.ts)がモジュールスコープの単一インスタンスとして持つ。
 */
export class DyldNotifyGate {
  private claimed = false;

  /** 最初の1回だけ true を返す。以降は同じインスタンスでは常に false。 */
  claim(): boolean {
    if (this.claimed) {
      return false;
    }
    this.claimed = true;
    return true;
  }
}
