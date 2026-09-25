// monitorDeviceOpsText.ts
// monitorDeviceOps.ts/monitorDeviceCreateOps.ts が共有する文言組み立ての純粋関数群。

import { t, type MessageKey } from "./i18n";
import { type MachineLock, isConfirmedHeld } from "./machineLockModel";
import { formatBytesAuto } from "./retentionModel";
import { type DeviceCommandSource } from "./remoteRunArgs";

/** エラーメッセージへマシン名を付記する(§13 段2「失敗時はマシン名込みのメッセージにする」)。
 * ローカルは素通し(既存の文言を変えない)。 */
export function withSourceContext(message: string, source: DeviceCommandSource): string {
  return source.kind === "remote" ? t("deviceOps.remoteMachineSuffix", { machine: source.machine, message }) : message;
}

/**
 * 失敗メッセージへ添える stderr の1行。**exit code だけでは受け手が何もできない** ——
 * とくにリモート転送(`remote exec <host>`)は原因と対処を stderr の最終行に出す
 * (例: exit 91 = "this issuer has no runner workspace on … — run `fleetest remote setup …`")。
 * 進捗見出し("==> …")は落として最後の実質行を採り、webview の1行表示に収まる長さで切る。
 * 実質行が無ければ null(呼び出し側は exit code だけの文言に落ちる)。
 */
export function stderrDetailLine(stderr: string, limit = 200): string | null {
  const lines = stderr
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !line.startsWith("==>"));
  const last = lines[lines.length - 1];
  if (last === undefined) {
    return null;
  }
  return last.length > limit ? `${last.slice(0, limit)}…` : last;
}

/** 種別 → 事実の i18n キー(FTBridgeClient の XcodeSigningProblem の raw 値と対。
 * 片方だけ変えない: Swift 側は testRawValuesAreTheWireContractWithTheExtension が固定)。
 * ここに無い種別は事実行を出さないだけ(見出しは出る)= CLI が判定を増やしても壊れない。 */
const SIGNING_FACT_KEYS: Record<string, MessageKey> = {
  noAccount: "deviceOps.signing.fact.noAccount",
  noAccountForTeam: "deviceOps.signing.fact.noAccountForTeam",
  invalidCertificate: "deviceOps.signing.fact.invalidCertificate",
  deviceNotRegistered: "deviceOps.signing.fact.deviceNotRegistered",
  certificateNotInProfile: "deviceOps.signing.fact.certificateNotInProfile",
  deviceNotInProfile: "deviceOps.signing.fact.deviceNotInProfile",
  keychainLocked: "deviceOps.signing.fact.keychainLocked",
};

/** ポータル通信(端末登録・プロファイルの取り直し)が要る種別(Swift 側 needsProvisioningUpdate
 * と対)。ssh 越し(= 別の機械へ `remote exec` した)なら「GUI セッションで一度」、手元なら
 * 「登録直後の1回目は落ちる。もう一度」だけを添える(GUI に居る人へ「GUI で」は行き止まり)。 */
const SIGNING_NEEDS_PORTAL = new Set([
  "deviceNotRegistered", "certificateNotInProfile", "deviceNotInProfile",
]);

/** CLI が「署名で止まった」と判定したときの案内を、**この拡張の言語で**組み立てる。
 * 判定は CLI(FTBridgeClient の XcodeSigningDiagnosis)、文言はここ
 * (CLAUDE.md「共有するのは判定であって文言ではない」)。
 *
 * **事実(どれが欠けているか)は言い、手順は書かない**(Xcode も macOS も版ごとに手順が
 * 変わり、書いた手順は必ず古くなる)。**1つも種別を知らなければ null** —— 見出しだけの案内で
 * CLI の error(全種別の事実を含む)を上書きすると、版ズレのとき情報を捨てることになる。 */
export function signingGuidance(
  problems: readonly string[], logPath: string | undefined, overSSH: boolean,
): string | null {
  if (problems.length === 0) {
    return null;
  }
  const facts = problems
    .map((kind) => SIGNING_FACT_KEYS[kind])
    .filter((key): key is MessageKey => key !== undefined)
    .map((key) => t(key));
  if (facts.length === 0) {
    return null;
  }
  // キーチェーンのロックだけなら Xcode の署名設定は無関係(CLI 側の guidance と同じ出し分け)
  const onlyKeychain = problems.every((kind) => kind === "keychainLocked");
  const lines = [t(onlyKeychain
    ? "deviceOps.signing.headlineNotXcodeSetup"
    : "deviceOps.signing.headline")];
  lines.push(t("deviceOps.signing.detected", { facts: facts.join(" / ") }));
  if (problems.some((kind) => SIGNING_NEEDS_PORTAL.has(kind))) {
    lines.push(t(overSSH ? "deviceOps.signing.portalNeedsGui" : "deviceOps.signing.portalRetryOnce"));
  }
  // CLI 側の guidance と同じ出し分け(判定は同じ、文言はそれぞれが持つ)
  if (overSSH && problems.includes("keychainLocked")) {
    lines.push(t("deviceOps.signing.keychainUnlockScope"));
  }
  if (logPath !== undefined) {
    lines.push(t("deviceOps.signing.fullLog", { path: logPath }));
  }
  return lines.join("\n");
}

/** xcodebuild 自身が出す素の verdict バナー(例: "** TEST BUILD FAILED **")。見出しと同じ
 * 「失敗した」を繰り返すだけで原因を持たないので、原因行を探すときは候補から外す
 * (外さないと常に最終行のこれを拾って見出しの言い直しにしかならない)。 */
const XCODEBUILD_VERDICT_BANNER = /^\*\*.*\*\*$/;

/** 失敗の印(error: / errSec* / failed)を含む行を**後ろから**探す。xcodebuild は原因の行を
 * 先に出し、末尾に verdict バナーを置く構成なので、後ろから探すほうが「直前の具体行」に
 * 素早く当たる(前から探すと無関係な note/序盤の行に当たる)。 */
function reasonLine(lines: readonly string[]): string | undefined {
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    const line = lines[i];
    if (line === undefined || XCODEBUILD_VERDICT_BANNER.test(line)) {
      continue;
    }
    if (/error|errsec|fail/i.test(line)) {
      return line;
    }
  }
  return undefined;
}

/** 複数行のエラーの1行目(バナー用)。空行は飛ばし、長ければ切る
 * (stderrDetailLine と対 —— あちらは stderr の**最後**の実質行、こちらは NDJSON の
 * error の**先頭**行。CLI が先頭行に要点を置く契約なのでここは先頭を採る)。
 *
 * **先頭行が見出し(":" で終わる)なら単独では情報が無い**
 * (実例: "xcodebuild build-for-testing failed:\n<tail>" — 原因は次の行以降。見出しだけを
 * 返すと「失敗しました」しか言わないバナーになる)。このときは reasonLine で原因らしい行を
 * 後ろから探して添える。見つからなければ最後の非空行を使う。見出しで終わらない普通の
 * 1行エラーはそのまま(ここを通らない)。 */
export function firstLine(message: string, limit = 200): string {
  const lines = message.split("\n").map((value) => value.trim()).filter((value) => value.length > 0);
  const head = lines[0];
  if (head === undefined) {
    return message;
  }
  let text = head;
  if (head.endsWith(":")) {
    const tail = lines.slice(1);
    const detail = reasonLine(tail) ?? tail[tail.length - 1];
    if (detail !== undefined && detail !== head) {
      text = `${head} ${detail}`;
    }
  }
  return text.length > limit ? `${text.slice(0, limit)}…` : text;
}

/** ダウンロードが要る Android システムイメージの容量注記("(約 1.9 GB)")。sizeBytes が読めなければ
 * 空文字(「不明」を断定しない。テンプレート側は空文字を許容する形で書く)。 */
function installSystemImageSizeNote(sizeBytes: number | null): string {
  return sizeBytes === null ? "" : t("deviceOps.installSystemImageSizeNote", { size: formatBytesAuto(sizeBytes) });
}

/** 同上のライセンス識別子注記("(android-sdk-arm-dbt-license)")。license が読めなければ空文字。 */
function installSystemImageLicenseNote(license: string | null): string {
  return license === null ? "" : t("deviceOps.installSystemImageLicenseNote", { license });
}

/**
 * confirmAndInstallThenCreate(単発作成)の確認メッセージ。vscode 非依存の純粋関数として切り出し、
 * 組み立てをテストできるようにする(firstLine/signingGuidance と同じ方針)。
 */
export function installSystemImageConfirmMessage(params: {
  readonly machine: string;
  readonly name: string;
  readonly packageName: string;
  readonly sizeBytes: number | null;
  readonly license: string | null;
}): string {
  return t("deviceOps.installSystemImageConfirmMessage", {
    machine: params.machine,
    package: params.packageName,
    sizeNote: installSystemImageSizeNote(params.sizeBytes),
    name: params.name,
    licenseNote: installSystemImageLicenseNote(params.license),
  });
}

/** runBatchCreateDevices の同名確認メッセージ(バッチ版。count/first/last は既存の
 * batchConfirmMessage と同じ組み立て方)。 */
export function installSystemImageBatchConfirmMessage(params: {
  readonly machine: string;
  readonly count: number;
  readonly first: string;
  readonly last: string;
  readonly packageName: string;
  readonly sizeBytes: number | null;
  readonly license: string | null;
}): string {
  return t("deviceOps.installSystemImageBatchConfirmMessage", {
    machine: params.machine,
    package: params.packageName,
    sizeNote: installSystemImageSizeNote(params.sizeBytes),
    count: String(params.count),
    first: params.first,
    last: params.last,
    licenseNote: installSystemImageLicenseNote(params.license),
  });
}

/**
 * 破壊的操作の確認に添える占有の1行(その機械で run が走っているときだけ)。
 * **`machine === null` は手元**で、呼び名は既存の1つ(`deviceOps.machineLocalLabel`)。
 * **占有が不明(観測できていない)なら何も足さない** —— 「走っていない」と請け合わないための沈黙
 * (docs/remote-runner.md §18.1 #6)。控えは呼び手が引いて渡す(純粋関数)。
 */
export function occupancyDetailLine(
  machine: string | null,
  lock: MachineLock | undefined,
): string | undefined {
  if (!isConfirmedHeld(lock)) {
    return undefined;
  }
  return t("deviceOps.occupiedDetail", {
    machine: machine ?? t("deviceOps.machineLocalLabel"),
    issuer: lock?.issuer ?? t("deviceOps.occupiedIssuerUnknown"),
  });
}
