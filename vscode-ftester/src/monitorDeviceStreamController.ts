// monitorDeviceStreamController.ts
// デバイスモニタータイル(deviceTiles.js)向け画面ストリーミング制御(iOS: ftester-simstream /
// Android: ftester-androidstream)。ライブ操作タブと同じ StreamPipeline(deviceStream.ts)を、
// connected な対象タイルの数だけ束ねて使い回す(供給・再起動ロジックはそちらに一本化されているため
// 複製しない)。
//
// ストリーミング中は monitorProcessManager.ts が2秒間隔で送るポーリングフレームを間引く
// (isStreaming で判定。両方を同時にタイルへ描画すると解像度(width/height)が行き来してチラつく)。
// 間引きは初回ストリームフレームが届いてから開始する — 起動直後(helper 起動待ち)はポーリングを
// 生かしたままにして、タイルが一瞬空白になるのを防ぐ(ポーリング→ストリーミングのシームレスな引き継ぎ)。
// ストリーミングが継続不能(onFailure)になった場合も同様にポーリングへ戻すだけで、明示的な
// フォールバック処理は不要(ポーリングは止めていないため)。
//
// streamingDeviceIds が変化するたび syncSuppressFrames() が monitor プロセスへ suppressFrames
// (Sources/ftester/ApiMonitorCommand.swift 同期)を送り、生成側でもポーリングを止める
// (monitorProcessManager.ts の間引きは受信後の安全弁として残る)。

import { resolveAdb, resolveAndroidStream, resolveSimStream } from "./config";
import { StreamPipeline } from "./deviceStream";
import type { MonitorDevice, MonitorPlatform } from "./monitorModel";
import type { MonitorPanelDeps } from "./monitorPanel";

/** applyDevices が1サイクル分の qualifying 判定と同時に組み立てる、起動に必要な情報一式。 */
interface QualifyingTarget {
  readonly platform: MonitorPlatform;
  /** iOS: シミュレータ UDID、Android: adb serial(disposeDevice の張り替え要否判定に使う)。 */
  readonly key: string;
  readonly command: string;
  readonly args: readonly string[];
}

interface StreamEntry {
  readonly platform: MonitorPlatform;
  readonly key: string;
  readonly pipeline: StreamPipeline;
}

export class MonitorDeviceStreamController {
  private readonly pipelines = new Map<string, StreamEntry>();
  /** 1フレーム以上届き、ポーリングフレームを間引いてよい状態のデバイス id 集合(isStreaming が見る)。 */
  private readonly streamingDeviceIds = new Set<string>();
  /** onFailure(helper が連続失敗で諦め)を受けたデバイス id。applyDevices は2秒毎に呼ばれるため、
   * これが無いと諦めた helper を毎回再生成してスパム再起動になる(将来の Xcode ABI 破壊時が該当)。
   * リセット条件は「デバイス切断=対象から外れる」か「パネル再表示(setVisible(true))」のみ。 */
  private readonly gaveUpDeviceIds = new Set<string>();
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
    const adbPath = androidStreamPath ? resolveAdb() : undefined;
    if (!simStreamPath && !(androidStreamPath && adbPath)) {
      this.disposeAll();
      return;
    }

    const qualifying = new Map<string, QualifyingTarget>();
    for (const device of devices) {
      if (device.state !== "connected") {
        continue;
      }
      if (simStreamPath && device.platform === "ios" && device.udid) {
        qualifying.set(device.id, {
          platform: "ios",
          key: device.udid,
          command: simStreamPath,
          args: ["--udid", device.udid, "--fps", String(config.liveFps), "--max-width", String(config.monitorMaxWidth)],
        });
      } else if (androidStreamPath && adbPath && device.platform === "android" && device.serial) {
        qualifying.set(device.id, {
          platform: "android",
          key: device.serial,
          command: androidStreamPath,
          args: [
            "--serial", device.serial, "--adb", adbPath,
            "--fps", String(config.liveFps), "--max-width", String(config.monitorMaxWidth),
          ],
        });
      }
    }

    // 対象から外れた(切断・一覧から消えた)、またはプラットフォーム/key が変わったデバイスを破棄する。
    for (const [deviceId, entry] of this.pipelines) {
      const target = qualifying.get(deviceId);
      if (!target || target.platform !== entry.platform || target.key !== entry.key) {
        this.disposeDevice(deviceId);
      }
    }
    // 対象から外れた=切断/消滅なので諦め状態を解除する(再接続したら再試行できるように)。
    for (const deviceId of [...this.gaveUpDeviceIds]) {
      if (!qualifying.has(deviceId)) {
        this.gaveUpDeviceIds.delete(deviceId);
      }
    }
    for (const [deviceId, target] of qualifying) {
      if (!this.pipelines.has(deviceId) && !this.gaveUpDeviceIds.has(deviceId)) {
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

  private startPipeline(deviceId: string, target: QualifyingTarget): void {
    const pipeline = new StreamPipeline({
      command: target.command,
      args: target.args,
      logPrefix: target.platform === "ios" ? "ios-stream" : "android-stream",
      outputChannel: this.deps.outputChannel,
      onFrame: (jpegBase64, width, height) => {
        if (!this.streamingDeviceIds.has(deviceId)) {
          this.streamingDeviceIds.add(deviceId);
          this.syncSuppressFrames();
        }
        this.deps.post({ type: "frame", device: deviceId, jpegBase64, width, height });
      },
      onConnectionOk: () => undefined,
      onFailure: (message) => {
        this.deps.outputChannel.appendLine(
          `[monitor-stream] ${deviceId}: ${message} ポーリングへ戻します。`,
        );
        this.disposeDevice(deviceId);
        this.gaveUpDeviceIds.add(deviceId); // 2秒毎の applyDevices による再生成スパムを止める
      },
    });
    this.pipelines.set(deviceId, { platform: target.platform, key: target.key, pipeline });
    pipeline.start();
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
    this.syncSuppressFrames();
  }

  /** streamingDeviceIds の現在値を monitor へ suppressFrames として送る(前回と同じなら送らない)。 */
  private syncSuppressFrames(): void {
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
