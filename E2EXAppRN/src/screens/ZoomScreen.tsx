import React, { useState } from 'react';
import { StyleSheet, View } from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import Animated, {
  runOnJS,
  useAnimatedStyle,
  useSharedValue,
  withTiming,
} from 'react-native-reanimated';

import { Tags } from '../tags';
import { EchoText, ScreenContainer, TaggedButton } from '../ui';

const MIN_SCALE = 1.0;
const MAX_SCALE = 4.0;

export function ZoomScreen() {
  const scale = useSharedValue(1);
  const savedScale = useSharedValue(1);
  const translateX = useSharedValue(0);
  const translateY = useSharedValue(0);
  const savedTranslateX = useSharedValue(0);
  const savedTranslateY = useSharedValue(0);
  const [scaleText, setScaleText] = useState('scale=1.0');

  const reportScale = (value: number) => {
    setScaleText(`scale=${value.toFixed(1)}`);
  };

  const pinch = Gesture.Pinch()
    .onUpdate(e => {
      const next = Math.min(Math.max(savedScale.value * e.scale, MIN_SCALE), MAX_SCALE);
      scale.value = next;
      runOnJS(reportScale)(next);
    })
    .onEnd(() => {
      savedScale.value = scale.value;
    });

  const pan = Gesture.Pan()
    .onUpdate(e => {
      translateX.value = savedTranslateX.value + e.translationX;
      translateY.value = savedTranslateY.value + e.translationY;
    })
    .onEnd(() => {
      savedTranslateX.value = translateX.value;
      savedTranslateY.value = translateY.value;
    });

  const composed = Gesture.Simultaneous(pinch, pan);

  const contentStyle = useAnimatedStyle(() => ({
    transform: [
      { translateX: translateX.value },
      { translateY: translateY.value },
      { scale: scale.value },
    ],
  }));

  const reset = () => {
    scale.value = withTiming(1);
    savedScale.value = 1;
    translateX.value = withTiming(0);
    translateY.value = withTiming(0);
    savedTranslateX.value = 0;
    savedTranslateY.value = 0;
    setScaleText('scale=1.0');
  };

  return (
    <ScreenContainer>
      <View style={styles.stage}>
        <GestureDetector gesture={composed}>
          {/* #zoom_target は切り取り枠(overflow: hidden)。拡大された中身がこの枠をはみ出して
              下の echo/ボタンを覆わないよう、実際に拡大縮小するのは内側の View。 */}
          <View testID={Tags.zoomTarget} style={styles.frame}>
            <Animated.View style={[styles.content, contentStyle]} />
          </View>
        </GestureDetector>
      </View>
      <EchoText testID={Tags.txtZoomScale}>{scaleText}</EchoText>
      <TaggedButton testID={Tags.btnZoomReset} label="元に戻す" onPress={reset} />
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  stage: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
  frame: {
    width: 200,
    height: 200,
    borderRadius: 12,
    overflow: 'hidden',
    backgroundColor: '#e6e6e6',
    alignItems: 'center',
    justifyContent: 'center',
  },
  content: {
    width: 160,
    height: 160,
    borderRadius: 12,
    backgroundColor: '#4a90d9',
  },
});
