// monitorDeviceStreamController.ts
// デバイスモニタータイル(deviceTiles.js)向け iOS 画面ストリーミング制御。ライブ操作タブと同じ
// IosStreamPipeline(deviceStream.ts)を、connected な iOS タイルの数だけ束ねて使い回す
// (供給・再起動ロジックはそちらに一本化されているため複製しない)。
//
// ストリーミング中は monitorProcessManager.ts が2秒間隔で送るポーリングフレームを間引く
// (isStreaming で判定。両方を同時にタイルへ描画すると解像度(width/height)が行き来してチラつく)。
// 間引きは初回ストリームフレームが届いてから開始する — 起動直後(helper 起動待ち)はポーリングを
// 生かしたままにして、タイルが一瞬空白になるのを防ぐ(ポーリング→ストリーミングのシームレスな引き継ぎ)。
// ストリーミングが継続不能(onFailure)になった場合も同様にポーリングへ戻すだけで、明示的な
// フォールバック処理は不要(ポーリングは止めていないため)。

import { resolveSimStream } from "./config";
import { IosStreamPipeline } from "./deviceStream";
import type { MonitorDevice } from "./monitorModel";
import type { MonitorPanelDeps } from "./monitorPanel";

interface StreamEntry {
  readonly udid: string;
  readonly pipeline: IosStreamPipeline;
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

  constructor(private readonly deps: MonitorPanelDeps) {}

  isStreaming(deviceId: string): boolean {
    return this.streamingDeviceIds.has(deviceId);
  }

  /** monitorDevices イベントのたびに呼ぶ(monitorProcessManager.ts 参照)。対象外になったデバイスは
   * 破棄し、新たに対象になったデバイスはパイプラインを起動する。 */
  applyDevices(devices: readonly MonitorDevice[]): void {
    if (!this.visible) {
      return; // 非表示中は setVisible(false) で全破棄済み。再開は次の setVisible(true) 後の呼び出しに任せる。
    }
    const config = this.deps.getConfig();
    const simStreamPath = config.iosStreamEnabled ? resolveSimStream(config) : undefined;
    if (!simStreamPath) {
      this.disposeAll();
      return;
    }

    const qualifying = new Map<string, string>(); // deviceId -> udid
    for (const device of devices) {
      if (device.platform === "ios" && device.state === "connected" && device.udid) {
        qualifying.set(device.id, device.udid);
      }
    }

    // 対象から外れた(切断・Android化・一覧から消えた)、または udid が変わったデバイスを破棄する。
    for (const [deviceId, entry] of this.pipelines) {
      const udid = qualifying.get(deviceId);
      if (udid === undefined || udid !== entry.udid) {
        this.disposeDevice(deviceId);
      }
    }
    // 対象から外れた=切断/消滅なので諦め状態を解除する(再接続したら再試行できるように)。
    for (const deviceId of [...this.gaveUpDeviceIds]) {
      if (!qualifying.has(deviceId)) {
        this.gaveUpDeviceIds.delete(deviceId);
      }
    }
    for (const [deviceId, udid] of qualifying) {
      if (!this.pipelines.has(deviceId) && !this.gaveUpDeviceIds.has(deviceId)) {
        this.startPipeline(deviceId, udid, simStreamPath, config.liveFps, config.monitorMaxWidth);
      }
    }
  }

  private startPipeline(
    deviceId: string,
    udid: string,
    simStreamPath: string,
    fps: number,
    maxWidth: number,
  ): void {
    const pipeline = new IosStreamPipeline({
      udid,
      fps,
      maxWidth,
      simStreamPath,
      outputChannel: this.deps.outputChannel,
      onFrame: (jpegBase64, width, height) => {
        this.streamingDeviceIds.add(deviceId);
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
    this.pipelines.set(deviceId, { udid, pipeline });
    pipeline.start();
  }

  private disposeDevice(deviceId: string): void {
    this.pipelines.get(deviceId)?.pipeline.dispose();
    this.pipelines.delete(deviceId);
    this.streamingDeviceIds.delete(deviceId);
  }

  private disposeAll(): void {
    for (const deviceId of [...this.pipelines.keys()]) {
      this.disposeDevice(deviceId);
    }
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
