// リモート機への配信(api device-stream)を**一斉に張らない**ための入場制限。
//
// 実測(2026-08-30): 1機械あたりの ssh は device-stream N 本 + monitor 1 + host-metrics 1 の
// N+2 本で、M1Max(8台)がちょうど 10 本だった。sshd の MaxStartups 既定 `10:30:100` は
// **未認証の同時接続**を数え、10 を超えると 30% の確率で落とし始める。認証済みの常駐接続は
// 枠を消費しないので、壊れるのは「一斉に張りにいく瞬間」だけ —— 実際そのとき
// `Connection timed out during banner exchange` で配信が張れなかった。
//
// **キューもタイマーも持たない**。呼び出し側(monitorDeviceStreamController.reapply)は
// モニターの更新ごと(既定2秒)に「パイプラインが無いデバイス」を起こし直すので、
// 今回見送った台は次のパスで拾われる。再試行の仕組みを二重に持たない = 取りこぼしで
// 永久に張られない状態を作らない。

/** 1回のパスで1機械あたり新しく起こす配信の本数。
 * 根拠: MaxStartups の第1閾値 10 から、その機械に常駐する monitor と host-metrics の 2 本を引き、
 * さらに手元から出る他の ssh(run のディスパッチ・remote status・remote exec の $HOME プローブ)に
 * 枠を残して 4。**尽きたときは次のパス(既定2秒後)で続きを起こす**ので、台数が増えても
 * 張れないのではなく張り終わるまでの時間が延びるだけになる。 */
export const MAX_REMOTE_STREAM_STARTS_PER_PASS = 4;

/** 今回のパスで起こしてよい deviceId を返す(入力の順序を保つ)。
 * machine が無い = 手元のデバイスは ssh を張らないので**制限しない**。 */
export function admitStreamStarts(
  pending: ReadonlyArray<{ deviceId: string; machine?: string }>,
  maxPerMachine: number = MAX_REMOTE_STREAM_STARTS_PER_PASS,
): string[] {
  const startedPerMachine = new Map<string, number>();
  const admitted: string[] = [];
  for (const { deviceId, machine } of pending) {
    if (machine === undefined) {
      admitted.push(deviceId);
      continue;
    }
    const started = startedPerMachine.get(machine) ?? 0;
    if (started >= maxPerMachine) {
      continue;
    }
    startedPerMachine.set(machine, started + 1);
    admitted.push(deviceId);
  }
  return admitted;
}
