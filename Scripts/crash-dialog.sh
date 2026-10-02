# shellcheck shell=bash
# macOS のクラッシュダイアログ(問題レポーター)を回帰スクリプトの実行中だけ止める。source して使う:
#   crash_dialog_suppress   # 開始時
#   crash_dialog_restore    # 終了時(trap から。何度呼んでもよい)
#
# - Simulator のアプリが落ちるとホストの問題レポーターが出る(陽性対照のクラッシュ検知が毎回落とす)。
#   Simulator 内のデーモンが落ちても出ない(アプリだけ)
# - `DialogType none` は**書くだけでは効かない**。ReportCrash(gui の agent)を kickstart して読み直させる。
#   戻すときも同じ(2026-10-03 実測: 書くだけ → 出る / + kickstart → 出ない / 消して + kickstart → 出る)
# - 止めても .ips は書かれる = fleetest のクラッシュ検知(.ips を読む)には影響しない
# - ユーザー単位の設定なので、同じ機械で e2e.sh と e2ex.sh が重なっても壊れないよう保持者を数える:
#   元の値は最初の保持者だけが退避し、戻すのは最後の保持者が抜けたときだけ。SIGKILL で戻せずに
#   死んだ保持者は、次に誰かが入る/抜けるときに pid の生死で片付ける(その間は止まったまま)

CRASH_DIALOG_STATE="$HOME/.fleetest-crash-dialog"
CRASH_DIALOG_HELD=""

_crash_dialog_lock() {
  local i=0
  # mkdir は原子的。50 × 0.1s = 5 秒待っても取れなければ、死んだ保持者のロックとみなして奪う
  until mkdir "$CRASH_DIALOG_STATE/lock" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge 50 ]; then rm -rf "$CRASH_DIALOG_STATE/lock"; i=0; fi
    sleep 0.1
  done
}
_crash_dialog_unlock() { rmdir "$CRASH_DIALOG_STATE/lock" 2>/dev/null || true; }

_crash_dialog_prune() {
  local f
  for f in "$CRASH_DIALOG_STATE"/holders/*; do
    [ -e "$f" ] || continue
    kill -0 "${f##*/}" 2>/dev/null || rm -f "$f"
  done
}

_crash_dialog_reload() {
  launchctl kickstart -k "gui/$(id -u)/com.apple.ReportCrash" >/dev/null 2>&1 \
    || echo "⚠️ ReportCrash を起こし直せませんでした(クラッシュダイアログの設定が反映されていない可能性)"
}

crash_dialog_suppress() {
  [ "$(uname)" = Darwin ] || return 0
  [ -z "$CRASH_DIALOG_HELD" ] || return 0
  mkdir -p "$CRASH_DIALOG_STATE/holders"
  _crash_dialog_lock
  _crash_dialog_prune
  # original が残っている = 誰かが止めている最中(または戻し損ねた後)。退避し直すと none を元の値として掴む
  if [ ! -f "$CRASH_DIALOG_STATE/original" ]; then
    # 1行目: present/absent、2行目: 値
    local v
    if v=$(defaults read com.apple.CrashReporter DialogType 2>/dev/null); then
      printf 'present\n%s\n' "$v" > "$CRASH_DIALOG_STATE/original"
    else
      printf 'absent\n' > "$CRASH_DIALOG_STATE/original"
    fi
    defaults write com.apple.CrashReporter DialogType none
    _crash_dialog_reload
  fi
  : > "$CRASH_DIALOG_STATE/holders/$$"
  CRASH_DIALOG_HELD=1
  _crash_dialog_unlock
  echo "→ クラッシュダイアログを止めました(終了時に元へ戻します)"
}

crash_dialog_restore() {
  [ -n "$CRASH_DIALOG_HELD" ] || return 0
  CRASH_DIALOG_HELD=""
  _crash_dialog_lock
  rm -f "$CRASH_DIALOG_STATE/holders/$$"
  _crash_dialog_prune
  if [ -z "$(ls -A "$CRASH_DIALOG_STATE/holders" 2>/dev/null)" ] && [ -f "$CRASH_DIALOG_STATE/original" ]; then
    local kind val
    { read -r kind; read -r val; } < "$CRASH_DIALOG_STATE/original" || true
    if [ "$kind" = present ]; then
      defaults write com.apple.CrashReporter DialogType "$val"
    else
      defaults delete com.apple.CrashReporter DialogType 2>/dev/null || true
    fi
    _crash_dialog_reload
    rm -f "$CRASH_DIALOG_STATE/original"
    echo "→ クラッシュダイアログの設定を元に戻しました"
  else
    echo "→ クラッシュダイアログは止めたままです(同じ機械で別の回帰スクリプトが実行中)"
  fi
  _crash_dialog_unlock
}
