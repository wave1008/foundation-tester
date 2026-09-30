// api steps / api list-scenarios は実行プロファイルの sandbox / sandboxConfig を効かせるため、
// api run と同じ選択中プロファイル(config.profile。空 = プラットフォーム直指定)を渡す。
export function profileArgs(profile: string): string[] {
  const name = profile.trim();
  return name.length > 0 ? ["--profile", name] : [];
}
