// deviceStream.ts
// ライブ操作タブ・デバイスモニタータイル向けの、デバイス画面を映像ストリーミングする常駐 helper の
// プロセス管理。iOS(ftester-simstream)・Android(ftester-androidstream)共通。両者の違いは
// spawn する command/args のみ(呼び出し側が組み立てる。StreamPipeline 自体はどちらのプラット
// フォームかを知らない)。ポーリング(monitorLiveController.ts の frameTick)に対する低負荷な代替
// として、helper が JPEG(v1)または H.264 AU(v2、--codec h264)を stdout へ流し続けるのを
// 逐次パースして onFrame/onChunk へ渡す。
// プロセス管理は monitorLiveController.ts の serve と同じ思想: SIGTERM→2秒後 SIGKILL・
// 予期しない終了は一定間隔で自動再起動・起動直後の異常終了が連続したら諦める。
//
// stdout フレームフォーマット(契約。対向: Sources/ftester-simstream/main.m(iOS)・
// Sources/ftester-androidstream/main.m(Android)。3ファイルとも直すこと):
//
// v1(既定。helper を --codec 未指定 or mjpeg で起動、StreamPipelineOptions.codec="mjpeg"):
//   フレームを次の順で繰り返す(テキストは一切混ざらない。ログ・エラーは stderr へ):
//     WIDTH : uint16 big-endian(エンコード済み画像の幅px)
//     HEIGHT: uint16 big-endian(エンコード済み画像の高さpx)
//     LEN   : uint32 big-endian(続く JPEG のバイト数)
//     JPEG  : LEN バイト
//   ライブ操作タブは w/h を使わない(タップ座標変換は serve snapshot の screen を基準にする)。
//   デバイスモニタータイルは w/h でタイルのアスペクト比を決めるため onFrame へ渡す(呼び出し側で
//   使うかどうかは自由。詳細は deviceTiles.js の applyFrame/--tile-aspect)。
//
// v2(helper を --codec h264 で起動、StreamPipelineOptions.codec="h264" のときのみ):
//   レコードを次の順で繰り返す:
//     KIND  : uint8(2=H.264 AU(Annex-B、SPS+PPS+IDR連結済みのキーフレームを含む)、
//             3=キープアライブ ping。他の値はプロトコル不整合)
//     FLAGS : uint8(bit0=キーフレーム。KIND=2 のみ意味を持つ)
//     WIDTH : uint16 big-endian(表示サイズpx。0=不明。受信側はデコード後の VideoFrame 実寸を使う)
//     HEIGHT: uint16 big-endian
//     LEN   : uint32 big-endian(続く DATA のバイト数。KIND=3 は 0)
//     DATA  : LEN バイト
//   KIND=3(ping)は onChunk を呼ばない(onConnectionOk+wedge リセットのみ)。未知 KIND は
//   ingest() が helper を kill する(handleUnknownKind。close ハンドラの自動再起動に任せる)。

import { type ChildProcessByStdio, spawn } from "node:child_process";
import type { Readable, Writable } from "node:stream";
import type { OutputChannel } from "vscode";

/** stdin/stdout/stderr すべてパイプの helper プロセス(stdin の EOF が helper への終了指示)。 */
type StreamProcess = ChildProcessByStdio<Writable, Readable, Readable>;

/** v1(mjpeg)ヘッダ長: WIDTH(u16)+HEIGHT(u16)+LEN(u32)=8バイト。 */
const MJPEG_HEADER_LEN = 8;
/** v2(h264)ヘッダ長: KIND(u8)+FLAGS(u8)+WIDTH(u16)+HEIGHT(u16)+LEN(u32)=10バイト。 */
const H264_HEADER_LEN = 10;
/** v2 KIND 値(ファイル冒頭の契約コメント参照)。 */
const H264_KIND_AU = 2;
const H264_KIND_PING = 3;
/** SIGTERM 後、応答が無ければ SIGKILL するまでの猶予(ms)。 */
const KILL_GRACE_MS = 2000;
/** 予期しない終了後、自動再起動するまでの待ち(ms)。 */
const RESTART_DELAY_MS = 1000;
/** 無フレーム監視(wedge)の上限(ms)。これを超えて1フレームも届かなければ helper が固まったとみなし
 * 再起動する。静止画面は正当に長時間ほぼ0フレームになり得るため、短くすると健全な待機を
 * 誤検知する。15秒は「本当に固まった」場合だけを拾うための余裕。wedge 由来の kill は起動から
 * 15秒後=HEALTHY_WINDOW_MS 超なので、下の連続失敗カウントには載らず give-up を誘発しない。 */
const WEDGE_TIMEOUT_MS = 15000;
/** 「起動直後の異常終了」を数える窓(ms)。この時間内での終了だけを連続失敗としてカウントする。 */
const HEALTHY_WINDOW_MS = 10000;
/** HEALTHY_WINDOW_MS 内の連続異常終了がこの回数に達したら諦めて onFailure(→ポーリングへ)。 */
const MAX_QUICK_FAILURES = 3;

/** iOS/Android 共通のストリーミング helper 制御インターフェース(monitorLiveController.ts・
 * monitorDeviceStreamController.ts が両プラットフォームを1つのフィールド/Mapで扱えるようにする)。 */
export interface LiveStreamPipeline {
  start(): void;
  isRunning(): boolean;
  dispose(): void;
}

export interface StreamPipelineOptions {
  /** helper 実行ファイルの絶対パス(iOS: ftester-simstream、Android: ftester-androidstream)。 */
  readonly command: string;
  /** helper へ渡す引数(--udid/--serial 等のプラットフォーム差分は呼び出し側が組み立て済み)。 */
  readonly args: readonly string[];
  /** outputChannel のログ行プレフィックス(例: "ios-stream"/"android-stream")。 */
  readonly logPrefix: string;
  readonly outputChannel: OutputChannel;
  /** stdout の形式。"mjpeg" は onFrame、"h264" は onChunk を使う(呼び出し側は両方定義してよい。
   * 使われない方は呼ばれないだけ)。helper には呼び出し側が args に "--codec h264" を付与すること
   * (このクラス自身は codec に応じたパース分岐のみ行い、起動引数は組み立てない)。 */
  readonly codec: "mjpeg" | "h264";
  /** 完成した1フレームを base64 エンコード済み JPEG(+エンコード済み画像の幅高さpx)で渡す(codec="mjpeg")。 */
  onFrame(jpegBase64: string, width: number, height: number): void;
  /** 完成した1 H.264 AU(Annex-B)を渡す(codec="h264"。KIND=3 ping では呼ばれない)。 */
  onChunk?(data: Buffer, keyframe: boolean, width: number, height: number): void;
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

export class StreamPipeline implements LiveStreamPipeline {
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

  constructor(private readonly options: StreamPipelineOptions) {}

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
    this.startedAt = Date.now();
    let proc: StreamProcess;
    try {
      proc = spawn(this.options.command, this.options.args, { shell: false, stdio: ["pipe", "pipe", "pipe"] });
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
        this.options.outputChannel.appendLine(`[${this.options.logPrefix}] ${line}`);
      }
    });

    proc.on("error", (error) => {
      this.options.outputChannel.appendLine(`[${this.options.logPrefix}] プロセスエラー: ${error.message}`);
    });

    proc.on("close", (code, signal) => {
      if (this.process !== proc) {
        return; // 既に別プロセスへ張り替え済み(通常起きない)
      }
      if (stderrTail.length > 0) {
        this.options.outputChannel.appendLine(`[${this.options.logPrefix}] ${stderrTail}`);
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

  /** stdout の受信バイトからレコード境界を切り出す(codec で v1/v2 に分岐)。1件完成するたびに
   * 即座にコールバックする(待ち貯めしない)。 */
  private ingest(chunk: Buffer): void {
    this.buffer = this.buffer.length === 0 ? chunk : Buffer.concat([this.buffer, chunk]);
    if (this.options.codec === "h264") {
      this.ingestH264();
    } else {
      this.ingestMjpeg();
    }
  }

  private ingestMjpeg(): void {
    for (;;) {
      if (this.buffer.length < MJPEG_HEADER_LEN) {
        return;
      }
      const width = this.buffer.readUInt16BE(0);
      const height = this.buffer.readUInt16BE(2);
      const len = this.buffer.readUInt32BE(4);
      const frameEnd = MJPEG_HEADER_LEN + len;
      if (this.buffer.length < frameEnd) {
        return; // JPEG がまだ全部届いていない。次チャンクを待つ。
      }
      const jpeg = this.buffer.subarray(MJPEG_HEADER_LEN, frameEnd);
      this.buffer = this.buffer.subarray(frameEnd);
      this.emitFrame(jpeg, width, height);
    }
  }

  private emitFrame(jpeg: Buffer, width: number, height: number): void {
    this.options.onConnectionOk();
    this.armWedgeTimer(); // フレーム到達で無フレーム監視をリセット
    this.options.onFrame(jpeg.toString("base64"), width, height);
  }

  /** v2(--codec h264)のレコードパーサ(ファイル冒頭の契約コメント参照)。未知 KIND はここでループを
   * 抜けて handleUnknownKind へ委ねる(以後の buffer は破棄済みなので継続パースしない)。 */
  private ingestH264(): void {
    for (;;) {
      if (this.buffer.length < H264_HEADER_LEN) {
        return;
      }
      const kind = this.buffer.readUInt8(0);
      const flags = this.buffer.readUInt8(1);
      const width = this.buffer.readUInt16BE(2);
      const height = this.buffer.readUInt16BE(4);
      const len = this.buffer.readUInt32BE(6);
      const recordEnd = H264_HEADER_LEN + len;
      if (this.buffer.length < recordEnd) {
        return; // DATA がまだ全部届いていない。次チャンクを待つ。
      }
      const data = this.buffer.subarray(H264_HEADER_LEN, recordEnd);
      this.buffer = this.buffer.subarray(recordEnd);
      if (kind === H264_KIND_AU) {
        this.emitChunk(data, (flags & 1) !== 0, width, height);
      } else if (kind === H264_KIND_PING) {
        this.options.onConnectionOk();
        this.armWedgeTimer();
      } else {
        this.handleUnknownKind(kind);
        return;
      }
    }
  }

  private emitChunk(data: Buffer, keyframe: boolean, width: number, height: number): void {
    this.options.onConnectionOk();
    this.armWedgeTimer();
    this.options.onChunk?.(data, keyframe, width, height);
  }

  /** 未知 KIND はプロトコル不整合(helper とパーサのバージョン不一致等)なのでログして helper を
   * kill する(handleWedge と同じく stopping を立てないため close ハンドラが自動再起動する)。
   * this.process が無い(未起動/直接 ingest を呼ぶ単体テスト)場合はログのみ。 */
  private handleUnknownKind(kind: number): void {
    this.buffer = Buffer.alloc(0); // 以後のバイト列は信頼できないため破棄する
    this.options.outputChannel.appendLine(
      `[${this.options.logPrefix}] 未知の KIND(${kind})を受信しました(プロトコル不整合)。helper を再起動します。`,
    );
    const proc = this.process;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    proc.stdin.end();
    killWithGrace(proc, KILL_GRACE_MS);
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
        `[${this.options.logPrefix}] 起動直後の異常終了が続いたため画面ストリーミングを停止します(${reason})。`,
      );
      this.options.onFailure(`画面ストリーミングを継続できませんでした(${reason})。`);
      return;
    }
    this.options.outputChannel.appendLine(
      `[${this.options.logPrefix}] 予期しない終了(${reason})。${RESTART_DELAY_MS}ms 後に再起動します。`,
    );
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
      `[${this.options.logPrefix}] ${WEDGE_TIMEOUT_MS / 1000}秒フレームが届かないため helper を再起動します。`,
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
