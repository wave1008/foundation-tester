import React, { useRef, useState } from 'react';
import { FlatList, StyleSheet, View } from 'react-native';

import { rowCount, tag, tagCount, tagLabel, Tags, row, rowLabel } from '../tags';
import { EchoText, TaggedButton } from '../ui';

const ROWS = Array.from({ length: rowCount }, (_, i) => i + 1);
const CAROUSEL = Array.from({ length: tagCount }, (_, i) => i + 1);

// FlatList は仮想化される(RN の現実に合わせた実装。契約の cacheExtent:0 相当の対策は無いため、
// 初期描画本数を絞って画面外行が広く先読みされないようにする)。
// #list_rows は容器そのものを公開する(スコープセレクタの対象)。コンテナ View に
// accessible={true} は付けない(子の testID が畳まれて消える罠を避ける)。
export function ScrollScreen() {
  const [selected, setSelected] = useState('-');
  const [tagSelected, setTagSelected] = useState('-');
  const listRef = useRef<FlatList<number>>(null);

  return (
    <View style={styles.container}>
      <EchoText testID={Tags.txtRowSelected}>{`selected=${selected}`}</EchoText>
      <TaggedButton
        testID={Tags.btnScrollTop}
        label="先頭へ"
        onPress={() => listRef.current?.scrollToOffset({ offset: 0, animated: false })}
      />
      <FlatList
        testID={Tags.listRows}
        ref={listRef}
        style={styles.list}
        data={ROWS}
        keyExtractor={n => row(n)}
        initialNumToRender={8}
        windowSize={3}
        // iOS は既定 false のため先読み行が実座標のままツリーに残り
        // scroll-leftover 警告の対象になる(Flutter の cacheExtent:0 と同じ趣旨)
        removeClippedSubviews
        // 下端の余白: 最終行がビューポート下端に貼り付いたままだと座標タップが外れやすい。
        contentContainerStyle={{ paddingBottom: 80 }}
        renderItem={({ item: n }) => (
          <TaggedButton
            testID={row(n)}
            label={rowLabel(n)}
            style={styles.row}
            onPress={() => setSelected(row(n))}
          />
        )}
      />
      {/* 横スクロールの検証材料(scrollFrame)。リストの下・画面下部に置く(中央に置くと
          領域指定なしの従来スクロールがカルーセルに吸われる)。1画面に3〜4個しか入らない幅。 */}
      <FlatList
        testID={Tags.carouselTags}
        horizontal
        data={CAROUSEL}
        keyExtractor={n => tag(n)}
        initialNumToRender={4}
        windowSize={3}
        removeClippedSubviews
        style={styles.carousel}
        renderItem={({ item: n }) => (
          <TaggedButton
            testID={tag(n)}
            label={tagLabel(n)}
            style={styles.tagButton}
            onPress={() => setTagSelected(tag(n))}
          />
        )}
      />
      <EchoText testID={Tags.txtTagSelected}>{`tag=${tagSelected}`}</EchoText>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: 16,
    gap: 8,
  },
  list: {
    flex: 1,
  },
  row: {
    minHeight: 56,
    alignItems: 'flex-start',
    justifyContent: 'center',
    marginBottom: 2,
  },
  carousel: {
    height: 60,
    flexGrow: 0,
  },
  tagButton: {
    width: 120,
    minHeight: 56,
    marginRight: 8,
  },
});
