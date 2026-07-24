// エミュレータ gRPC エンドポイントのディスカバリ(vscode / @grpc を import しない純粋部。
// テストバンドル(esm)が grpc-js を引き込むと動的 require で落ちるため、gRPC 呼び出し系
// (emulatorGrpc.ts)と分離してある。統合しないこと)。
// Swift 側の対応実装: Sources/FTEmulatorGrpc/EmulatorEndpoints.swift(挙動を変えるときは同期させる)

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

export interface EmulatorEndpoint {
  readonly serial: string; // "emulator-5554"
  readonly avdId: string;
  readonly grpcPort: number;
  readonly token: string;
  readonly pid: number; // 同一 serial の再ブート判別に使う(gRPC 失敗メモのキー)
}

const DEFAULT_DISCOVERY_DIR = path.join(os.homedir(), "Library/Caches/TemporaryItems/avd/running");

/** ディスカバリ ini の parse(テスト対象の純粋関数)。書式: `key=value` 行の羅列。
 * grpc.token は base64 で `=` を含みうるため、行内の最初の `=` でのみ分割する(グローバル split 禁止)。 */
export function parseEmulatorIni(text: string, pid: number): EmulatorEndpoint | undefined {
  const values = new Map<string, string>();
  for (const line of text.split("\n")) {
    const eq = line.indexOf("=");
    if (eq < 0) continue;
    values.set(line.slice(0, eq), line.slice(eq + 1));
  }
  const avdId = values.get("avd.id");
  const serialPort = values.get("port.serial");
  const grpcPort = Number(values.get("grpc.port"));
  const token = values.get("grpc.token");
  if (avdId === undefined || serialPort === undefined || !Number.isFinite(grpcPort) ||
      token === undefined || token === "") {
    return undefined;
  }
  return { serial: `emulator-${serialPort}`, avdId, grpcPort, token, pid };
}

function isPidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/** serial に対応する稼働中(プロセス生存確認済み)エンドポイントを返す(無ければ undefined =
 * 実機 or gRPC 情報なし)。directory はテスト用の差し替え口(既定は実ディスカバリディレクトリ)。 */
export function endpointForSerial(
  serial: string,
  directory: string = DEFAULT_DISCOVERY_DIR,
): EmulatorEndpoint | undefined {
  let names: string[];
  try {
    names = fs.readdirSync(directory);
  } catch {
    return undefined;
  }
  for (const name of names) {
    if (!name.startsWith("pid_") || !name.endsWith(".ini")) continue;
    const pid = Number(name.slice(4, -4));
    if (!Number.isFinite(pid) || !isPidAlive(pid)) continue;
    let text: string;
    try {
      text = fs.readFileSync(path.join(directory, name), "utf8");
    } catch {
      continue;
    }
    const endpoint = parseEmulatorIni(text, pid);
    if (endpoint !== undefined && endpoint.serial === serial) return endpoint;
  }
  return undefined;
}
