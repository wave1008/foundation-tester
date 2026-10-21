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
// 永久に張られない状態を作らない。**手元のハードウェアエンコーダの上限(下)は例外** —— 速さの上限なので
// モニターの更新(既定2秒)を待つと守れず、空く時刻に起こし直すタイマーと直近の起動時刻をコントローラ
// (monitorDeviceStreamController.ts)が持つ。このファイルは今回の枠を受け取って振り分けるだけ。

// **手元の iOS Simulator の h264 配信(fleetest-simstream)も一斉に張らない** —— こちらは ssh ではなく
// ホストのハードウェアエンコーダ(AppleAVE)の枠。パネルを隠して戻した瞬間に手元の 10 本が同時にセッションを
// 開き、AVE がマシン全体で -17691 を返し始めた(実測。約5分で自然回復)。同じ日の 9 本の一斉起動では
// 起きていない = 観測1回で閾値は分からないので、起こす速さを抑える(0.5秒に1本 = ユーザー決定)。Android Emulator の配信
// (screenrecord)はエミュレータの中で符号化し、ホストのエンコーダの客にならない(同じ時刻の客は simstream だけ)ので数えない。

/** 1回のパスで1機械あたり新しく起こす配信の本数。
 * 根拠: MaxStartups の第1閾値 10 から、その機械に常駐する monitor と host-metrics の 2 本を引き、
 * さらに手元から出る他の ssh(run のディスパッチ・remote status・remote exec の $HOME プローブ)に
 * 枠を残して 4。**尽きたときは次のパス(既定2秒後)で続きを起こす**ので、台数が増えても
 * 張れないのではなく張り終わるまでの時間が延びるだけになる。 */
export const MAX_REMOTE_STREAM_STARTS_PER_PASS = 4;

/** 手元のハードウェアエンコーダを使う配信(iOS Simulator の h264)を起こす速さの上限:
 * 直近 `LOCAL_HW_STREAM_WINDOW_MS` の間に `LOCAL_HW_STREAM_STARTS_PER_WINDOW` 本まで(= 0.5秒に1本。ユーザー決定)。
 * 落ちた回は 10 本が約 0.16 秒の間にセッションを開いた直後だった(9 本の一斉起動では落ちていない = 閾値は不明)。
 * 手元 10 台は約 4.5 秒で張り終わる(その間タイルはポーリングで更新される)。枠が尽きたら呼び手が空く時刻に起こし直す
 * (monitorDeviceStreamController.ts。モニターの更新の周期を待たない) */
export const LOCAL_HW_STREAM_STARTS_PER_WINDOW = 1;
export const LOCAL_HW_STREAM_WINDOW_MS = 500;

/** 今回のパスで起こしてよい deviceId を返す(入力の順序を保つ)。
 * machine が無い = 手元のデバイスは ssh を張らないので機械の枠では制限しない。
 * 手元でも `hardwareEncoded` のものはエンコーダの枠(`maxLocalHardwareEncoded` = 呼び手が直近の起動から求めた今の残り)で
 * 制限する。**既定値を置かない** —— 渡し忘れると手元の一斉起動が素通りする */
export function admitStreamStarts(
  pending: ReadonlyArray<{ deviceId: string; machine?: string; hardwareEncoded?: boolean }>,
  maxPerMachine: number,
  maxLocalHardwareEncoded: number,
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
