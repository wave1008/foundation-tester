import React, { useState } from 'react';
import { FlatList, StyleSheet } from 'react-native';

import { Tags } from '../tags';
import { EchoText, ScreenContainer, TaggedButton } from '../ui';

const CELLS = Array.from({ length: 90 }, (_, n) => n);

export function GridScreen() {
  const [result, setResult] = useState('grid=none');

  return (
    <ScreenContainer>
      <EchoText testID={Tags.txtGridResult}>{result}</EchoText>
      <FlatList
        testID={Tags.gridMain}
        style={styles.grid}
        data={CELLS}
        numColumns={3}
        keyExtractor={n => String(n)}
        renderItem={({ item }) => (
          <TaggedButton
            testID={Tags.cell(item)}
            label={`セル ${String(item).padStart(2, '0')}`}
            onPress={() => setResult(`grid=${String(item).padStart(2, '0')}`)}
            style={styles.cell}
          />
        )}
      />
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  grid: {
    flex: 1,
  },
  cell: {
    flex: 1 / 3,
    height: 96,
    margin: 2,
  },
});
