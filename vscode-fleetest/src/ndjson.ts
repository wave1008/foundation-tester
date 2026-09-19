// ndjson.ts
// NDJSON ストリームのパーサ。vscode モジュールに依存しない。
//
// Buffer チャンクは文字列化せず連結し、改行バイト(0x0A)で1行分の Buffer が確定してから
// toString('utf8') する。UTF-8 マルチバイト文字がチャンク境界で分断されても文字化けしないための実装。

export type NdjsonValueHandler = (value: unknown) => void;
export type NdjsonNonJsonHandler = (line: string) => void;

const LF = 0x0a;
const CR = 0x0d;

/** onNonJson に渡る行(パース失敗・空行を除く)は呼び出し側で log として扱う想定。 */
export class NdjsonParser {
  private buffer: Buffer = Buffer.alloc(0);

  constructor(
    private readonly onValue: NdjsonValueHandler,
    private readonly onNonJson: NdjsonNonJsonHandler,
  ) {}

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

  /** 末尾に改行が無いまま EOF になったデータも1行として処理する。 */
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
      return;
    }
    try {
      const value: unknown = JSON.parse(trimmed);
      this.onValue(value);
    } catch {
      this.onNonJson(line);
    }
  }
}

/** OUTPUT へ生の行を出すときの上限(文字)。モニターの行は画像フレーム(jpegBase64・約10万文字)を
 * 含みうるので、読めなかった行を全文出すと base64 で OUTPUT が埋まる。診断に要るのは先頭(kind・device)と長さだけ */
export const LOG_LINE_MAX_CHARS = 300;

export function abbreviateLogLine(line: string, max: number = LOG_LINE_MAX_CHARS): string {
  if (line.length <= max) {
    return line;
  }
  return `${line.slice(0, max)}… (${line.length} chars, truncated)`;
}
