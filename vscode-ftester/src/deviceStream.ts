// deviceStream.ts
// ライブ操作タブ向けの、デバイス画面を映像ストリーミングする常駐 helper のプロセス管理。
// 現状は iOS シミュレータ専用(ftester-simstream)。ポーリング(monitorLiveController.ts の
// frameTick)に対する低負荷な代替として、helper が JPEG フレームを stdout へ流し続けるのを
// 逐次パースして onFrame へ渡す。プロセス管理は monitorLiveController.ts の serve と同じ思想:
// SIGTERM→2秒後 SIGKILL・予期しない終了は一定間隔で自動再起動・起動直後の異常終了が連続したら諦める。
//
// stdout フレームフォーマット(契約。対向: Sources/ftester-simstream/main.m。片方を変えたら両方直す):
//   フレームを次の順で繰り返す(テキストは一切混ざらない。ログ・エラーは stderr へ):
//     WIDTH : uint16 big-endian(エンコード済み画像の幅px)
//     HEIGHT: uint16 big-endian(エンコード済み画像の高さpx)
//     LEN   : uint32 big-endian(続く JPEG のバイト数)
//     JPEG  : LEN バイト
//   ライブ操作タブは w/h を使わない(タップ座標変換は serve snapshot の screen を基準にする)。
//   デバイスモニタータイルは w/h でタイルのアスペクト比を決めるため onFrame へ渡す(呼び出し側で
//   使うかどうかは自由。詳細は deviceTiles.js の applyFrame/--tile-aspect)。

import { type ChildProcessByStdio, spawn } from "node:child_process";
import type { Readable, Writable } from "node:stream";
import type { OutputChannel } from "vscode";

/** stdin/stdout/stderr すべてパイプの helper プロセス(stdin の EOF が helper への終了指示)。 */
type StreamProcess = ChildProcessByStdio<Writable, Readable, Readable>;

/** ヘッダ長: WIDTH(u16)+HEIGHT(u16)+LEN(u32)=8バイト。 */
const HEADER_LEN = 8;
/** SIGTERM 後、応答が無ければ SIGKILL するまでの猶予(ms)。 */
const KILL_GRACE_MS = 2000;
/** 予期しない終了後、自動再起動するまでの待ち(ms)。 */
const RESTART_DELAY_MS = 1000;
/** 無フレーム監視(wedge)の上限(ms)。これを超えて1フレームも届かなければ helper が固まったとみなし
 * 再起動する。iOS の静止画面は正当に長時間ほぼ0フレームになり得るため、短くすると健全な待機を
 * 誤検知する。15秒は「本当に固まった」場合だけを拾うための余裕。wedge 由来の kill は起動から
 * 15秒後=HEALTHY_WINDOW_MS 超なので、下の連続失敗カウントには載らず give-up を誘発しない。 */
const WEDGE_TIMEOUT_MS = 15000;
/** 「起動直後の異常終了」を数える窓(ms)。この時間内での終了だけを連続失敗としてカウントする。 */
const HEALTHY_WINDOW_MS = 10000;
/** HEALTHY_WINDOW_MS 内の連続異常終了がこの回数に達したら諦めて onFailure(→ポーリングへ)。 */
const MAX_QUICK_FAILURES = 3;

/** AndroidStreamPipeline 等が将来追加されても monitorLiveController.ts が両者を1つのフィールドで
 * 持てるようにする共通インターフェース(現状の実装は IosStreamPipeline のみ)。 */
export interface LiveStreamPipeline {
  start(): void;
  isRunning(): boolean;
  dispose(): void;
}

export interface IosStreamPipelineOptions {
  readonly udid: string;
  readonly fps: number;
  readonly maxWidth: number;
  readonly simStreamPath: string;
  readonly outputChannel: OutputChannel;
  /** 完成した1フレームを base64 エンコード済み JPEG(+エンコード済み画像の幅高さpx)で渡す。 */
  onFrame(jpegBase64: string, width: number, height: number): void;
  /** フレーム到達=接続健全のシグナル(接続断オーバーレイの解除に使う)。 */
  onConnectionOk(): void;
  /** ストリーミングを継続できず諦めたときに1回だけ呼ぶ(呼び出し側はポーリングへフォールバック)。 */
  onFailure(message: string): void;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** proc を SIGTERM(graceMs 後に SIGKILL)で止める。stdin EOF は呼び出し側で別途送る。 */
function killWithGrace(proc: StreamProcess, graceMs: number): void {
  if (proc.exitCode !== null || proc.signalCode !== null) {
    return;
  }
  proc.kill("SIGTERM");
  setTimeout(() => {
    if (proc.exitCode === null && proc.signalCode === null) {
      proc.kill("SIGKILL");
    }
  }, graceMs);
}

export class IosStreamPipeline implements LiveStreamPipeline {
  private process: StreamProcess | undefined;
  /** stdout の未処理バイト(フレーム境界をまたぐ端数を次チャンクへ持ち越す)。 */
  private buffer: Buffer = Buffer.alloc(0);
  private restartTimer: ReturnType<typeof setTimeout> | undefined;
  private wedgeTimer: ReturnType<typeof setTimeout> | undefined;
  /** 直近 spawn 時刻(ms)。close 時の経過時間で「起動直後の異常終了」を判定する。 */
  private startedAt = 0;
  private failureStreak = 0;
  /** stop()/dispose() による意図した終了か(close ハンドラで自動再起動を抑止する)。 */
  private stopping = false;
  private disposed = false;
  /** 連続失敗で諦めた状態。以後 start()/再起動は行わない。 */
  private gaveUp = false;

  constructor(private readonly options: IosStreamPipelineOptions) {}

  start(): void {
    if (this.disposed || this.gaveUp || this.isRunning()) {
      return;
    }
    this.spawnProcess();
  }

  isRunning(): boolean {
    const proc = this.process;
    return proc !== undefined && proc.exitCode === null && proc.signalCode === null;
  }

  /** helper を止める(再起動しない)。dispose との違いは disposed フラグを立てない点のみ。 */
  stop(): void {
    this.clearRestartTimer();
    this.clearWedgeTimer();
    const proc = this.process;
    this.process = undefined;
    this.buffer = Buffer.alloc(0);
    if (!proc) {
      return;
    }
    this.stopping = true;
    proc.stdin.end();
    killWithGrace(proc, KILL_GRACE_MS);
  }

  dispose(): void {
    this.disposed = true;
    this.stop();
  }

  private spawnProcess(): void {
    if (this.disposed) {
      return;
    }
    const args = [
      "--udid",
      this.options.udid,
      "--fps",
      String(this.options.fps),
      "--max-width",
      String(this.options.maxWidth),
    ];
    this.startedAt = Date.now();
    let proc: StreamProcess;
    try {
      proc = spawn(this.options.simStreamPath, args, { shell: false, stdio: ["pipe", "pipe", "pipe"] });
    } catch (error) {
      // spawn 失敗も「起動直後の異常終了」として連続失敗にカウントする(3連続で諦める)。
      this.handleUnexpectedExit(`起動に失敗しました: ${errorMessage(error)}`);
      return;
    }
    this.stopping = false;
    this.process = proc;
    this.buffer = Buffer.alloc(0);
    proc.stdin.on("error", () => undefined);
    proc.stdout.on("data", (chunk: Buffer) => this.ingest(chunk));

    // stderr は行単位で outputChannel へ。チャンク境界が行の途中で切れても取りこぼさないよう
    // 未完の末尾行を持ち越し、close で flush する。
    let stderrTail = "";
    proc.stderr.on("data", (chunk: Buffer) => {
      stderrTail += chunk.toString("utf8");
      const lines = stderrTail.split("\n");
      stderrTail = lines.pop() ?? "";
      for (const line of lines) {
        this.options.outputChannel.appendLine(`[ios-stream] ${line}`);
      }
    });

    proc.on("error", (error) => {
      this.options.outputChannel.appendLine(`[ios-stream] プロセスエラー: ${error.message}`);
    });

    proc.on("close", (code, signal) => {
      if (this.process !== proc) {
        return; // 既に別プロセスへ張り替え済み(通常起きない)
      }
      if (stderrTail.length > 0) {
        this.options.outputChannel.appendLine(`[ios-stream] ${stderrTail}`);
        stderrTail = "";
      }
      this.process = undefined;
      this.clearWedgeTimer();
      if (this.stopping) {
        this.stopping = false;
        return;
      }
      const reason = signal ? `signal ${signal}` : `exit code ${String(code)}`;
      this.handleUnexpectedExit(reason);
    });

    // 起動直後から無フレーム監視を開始する(以後フレームごとに再武装)。
    this.armWedgeTimer();
  }

  /** stdout の受信バイトからフレーム境界を切り出す。1フレーム完成するたびに即 onFrame(待ち貯めしない)。 */
  private ingest(chunk: Buffer): void {
    this.buffer = this.buffer.length === 0 ? chunk : Buffer.concat([this.buffer, chunk]);
    for (;;) {
      if (this.buffer.length < HEADER_LEN) {
        return;
      }
      const width = this.buffer.readUInt16BE(0);
      const height = this.buffer.readUInt16BE(2);
      const len = this.buffer.readUInt32BE(4);
      const frameEnd = HEADER_LEN + len;
      if (this.buffer.length < frameEnd) {
        return; // JPEG がまだ全部届いていない。次チャンクを待つ。
      }
      const jpeg = this.buffer.subarray(HEADER_LEN, frameEnd);
      this.buffer = this.buffer.subarray(frameEnd);
      this.emitFrame(jpeg, width, height);
    }
  }

  private emitFrame(jpeg: Buffer, width: number, height: number): void {
    this.options.onConnectionOk();
    this.armWedgeTimer(); // フレーム到達で無フレーム監視をリセット
    this.options.onFrame(jpeg.toString("base64"), width, height);
  }

  private handleUnexpectedExit(reason: string): void {
    if (this.disposed) {
      return;
    }
    const elapsed = Date.now() - this.startedAt;
    if (elapsed < HEALTHY_WINDOW_MS) {
      this.failureStreak += 1;
    } else {
      this.failureStreak = 0;
    }
    if (this.failureStreak >= MAX_QUICK_FAILURES) {
      this.gaveUp = true;
      this.options.outputChannel.appendLine(
        `[ios-stream] 起動直後の異常終了が続いたため画面ストリーミングを停止します(${reason})。`,
      );
      this.options.onFailure(`iOS 画面ストリーミングを継続できませんでした(${reason})。`);
      return;
    }
    this.options.outputChannel.appendLine(`[ios-stream] 予期しない終了(${reason})。${RESTART_DELAY_MS}ms 後に再起動します。`);
    this.scheduleRestart();
  }

  private scheduleRestart(): void {
    this.clearRestartTimer();
    this.restartTimer = setTimeout(() => {
      this.restartTimer = undefined;
      if (this.disposed || this.gaveUp) {
        return;
      }
      this.spawnProcess();
    }, RESTART_DELAY_MS);
  }

  private armWedgeTimer(): void {
    this.clearWedgeTimer();
    this.wedgeTimer = setTimeout(() => {
      this.wedgeTimer = undefined;
      this.handleWedge();
    }, WEDGE_TIMEOUT_MS);
  }

  /** 無フレームが続いた=固まったとみなし kill する。stopping を立てないので close ハンドラが
   * unexpected 扱いで再起動する(=wedge からの自動復帰)。 */
  private handleWedge(): void {
    const proc = this.process;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    this.options.outputChannel.appendLine(
      `[ios-stream] ${WEDGE_TIMEOUT_MS / 1000}秒フレームが届かないため helper を再起動します。`,
    );
    proc.stdin.end();
    killWithGrace(proc, KILL_GRACE_MS);
  }

  private clearRestartTimer(): void {
    if (this.restartTimer) {
      clearTimeout(this.restartTimer);
      this.restartTimer = undefined;
    }
  }

  private clearWedgeTimer(): void {
    if (this.wedgeTimer) {
      clearTimeout(this.wedgeTimer);
      this.wedgeTimer = undefined;
    }
  }
}
