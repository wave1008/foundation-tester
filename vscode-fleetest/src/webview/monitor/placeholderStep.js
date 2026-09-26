// 空欄(= 既定値がプレースホルダに見えている)の number 入力で、スピンボタン/↑↓キーの増減を
// **既定値を起点に**する。ブラウザは空欄を 0(か min)から数えるので、押した瞬間に既定値を仮に入れる。
//
// - スピンボタンはボタン部分だけを判定できない(当たり判定は UA 依存)ので、mousedown では常に
//   仮に入れ、**mouseup までに input が来なければ(= 文字部分をクリックしただけ)空欄へ戻す**。
//   ブラウザの増減は mousedown の既定動作なので、リスナで入れた値から数えられる
// - ↑↓キーは必ず増減するので戻さない
// - プログラムからの value 代入は input を発火しないので、仮の値だけでは change は飛ばない
//   (設定は利用者が実際に増減した回だけ保存される)

/** input に一度だけ付ける。プレースホルダが数値でないとき(既定が未着)は何もしない */
export function stepFromPlaceholder(input) {
  let seeded = false;
  const seed = () => {
    if (input.value !== '' || input.disabled || !Number.isFinite(Number.parseFloat(input.placeholder))) {
      return false;
    }
    input.value = input.placeholder;
    return true;
  };
  input.addEventListener('mousedown', () => {
    seeded = seed();
  });
  input.addEventListener('input', () => {
    seeded = false;
  });
  const revert = () => {
    if (seeded) {
      seeded = false;
      input.value = '';
    }
  };
  input.addEventListener('mouseup', revert);
  // ボタンを押したまま欄の外で離したときは mouseup が input に来ない
  input.addEventListener('mouseleave', revert);
  input.addEventListener('keydown', (event) => {
    if (event.key === 'ArrowUp' || event.key === 'ArrowDown') {
      seed();
    }
  });
}
