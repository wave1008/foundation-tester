// 作成の前に1回だけ行う導入(install-system-image / install-ios-runtime)の門。vscode 非依存(テストのため)。
// 導入が失敗したら proceed(= create-device ループ)を1度も呼ばない。バッチで1台ずつ create-device に
// 導入を任せると、失敗のたびに2台目以降も導入を試みてしまうため、導入は作成の外で1回だけにする。

export type InstallOutcome = { readonly ok: boolean; readonly error: string | null };

export type GatedResult<T> =
  | { readonly proceeded: true; readonly value: T }
  | { readonly proceeded: false; readonly error: string };

/** install が undefined なら導入不要として proceed へ進む。失敗の error が null のときは fallbackError。 */
export async function runAfterInstall<T>(
  install: (() => Promise<InstallOutcome>) | undefined,
  proceed: () => Promise<T>,
  fallbackError: string,
): Promise<GatedResult<T>> {
  if (install) {
    const outcome = await install();
    if (!outcome.ok) {
      return { proceeded: false, error: outcome.error ?? fallbackError };
    }
  }
  return { proceeded: true, value: await proceed() };
}
