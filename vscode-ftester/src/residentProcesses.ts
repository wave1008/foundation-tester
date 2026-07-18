// residentProcesses.ts
// 設定タブ「常駐プロセス」一覧の中核。`ps -axo pid=,ppid=,state=,command=` の出力から ftester 関連の
// 常駐プロセスを分類・抽出する。vscode を import しない(test/residentProcesses.test.mjs から
// 素の node:test で検証するため。orphanSweep.ts と同じ方針)。表示文字列の i18n は vscode 依存の
// i18n/index.ts の t() ではなく、vscode 非依存の i18n/core.ts + strings/deviceOps.ts を直接引く
// (下記 rt())。locale は呼び出し側が明示的に渡す(既定 "ja")— 現状 monitorPanel.ts(呼び出し元)
// は locale を渡していないため常に ja 表示。currentLocale() を渡す配線は将来追加の余地として残す。
//
// 「ftester 関連」の判定はコマンド文字列のみに依存する。実行時の kill 経路(monitorPanel.ts)は
// ここで得た pid を使うが、実際の停止は原則 `ftester devices down`(confirmDeaths→simctl
// shutdown→emu kill の安全順序を Swift 側が保証)経由で行い、残余のみ SIGKILL で掃討する。

import { formatMessage, type Locale } from "./i18n/core";
import { deviceOpsStrings } from "./i18n/strings/deviceOps";

/** vscode 非依存の辞書引き(i18n/index.ts の t() のここでの代替。ファイル冒頭コメント参照)。 */
function rt(
  key: keyof typeof deviceOpsStrings,
  locale: Locale,
  params?: Record<string, string | number>,
): string {
  return formatMessage(deviceOpsStrings[key][locale], params);
}

/** 常駐プロセスの種別。表示順もこの配列順(TYPE_ORDER)に従う。 */
export type ResidentType =
  | "bridge" // iOS ブリッジ本体: xcodebuild test-without-building(FTesterRunner の xctestrun)
  | "sim-runner" // シミュレータ内の XCUITest ランナー: FTesterRunnerUITests-Runner.app
  | "inapp-bridge" // in-app ブリッジ: dylib 注入されたテスト対象アプリ本体(.inapp の UDID で識別)
  | "emulator" // Android エミュレータ: qemu-system-… -avd <name>
  | "android-bridge" // Android ブリッジ: エミュレータ内の am instrument(ホスト PID 無し。adb forward から合成)
  | "monitor" // ftester api monitor(デバイスモニター常駐)
  | "host-metrics" // ftester api host-metrics
  | "live-serve" // ftester api live serve(ライブ操作の配信)
  | "stream" // ftester-simstream / ftester-androidstream(画面ストリーム helper)
  | "run" // ftester api run / ftester run(実行。非常駐だが孤児化するとブリッジを占有)
  | "mcp" // ftester-mcp(MCP サーバ)
  | "ftester"; // その他の ftester CLI(上のどれにも当たらない常駐)

export interface ResidentProcess {
  readonly pid: number;
  readonly ppid: number;
  readonly type: ResidentType;
  /** 種別の短い日本語ラベル(UI 表示用)。 */
  readonly label: string;
  /** 識別子(ポート/avd 名/UDID など、コマンドから抽出できた場合のみ。無ければ "")。 */
  readonly detail: string;
  /** ブリッジポート(iOS の bridge/sim-runner/inapp-bridge のみ。他種別・不明は "")。
   *  bridge は xctestrun 名(FTesterRunner-<port>.xctestrun)から、sim-runner は自分のコマンドに
   *  ポートが出ない(FT_PORT は env)ため同一 UDID の bridge から、inapp-bridge は
   *  bridge-<port>.inapp(inappBridges)から解決する。 */
  readonly port: string;
  /** ゾンビ(defunct)プロセスか。ps の state 先頭が Z、または command に <defunct> を含む。
   *  親に reap されず残った残骸で、kill しても親が回収するまで消えない(識別のため表示する)。 */
  readonly zombie: boolean;
  /** 親プロセスの人間可読な説明(親PID の command から導出)。シミュレータ配下なら launchd_sim を
   *  たどってデバイス名(例「iPhone 17 Pro(iOS 27.0)-06」)にする。解決できなければ実行ファイル名等。 */
  readonly parentDescription: string;
  /** ps のコマンド列(先頭を切り詰めたもの。ツールチップ等の補助表示用)。 */
  readonly command: string;
  /** 補足(UI「補足」列)。エミュレータ/シミュレータ内プロセスであること等、ホスト PID からは
   *  読み取れない注記。ホストの ps 由来行は ""。android-bridge 等の合成行にのみ入る。 */
  readonly note: string;
  /** デバイス内 PID(android-bridge のみ。`adb shell pidof` で採取)。ホスト PID(pid)ではないため
   *  kill には使わない。PID 列に "(12345)" と括弧付きで表示するための値。未取得なら undefined。 */
  readonly devicePid?: number;
}

/** 全プロセス表(pid → 親pid/状態/コマンド)。親PID の説明解決に使う。 */
interface RawProc {
  readonly ppid: number;
  readonly state: string;
  readonly command: string;
}

/** parseResidentProcesses のオプション。 */
export interface ParseResidentOptions {
  /** UDID(大文字)→ シミュレータ表示名。simctl list devices から作る。 */
  readonly simulatorNames?: Record<string, string>;
  /** ftester のビルド成果物ディレクトリ(絶対パス、例 .../.build/debug)。この配下の実行ファイルは
   *  名前を問わず ftester 由来として拾う(新規追加バイナリのもれ防止)。monitorPanel が config から渡す。 */
  readonly binaryDir?: string;
  /** in-app ブリッジの UDID(大文字)→ ポート。`.ftester/bridge-<port>.inapp`(ファイル名=ポート、
   *  1行目先頭=UDID)から作る。この UDID のシミュレータ内で走る注入アプリ本体を inapp-bridge 種別で
   *  拾い、ポートもここから解決する。 */
  readonly inappBridges?: ReadonlyMap<string, string>;
  /** 表示文字列(label/parentDescription)の言語。既定 "ja"(ファイル冒頭コメント参照)。 */
  readonly locale?: Locale;
}

/** 表示・kill の並び順(重いフリートを上に、補助常駐を下に)。 */
export const TYPE_ORDER: readonly ResidentType[] = [
  "bridge",
  "sim-runner",
  "inapp-bridge",
  "emulator",
  "android-bridge",
  "monitor",
  "host-metrics",
  "live-serve",
  "stream",
  "run",
  "mcp",
  "ftester",
];

// ResidentType → 辞書キー(表示ラベル)。ftester は素の CLI 名で ja/en 差が無いためキー無し。
const TYPE_LABEL_KEY: Partial<Record<ResidentType, keyof typeof deviceOpsStrings>> = {
  bridge: "deviceOps.type.bridge",
  "sim-runner": "deviceOps.type.simRunner",
  "inapp-bridge": "deviceOps.type.inappBridge",
  emulator: "deviceOps.type.emulator",
  "android-bridge": "deviceOps.type.androidBridge",
  monitor: "deviceOps.type.monitor",
  "host-metrics": "deviceOps.type.hostMetrics",
  "live-serve": "deviceOps.type.liveServe",
  stream: "deviceOps.type.stream",
  run: "deviceOps.type.run",
  mcp: "deviceOps.type.mcp",
};

function typeLabel(type: ResidentType, locale: Locale): string {
  const key = TYPE_LABEL_KEY[type];
  return key ? rt(key, locale) : "ftester";
}

// ftester CLI をパス前置(相対/絶対)を問わずサブコマンド位置で判定する土台。ftester-mcp /
// ftester-simstream / ftester-androidstream は "ftester" の直後が "-" なので (?:\s|$) に当たらず、
// この正規表現には一致しない(それぞれ専用の前置チェックで先に捕まえる)。
const FTESTER_CLI_RE = /(^|\/)ftester(?:\s|$)/;

const SIM_UDID_RE = /CoreSimulator\/Devices\/([0-9A-Fa-f-]{36})/;

// iOS ブリッジ(xcodebuild)は BridgeLauncher が注入したポート専用の xctestrun を回す
// (Sources/FTBridgeClient/BridgeLauncher.swift の FTesterRunner-<port>.xctestrun)。この2つで
// ブリッジのポートと相手シミュレータの UDID を1本のコマンドから取れる(destination は
// "platform=iOS Simulator,id=<UDID>")。
const BRIDGE_XCTESTRUN_RE = /FTesterRunner-(\d+)\.xctestrun/;
const DESTINATION_UDID_RE = /\bid=([0-9A-Fa-f-]{36})/;

/** ps コマンド列から指定オプションの値を1つ取り出す(例: extractArg(cmd, "--serial"))。 */
function extractArg(command: string, flag: string): string {
  const re = new RegExp(`${flag.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}[= ]+(\\S+)`);
  const m = command.match(re);
  return m?.[1] ?? "";
}

/** コマンド列1本を分類する。ftester 関連でなければ null。
 *  opts.binaryDir を渡すと、その配下の実行ファイルを名前を問わず ftester 由来として拾う。 */
export function classifyResident(
  command: string,
  opts: { binaryDir?: string; inappBridges?: ReadonlyMap<string, string> } = {},
): { type: ResidentType; detail: string } | null {
  const cmd = command.trim();
  if (!cmd) {
    return null;
  }

  // 1. helper バイナリ(専用プロセス名。ftester CLI 判定より先に確定させる)
  if (/(^|\/)ftester-mcp(?:\s|$)/.test(cmd)) {
    return { type: "mcp", detail: "" };
  }
  if (/(^|\/)ftester-(?:sim|android)stream(?:\s|$)/.test(cmd)) {
    const serial = extractArg(cmd, "--serial") || extractArg(cmd, "--device") || extractArg(cmd, "--udid");
    return { type: "stream", detail: serial };
  }
  // 1b. その他の ftester-<name> helper を汎用に拾う(専用判定の後。新規 helper のもれ防止)。
  //     detail に helper 名を出して種別「ftester」の中で区別できるようにする。
  const genericHelper = cmd.match(/(^|\/)(ftester-[A-Za-z0-9][A-Za-z0-9._-]*)(?:\s|$)/);
  if (genericHelper) {
    return { type: "ftester", detail: genericHelper[2] ?? "" };
  }

  // 2. ftester CLI サブコマンド
  if (FTESTER_CLI_RE.test(cmd)) {
    if (/\bapi\s+monitor(?:\s|$)/.test(cmd)) {
      return { type: "monitor", detail: extractArg(cmd, "--project") || extractArg(cmd, "--profile") };
    }
    if (/\bapi\s+host-metrics(?:\s|$)/.test(cmd)) {
      return { type: "host-metrics", detail: "" };
    }
    if (/\bapi\s+live\s+serve(?:\s|$)/.test(cmd)) {
      const dev = extractArg(cmd, "--device") || extractArg(cmd, "--name");
      return { type: "live-serve", detail: dev };
    }
    // 実行(run)。孤児化するとプロファイル全デバイスのブリッジを占有し続けるため対象に含める。
    if (/\bapi\s+run(?:\s|$)/.test(cmd) || /(^|\/)ftester\s+run(?:\s|$)/.test(cmd)) {
      return { type: "run", detail: extractArg(cmd, "--profile") };
    }
    // その他の ftester CLI 常駐(devices-up 等の一括操作を含む取りこぼし受け)
    return { type: "ftester", detail: "" };
  }

  // 3. iOS ブリッジ本体: FTesterRunner の xctestrun を回す xcodebuild
  if (/\bxcodebuild\b/.test(cmd) && /test-without-building/.test(cmd) && /FTesterRunner/.test(cmd)) {
    const udid = extractArg(cmd, "-destination")
      ? (cmd.match(/-destination[= ]+id=([0-9A-Fa-f-]{36})/)?.[1] ?? "")
      : "";
    return { type: "bridge", detail: udid };
  }

  // 4. シミュレータ内 XCUITest ランナー(in-app 判定より先。ランナー自身は inapp ではない)
  if (/FTesterRunnerUITests-Runner/.test(cmd)) {
    return { type: "sim-runner", detail: cmd.match(SIM_UDID_RE)?.[1] ?? "" };
  }

  // 4b. in-app ブリッジ: `.inapp` が記録した UDID のシミュレータ内で走る注入アプリ本体
  //     (dylib 注入済み。プロセスのコマンドはアプリバイナリのパスで ftester 名を持たない)。
  //     detail はアプリ名。どのシミュレータかは親プロセス列(launchd_sim 解決)に出る。
  if (opts.inappBridges && opts.inappBridges.size > 0) {
    const app = cmd.match(
      /CoreSimulator\/Devices\/([0-9A-Fa-f-]{36})\/data\/Containers\/Bundle\/Application\/[^/]+\/([^/]+)\.app\//,
    );
    if (app && opts.inappBridges.has((app[1] ?? "").toUpperCase())) {
      return { type: "inapp-bridge", detail: app[2] ?? "" };
    }
  }

  // 5. Android エミュレータ(qemu)。ftester のフリートはここに含まれる。
  //    `ftester devices down` が `pkill -f sdk/emulator/qemu` で全 qemu を落とすのと対象範囲を揃える。
  if ((/qemu-system-/.test(cmd) || /sdk\/emulator\/qemu/.test(cmd)) && /\s-avd\s+\S/.test(cmd)) {
    return { type: "emulator", detail: extractArg(cmd, "-avd") };
  }

  // 6. フォールバック: リポジトリのビルド成果物ディレクトリ配下の実行ファイルは、名前を問わず
  //    ftester 由来として拾う(この repo から新規追加されたバイナリのもれ防止)。
  if (opts.binaryDir) {
    const exe = cmd.split(/\s+/)[0] ?? "";
    const dir = opts.binaryDir.replace(/\/+$/, "");
    if (dir && (exe === dir || exe.startsWith(`${dir}/`))) {
      return { type: "ftester", detail: exe.split("/").pop() ?? "" };
    }
  }

  return null;
}

// launchd_sim(シミュレータのゲスト側 init)の command はデバイスの UDID をパスに含む。
const SIM_DEVICE_UDID_RE = /CoreSimulator\/Devices\/([0-9A-Fa-f-]{36})/;

/** 親PID(ppid)を全プロセス表 byPid から引き、人間可読な説明を返す。 */
export function describeParent(
  ppid: number,
  byPid: Map<number, RawProc>,
  simulatorNames: Record<string, string>,
  locale: Locale = "ja",
): string {
  if (ppid <= 1) {
    return rt("deviceOps.parent.systemLaunchd", locale);
  }
  const parent = byPid.get(ppid);
  if (!parent) {
    return rt("deviceOps.parent.unknown", locale);
  }
  const cmd = parent.command;
  // シミュレータの launchd_sim → デバイス名(UDID から解決)
  const simUdid = cmd.match(SIM_DEVICE_UDID_RE)?.[1];
  if (/\blaunchd_sim\b/.test(cmd) && simUdid) {
    return (
      simulatorNames[simUdid.toUpperCase()] ??
      rt("deviceOps.parent.simulatorFallback", locale, { shortUdid: simUdid.slice(0, 8) })
    );
  }
  // 親自身が ftester 関連なら種別ラベル(+識別子)で示す
  const cls = classifyResident(cmd);
  if (cls) {
    const label = typeLabel(cls.type, locale);
    return cls.detail ? `${label}(${cls.detail})` : label;
  }
  // 代表的な既知プロセス
  if (/Code Helper|\/Electron(?:\s|$)|Visual Studio Code/.test(cmd)) {
    return rt("deviceOps.parent.vscodeExtHost", locale);
  }
  if (/\bxcodebuild\b/.test(cmd)) {
    return "xcodebuild";
  }
  if (/qemu-system-|sdk\/emulator\/qemu/.test(cmd)) {
    return rt("deviceOps.parent.androidEmulatorQemu", locale);
  }
  if (/\blaunchd_sim\b/.test(cmd)) {
    return rt("deviceOps.parent.simulatorLaunchdSim", locale);
  }
  // 実行ファイル名(パス末尾)を落とす
  const first = cmd.trim().split(/\s+/)[0] ?? "";
  return first.split("/").pop() || rt("deviceOps.parent.unknown", locale);
}

/** 種別ごとにブリッジポートを解決する。bridge は自コマンド、sim-runner は同一 UDID の bridge
 *  (bridgePortByUdid)、inapp-bridge は inappBridges から引く。どれにも当たらなければ ""。 */
function resolveResidentPort(
  type: ResidentType,
  command: string,
  bridgePortByUdid: ReadonlyMap<string, string>,
  inappBridges: ReadonlyMap<string, string> | undefined,
): string {
  if (type === "bridge") {
    return command.match(BRIDGE_XCTESTRUN_RE)?.[1] ?? "";
  }
  if (type === "sim-runner" || type === "inapp-bridge") {
    const udid = command.match(SIM_UDID_RE)?.[1]?.toUpperCase();
    if (!udid) {
      return "";
    }
    const table = type === "sim-runner" ? bridgePortByUdid : inappBridges;
    return table?.get(udid) ?? "";
  }
  return "";
}

/** ps 出力(`ps -axo pid=,ppid=,state=,command=`)から ftester 関連の常駐プロセスを抽出し、
 *  TYPE_ORDER→pid 昇順に整列して返す。親PID の説明は全プロセス表を引いて解決する。 */
export function parseResidentProcesses(
  psOutput: string,
  opts: ParseResidentOptions = {},
): ResidentProcess[] {
  const simulatorNames = opts.simulatorNames ?? {};
  const locale = opts.locale ?? "ja";
  // 1パス目: 親解決のため全プロセスを pid で索引する(フィルタ前)。併せて iOS ブリッジの
  // UDID→ポートを採取する(sim-runner 側は自コマンドにポートが無く、この対応で解決する)。
  const byPid = new Map<number, RawProc>();
  const bridgePortByUdid = new Map<string, string>();
  const rows: Array<{ pid: number; ppid: number; state: string; command: string }> = [];
  for (const line of psOutput.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) {
      continue;
    }
    // 列は pid ppid state command。state は S/R/Z 等の1トークン(+, <, s 等の修飾付き)。
    const m = trimmed.match(/^(\d+)\s+(\d+)\s+(\S+)\s+(.*)$/);
    if (!m) {
      continue;
    }
    const pid = Number(m[1]);
    const ppid = Number(m[2]);
    const state = m[3] ?? "";
    const command = m[4] ?? "";
    byPid.set(pid, { ppid, state, command });
    rows.push({ pid, ppid, state, command });
    // FTesterRunner-<port>.xctestrun を持つのは iOS ブリッジの xcodebuild のみ(誤検出しない)。
    const bport = command.match(BRIDGE_XCTESTRUN_RE)?.[1];
    const budid = command.match(DESTINATION_UDID_RE)?.[1]?.toUpperCase();
    if (bport && budid) {
      bridgePortByUdid.set(budid, bport);
    }
  }
  // 2パス目: ftester 関連だけ残し、親説明を付ける。
  const out: ResidentProcess[] = [];
  for (const r of rows) {
    const cls = classifyResident(r.command, { binaryDir: opts.binaryDir, inappBridges: opts.inappBridges });
    if (!cls) {
      continue;
    }
    out.push({
      pid: r.pid,
      ppid: r.ppid,
      type: cls.type,
      label: typeLabel(cls.type, locale),
      detail: cls.detail,
      port: resolveResidentPort(cls.type, r.command, bridgePortByUdid, opts.inappBridges),
      zombie: /^Z/i.test(r.state) || /<defunct>|\(defunct\)/i.test(r.command),
      parentDescription: describeParent(r.ppid, byPid, simulatorNames, locale),
      command: r.command.length > 300 ? `${r.command.slice(0, 300)}…` : r.command,
      note: "", // ホスト ps 由来行に補足は無い(合成行の android-bridge のみ note を持つ)
    });
  }
  out.sort((a, b) => {
    const ka = TYPE_ORDER.indexOf(a.type);
    const kb = TYPE_ORDER.indexOf(b.type);
    return ka !== kb ? ka - kb : a.pid - b.pid;
  });
  return out;
}

// Android ブリッジのデバイス内ポート。Sources/FTAndroid/AndroidBridge.swift の bridgeDevicePort と
// 同期(am instrument -e port <これ> / adb forward tcp:<host> tcp:<これ>)。他用途の forward を除外する鍵。
const ANDROID_BRIDGE_DEVICE_PORT = "8123";

/** `adb forward --list` の出力から Android ブリッジの情報行を合成する。行形式は
 *  "<serial> tcp:<hostPort> tcp:<devicePort>"。デバイス内ポートが ANDROID_BRIDGE_DEVICE_PORT の
 *  転送だけを拾う(他の forward を除外)。これらはエミュレータ内の am instrument で、ホスト PID を
 *  持たない → pid=0(kill 非対象)。デバイス内 PID は pidBySerial(adb shell pidof)で埋め、PID 列に
 *  "(12345)" と括弧付きで出す。kill 対象外だが「すべて強制終了」の掃除対象(am/adb で停止)。 */
export function parseAndroidBridges(
  adbForwardListOutput: string,
  pidBySerial?: ReadonlyMap<string, number>,
  locale: Locale = "ja",
): ResidentProcess[] {
  const rows: ResidentProcess[] = [];
  for (const line of adbForwardListOutput.split("\n")) {
    const m = line.trim().match(/^(\S+)\s+tcp:(\d+)\s+tcp:(\d+)$/);
    if (!m) {
      continue;
    }
    const serial = m[1] ?? "";
    const hostPort = m[2] ?? "";
    const devicePort = m[3] ?? "";
    if (devicePort !== ANDROID_BRIDGE_DEVICE_PORT) {
      continue;
    }
    rows.push({
      pid: 0, // ホスト PID 無し(エミュレータ内プロセス)
      ppid: 0,
      type: "android-bridge",
      label: typeLabel("android-bridge", locale),
      port: hostPort, // ホスト側転送ポート(ここへ接続 → デバイスの 8123)
      detail: serial,
      zombie: false,
      parentDescription: `Android(${serial})`,
      command: `am instrument com.example.ftbridge/.BridgeInstrumentation @ ${serial}`,
      note: rt("deviceOps.note.emulatorInternalProcess", locale),
      devicePid: pidBySerial?.get(serial),
    });
  }
  return rows;
}
