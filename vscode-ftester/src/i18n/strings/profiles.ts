// バッチA 辞書。namespace: profiles.
// 対象ソース: monitorProfilesController.ts
// キーは "profiles." 始まり。ja は元の日本語と byte-identical(既存テスト互換)。
import type { MessageDict } from "../core";

export const profilesStrings = {
  "profiles.error.projectUnresolved": {
    ja: "対象のテストプロジェクトを解決できませんでした。ftester.project 設定を確認してください。",
    en: "Could not resolve the target test project. Check the ftester.project setting.",
  },

  "profiles.label.noProfile": { ja: "(プロファイルなし)", en: "(No profile)" },
  "profiles.label.none": { ja: "なし", en: "None" },
  "profiles.label.runProfile": { ja: "実行プロファイル", en: "Run profile" },
  "profiles.label.appProfile": { ja: "アプリプロファイル", en: "App profile" },
  "profiles.label.machineProfile": { ja: "マシンプロファイル", en: "Machine profile" },

  "profiles.noun.profileName": { ja: "プロファイル名", en: "Profile name" },
  "profiles.noun.appProfileName": { ja: "アプリプロファイル名", en: "App profile name" },
  "profiles.noun.machineProfileName": { ja: "マシンプロファイル名", en: "Machine profile name" },

  "profiles.title.newRunProfile": { ja: "新しい実行プロファイル名", en: "New run profile name" },
  "profiles.title.copyRunProfile": {
    ja: "「{source}」のコピー先の実行プロファイル名",
    en: "Run profile name to copy \"{source}\" to",
  },
  "profiles.title.renameRunProfile": {
    ja: "「{name}」の新しい実行プロファイル名",
    en: "New run profile name for \"{name}\"",
  },
  "profiles.title.newAppProfile": { ja: "新しいアプリプロファイル名", en: "New app profile name" },
  "profiles.title.copyAppProfile": {
    ja: "「{source}」のコピー先のアプリプロファイル名",
    en: "App profile name to copy \"{source}\" to",
  },
  "profiles.title.renameAppProfile": {
    ja: "「{name}」の新しいアプリプロファイル名",
    en: "New app profile name for \"{name}\"",
  },
  "profiles.title.newMachineProfile": { ja: "新しいマシンプロファイル名", en: "New machine profile name" },
  "profiles.title.copyMachineProfile": {
    ja: "「{name}」のコピー先のマシンプロファイル名",
    en: "Machine profile name to copy \"{name}\" to",
  },
  "profiles.title.renameMachineProfile": {
    ja: "「{name}」の新しいマシンプロファイル名",
    en: "New machine profile name for \"{name}\"",
  },

  "profiles.button.delete": { ja: "削除", en: "Delete" },
  "profiles.button.remove": { ja: "除去", en: "Remove" },

  "profiles.confirm.deleteRunProfile": {
    ja: "実行プロファイル「{name}」を削除しますか?この操作は元に戻せません。",
    en: "Delete run profile \"{name}\"? This action cannot be undone.",
  },
  "profiles.confirm.deleteAppProfile": {
    ja: "アプリプロファイル「{name}」を削除しますか?この操作は元に戻せません。",
    en: "Delete app profile \"{name}\"? This action cannot be undone.",
  },
  "profiles.confirm.deleteMachineProfile": {
    ja: "マシンプロファイル「{name}」を削除しますか?この操作は元に戻せません(プロファイルファイルのみ削除され、シミュレータ/AVD 本体は削除されません)。",
    en: "Delete machine profile \"{name}\"? This action cannot be undone (only the profile file is deleted; the simulator/AVD itself is not).",
  },
  "profiles.confirm.removeDeviceSingle": {
    ja: "マシンプロファイル「{machine}」からデバイス「{name}」を除去しますか?プロファイルからの除去のみで、シミュレータ/AVD 本体は削除されません。",
    en: "Remove device \"{name}\" from machine profile \"{machine}\"? This only removes it from the profile; the simulator/AVD itself is not deleted.",
  },
  "profiles.confirm.removeDeviceMultiple": {
    ja: "マシンプロファイル「{machine}」から{count}台のデバイス({names})を除去しますか?プロファイルからの除去のみで、シミュレータ/AVD 本体は削除されません。",
    en: "Remove {count} device(s) ({names}) from machine profile \"{machine}\"? This only removes them from the profile; the simulator/AVD itself is not deleted.",
  },

  // ---- 実行プロファイル ----
  "profiles.log.runProfileSet": {
    ja: "[ftester] 実行プロファイルを「{name}」に設定しました。",
    en: "[ftester] Set the run profile to \"{name}\".",
  },
  "profiles.log.runProfileSetFailed": {
    ja: "[ftester] 実行プロファイルの設定に失敗しました({name}): {error}",
    en: "[ftester] Failed to set the run profile ({name}): {error}",
  },
  "profiles.log.runProfileAdded": {
    ja: "[ftester] 実行プロファイル「{name}」を追加しました。",
    en: "[ftester] Added run profile \"{name}\".",
  },
  "profiles.log.runProfileAddFailed": {
    ja: "[ftester] 実行プロファイル「{name}」の追加に失敗しました: {error}",
    en: "[ftester] Failed to add run profile \"{name}\": {error}",
  },
  "profiles.msg.runProfileAddFailed": {
    ja: "実行プロファイル「{name}」の追加に失敗しました。",
    en: "Failed to add run profile \"{name}\".",
  },
  "profiles.msg.runProfileNotFound": {
    ja: "実行プロファイル「{name}」が見つかりません。",
    en: "Run profile \"{name}\" not found.",
  },
  "profiles.log.runProfileCopied": {
    ja: "[ftester] 実行プロファイル「{source}」を「{name}」としてコピーしました。",
    en: "[ftester] Copied run profile \"{source}\" as \"{name}\".",
  },
  "profiles.log.runProfileCopyFailed": {
    ja: "[ftester] 実行プロファイル「{name}」のコピーに失敗しました: {error}",
    en: "[ftester] Failed to copy run profile \"{name}\": {error}",
  },
  "profiles.msg.runProfileCopyFailed": {
    ja: "実行プロファイル「{name}」のコピーに失敗しました。",
    en: "Failed to copy run profile \"{name}\".",
  },
  "profiles.log.runProfileDeleted": {
    ja: "[ftester] 実行プロファイル「{name}」を削除しました。",
    en: "[ftester] Deleted run profile \"{name}\".",
  },
  "profiles.log.runProfileDeleteFailed": {
    ja: "[ftester] 実行プロファイル「{name}」の削除に失敗しました: {error}",
    en: "[ftester] Failed to delete run profile \"{name}\": {error}",
  },
  "profiles.msg.runProfileDeleteFailed": {
    ja: "実行プロファイル「{name}」の削除に失敗しました。",
    en: "Failed to delete run profile \"{name}\".",
  },
  "profiles.log.runProfileRenamed": {
    ja: "[ftester] 実行プロファイル「{oldName}」を「{newName}」に変更しました。",
    en: "[ftester] Renamed run profile \"{oldName}\" to \"{newName}\".",
  },
  "profiles.log.runProfileRenameFailed": {
    ja: "[ftester] 実行プロファイル「{name}」の名前変更に失敗しました: {error}",
    en: "[ftester] Failed to rename run profile \"{name}\": {error}",
  },
  "profiles.msg.runProfileRenameFailed": {
    ja: "実行プロファイル「{name}」の名前変更に失敗しました。",
    en: "Failed to rename run profile \"{name}\".",
  },
  "profiles.msg.runProfileLoadFailed": {
    ja: "実行プロファイル「{name}」を読み込めませんでした。",
    en: "Could not load run profile \"{name}\".",
  },
  "profiles.log.runProfileLoadFailed": {
    ja: "[ftester] 実行プロファイル「{name}」の読み込みに失敗しました: {error}",
    en: "[ftester] Failed to load run profile \"{name}\": {error}",
  },
  "profiles.msg.runProfileInvalidFormat": {
    ja: "実行プロファイル「{name}」の形式が不正です。",
    en: "Run profile \"{name}\" has an invalid format.",
  },
  "profiles.log.runProfileWriteFailed": {
    ja: "[ftester] 実行プロファイル「{name}」の書き込みに失敗しました: {error}",
    en: "[ftester] Failed to write run profile \"{name}\": {error}",
  },
  "profiles.msg.runProfileWriteFailed": {
    ja: "実行プロファイル「{name}」への書き込みに失敗しました。",
    en: "Failed to write to run profile \"{name}\".",
  },
  "profiles.log.runProfileUpdated": {
    ja: "[ftester] 実行プロファイル「{name}」を更新しました。",
    en: "[ftester] Updated run profile \"{name}\".",
  },

  // ---- アプリプロファイル ----
  "profiles.log.appProfileAdded": {
    ja: "[ftester] アプリプロファイル「{name}」を追加しました。",
    en: "[ftester] Added app profile \"{name}\".",
  },
  "profiles.log.appProfileAddFailed": {
    ja: "[ftester] アプリプロファイル「{name}」の追加に失敗しました: {error}",
    en: "[ftester] Failed to add app profile \"{name}\": {error}",
  },
  "profiles.msg.appProfileAddFailed": {
    ja: "アプリプロファイル「{name}」の追加に失敗しました。",
    en: "Failed to add app profile \"{name}\".",
  },
  "profiles.msg.appProfileNotFound": {
    ja: "アプリプロファイル「{name}」が見つかりません。",
    en: "App profile \"{name}\" not found.",
  },
  "profiles.log.appProfileCopied": {
    ja: "[ftester] アプリプロファイル「{source}」を「{name}」としてコピーしました。",
    en: "[ftester] Copied app profile \"{source}\" as \"{name}\".",
  },
  "profiles.log.appProfileCopyFailed": {
    ja: "[ftester] アプリプロファイル「{name}」のコピーに失敗しました: {error}",
    en: "[ftester] Failed to copy app profile \"{name}\": {error}",
  },
  "profiles.msg.appProfileCopyFailed": {
    ja: "アプリプロファイル「{name}」のコピーに失敗しました。",
    en: "Failed to copy app profile \"{name}\".",
  },
  "profiles.log.appProfileDeleted": {
    ja: "[ftester] アプリプロファイル「{name}」を削除しました。",
    en: "[ftester] Deleted app profile \"{name}\".",
  },
  "profiles.log.appProfileDeleteFailed": {
    ja: "[ftester] アプリプロファイル「{name}」の削除に失敗しました: {error}",
    en: "[ftester] Failed to delete app profile \"{name}\": {error}",
  },
  "profiles.msg.appProfileDeleteFailed": {
    ja: "アプリプロファイル「{name}」の削除に失敗しました。",
    en: "Failed to delete app profile \"{name}\".",
  },
  "profiles.log.appProfileRenamed": {
    ja: "[ftester] アプリプロファイル「{oldName}」を「{newName}」に変更しました。",
    en: "[ftester] Renamed app profile \"{oldName}\" to \"{newName}\".",
  },
  "profiles.log.appProfileRenameFailed": {
    ja: "[ftester] アプリプロファイル「{name}」の名前変更に失敗しました: {error}",
    en: "[ftester] Failed to rename app profile \"{name}\": {error}",
  },
  "profiles.msg.appProfileRenameFailed": {
    ja: "アプリプロファイル「{name}」の名前変更に失敗しました。",
    en: "Failed to rename app profile \"{name}\".",
  },
  "profiles.msg.appProfileLoadFailed": {
    ja: "アプリプロファイル「{name}」を読み込めませんでした。",
    en: "Could not load app profile \"{name}\".",
  },
  "profiles.log.appProfileLoadFailed": {
    ja: "[ftester] アプリプロファイル「{name}」の読み込みに失敗しました: {error}",
    en: "[ftester] Failed to load app profile \"{name}\": {error}",
  },
  "profiles.msg.appProfileInvalidFormat": {
    ja: "アプリプロファイル「{name}」の形式が不正です。",
    en: "App profile \"{name}\" has an invalid format.",
  },
  "profiles.log.appProfileWriteFailed": {
    ja: "[ftester] アプリプロファイル「{name}」の書き込みに失敗しました: {error}",
    en: "[ftester] Failed to write app profile \"{name}\": {error}",
  },
  "profiles.msg.appProfileWriteFailed": {
    ja: "アプリプロファイル「{name}」への書き込みに失敗しました。",
    en: "Failed to write to app profile \"{name}\".",
  },
  "profiles.log.appProfileUpdated": {
    ja: "[ftester] アプリプロファイル「{name}」を更新しました。",
    en: "[ftester] Updated app profile \"{name}\".",
  },

  // ---- マシンプロファイル ----
  "profiles.log.machineProfileAdded": {
    ja: "[ftester] マシンプロファイル「{name}」を追加しました。",
    en: "[ftester] Added machine profile \"{name}\".",
  },
  "profiles.log.machineProfileAddFailed": {
    ja: "[ftester] マシンプロファイル「{name}」の追加に失敗しました: {error}",
    en: "[ftester] Failed to add machine profile \"{name}\": {error}",
  },
  "profiles.msg.machineProfileAddFailed": {
    ja: "マシンプロファイル「{name}」の追加に失敗しました。",
    en: "Failed to add machine profile \"{name}\".",
  },
  "profiles.msg.machineProfileNotFound": {
    ja: "マシンプロファイル「{name}」が見つかりません。",
    en: "Machine profile \"{name}\" not found.",
  },
  "profiles.log.machineProfileCopied": {
    ja: "[ftester] マシンプロファイル「{machine}」を「{name}」としてコピーしました。",
    en: "[ftester] Copied machine profile \"{machine}\" as \"{name}\".",
  },
  "profiles.log.machineProfileCopyFailed": {
    ja: "[ftester] マシンプロファイル「{name}」のコピーに失敗しました: {error}",
    en: "[ftester] Failed to copy machine profile \"{name}\": {error}",
  },
  "profiles.msg.machineProfileCopyFailed": {
    ja: "マシンプロファイル「{name}」のコピーに失敗しました。",
    en: "Failed to copy machine profile \"{name}\".",
  },
  "profiles.log.registeredMachineNameUpdated": {
    ja: "[ftester] 登録マシン名(machine set)も「{name}」に更新しました。",
    en: "[ftester] Also updated the registered machine name (machine set) to \"{name}\".",
  },
  "profiles.log.machineProfileRenamed": {
    ja: "[ftester] マシンプロファイル「{oldName}」を「{newName}」に変更しました。",
    en: "[ftester] Renamed machine profile \"{oldName}\" to \"{newName}\".",
  },
  "profiles.log.machineProfileRenameFailed": {
    ja: "[ftester] マシンプロファイル「{name}」の名前変更に失敗しました: {error}",
    en: "[ftester] Failed to rename machine profile \"{name}\": {error}",
  },
  "profiles.msg.machineProfileRenameFailed": {
    ja: "マシンプロファイル「{name}」の名前変更に失敗しました。",
    en: "Failed to rename machine profile \"{name}\".",
  },
  "profiles.log.machineProfileDeleted": {
    ja: "[ftester] マシンプロファイル「{name}」を削除しました。",
    en: "[ftester] Deleted machine profile \"{name}\".",
  },
  "profiles.log.machineProfileDeleteFailed": {
    ja: "[ftester] マシンプロファイル「{name}」の削除に失敗しました: {error}",
    en: "[ftester] Failed to delete machine profile \"{name}\": {error}",
  },
  "profiles.msg.machineProfileDeleteFailed": {
    ja: "マシンプロファイル「{name}」の削除に失敗しました。",
    en: "Failed to delete machine profile \"{name}\".",
  },
  "profiles.log.machineProfileLoadFailed": {
    ja: "[ftester] マシンプロファイル「{name}」の読み込みに失敗しました: {error}",
    en: "[ftester] Failed to load machine profile \"{name}\": {error}",
  },
  "profiles.msg.machineProfileLoadFailed": {
    ja: "マシンプロファイル「{name}」を読み込めませんでした。",
    en: "Could not load machine profile \"{name}\".",
  },
  "profiles.log.machineProfileInvalidFormatRemoveAborted": {
    ja: "[ftester] マシンプロファイル「{name}」の形式が不正なため、デバイスの除去を中断しました。",
    en: "[ftester] Machine profile \"{name}\" has an invalid format, so device removal was aborted.",
  },
  "profiles.log.machineProfileDeviceNotFoundRemoveFailed": {
    ja: "[ftester] マシンプロファイル「{name}」に指定のデバイスが見つからず、除去できませんでした。",
    en: "[ftester] Could not remove: the specified device was not found in machine profile \"{name}\".",
  },
  "profiles.msg.machineProfileDeviceNotFound": {
    ja: "マシンプロファイル「{name}」に指定のデバイスが見つかりませんでした。",
    en: "The specified device was not found in machine profile \"{name}\".",
  },
  "profiles.log.machineProfileDevicesRemoved": {
    ja: "[ftester] マシンプロファイル「{name}」から{count}台のデバイスを除去しました({names})。",
    en: "[ftester] Removed {count} device(s) from machine profile \"{name}\" ({names}).",
  },
  "profiles.log.machineProfileDeviceRemoveFailed": {
    ja: "[ftester] マシンプロファイル「{name}」からのデバイス除去に失敗しました: {error}",
    en: "[ftester] Failed to remove device(s) from machine profile \"{name}\": {error}",
  },
  "profiles.msg.machineProfileDeviceRemoveFailed": {
    ja: "マシンプロファイル「{name}」からのデバイス除去に失敗しました。",
    en: "Failed to remove device(s) from machine profile \"{name}\".",
  },
  "profiles.log.machineProfileDeviceUpdateFailed": {
    ja: "[ftester] マシンプロファイル「{machine}」のデバイス「{device}」の更新に失敗しました: {error}",
    en: "[ftester] Failed to update device \"{device}\" in machine profile \"{machine}\": {error}",
  },
  "profiles.msg.machineProfileWriteFailed": {
    ja: "マシンプロファイル「{name}」への書き込みに失敗しました。",
    en: "Failed to write to machine profile \"{name}\".",
  },
  "profiles.log.machineProfileDeviceUpdated": {
    ja: "[ftester] マシンプロファイル「{machine}」のデバイス「{device}」を更新しました。",
    en: "[ftester] Updated device \"{device}\" in machine profile \"{machine}\".",
  },
  "profiles.log.machineProfileDevicesSyncWriteFailed": {
    ja: "[ftester] マシンプロファイル「{machine}」へのデバイス同期の書き込みに失敗しました: {error}",
    en: "[ftester] Failed to write device sync to machine profile \"{machine}\": {error}",
  },
  "profiles.log.machineProfileDevicesSynced": {
    ja: "[ftester] マシンプロファイル「{machine}」に追加{added}台・登録解除{removed}台を適用しました(追加: {addedList}、登録解除: {removeList})。",
    en: "[ftester] Applied {added} added and {removed} unregistered device(s) to machine profile \"{machine}\" (added: {addedList}, unregistered: {removeList}).",
  },
} satisfies MessageDict;
