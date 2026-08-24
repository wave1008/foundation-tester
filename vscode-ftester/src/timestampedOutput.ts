// OUTPUT「ftester」の全行に時刻を付ける薄いラッパ。**唯一の定義元** —— 呼び出し側(238 箇所)は
// appendLine のままなので、ライフサイクル行を足すたびに時刻を付け忘れる余地が無い。
//
// 受け手報告 2026-08-24: 行に時刻が無く、monitor の死亡時刻をチャンネルファイルの mtime から
// 「13:15〜15:47 の間」と括るのが限界で、update.sh の実行時刻との相関(SIGKILL 説)を
// 確定できなかった。終了行(exit code/signal)も時刻が無いと外部イベントと突き合わせられない。
//
// **日付は行に載せず、変わったときだけ日付行を挟む**(1行あたり 9 文字に抑えつつ、日をまたいで
// 開きっぱなしのパネルでも時刻が曖昧にならない)。vscode を import しない(node:test から
// 検証するため。monitorHealthWatchdog.ts と同じ方針)。

/** OutputChannel のうちこのモジュールが触る部分だけ(テストのダミーを最小に保つ)。 */
export interface AppendOnlyChannel {
  appendLine(value: string): void;
}

function two(value: number): string {
  return String(value).padStart(2, "0");
}

/**
 * channel.appendLine を包み、"HH:mm:ss " を前置する関数を返す。日付が変わった最初の1行の前に
 * 区切り行を挟む(初回も必ず出るので、チャンネルの先頭を見れば何日の記録か分かる)。
 * now はテスト用の時刻注入(既定は実時刻)。
 */
export function createTimestampedAppender(
  channel: AppendOnlyChannel,
  now: () => Date = () => new Date(),
): (value: string) => void {
  let lastDate: string | undefined;
  return (value: string) => {
    const at = now();
    const date = `${at.getFullYear()}-${two(at.getMonth() + 1)}-${two(at.getDate())}`;
    if (date !== lastDate) {
      lastDate = date;
      channel.appendLine(`──── ${date} ────`);
    }
    channel.appendLine(`${two(at.getHours())}:${two(at.getMinutes())}:${two(at.getSeconds())} ${value}`);
  };
}
