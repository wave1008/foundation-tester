import React, { useState } from 'react';
import { StyleSheet, View } from 'react-native';
import { FlashList } from '@shopify/flash-list';

import { Tags } from '../tags';
import { EchoText, TaggedButton } from '../ui';

const TILES = Array.from({ length: 60 }, (_, i) => i);
const tileHeight = (i: number) => 80 + ((i * 37) % 5) * 30;

export function StaggeredScreen() {
  const [result, setResult] = useState('stag=none');
  return (
    <View style={styles.root}>
      <View style={styles.echo}>
        <EchoText testID={Tags.txtStaggeredResult}>{result}</EchoText>
      </View>
      <FlashList
        testID={Tags.gridStaggered}
        data={TILES}
        masonry
        numColumns={2}
        keyExtractor={i => String(i)}
        renderItem={({ item }) => (
          <TaggedButton
            testID={Tags.stag(item)}
            label={`タイル ${String(item).padStart(2, '0')}`}
            onPress={() => setResult(`stag=${Tags.stag(item)}`)}
            style={{ height: tileHeight(item), margin: 4 }}
          />
        )}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#ffffff' },
  echo: { padding: 8 },
});
