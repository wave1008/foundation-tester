import React, { useState } from 'react';
import { StyleSheet, View } from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import Animated, {
  runOnJS,
  useAnimatedStyle,
  useSharedValue,
  withSpring,
} from 'react-native-reanimated';

import { Tags } from '../tags';
import { EchoText, ScreenContainer } from '../ui';

const ROW_HEIGHT = 56;
const INITIAL_ORDER = [1, 2, 3, 4, 5];

// 定番のドラッグ並べ替えライブラリ(react-native-draggable-flatlist 等)は New Architecture 前提での
// 保守が薄く未検証のため、gesture-handler + reanimated の自前実装で代替する(CMP の自前実装と
// 同じ方針。契約が許容)。しきい値(行の半分)を跨ぐたびに配列を並べ替え、離した位置がそのまま
// 最終位置になる(隣との1回だけの入れ替えに丸めない)。
function DragRow({
  id,
  order,
  onReorder,
}: {
  id: number;
  order: number[];
  onReorder: (next: number[]) => void;
}) {
  const translateY = useSharedValue(0);
  const isDragging = useSharedValue(false);
  const orderRef = useSharedValue(order);
  orderRef.value = order;

  const commitMove = (fromIndex: number, toIndex: number) => {
    const next = [...orderRef.value];
    const [moved] = next.splice(fromIndex, 1);
    next.splice(toIndex, 0, moved);
    onReorder(next);
  };

  const pan = Gesture.Pan()
    .activateAfterLongPress(250)
    .onStart(() => {
      isDragging.value = true;
    })
    .onUpdate(e => {
      translateY.value = e.translationY;
      const currentIndex = orderRef.value.indexOf(id);
      const shift = Math.round(translateY.value / ROW_HEIGHT);
      if (shift === 0) return;
      const targetIndex = Math.min(Math.max(currentIndex + shift, 0), orderRef.value.length - 1);
      if (targetIndex !== currentIndex) {
        translateY.value -= shift * ROW_HEIGHT;
        runOnJS(commitMove)(currentIndex, targetIndex);
      }
    })
    .onFinalize(() => {
      isDragging.value = false;
      translateY.value = withSpring(0);
    });

  const style = useAnimatedStyle(() => ({
    transform: [{ translateY: translateY.value }],
    zIndex: isDragging.value ? 1 : 0,
    elevation: isDragging.value ? 4 : 0,
  }));

  return (
    <GestureDetector gesture={pan}>
      <Animated.View style={[styles.row, style]}>
        <EchoText testID={Tags.reorderRow(id)}>{`並べ替え ${id}`}</EchoText>
      </Animated.View>
    </GestureDetector>
  );
}

export function ReorderScreen() {
  const [order, setOrder] = useState<number[]>(INITIAL_ORDER);

  return (
    <ScreenContainer>
      <EchoText testID={Tags.txtReorderResult}>{`order=${order.join(',')}`}</EchoText>
      <View style={styles.list}>
        {order.map(id => (
          <DragRow key={id} id={id} order={order} onReorder={setOrder} />
        ))}
      </View>
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  list: {
    position: 'relative',
  },
  row: {
    height: ROW_HEIGHT,
    justifyContent: 'center',
    paddingHorizontal: 16,
    backgroundColor: '#f2f2f2',
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#cccccc',
  },
});
