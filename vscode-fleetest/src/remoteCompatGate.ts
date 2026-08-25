// remoteCompatGate.ts
// `fleetest api remote-compat` の結果からダイアログ表示の要否を決める純粋関数(vscode 非依存)。
// テストは vscode-stub を経由せずここを直接 import する(remoteRunArgs.ts と同じ理由)。
// runHandler.ts の executeRun がこの判定を元に確認ダイアログ・align 実行を配線する。

export interface RemoteCompatHost {
  readonly name: string;
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
  readonly hosts: RemoteCompatHost[];
  readonly localRevision?: string | null;
  readonly localDirty?: boolean;
  readonly revisionPublished?: boolean;
}

export type RemoteCompatDecision =
  | { readonly kind: "proceed" }
  | {
      readonly kind: "ask";
      readonly incompatible: RemoteCompatHost[];
      readonly canUpdate: boolean;
      readonly updatableHosts: string[];
      readonly localDirty: boolean;
      readonly revisionUnpublished: boolean;
      readonly localBehindHosts: string[];
      readonly divergedHosts: string[];
      readonly unknownRelationHosts: string[];
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
  if (!report || !Array.isArray(report.hosts)) {
    return { kind: "proceed" };
  }
  const incompatible = report.hosts.filter(
    (host) =>
      !host || typeof host !== "object"
        ? false
        : host.reachable === false || host.revisionCompatible === false || host.toolchainCompatible === false,
  );
  if (incompatible.length === 0) {
    return { kind: "proceed" };
  }

  const revisionUnpublished = report.revisionPublished === false;
  const canUpdate =
    !revisionUnpublished
    && incompatible.every(
      (host) =>
        host.reachable === true
        && host.toolchainCompatible !== false
        && (host.revisionRelation === "remoteBehind"
          || host.revisionRelation === undefined
          || host.revisionRelation === null),
    );
  const updatableHosts = canUpdate ? incompatible.map((host) => host.name) : [];

  return {
    kind: "ask",
    incompatible,
    canUpdate,
    updatableHosts,
    localDirty: report.localDirty === true,
    revisionUnpublished,
    localBehindHosts: incompatible.filter((host) => host.revisionRelation === "localBehind").map((host) => host.name),
    divergedHosts: incompatible.filter((host) => host.revisionRelation === "diverged").map((host) => host.name),
    unknownRelationHosts: incompatible
      .filter((host) => host.revisionRelation === "unknown")
      .map((host) => host.name),
  };
}
