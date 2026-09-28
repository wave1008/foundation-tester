import React, { useRef, useState } from 'react';
import { Text, View } from 'react-native';
import { IconButton, Tooltip } from 'react-native-paper';

import { Tags } from '../tags';
import { EchoText, ScreenContainer } from '../ui';

const TOOLTIP_TEXT = 'これはツールチップです';
const ENTER_DELAY_MS = 500; // paper Tooltip の既定 enterTouchDelay と揃える

export function TooltipScreen() {
  const [shown, setShown] = useState(false);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // paper の Tooltip は children を cloneElement して onPress/onLongPress/onPressOut を
  // 自前のものへ差し替える(渡しても上書きされて呼ばれない)ため、その中身へ表示状態のフックを
  // 足せない。生の onTouchStart/onTouchEnd は「responder を取る」操作系とは別経路で
  // 祖先まで届く(観測専用・奪わない)ので、これで Tooltip 本体の挙動を邪魔せずに
  // #txt_tooltip / #txt_tooltip_state を独立に駆動する。
  //
  // Tooltip は children(IconButton)を素の Pressable でも包む(accessible の既定が true)。
  // iOS は「非対話の親の下は個々の子を数えず親ごと畳む」ため、IconButton 自身に付けた
  // testID/accessibilityLabel は木から消える(Android は消えない)。この外側の View を
  // accessible にして id/label をここへ乗せることで、iOS でも #btn_tooltip_anchor が
  // 実際のボタンと同じ位置に現れる(タップは pointerEvents に関与しないのでそのまま通る)。
  const handleTouchStart = () => {
    timerRef.current = setTimeout(() => setShown(true), ENTER_DELAY_MS);
  };
  const handleTouchEnd = () => {
    if (timerRef.current) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
    setShown(false);
  };

  return (
    <ScreenContainer>
      <View
        accessible
        testID={Tags.btnTooltipAnchor}
        accessibilityLabel="情報"
        onTouchStart={handleTouchStart}
        onTouchEnd={handleTouchEnd}
      >
        <Tooltip title={TOOLTIP_TEXT}>
          <IconButton icon={({ size, color }) => <Text style={{ fontSize: size, color }}>i</Text>} />
        </Tooltip>
      </View>
      {shown && <EchoText testID={Tags.txtTooltip}>{TOOLTIP_TEXT}</EchoText>}
      <EchoText testID={Tags.txtTooltipState}>{`tooltip=${shown ? 'shown' : 'hidden'}`}</EchoText>
    </ScreenContainer>
  );
}
