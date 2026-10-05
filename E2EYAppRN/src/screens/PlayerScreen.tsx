import React, { useRef, useState } from 'react';
import { FlatList, Pressable, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import BottomSheet, { BottomSheetFlatList } from '@gorhom/bottom-sheet';
import { runOnJS, useAnimatedReaction, useSharedValue } from 'react-native-reanimated';

import { Tags } from '../tags';
import { EchoText, TaggedButton } from '../ui';

const MINI_HEIGHT = 64;
// 畳む(index 0)・半分(1)・全開(2)。非モーダルの BottomSheet = 背面も押せる常駐シート
const SNAP_POINTS = [MINI_HEIGHT, '50%', '100%'];
const STATES = ['collapsed', 'half', 'expanded'] as const;
const pad2 = (n: number) => String(n).padStart(2, '0');
const MAIN = Array.from({ length: 40 }, (_, n) => n);
const QUEUE = Array.from({ length: 30 }, (_, n) => n);

export function PlayerScreen() {
  const insets = useSafeAreaInsets();
  const sheetRef = useRef<BottomSheet>(null);
  const [index, setIndex] = useState(0);
  // シートの位置そのもの(UI スレッドの共有値)から段を決める。外部の指の払いで動いたとき onChange / onAnimate が
  // 来ない回があった(E2EY-RN の S0040: シートは上端まで動いたのに sheet=collapsed のまま)
  const animatedIndex = useSharedValue(0);
  useAnimatedReaction(
    () => Math.round(animatedIndex.value),
    (cur, prev) => {
      if (cur !== prev) runOnJS(setIndex)(cur);
    },
  );
  const [result, setResult] = useState('player=none');
  const [playing, setPlaying] = useState(false);

  return (
    // 畳んだシートをジェスチャナビのバーの上に置く(下端からの上払いが OS のホーム操作に取られる)
    <View style={[styles.root, { paddingBottom: insets.bottom }]}>
      <View style={styles.echo}>
        <EchoText testID={Tags.txtSheetState}>{`sheet=${STATES[index]}`}</EchoText>
        <EchoText testID={Tags.txtPlayerResult}>{result}</EchoText>
      </View>
      <View style={styles.body}>
        <FlatList
          data={MAIN}
          keyExtractor={n => String(n)}
          // シートの高さぶんの余白(最後の行がシートの裏に潜らない)
          contentContainerStyle={{ paddingBottom: MINI_HEIGHT }}
          renderItem={({ item }) => (
            <TaggedButton
              testID={Tags.rowMain(item)}
              label={`本文 ${pad2(item)}`}
              onPress={() => setResult(`player=main:${Tags.rowMain(item)}`)}
              style={styles.row}
            />
          )}
        />
        <BottomSheet
          ref={sheetRef}
          index={0}
          snapPoints={SNAP_POINTS}
          enableDynamicSizing={false}
          enablePanDownToClose={false}
          handleComponent={null}
          animatedIndex={animatedIndex}
          onChange={setIndex}
          // 払いで動いた先を、止まるのを待たずに反映する(止まった後の onChange が来ない場合の備え)
          onAnimate={(_from: number, to: number) => setIndex(to)}
          style={styles.sheet}
          // 既定の accessible 畳み込みを止める(gorhom は中身を1要素へ畳みうる)
          accessible={false}
        >
          {index === 0 ? (
            <Pressable
              testID={Tags.miniPlayer}
              accessible={false}
              onPress={() => sheetRef.current?.snapToIndex(1)}
              style={styles.mini}
            >
              <EchoText testID={Tags.txtMiniTitle}>再生中: トラック 1</EchoText>
              <TaggedButton
                testID={Tags.btnMiniPlay}
                label={playing ? '一時停止' : '再生'}
                onPress={() => {
                  setResult(`player=${playing ? 'pause' : 'play'}`);
                  setPlaying(p => !p);
                }}
              />
            </Pressable>
          ) : (
            <View style={styles.full}>
              <View style={styles.header}>
                <EchoText testID={Tags.txtPlayerTitle}>トラック 1</EchoText>
                <Pressable
                  testID={Tags.btnPlayerCollapse}
                  accessible
                  accessibilityRole="button"
                  accessibilityLabel="畳む"
                  onPress={() => sheetRef.current?.snapToIndex(0)}
                  style={styles.collapse}
                >
                  <Text importantForAccessibility="no-hide-descendants" accessibilityElementsHidden>
                    ▾
                  </Text>
                </Pressable>
              </View>
              <BottomSheetFlatList
                testID={Tags.listQueue}
                data={QUEUE}
                keyExtractor={(n: number) => String(n)}
                renderItem={({ item }: { item: number }) => (
                  <TaggedButton
                    testID={Tags.queueRow(item)}
                    label={`キュー ${pad2(item)}`}
                    onPress={() => setResult(`player=queue:${Tags.queueRow(item)}`)}
                    style={styles.row}
                  />
                )}
              />
            </View>
          )}
        </BottomSheet>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#ffffff' },
  echo: { padding: 8, gap: 2 },
  body: { flex: 1 },
  row: { height: 48, marginVertical: 2, marginHorizontal: 8 },
  sheet: {
    backgroundColor: '#ffffff',
    borderTopLeftRadius: 12,
    borderTopRightRadius: 12,
    shadowColor: '#000000',
    shadowOpacity: 0.25,
    shadowRadius: 6,
    elevation: 8,
  },
  mini: {
    height: MINI_HEIGHT,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 16,
  },
  full: { flex: 1 },
  header: {
    height: MINI_HEIGHT,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 16,
  },
  collapse: { minWidth: 44, minHeight: 44, alignItems: 'center', justifyContent: 'center' },
});
