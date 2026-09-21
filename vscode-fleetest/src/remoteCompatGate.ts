// remoteCompatGate.ts
// `fleetest api remote-compat` の結果からダイアログ表示の要否を決める純粋関数(vscode 非依存)。
// テストは vscode-stub を経由せずここを直接 import する(remoteRunArgs.ts と同じ理由)。
// runHandler.ts の executeRun がこの判定を元に確認ダイアログ・align 実行を配線する。

export interface RemoteCompatMachine {
  /** 登録簿のマシン名(エイリアス)。sshTarget は解決後のホスト名 / IP で別物。
   * **キーは "machine"**(ProtocolVersion 9。Sources/fleetest/ApiRemoteCompatCommand.swift と対) */
  readonly machine: string;
  readonly sshTarget?: string;
  readonly reachable: boolean;
  readonly revision?: string | null;
  readonly revisionCompatible?: boolean | null;
  readonly revisionRelation?: string | null;
  readonly toolchain?: string | null;
  readonly toolchainCompatible?: boolean | null;
  /** 非 null なら「止めないが混在している」(例: Xcode 製品版は同じでベータ seed だけ違う)。
   * 非 null のときは toolchainCompatible は true(止めない側) */
  readonly toolchainAdvisory?: string | null;
  /** 非 null なら「そのランナーで使う Xcode を決められなかった」(候補一覧つきの英語1文)。
   * **toolchainCompatible は既に false**(CLI 側 `HostReport.toolchainCompatible` の不変条件)だが、
   * このゲート単体でも blocking 側へ倒す(呼び手が CLI の不変条件に依存しなくて済むように)。
   * align では直らない(Xcode の選定はランナー機側の作業) */
  readonly xcodeSelectionError?: string | null;
  readonly error?: string | null;
}

export interface RemoteCompatReport {
  readonly machines: RemoteCompatMachine[];
  readonly localRevision?: string | null;
  readonly localDirty?: boolean;
  readonly revisionPublished?: boolean;
}

export interface RemoteCompatAdvisory {
  readonly machine: string;
  readonly advisory: string;
}

export type RemoteCompatDecision =
  | { readonly kind: "proceed"; readonly advisoryMachines: RemoteCompatAdvisory[] }
  | {
      readonly kind: "ask";
      readonly incompatible: RemoteCompatMachine[];
      readonly advisoryMachines: RemoteCompatAdvisory[];
      readonly canUpdate: boolean;
      readonly updatableMachines: string[];
      readonly localDirty: boolean;
      readonly revisionUnpublished: boolean;
      readonly localBehindMachines: string[];
      readonly divergedMachines: string[];
      readonly unknownRelationMachines: string[];
    };

function collectAdvisoryMachines(machines: RemoteCompatMachine[]): RemoteCompatAdvisory[] {
  const result: RemoteCompatAdvisory[] = [];
  for (const machine of machines) {
    if (!machine || typeof machine !== "object") {
      continue;
    }
    if (typeof machine.toolchainAdvisory === "string" && machine.toolchainAdvisory.length > 0) {
      result.push({ machine: machine.machine, advisory: machine.toolchainAdvisory });
    }
  }
  return result;
}

/** xcodeSelectionError が非空文字列か(runHandler.ts の文言優先判定とも共有)。 */
export function hasXcodeSelectionError(machine: RemoteCompatMachine): boolean {
  return typeof machine.xcodeSelectionError === "string" && machine.xcodeSelectionError.length > 0;
}

/**
 * report を判定する。hosts が空(プロファイルにリモート機なし)・全ホスト互換なら proceed。
 * それ以外は ask を返す。canUpdate は「align で直せる不一致だけか」の判定
 * (align は rev しか直せない。unreachable と toolchain 不一致は align では直らない。
 * さらに revisionRelation が "remoteBehind"(ランナーが古い)以外 —— localBehind(この機械が古い。
 * 巻き戻しは誤り。直すのは Scripts/update.sh)/ diverged(ブランチ分岐。共有ランナーでは実行不可)/
 * unknown(判定不能。多くの場合この機械が古い)—— が1機でも居たら align では直らない)。
 * パース不能・想定外の形は proceed(最終ゲートは checkCompatibility 側に残っており、
 * ここでの判定失敗が run を止める理由にはならない)。
 * advisory(toolchainAdvisory 非 null。ベータ seed 違いなど)は止めない —— incompatible には
 * 入れず、proceed/ask どちらの variant でも advisoryMachines として並べて返すだけ。
 */
export function decideRemoteCompat(report: RemoteCompatReport | null | undefined): RemoteCompatDecision {
  if (!report || !Array.isArray(report.machines)) {
    return { kind: "proceed", advisoryMachines: [] };
  }
  const advisoryMachines = collectAdvisoryMachines(report.machines);
  const incompatible = report.machines.filter(
    (machine) =>
      !machine || typeof machine !== "object"
        ? false
        : machine.reachable === false || machine.revisionCompatible === false || machine.toolchainCompatible === false
          || hasXcodeSelectionError(machine),
  );
  if (incompatible.length === 0) {
    return { kind: "proceed", advisoryMachines };
  }

  const revisionUnpublished = report.revisionPublished === false;
  const canUpdate =
    !revisionUnpublished
    && incompatible.every(
      (machine) =>
        machine.reachable === true
        && machine.toolchainCompatible !== false
        && !hasXcodeSelectionError(machine)
        && (machine.revisionRelation === "remoteBehind"
          || machine.revisionRelation === undefined
          || machine.revisionRelation === null),
    );
  const updatableMachines = canUpdate ? incompatible.map((machine) => machine.machine) : [];

  return {
    kind: "ask",
    incompatible,
    advisoryMachines,
    canUpdate,
    updatableMachines,
    localDirty: report.localDirty === true,
    revisionUnpublished,
    localBehindMachines: incompatible.filter((machine) => machine.revisionRelation === "localBehind").map((machine) => machine.machine),
    divergedMachines: incompatible.filter((machine) => machine.revisionRelation === "diverged").map((machine) => machine.machine),
    unknownRelationMachines: incompatible
      .filter((machine) => machine.revisionRelation === "unknown")
      .map((machine) => machine.machine),
  };
}
