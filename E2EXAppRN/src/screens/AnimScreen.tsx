import React, { useState } from 'react';
import Animated, { FadeIn, FadeOut, SlideInDown, SlideOutUp } from 'react-native-reanimated';

import { Tags } from '../tags';
import { EchoText, ScreenContainer, TaggedButton } from '../ui';

export function AnimScreen() {
  const [visible, setVisible] = useState(false);
  const [count, setCount] = useState(0);

  return (
    <ScreenContainer>
      <TaggedButton
        testID={Tags.btnToggleAnim}
        label="表示を切り替える"
        onPress={() => setVisible(v => !v)}
      />
      <EchoText testID={Tags.txtAnimVisible}>{`visible=${visible}`}</EchoText>
      {visible && (
        <Animated.View entering={FadeIn.duration(1500)} exiting={FadeOut.duration(1500)}>
          <EchoText testID={Tags.txtAnimTarget}>アニメ完了</EchoText>
        </Animated.View>
      )}

      <TaggedButton testID={Tags.btnAnimInc} label="増やす" onPress={() => setCount(c => c + 1)} />
      {/* key={count} での再マウントに enter/exit を掛けて縦スライドを表現する
          (Compose の AnimatedContent 相当。Reanimated には値変化だけをトリガーに
          slide させる同等 API が無いため、キー変更 remount で代替)。 */}
      <Animated.View key={count} entering={SlideInDown.duration(800)} exiting={SlideOutUp.duration(800)}>
        <EchoText testID={Tags.txtAnimCount}>{`count=${count}`}</EchoText>
      </Animated.View>
    </ScreenContainer>
  );
}
