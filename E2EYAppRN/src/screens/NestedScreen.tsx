import React from 'react';
import { FlatList, Pressable, StyleSheet, Text, View } from 'react-native';

import { Tags } from '../tags';
import { EchoText, ScreenContainer } from '../ui';

const SHELVES = Array.from({ length: 10 }, (_, i) => i);
const CARDS = Array.from({ length: 15 }, (_, j) => j);

export function NestedScreen() {
  const [result, setResult] = React.useState('nested=none');
  return (
    <ScreenContainer>
      <EchoText testID={Tags.txtNestedResult}>{result}</EchoText>
      <FlatList
        testID={Tags.listNested}
        style={styles.list}
        data={SHELVES}
        keyExtractor={i => String(i)}
        renderItem={({ item: i }) => (
          <View style={styles.shelf}>
            <EchoText testID={Tags.txtShelf(i)} style={styles.shelfTitle}>{`棚 ${i}`}</EchoText>
            {/* 窓を 3 画面ぶんに絞る: 既定(21)だと 15 枚が全部マウントされ「画面外のカードは木に居ない」が崩れる */}
            <FlatList
              testID={Tags.shelf(i)}
              horizontal
              data={CARDS}
              keyExtractor={j => String(j)}
              initialNumToRender={3}
              windowSize={3}
              maxToRenderPerBatch={3}
              showsHorizontalScrollIndicator={false}
              renderItem={({ item: j }) => (
                <Pressable
                  testID={Tags.card(i, j)}
                  accessible
                  accessibilityRole="button"
                  accessibilityLabel={`カード ${i}-${String(j).padStart(2, '0')}`}
                  onPress={() => setResult(`nested=${Tags.card(i, j)}`)}
                  style={styles.card}
                >
                  <Text
                    importantForAccessibility="no-hide-descendants"
                    accessibilityElementsHidden
                  >{`カード ${i}-${String(j).padStart(2, '0')}`}</Text>
                </Pressable>
              )}
            />
          </View>
        )}
      />
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  list: { flex: 1 },
  shelf: { marginBottom: 12 },
  shelfTitle: { fontSize: 16, fontWeight: '600', marginBottom: 4 },
  card: {
    width: 140,
    height: 120,
    marginRight: 8,
    backgroundColor: '#dde6f0',
    borderRadius: 8,
    justifyContent: 'center',
    alignItems: 'center',
  },
});
