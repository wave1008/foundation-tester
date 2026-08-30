// monitorDeviceStreamController.ts
// デバイスモニタータイル(deviceTiles.js)向け画面ストリーミング制御(iOS: fleetest-simstream /
// Android: fleetest-androidstream)。ライブ操作タブと同じ StreamPipeline(deviceStream.ts)を、
// connected な対象タイルの数だけ束ねて使い回す(供給・再起動ロジックはそちらに一本化されているため
// 複製しない)。
//
// ストリーミング中は monitorProcessManager.ts が2秒間隔で送るポーリングフレームを間引く
// (isStreaming で判定。両方を同時にタイルへ描画すると解像度(width/height)が行き来してチラつく)。
// 間引き開始は「webview がストリームフレームを実際に描画した」ack(streamRendered。
// deviceTiles.js → monitorPanel.ts → noteStreamRendered)を受けてから。ホストがチャンクを
// 受信した時点で間引くと、Reload Window 直後など webview 準備前に初期キーフレームが落ちた場合、
// 静止画面では以後チャンクが来ず「ポーリング抑止済み・ストリーム無描画」でタイルが永久に
// 「起動中」のまま止まる(2026-07-15 実害)。
// ストリーミングが継続不能(onFailure)になった場合も同様にポーリングへ戻すだけで、明示的な
// フォールバック処理は不要(ポーリングは止めていないため)。
//
// streamingDeviceIds が変化するたび syncSuppressFrames() が monitor プロセスへ suppressFrames
// (Sources/fleetest/ApiMonitorCommand.swift 同期)を送り、生成側でもポーリングを止める
// (monitorProcessManager.ts の間引きは受信後の安全弁として残る)。

import { resolveAdb, resolveAndroidStream, resolveDevicePoll, resolveProjectName, resolveSimStream } from "./config";
import { StreamPipeline } from "./deviceStream";
import { t } from "./i18n";
import type { MonitorDevice, MonitorPlatform } from "./monitorModel";
import type { MonitorPanelDeps } from "./monitorPanel";
import { admitStreamStarts } from "./remoteStreamAdmission";

/** applyDevices が1サイクル分の qualifying 判定と同時に組み立てる、起動に必要な情報一式。 */
interface QualifyingTarget {
  readonly platform: MonitorPlatform;
  /** iOS: シミュレータ UDID、Android: adb serial(disposeDevice の張り替え要否判定に使う)。 */
  readonly key: string;
  readonly command: string;
  readonly args: readonly string[];
  readonly codec: "mjpeg" | "h264";
  /** リモート機のデバイスならその machine(手元は undefined)。**ssh を張るのはこちらだけ**なので、
   * 一斉起動の入場制限(remoteStreamAdmission.ts)はこの有無で判断する。 */
  readonly machine?: string;
}

interface StreamEntry {
  readonly platform: MonitorPlatform;
  readonly key: string;
  // 稼働中パイプラインの codec。設定 streamCodec 変更(h264⇔mjpeg)を稼働中ストリームへ反映
  // するため、破棄判定で target.codec と比較する(不一致なら張り替え)。
  readonly codec: "mjpeg" | "h264";
  readonly pipeline: StreamPipeline;
}

/** MonitorTarget.id("<platform>:<name>" / リモートは "<platform>:<machine>/<name>")が
 * (machine, name) と一致するか。**名前だけで引かない** —— 同名の台が別の機械にも居るのは通常で、
 * 手元の停止でリモートの配信まで畳む(逆も同じ)。machine 省略は「手元」の意味
 * (id の綴りは Swift 側 DeviceMachineGrouping.workerID が決める) */
function matchesDeviceName(deviceId: string, name: string, machine?: string): boolean {
  return deviceId.endsWith(machine === undefined ? `:${name}` : `:${machine}/${name}`);
}

export class MonitorDeviceStreamController {
  private readonly pipelines = new Map<string, StreamEntry>();
  /** webview がストリームフレームの描画を ack(streamRendered)済みで、ポーリングフレームを
   * 間引いてよい状態のデバイス id 集合(isStreaming が見る)。 */
  private readonly streamingDeviceIds = new Set<string>();
  /** onFailure(helper が連続失敗で諦め)を受けたデバイス id。applyDevices は2秒毎に呼ばれるため、
   * これが無いと諦めた helper を毎回再生成してスパム再起動になる(将来の Xcode ABI 破壊時が該当)。
   * リセット条件は「デバイス切断=対象から外れる」か「パネル再表示(setVisible(true))」のみ。 */
  private readonly gaveUpDeviceIds = new Set<string>();
  /** webview から codecError(scope=tile)を受けたデバイス id。以後 applyDevices は設定値に関わらず
   * mjpeg を使う(fallbackToMjpeg 参照。gaveUpDeviceIds と違い切断でもクリアしない — WebCodecs
   * 非対応はデバイス側でなく webview 側の恒常的な制約のため)。 */
  private readonly mjpegFallbackIds = new Set<string>();
  private visible = true;
  /** 直近の applyDevices 呼び出し引数。reapply() がポーリングモードのトグル直後に同じ入力で
   * 再判定するために保持する(次の monitorDevices イベント[最大 monitorInterval 秒後]を待たない)。 */
  private lastDevices: readonly MonitorDevice[] | undefined;
  /** 直近に monitor へ送った suppressFrames の対象集合。同じ内容なら再送しない
   * (applyDevices は monitorInterval 秒毎に呼ばれるためスパム防止。syncSuppressFrames 参照)。 */
  private lastSuppressedIds: ReadonlySet<string> | undefined;

  constructor(private readonly deps: MonitorPanelDeps) {}

  isStreaming(deviceId: string): boolean {
    return this.streamingDeviceIds.has(deviceId);
  }

  /** 現在フレーム抑制中のデバイス id 一覧。monitor プロセス再起動直後の suppressFrames 再送に使う
   * (monitorProcessManager.ts 参照。再起動でプロセス側の抑制状態が失われるため)。 */
  streamingIds(): readonly string[] {
    return [...this.streamingDeviceIds];
  }

  /** monitorDevices イベントのたびに呼ぶ(monitorProcessManager.ts 参照)。対象外になったデバイスは
   * 破棄し、新たに対象になったデバイスはパイプラインを起動する。 */
  applyDevices(devices: readonly MonitorDevice[]): void {
    this.lastDevices = devices;
    if (!this.visible) {
      return; // 非表示中は setVisible(false) で全破棄済み。再開は次の setVisible(true) 後の呼び出しに任せる。
    }
    if (this.deps.isPollingMode()) {
      // 全破棄のみでポーリングへ委ねる(disposeAll が streamingDeviceIds もクリアするため、
      // monitorProcessManager.ts の間引き判定[isStreaming]が false に戻りタイルはポーリングで更新される)。
      this.disposeAll();
      return;
    }
    const config = this.deps.getConfig();
    // helper・adb の解決は1サイクルにつき1回(resolveSimStream/resolveAndroidStream/resolveAdb は
    // いずれもキャッシュ済みだが、config.*StreamEnabled による無効化判定はここでまとめて行う)。
    const simStreamPath = config.iosStreamEnabled ? resolveSimStream(config) : undefined;
    const androidStreamPath = config.androidStreamEnabled ? resolveAndroidStream(config) : undefined;
    const adbPath = (androidStreamPath || resolveDevicePoll(config)) ? resolveAdb() : undefined;
    // 実機はスクリーンショットのポーリング(fleetest-devicepoll)。iOS/Android で共通の helper。
    // iOS 実機の有効/無効は iosStreamEnabled、Android 実機は androidStreamEnabled に従う
    const devicePollPath = resolveDevicePoll(config);
    // **リモートは手元のヘルパーを使わない**(向こうの fleetest が起こす)ので、手元に
    // ヘルパーが1つも無くてもリモートのタイルは配信できる。ここで早期 return すると
    // 「手元にビルドが無い機械ではリモート映像も出ない」になる
    const hasRemote = devices.some((device) => device.machine !== undefined);
    if (!simStreamPath && !(androidStreamPath && adbPath) && !devicePollPath && !hasRemote) {
      this.disposeAll();
      return;
    }

    // リモートの device-stream は向こうでマシンプロファイルを引くのでプロジェクト名が要る
    // (未解決なら省略 = 向こうの既定プロジェクトに委ねる)。**リモートが1台も無いなら引かない**
    let projectArgs: string[] | undefined;
    const remoteProjectArgs = (): string[] => {
      if (!projectArgs) {
        const resolution = resolveProjectName(this.deps.workspaceRoot, config);
        projectArgs = resolution.kind === "resolved" ? ["--project", resolution.project] : [];
      }
      return projectArgs;
    };

    const qualifying = new Map<string, QualifyingTarget>();
    for (const device of devices) {
      if (device.state !== "connected") {
        continue;
      }
      // codecError を受けたデバイスは設定値に関わらず mjpeg 固定(fallbackToMjpeg 参照)。
      const codec: "mjpeg" | "h264" = this.mjpegFallbackIds.has(device.id) ? "mjpeg" : config.streamCodec;
      const codecArgs = codec === "h264" ? ["--codec", "h264"] : [];
      if (device.machine) {
        // **別の機械のデバイス**。udid も adb serial も向こうのものなので、手元でヘルパーを
        // 起こしても当たらない(同名の手元の台に当たると**別の機械の画面が映る**)。代わりに
        // その機械で `api device-stream` を起こす —— 向こうは宛先を解決してヘルパーへ exec で
        // 化けるので、**stdout に流れるバイト列はここで直接起こしたときと同じ**。だから
        // StreamPipeline も codec の扱いも失敗時のポーリング復帰もそのまま使える
        // (契約: Sources/fleetest/ApiDeviceStreamCommand.swift)。
        // 配信できないときは何も起こさない = そのタイルはリモート monitor のポーリング
        // フレーム(2秒毎)で更新され続ける
        const enabled = device.platform === "ios" ? config.iosStreamEnabled : config.androidStreamEnabled;
        if (!enabled) {
          continue;
        }
        qualifying.set(device.id, {
          platform: device.platform,
          machine: device.machine,
          key: `${device.machine}/${device.name}`,
          // 手元と同じ規則: **実機は devicepoll(MJPEG 固定)** —— 向こうの
          // ApiDeviceStreamCommand が実機で codec を落とすので、h264 を期待すると
          // v1 レコードを v2 として読んで desync → kill/再起動のループになる
          codec: device.kind === "physical" ? "mjpeg" : codec,
          command: config.binaryPath,
          args: [
            "remote", "exec", device.machine, "--",
            // **向こうでは "local"**。転送したプロファイルは RunnerProfileView が「そのランナーから
            // 見た姿」へ畳んである(自分の台は machine:"local"・他機の台は削除)ので、エイリアスで
            // 絞ると1台も残らず "no ios device named …" で落ちる。fan-out の子
            // (Sources/fleetest/RemoteMonitorFanout.swift)が `--device-machine local` を渡すのと同じ理由 ——
            // **片方だけ直さない**(この経路は 8ef49815 で追随が漏れていた)
            "api", "device-stream", "--device-machine", "local",
            "--platform", device.platform, "--name", device.name,
            "--fps", String(config.liveFps), "--max-width", String(config.monitorMaxWidth),
            ...remoteProjectArgs(),
            ...(config.profile ? ["--profile", config.profile] : []),
            ...(device.kind === "physical" ? [] : codecArgs),
          ],
        });
        continue;
      }
      // 実機は種別を問わず devicepoll(スクリーンショットのポーリング)。
      // iOS 実機に simstream は使えず(CoreSimulator 私有 API)、Android 実機は screenrecord だと
      // 静止画面でフレームが流れないため、両者ともこちらへ寄せる
      if (devicePollPath && device.kind === "physical") {
        const enabled = device.platform === "ios" ? config.iosStreamEnabled : config.androidStreamEnabled;
        const reachable = device.platform === "ios" ? device.port !== undefined : device.serial !== undefined;
        if (!enabled || !reachable) {
          continue;
        }
        const pollArgs = device.platform === "ios"
          ? ["--platform", "ios", "--host", device.host ?? "127.0.0.1", "--port", String(device.port)]
          : ["--platform", "android", "--serial", String(device.serial), "--adb", adbPath ?? "adb"];
        qualifying.set(device.id, {
          platform: device.platform,
          key: device.platform === "ios" ? String(device.port) : String(device.serial),
          command: devicePollPath,
          args: [
            ...pollArgs,
            "--fps", String(config.liveFps), "--max-width", String(config.monitorMaxWidth),
          ],
          // devicepoll は MJPEG(v1)固定。h264 パススルーは持たない
          codec: "mjpeg",
        });
      } else if (simStreamPath && device.platform === "ios" && device.udid && device.kind !== "physical") {
        qualifying.set(device.id, {
          platform: "ios",
          key: device.udid,
          command: simStreamPath,
          args: [
            "--udid", device.udid, "--fps", String(config.liveFps), "--max-width", String(config.monitorMaxWidth),
            ...codecArgs,
          ],
          codec,
        });
      } else if (androidStreamPath && adbPath && device.platform === "android" && device.serial) {
        qualifying.set(device.id, {
          platform: "android",
          key: device.serial,
          command: androidStreamPath,
          args: [
            "--serial", device.serial, "--adb", adbPath,
            "--fps", String(config.liveFps), "--max-width", String(config.monitorMaxWidth),
            ...codecArgs,
          ],
          codec,
        });
      }
    }

    // 対象から外れた(切断・一覧から消えた)、プラットフォーム/key が変わった、または codec 設定が
    // 変わったデバイスを破棄する(次ループで新 codec のヘルパーとして張り直される)。
    for (const [deviceId, entry] of this.pipelines) {
      const target = qualifying.get(deviceId);
      if (!target || target.platform !== entry.platform || target.key !== entry.key
          || target.codec !== entry.codec) {
        this.disposeDevice(deviceId);
      }
    }
    // 対象から外れた=切断/消滅なので諦め状態を解除する(再接続したら再試行できるように)。
    for (const deviceId of [...this.gaveUpDeviceIds]) {
      if (!qualifying.has(deviceId)) {
        this.gaveUpDeviceIds.delete(deviceId);
        this.deps.post({ type: "streamUnavailable", device: deviceId, unavailable: false });
      }
    }
    // **リモートは一斉に張らない**(1機械あたり ssh が N+2 本になり sshd の MaxStartups に
    // 当たる。remoteStreamAdmission.ts)。見送った台はこの reapply が次のモニター更新で
    // また拾うので、取りこぼしにはならない
    const pending = [...qualifying]
      .filter(([deviceId]) => !this.pipelines.has(deviceId) && !this.gaveUpDeviceIds.has(deviceId))
      .map(([deviceId, target]) => ({ deviceId, machine: target.machine }));
    for (const deviceId of admitStreamStarts(pending)) {
      const target = qualifying.get(deviceId);
      if (target) {
        this.startPipeline(deviceId, target);
      }
    }
  }

  /** 設定タブの「ポーリングモードを使用する」トグル直後に monitorPanel.ts から呼ぶ。直近の
   * applyDevices 引数で再判定する(未呼び出しなら何もしない)。 */
  reapply(): void {
    if (this.lastDevices) {
      this.applyDevices(this.lastDevices);
    }
  }

  /** webview の streamRendered ack(monitorPanel.ts 経由)で呼ぶ。パイプライン破棄後に遅れて
   * 届いた ack で抑止だけ復活するとタイル餓死が再発するため、稼働中のみ受け付ける。
   * ack はストリーム描画のたび(2秒スロットリング)届くので、二重呼び出しは no-op。 */
  noteStreamRendered(deviceId: string): void {
    if (!this.pipelines.has(deviceId)) {
      return;
    }
    if (!this.streamingDeviceIds.has(deviceId)) {
      this.streamingDeviceIds.add(deviceId);
      this.syncSuppressFrames();
    }
  }

  /** webview の streamStall(キーフレーム未受信のままデルタが流れ続けている)で呼ぶ。
   * ヘルパーを作り直して新しいキーフレームから始めさせる(gaveUp/mjpeg 扱いにはしない)。 */
  restartDevice(deviceId: string): void {
    if (!this.pipelines.has(deviceId)) {
      return;
    }
    this.disposeDevice(deviceId);
    this.reapply(); // 次の monitorDevices(最大2秒後)を待たず直近入力で即再生成する
  }

  /** モニター再起動(restartMonitor)時に呼ぶ。全ヘルパーを作り直して新キーフレームから始めさせる。
   * 再起動では processManager が旧 streamingIds を根拠に suppressFrames を再送するが、走行中の
   * h264 ストリームは新キーフレームを出さないため、ポーリング抑止・ストリーム無描画でタイルが
   * 「起動中」に餓死する(冒頭コメントのデッドロック)。disposeAll で streamingIds も一旦クリアされる
   * ため、新モニターへの stale な suppressFrames 再送も防げる。restartDevice の全台版。 */
  restartAllStreams(): void {
    this.disposeAll();
    this.reapply();
  }

  /** device-down ジョブ(monitorDeviceOps.ts)の実行開始時に呼ぶ。deviceId は "<platform>:<name>"
   * (リモートは "<platform>:<machine>/<name>"。Swift 側 MonitorTarget.id)だがジョブは name しか
   * 持たないため、名前部分の一致で判定する(同名デバイスが ios/android 両方・複数の機械に
   * 存在する場合も全部破棄する)。 */
  disposeForDeviceName(name: string, machine?: string): void {
    for (const deviceId of [...this.pipelines.keys()]) {
      if (matchesDeviceName(deviceId, name, machine)) {
        this.disposeDevice(deviceId);
      }
    }
  }

  /** health watchdog の blank-screen 軽量修復(monitorHealthWatchdog.ts)。name の稼働中パイプラインを
   * 破棄して即再生成する(restartDevice と同じ仕組み)。1本でも張り替えたら true。 */
  restartForDeviceName(name: string): boolean {
    let found = false;
    for (const deviceId of [...this.pipelines.keys()]) {
      // health watchdog は手元のデバイスにしか出さない(monitorHealthWatchdog.ts のガード)
      if (matchesDeviceName(deviceId, name)) {
        this.disposeDevice(deviceId);
        found = true;
      }
    }
    if (found) {
      this.reapply();
    }
    return found;
  }

  /** 一括 down ジョブの実行開始時に monitorDeviceOps.ts から呼ぶ。disposeAll と同じ全破棄(冪等)。 */
  disposeAllForDown(): void {
    this.disposeAll();
  }

  private startPipeline(deviceId: string, target: QualifyingTarget): void {
    const pipeline = new StreamPipeline({
      command: target.command,
      args: target.args,
      // 台名を入れる —— helper の stderr(encode 失敗・wedge)は全部この prefix で出るので、
      // 無いと数十本のどれが壊れたか分からない(2026-08-31: iOS 4本の同時失敗が特定できなかった)
      logPrefix: `${target.platform === "ios" ? "ios-stream" : "android-stream"} ${deviceId}`,
      outputChannel: this.deps.outputChannel,
      codec: target.codec,
      // 受信時に間引きは発動しない(stream: true を付けて webview の描画 ack に委ねる。冒頭コメント参照)
      onFrame: (jpegBase64, width, height) => {
        this.deps.post({ type: "frame", device: deviceId, jpegBase64, width, height, stream: true });
      },
      onChunk: (data, keyframe, width, height) => {
        this.deps.post({ type: "h264Chunk", device: deviceId, keyframe, width, height, data: new Uint8Array(data) });
      },
      onConnectionOk: () => undefined,
      // helper が「この機械では h264 が無理」と降りたら mjpeg へ張り替える(webview の
      // codecError と同じ扱い。あちらは受け手の非対応、こちらは送り手の資源不足)
      onCodecUnavailable: () => this.fallbackToMjpeg(deviceId),
      onFailure: (message) => {
        this.deps.outputChannel.appendLine(
          `[monitor-stream] ${deviceId}: ${message} ${t("monitor.deviceStream.fallbackToPolling")}`,
        );
        this.disposeDevice(deviceId);
        this.gaveUpDeviceIds.add(deviceId); // 2秒毎の applyDevices による再生成スパムを止める
        // **タイルに黙って「接続中」を出し続けない** —— プロファイル未選択(未登録デバイス)の
        // iOS はブリッジが無くポーリングのフレームも来ないので、諦めたことを伝えないと
        // 永久に「接続中」に見える(2026-08-17 の実害)
        this.deps.post({ type: "streamUnavailable", device: deviceId, unavailable: true });
      },
    });
    this.pipelines.set(deviceId, {
      platform: target.platform, key: target.key, codec: target.codec, pipeline,
    });
    pipeline.start();
  }

  /** webview から codecError(scope=tile, device=deviceId)を受けたら monitorPanel.ts から呼ぶ。
   * 以後このデバイスは mjpeg 固定にし、稼働中のパイプラインを破棄する(次の applyDevices[最大
   * monitorInterval 秒後]で mjpeg として再生成される。gaveUpDeviceIds には入れない=諦め扱いにしない)。 */
  fallbackToMjpeg(deviceId: string): void {
    this.mjpegFallbackIds.add(deviceId);
    this.disposeDevice(deviceId);
    this.reapply(); // restartDevice と同様に即座に mjpeg で張り直す(次の applyDevices を待たない)
  }

  private disposeDevice(deviceId: string): void {
    this.pipelines.get(deviceId)?.pipeline.dispose();
    this.pipelines.delete(deviceId);
    if (this.streamingDeviceIds.delete(deviceId)) {
      this.syncSuppressFrames();
    }
  }

  private disposeAll(): void {
    // disposeDevice を都度呼ぶと streamingDeviceIds が変化するたび syncSuppressFrames が走り
    // スパムになるため、集合操作をここで直接行いループ後に1回だけ同期する。
    for (const deviceId of [...this.pipelines.keys()]) {
      this.pipelines.get(deviceId)?.pipeline.dispose();
      this.pipelines.delete(deviceId);
      this.streamingDeviceIds.delete(deviceId);
    }
    this.syncSuppressFramesNow();
  }

  /** 描画 ack は webview から1本ずつ別メッセージで届く(起動時は数十本が連続)ので、送信を
   * **monitor の polling 間隔1つ分**だけ溜めてまとめる。窓がこの値なのは、抑止がその cadence で
   * しか効かないため —— 遅らせる代償は台ごとに最大1枚余分にポーリングするだけ。
   * (microtask ではメッセージを跨いで畳めず、実運用で 31 行/秒のままだった 2026-08-31) */
  private suppressSyncTimer: ReturnType<typeof setTimeout> | undefined;
  private syncSuppressFrames(): void {
    if (this.suppressSyncTimer) {
      return;
    }
    this.suppressSyncTimer = setTimeout(() => {
      this.suppressSyncTimer = undefined;
      this.flushSuppressFrames();
    }, this.deps.getConfig().monitorInterval * 1000);
  }

  /** 溜めずに今送る(restartAllStreams / 全破棄。空集合の再同期が遅れるとタイル餓死の回帰) */
  private syncSuppressFramesNow(): void {
    if (this.suppressSyncTimer) {
      clearTimeout(this.suppressSyncTimer);
      this.suppressSyncTimer = undefined;
    }
    this.flushSuppressFrames();
  }

  /** streamingDeviceIds の現在値を monitor へ suppressFrames として送る(前回と同じなら送らない)。 */
  private flushSuppressFrames(): void {
    const current = this.streamingDeviceIds;
    if (
      this.lastSuppressedIds &&
      this.lastSuppressedIds.size === current.size &&
      [...current].every((id) => this.lastSuppressedIds?.has(id))
    ) {
      return;
    }
    this.lastSuppressedIds = new Set(current);
    this.deps.writeMonitorControl({ cmd: "suppressFrames", devices: [...current] });
  }

  /** パネルの表示状態(WebviewPanel.visible)に合わせる。非表示中はリソースを使わないよう全破棄し、
   * 再表示時は次の monitorDevices イベント(monitorProcessManager.ts、最大 monitorInterval 秒後)で
   * applyDevices が呼ばれ再構築される。 */
  setVisible(visible: boolean): void {
    this.visible = visible;
    if (visible) {
      this.gaveUpDeviceIds.clear(); // 再表示は仕切り直し(諦めたデバイスも次の applyDevices で再試行)
    } else {
      this.disposeAll();
    }
  }

  dispose(): void {
    this.disposeAll();
  }
}
