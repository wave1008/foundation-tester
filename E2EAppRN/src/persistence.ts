import AsyncStorage from '@react-native-async-storage/async-storage';

// 永続化するのは launch(起動回数)/ auto(起動時ダイアログ)/ schema(自己修復の id スキーマ)の
// 3つだけ(E2EAppCMP/docs/ui-contract.md §永続化する値)。それ以外の状態は React state のみ。
const KEY_LAUNCH_COUNT = 'launch_count';
const KEY_AUTO_DIALOG = 'auto_dialog';
const KEY_HEAL_SCHEMA_V1 = 'heal_schema_v1';

export type PersistedState = {
  launchCount: number;
  autoDialog: boolean;
  healSchemaV1: boolean;
};

/** JS コンテキスト生成ごとに1回だけ呼ぶ(App のマウント時)。launch を先に読んで+1で書き戻す。 */
export async function bootstrapPersistedState(): Promise<PersistedState> {
  const [launchRaw, autoRaw, schemaRaw] = await Promise.all([
    AsyncStorage.getItem(KEY_LAUNCH_COUNT),
    AsyncStorage.getItem(KEY_AUTO_DIALOG),
    AsyncStorage.getItem(KEY_HEAL_SCHEMA_V1),
  ]);
  const launchCount = (launchRaw ? parseInt(launchRaw, 10) : 0) + 1;
  await AsyncStorage.setItem(KEY_LAUNCH_COUNT, String(launchCount));
  return {
    launchCount,
    autoDialog: autoRaw === 'true',
    // 既定 ON(= v1)。未保存(null)のときだけ既定を使う。
    healSchemaV1: schemaRaw === null ? true : schemaRaw === 'true',
  };
}

export async function persistAutoDialog(value: boolean): Promise<void> {
  await AsyncStorage.setItem(KEY_AUTO_DIALOG, String(value));
}

export async function persistHealSchemaV1(value: boolean): Promise<void> {
  await AsyncStorage.setItem(KEY_HEAL_SCHEMA_V1, String(value));
}

/** 現プロセス分の launch を 1 に戻す。 */
export async function resetLaunchCount(): Promise<number> {
  await AsyncStorage.setItem(KEY_LAUNCH_COUNT, '1');
  return 1;
}
