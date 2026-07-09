// ndjson.ts
// NDJSON (改行区切り JSON) ストリームのパーサ。vscode モジュールに依存しない純粋なクラス。
//
// ポイント: 受け取った Buffer チャンクは文字列化せずにそのまま連結し、
// 改行バイト(0x0A)で1行分の Buffer が確定してから初めて toString('utf8') する。
// これにより、UTF-8 のマルチバイト文字(日本語など)がチャンク境界で分断されても
// 文字化けせずに正しく復元できる。

export type NdjsonValueHandler = (value: unknown) => void;
export type NdjsonNonJsonHandler = (line: string) => void;

const LF = 0x0a;
const CR = 0x0d;

/**
 * push() で Buffer チャンクを渡すとバイト単位で行を切り出し、
 * JSON としてパースできた行は onValue に、パースできなかった行(空行を除く)は
 * onNonJson に渡す(呼び出し側はこれを log として扱う想定)。
 *
 * ストリーム終了時は end() を呼ぶこと。末尾に改行が無いまま EOF になったデータも
 * 1行として処理される。
 */
export class NdjsonParser {
  private buffer: Buffer = Buffer.alloc(0);

  constructor(
    private readonly onValue: NdjsonValueHandler,
    private readonly onNonJson: NdjsonNonJsonHandler,
  ) {}

  /** 新しいチャンクを追加し、確定した行があれば逐次コールバックを呼ぶ。 */
  push(chunk: Buffer): void {
    this.buffer = this.buffer.length === 0 ? chunk : Buffer.concat([this.buffer, chunk]);

    let newlineIndex = this.buffer.indexOf(LF);
    while (newlineIndex !== -1) {
      const lineBuf = this.buffer.subarray(0, newlineIndex);
      this.buffer = this.buffer.subarray(newlineIndex + 1);
      this.emitLine(lineBuf);
      newlineIndex = this.buffer.indexOf(LF);
    }
  }

  /** ストリーム終了時に呼ぶ。改行の無い残存データがあれば1行として処理してからバッファを空にする。 */
  end(): void {
    if (this.buffer.length > 0) {
      const rest = this.buffer;
      this.buffer = Buffer.alloc(0);
      this.emitLine(rest);
    }
  }

  private emitLine(lineBuf: Buffer): void {
    // CRLF 対応: 末尾の \r を取り除く。
    let end = lineBuf.length;
    if (end > 0 && lineBuf[end - 1] === CR) {
      end -= 1;
    }
    const line = lineBuf.subarray(0, end).toString("utf8");
    const trimmed = line.trim();
    if (trimmed.length === 0) {
      return; // 空行は無視する
    }
    try {
      const value: unknown = JSON.parse(trimmed);
      this.onValue(value);
    } catch {
      this.onNonJson(line);
    }
  }
}
