import React, { useRef, useState } from 'react';
import { LayoutChangeEvent, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import ReanimatedSwipeable, {
  SwipeableMethods,
} from 'react-native-gesture-handler/ReanimatedSwipeable';
import Animated, {
  SharedValue,
  runOnJS,
  useAnimatedReaction,
  useAnimatedStyle,
  useSharedValue,
  withSpring,
} from 'react-native-reanimated';

import { Tags } from '../tags';
import { EchoText } from '../ui';

const FULL_SWIPE_RATIO = 0.6;
const REPLY_RATIO = 0.25;
const ACTION_WIDTH = 80;

function ActionButton({
  testID,
  label,
  color,
  onPress,
}: {
  testID: string;
  label: string;
  color: string;
  onPress: () => void;
}) {
  return (
    <Pressable
      testID={testID}
      accessible
      accessibilityRole="button"
      accessibilityLabel={label}
      onPress={onPress}
      style={[styles.action, { backgroundColor: color }]}
    >
      <Text style={styles.actionLabel} importantForAccessibility="no-hide-descendants" accessibilityElementsHidden>
        {label}
      </Text>
    </Pressable>
  );
}

// 払い量が閾値を越えたかを JS 側へ渡す(離した時点で越えていれば full swipe)
function RightActions({
  translation,
  rowWidth,
  onPast,
  id,
  onArchive,
  onDelete,
}: {
  translation: SharedValue<number>;
  rowWidth: number;
  onPast: (past: boolean) => void;
  id: number;
  onArchive: () => void;
  onDelete: () => void;
}) {
  useAnimatedReaction(
    () => -translation.value > rowWidth * FULL_SWIPE_RATIO,
    (cur, prev) => {
      if (cur !== prev) runOnJS(onPast)(cur);
    },
  );
  return (
    <View style={styles.actions}>
      <ActionButton testID={Tags.btnSwArchive(id)} label="アーカイブ" color="#3b82f6" onPress={onArchive} />
      <ActionButton testID={Tags.btnSwDelete(id)} label="削除" color="#dc2626" onPress={onDelete} />
    </View>
  );
}

function SwipeRow({
  id,
  onResult,
  onDelete,
}: {
  id: number;
  onResult: (s: string) => void;
  onDelete: (id: number) => void;
}) {
  const ref = useRef<SwipeableMethods | null>(null);
  const [width, setWidth] = useState(360);
  const pastRef = useRef(false);
  const openRef = useRef(false);

  return (
    <View onLayout={(e: LayoutChangeEvent) => setWidth(e.nativeEvent.layout.width)}>
      <ReanimatedSwipeable
        ref={ref}
        friction={1}
        onSwipeableWillOpen={dir => {
          openRef.current = true;
          if (dir === 'left' && pastRef.current) {
            onResult(`action=row${id}:delete`);
            onDelete(id);
          }
        }}
        onSwipeableClose={() => {
          openRef.current = false;
          pastRef.current = false;
        }}
        renderRightActions={(_p, translation) => (
          <RightActions
            translation={translation}
            rowWidth={width}
            id={id}
            onPast={p => {
              pastRef.current = p;
            }}
            onArchive={() => {
              onResult(`action=row${id}:archive`);
              ref.current?.close();
            }}
            onDelete={() => {
              onResult(`action=row${id}:delete`);
              onDelete(id);
            }}
          />
        )}
        renderLeftActions={() => (
          <View style={styles.actions}>
            <ActionButton
              testID={Tags.btnSwPin(id)}
              label="ピン留め"
              color="#16a34a"
              onPress={() => {
                onResult(`action=row${id}:pin`);
                ref.current?.close();
              }}
            />
          </View>
        )}
      >
        <Pressable
          testID={Tags.swRow(id)}
          accessible
          accessibilityRole="button"
          accessibilityLabel={`スワイプ行 ${id}`}
          onPress={() => {
            // 開いている間の本体タップは閉じるだけ(Swipeable 内蔵の Tap が閉じる)
            if (!openRef.current) onResult(`action=row${id}:open`);
          }}
          style={styles.row}
        >
          <Text importantForAccessibility="no-hide-descendants" accessibilityElementsHidden>
            {`スワイプ行 ${id}`}
          </Text>
        </Pressable>
      </ReanimatedSwipeable>
    </View>
  );
}

function ReplyRow({ id, onReply }: { id: number; onReply: (id: number) => void }) {
  const tx = useSharedValue(0);
  const width = useSharedValue(360);
  const pan = Gesture.Pan()
    .activeOffsetX([-1000, 12])
    .failOffsetY([-15, 15])
    .onUpdate(e => {
      tx.value = Math.max(0, e.translationX);
    })
    .onEnd(e => {
      if (e.translationX > width.value * REPLY_RATIO) runOnJS(onReply)(id);
      tx.value = withSpring(0);
    });
  const style = useAnimatedStyle(() => ({ transform: [{ translateX: tx.value }] }));
  return (
    <GestureDetector gesture={pan}>
      <Animated.View
        testID={Tags.replyRow(id)}
        accessible
        accessibilityLabel={`返信行 ${id}`}
        onLayout={e => {
          width.value = e.nativeEvent.layout.width;
        }}
        style={[styles.row, style]}
      >
        <Text importantForAccessibility="no-hide-descendants" accessibilityElementsHidden>
          {`返信行 ${id}`}
        </Text>
      </Animated.View>
    </GestureDetector>
  );
}

export function SwipeActionsScreen() {
  const [rows, setRows] = useState([1, 2, 3, 4, 5, 6]);
  const [result, setResult] = useState('action=none');
  const [reply, setReply] = useState('reply=none');

  return (
    <View style={styles.root}>
      <View style={styles.echo}>
        <EchoText testID={Tags.txtSwipeActionsResult}>{result}</EchoText>
        <EchoText testID={Tags.txtSwipeActionsCount}>{`rows=${rows.length}`}</EchoText>
        <EchoText testID={Tags.txtReplyTarget}>{reply}</EchoText>
      </View>
      <ScrollView>
        {rows.map(id => (
          <SwipeRow
            key={id}
            id={id}
            onResult={setResult}
            onDelete={rid => setRows(prev => prev.filter(r => r !== rid))}
          />
        ))}
        <View style={styles.gap} />
        {[1, 2, 3].map(id => (
          <ReplyRow key={id} id={id} onReply={rid => setReply(`reply=reply_row_${rid}`)} />
        ))}
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#ffffff' },
  echo: { padding: 8, gap: 2 },
  row: {
    minHeight: 56,
    justifyContent: 'center',
    paddingHorizontal: 16,
    backgroundColor: '#f2f2f2',
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#cccccc',
  },
  actions: { flexDirection: 'row' },
  action: { width: ACTION_WIDTH, justifyContent: 'center', alignItems: 'center' },
  actionLabel: { color: '#ffffff', fontSize: 14 },
  gap: { height: 16 },
});
