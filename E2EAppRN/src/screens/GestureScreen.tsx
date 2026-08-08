import React, { useRef, useState } from 'react';
import { PanResponder, Pressable, StyleSheet, Text, View } from 'react-native';

import { Tags } from '../tags';
import { EchoText, TaggedButton } from '../ui';

// ブリッジの swipe は要素を狙わず画面を払う(iOS = XCUITest の swipeUp 等でアプリ frame 全体、
// Android = 縦 0.3h↔0.7h・横 0.2w↔0.8w の固定座標)。よって #pad_swipe はコンテンツ領域いっぱいに
// 敷き、操作要素はその上に重ねる。ボタン類は始点を塞がないよう幅45%以内(中央列を空ける)かつ
// 上下の端(中央行を空ける)に置く。
export function GestureScreen({ onOpenMap }: { onOpenMap: () => void }) {
  const [tap, setTap] = useState(0);
  const [press, setPress] = useState(0);
  const [swipeDir, setSwipeDir] = useState('-');
  const [last, setLast] = useState('-');

  const panResponder = useRef(
    PanResponder.create({
      onStartShouldSetPanResponder: () => true,
      onMoveShouldSetPanResponder: (_, g) => Math.abs(g.dx) > 4 || Math.abs(g.dy) > 4,
      // 判定は指の移動方向(上へ払う = up)。ブリッジの direction 定義と一致させる契約。
      onPanResponderRelease: (_, g) => {
        if (Math.abs(g.dx) < 4 && Math.abs(g.dy) < 4) {
          return;
        }
        const dir =
          Math.abs(g.dx) > Math.abs(g.dy)
            ? g.dx < 0
              ? 'left'
              : 'right'
            : g.dy < 0
              ? 'up'
              : 'down';
        setSwipeDir(dir);
        setLast('swipe');
      },
    }),
  ).current;

  const reset = () => {
    setTap(0);
    setPress(0);
    setSwipeDir('-');
    setLast('-');
  };

  return (
    <View style={styles.root}>
      <View testID={Tags.padSwipe} style={[styles.pad, StyleSheet.absoluteFill]} {...panResponder.panHandlers}>
        <Text>スワイプ領域</Text>
      </View>
      <View style={[styles.overlay, styles.topLeft]}>
        <TaggedButton
          testID={Tags.btnTapCounter}
          label="タップ"
          fillWidth
          onPress={() => {
            setTap(t => t + 1);
            setLast('tap');
          }}
        />
        {/* 通常タップでは増えず長押しでのみ増える */}
        <Pressable
          testID={Tags.btnLongPress}
          accessible
          accessibilityRole="button"
          accessibilityLabel="長押し"
          onPress={() => {}}
          onLongPress={() => {
            setPress(p => p + 1);
            setLast('longpress');
          }}
          style={styles.longPressBox}
        >
          <Text style={styles.longPressLabel}>長押し</Text>
        </Pressable>
      </View>
      <View style={[styles.overlay, styles.topRight]}>
        <EchoText testID={Tags.txtTapCount}>{`tap=${tap}`}</EchoText>
        <EchoText testID={Tags.txtPressCount}>{`press=${press}`}</EchoText>
        <EchoText testID={Tags.txtSwipeDir}>{`swipe=${swipeDir}`}</EchoText>
        <EchoText testID={Tags.txtLastGesture}>{`last=${last}`}</EchoText>
      </View>
      {/* マップ画面への導線。右下に置く(ホーム末尾に足すとタブに吸われる事故を避ける)。 */}
      <View style={[styles.overlay, styles.bottomRight]}>
        <TaggedButton testID={Tags.navMap} label="マップ" fillWidth onPress={onOpenMap} />
      </View>
      <View style={[styles.overlay, styles.bottomLeft]}>
        <TaggedButton testID={Tags.btnGestureReset} label="ジェスチャクリア" fillWidth onPress={reset} />
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  root: {
    flex: 1,
  },
  pad: {
    backgroundColor: '#eeeeee',
    alignItems: 'center',
    justifyContent: 'center',
  },
  overlay: {
    position: 'absolute',
    width: '45%',
    gap: 8,
  },
  topLeft: { top: 12, left: 12 },
  topRight: { top: 12, right: 12, alignItems: 'flex-end' },
  bottomLeft: { bottom: 12, left: 12 },
  bottomRight: { bottom: 12, right: 12 },
  longPressBox: {
    height: 56,
    backgroundColor: '#3366ff',
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 6,
  },
  longPressLabel: {
    color: '#ffffff',
  },
});
