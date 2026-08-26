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
  readonly error?: string | null;
}

export interface RemoteCompatReport {
  readonly machines: RemoteCompatMachine[];
  readonly localRevision?: string | null;
  readonly localDirty?: boolean;
  readonly revisionPublished?: boolean;
}

export type RemoteCompatDecision =
  | { readonly kind: "proceed" }
  | {
      readonly kind: "ask";
      readonly incompatible: RemoteCompatMachine[];
      readonly canUpdate: boolean;
      readonly updatableMachines: string[];
      readonly localDirty: boolean;
      readonly revisionUnpublished: boolean;
      readonly localBehindMachines: string[];
      readonly divergedMachines: string[];
      readonly unknownRelationMachines: string[];
    };

/**
 * report を判定する。hosts が空(プロファイルにリモート機なし)・全ホスト互換なら proceed。
 * それ以外は ask を返す。canUpdate は「align で直せる不一致だけか」の判定
 * (align は rev しか直せない。unreachable と toolchain 不一致は align では直らない。
 * さらに revisionRelation が "remoteBehind"(ランナーが古い)以外 —— localBehind(この機械が古い。
 * 巻き戻しは誤り。直すのは Scripts/update.sh)/ diverged(ブランチ分岐。共有ランナーでは実行不可)/
 * unknown(判定不能。多くの場合この機械が古い)—— が1機でも居たら align では直らない)。
 * パース不能・想定外の形は proceed(最終ゲートは checkCompatibility 側に残っており、
 * ここでの判定失敗が run を止める理由にはならない)。
 */
export function decideRemoteCompat(report: RemoteCompatReport | null | undefined): RemoteCompatDecision {
  if (!report || !Array.isArray(report.machines)) {
    return { kind: "proceed" };
  }
  const incompatible = report.machines.filter(
    (machine) =>
      !machine || typeof machine !== "object"
        ? false
        : machine.reachable === false || machine.revisionCompatible === false || machine.toolchainCompatible === false,
  );
  if (incompatible.length === 0) {
    return { kind: "proceed" };
  }

  const revisionUnpublished = report.revisionPublished === false;
  const canUpdate =
    !revisionUnpublished
    && incompatible.every(
      (machine) =>
        machine.reachable === true
        && machine.toolchainCompatible !== false
        && (machine.revisionRelation === "remoteBehind"
          || machine.revisionRelation === undefined
          || machine.revisionRelation === null),
    );
  const updatableMachines = canUpdate ? incompatible.map((machine) => machine.machine) : [];

  return {
    kind: "ask",
    incompatible,
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
