// emulatorGrpc.ts
// Android エミュレータの EmulatorController gRPC 経路(vscode を import しない。
// adbWifiRepair.ts/orphanSweep.ts と同じ方針)。Swift 側の対応実装(挙動を変えるときは同期させる):
//   - ini ディスカバリ/parse: Sources/FTEmulatorGrpc/EmulatorEndpoints.swift
//   - RPC 呼び出し・タイムアウト・接続方針: Sources/FTEmulatorGrpc/EmulatorGrpcSession.swift
//   - フォールバック方針・pid 失敗メモ・殺しスイッチ: Sources/FTAndroid/EmulatorControl.swift
// proto は third_party/emulator-proto/emulator_controller.proto の逐語コピー(assets/ 配下。
// 同期手順は third_party/emulator-proto/README.md。手で編集しない)。

import * as path from "node:path";
import * as grpc from "@grpc/grpc-js";
import * as protoLoader from "@grpc/proto-loader";
import { EmulatorEndpoint, endpointForSerial } from "./emulatorEndpoints";

// --- gRPC 呼び出し ---
// evdev キーコード。KEY_WAKEUP(143) は emulator のキー変換で欠落し不発(2026-07-25 実測)なので
// 使わない。KEY_SLEEP は非トグルで確実に Asleep、直後の KEY_POWER トグルは確実に wake になる
// (EmulatorGrpcSession.sleepWake と同じ順序であること)。
const KEY_SLEEP = 142;
const KEY_POWER = 116;
const KEY_CODE_TYPE_EVDEV = 1;
const KEY_EVENT_TYPE_KEYPRESS = 2;
const IMAGE_FORMAT_PNG = 0;
const RPC_DEADLINE_MS = 10_000;

/** 一度でも gRPC 呼び出しに失敗した emulator pid(同一ブート中は adb 固定。再試行で遅くしない。
 * 再ブートで pid が変われば自動的に gRPC へ復帰する)。Node はシングルスレッドなので
 * Swift 側 EmulatorControl.failedPids と違いロック不要。 */
const failedPids = new Set<number>();

function grpcDisabled(): boolean {
  return process.env.FT_EMULATOR_CONTROL === "adb";
}

// 動的ロードした proto の型(grpc.loadPackageDefinition の戻り値)には静的な形が無いため、
// この境界だけ any を使う(動的 gRPC クライアントの標準的な扱い)。
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type DynamicProto = any;

let cachedProto: DynamicProto | undefined;

function loadEmulatorControllerProto(): DynamicProto {
  if (cachedProto === undefined) {
    // __dirname は cjs ビルド(dist/extension.js)基準で assets/ を指す。esm のテストバンドル
    // (esbuild.mjs --tests)では __dirname 未定義だが、この関数はテスト対象の parse 系関数からは
    // 呼ばれないため評価されない(呼べば ReferenceError。モジュール top-level に置かないこと)。
    const protoPath = path.join(__dirname, "..", "assets", "emulator_controller.proto");
    // google/protobuf/empty.proto(sendKey の応答型)は protobufjs 内蔵の well-known types で
    // 解決される。ファイルをディスクに置く必要も includeDirs も不要。
    const packageDefinition = protoLoader.loadSync(protoPath, {
      keepCase: true,
      longs: String,
      enums: String,
      defaults: true,
      oneofs: true,
    });
    cachedProto = grpc.loadPackageDefinition(packageDefinition);
  }
  return cachedProto;
}

function newControllerClient(endpoint: EmulatorEndpoint): DynamicProto {
  const proto = loadEmulatorControllerProto();
  const ControllerCtor = proto.android.emulation.control.EmulatorController;
  return new ControllerCtor(`127.0.0.1:${endpoint.grpcPort}`, grpc.credentials.createInsecure());
}

function authMetadata(endpoint: EmulatorEndpoint): grpc.Metadata {
  const metadata = new grpc.Metadata();
  metadata.add("authorization", `Bearer ${endpoint.token}`);
  return metadata;
}

/** 単発 RPC(呼び出し毎に接続を張って閉じる。loopback なので接続コストは ~ms。
 * Swift 側 EmulatorGrpcSession.withController と同じ「connect per call」方針)。 */
function callRpc<TRequest, TResponse>(
  endpoint: EmulatorEndpoint,
  method: string,
  request: TRequest,
): Promise<TResponse> {
  const client = newControllerClient(endpoint);
  return new Promise<TResponse>((resolve, reject) => {
    client[method](
      request,
      authMetadata(endpoint),
      { deadline: Date.now() + RPC_DEADLINE_MS },
      (error: grpc.ServiceError | null, response: TResponse) => {
        client.close();
        if (error) reject(error);
        else resolve(response);
      },
    );
  });
}

/** 殺しスイッチ・ディスカバリ・pid 失敗メモを一括で見る包み(Swift 側 EmulatorControl.perform 相当)。
 * op が投げたら pid を失敗メモに記録し、以降このブート中は undefined を返し続ける。 */
async function withGrpc<T>(
  serial: string,
  op: (endpoint: EmulatorEndpoint) => Promise<T>,
): Promise<T | undefined> {
  if (grpcDisabled()) return undefined;
  const endpoint = endpointForSerial(serial);
  if (endpoint === undefined || failedPids.has(endpoint.pid)) return undefined;
  try {
    return await op(endpoint);
  } catch {
    failedPids.add(endpoint.pid);
    return undefined;
  }
}

/** PNG スクリーンショットのバイト数。undefined = gRPC 不可(呼び出し側が adb screencap へ
 * フォールバックする。blank 閾値の適用はここでは行わない=呼び出し側の責務、Swift 側
 * screencapByteCount/blankScreen の分離と同じ)。 */
export function grpcScreenshotPngBytes(serial: string): Promise<number | undefined> {
  return withGrpc(serial, async (endpoint) => {
    const image = await callRpc<{ format: number }, { image: Buffer }>(endpoint, "getScreenshot", {
      format: IMAGE_FORMAT_PNG,
    });
    return image.image.length;
  });
}

function sendEvdevKeypress(endpoint: EmulatorEndpoint, keyCode: number): Promise<unknown> {
  return callRpc(endpoint, "sendKey", {
    codeType: KEY_CODE_TYPE_EVDEV,
    eventType: KEY_EVENT_TYPE_KEYPRESS,
    keyCode,
  });
}

/** sleep/wake 1サイクル(KEY_SLEEP→dwell→KEY_POWER)。false = gRPC 不可(呼び出し側が adb の
 * sleep/dwell/wake フルサイクルへフォールバックする)。呼び出し側は戻り値に関わらずこの後さらに
 * dwellMs 待ってからプローブすること(整定待ちは呼び出し側の責務。adbWifiRepair.ts 参照)。 */
export async function grpcSleepWake(serial: string, dwellMs: number): Promise<boolean> {
  const result = await withGrpc(serial, async (endpoint) => {
    await sendEvdevKeypress(endpoint, KEY_SLEEP);
    await new Promise((resolve) => setTimeout(resolve, dwellMs));
    await sendEvdevKeypress(endpoint, KEY_POWER);
  });
  return result !== undefined;
}
