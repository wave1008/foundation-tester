# shellcheck shell=bash
# RN の SUT のビルド前に、入っている依存(node_modules・Pods)をリポジトリの lock に揃える。
# E2E*AppRN/scripts/build-*.sh が SUT ディレクトリを cwd にして source する:
#   rn_sync_node_modules   # iOS / Android とも
#   rn_sync_pods           # iOS だけ(node_modules の後 = Podfile が node_modules を読む)
#
# - ビルドは入っている依存をそのまま使う。lock だけ新しい版になった機械(align で package-lock.json だけ
#   変わったリモート等)では、揃えないと古い版の RN で「作り直した」アプリになり、黙って古い版で回る
# - 揃える側は **lock を書き換えない**(npm ci / pod install --deployment)。lock は追跡ファイルで、
#   書き換えるとクローンが汚れて次の align が止まる。lock と食い違う解決が要るなら、ここで落ちる
# - 判定は mtime でなく中身で見る(git checkout は内容が同じでも mtime を進め、毎回 npm ci になる)

# package-lock.json の各パッケージの版が node_modules/.package-lock.json(npm が入れた記録)と一致するか。
# optional は機種で入らないものがあるので見ない
_rn_node_modules_match_lock() {
  python3 -I -c '
import json, sys
lock = json.load(open("package-lock.json"))["packages"]
try:
    have = json.load(open("node_modules/.package-lock.json"))["packages"]
except (OSError, ValueError, KeyError):
    sys.exit(1)
sys.exit(1 if any(
    k.startswith("node_modules/") and not v.get("optional")
    and have.get(k, {}).get("version") != v.get("version")
    for k, v in lock.items()) else 0)'
}

rn_sync_node_modules() {
  _rn_node_modules_match_lock && return 0
  echo "→ node_modules が package-lock.json と食い違うので npm ci で入れ直します"
  npm ci
}

rn_sync_pods() {
  # Manifest.lock は pod install が Pods/ に書く Podfile.lock の写し(CocoaPods 自身の同期判定と同じ)
  cmp -s ios/Podfile.lock ios/Pods/Manifest.lock && return 0
  echo "→ Pods が Podfile.lock と食い違うので pod install --deployment で入れ直します"
  (cd ios && pod install --deployment)
}
