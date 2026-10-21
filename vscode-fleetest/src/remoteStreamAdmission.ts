// リモート機への配信(api device-stream)を**一斉に張らない**ための入場制限。
//
// 実測: 1機械あたりの ssh は device-stream N 本 + monitor 1 + host-metrics 1 の
// N+2 本で、M1Max(8台)がちょうど 10 本だった。sshd の MaxStartups 既定 `10:30:100` は
// **未認証の同時接続**を数え、10 を超えると 30% の確率で落とし始める。認証済みの常駐接続は
// 枠を消費しないので、壊れるのは「一斉に張りにいく瞬間」だけ —— 実際そのとき
// `Connection timed out during banner exchange` で配信が張れなかった。
//
// **キューもタイマーも持たない**。呼び出し側(monitorDeviceStreamController.reapply)は
// モニターの更新ごと(既定2秒)に「パイプラインが無いデバイス」を起こし直すので、
// 今回見送ったデバイスは次のパスで拾われる。再試行の仕組みを二重に持たない = 取りこぼしで
// 永久に張られない状態を作らない。

// **手元の iOS Simulator の h264 配信(fleetest-simstream)も一斉に張らない** —— こちらは ssh ではなく
// ホストのハードウェアエンコーダ(AppleAVE)の枠。パネルを隠して戻した瞬間に手元の 10 本が同時にセッションを
// 開き、AVE がマシン全体で -17691 を返し始めた(実測。約5分で自然回復)。同じ日の 9 本の一斉起動では
// 起きていない = 観測1回で閾値は分からないので、同時に開く本数を十分下に抑える。Android Emulator の配信
// (screenrecord)はエミュレータの中で符号化し、ホストのエンコーダの客にならない(同じ時刻の客は simstream だけ)ので数えない。

/** 1回のパスで1機械あたり新しく起こす配信の本数。
 * 根拠: MaxStartups の第1閾値 10 から、その機械に常駐する monitor と host-metrics の 2 本を引き、
 * さらに手元から出る他の ssh(run のディスパッチ・remote status・remote exec の $HOME プローブ)に
 * 枠を残して 4。**尽きたときは次のパス(既定2秒後)で続きを起こす**ので、台数が増えても
 * 張れないのではなく張り終わるまでの時間が延びるだけになる。 */
export const MAX_REMOTE_STREAM_STARTS_PER_PASS = 4;

/** 1回のパスで新しく起こす、手元のハードウェアエンコーダを使う配信(iOS Simulator の h264)の本数。
 * 根拠: 10 本の同時起動で AVE が落ち、9 本では落ちなかった(各1回の観測)。その十分下の 3。
 * パスは主にモニターの更新ごと(既定2秒)で、手元 10 台は約 8 秒で張り終わる(その間タイルはポーリングで更新される)。
 * ただし `reapply`(配信の起こし直し・ロックの変化)は更新を待たずにパスを回すので、短い間隔で2パス = 6 本になることはある
 * **尽きたときは次のパスで続きを起こす**(リモートと同じ) */
export const MAX_LOCAL_HW_STREAM_STARTS_PER_PASS = 3;

/** 今回のパスで起こしてよい deviceId を返す(入力の順序を保つ)。
 * machine が無い = 手元のデバイスは ssh を張らないので機械の枠では制限しない。
 * 手元でも `hardwareEncoded` のものはエンコーダの枠(`maxLocalHardwareEncoded`)で制限する */
export function admitStreamStarts(
  pending: ReadonlyArray<{ deviceId: string; machine?: string; hardwareEncoded?: boolean }>,
  maxPerMachine: number = MAX_REMOTE_STREAM_STARTS_PER_PASS,
  maxLocalHardwareEncoded: number = MAX_LOCAL_HW_STREAM_STARTS_PER_PASS,
): string[] {
  const startedPerMachine = new Map<string, number>();
  let startedLocalHardwareEncoded = 0;
  const admitted: string[] = [];
  for (const { deviceId, machine, hardwareEncoded } of pending) {
    if (machine === undefined) {
      if (hardwareEncoded === true) {
        if (startedLocalHardwareEncoded >= maxLocalHardwareEncoded) {
          continue;
        }
        startedLocalHardwareEncoded += 1;
      }
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
