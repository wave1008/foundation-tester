import React, { useState } from 'react';
import { SectionList, StyleSheet } from 'react-native';

import { Tags } from '../tags';
import { EchoText, ScreenContainer, TaggedButton } from '../ui';

const LETTERS = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H'];
const SECTIONS = LETTERS.map(letter => ({
  letter,
  title: `セクション ${letter}`,
  data: Array.from({ length: 10 }, (_, n) => n),
}));

export function StickyScreen() {
  const [result, setResult] = useState('sticky=none');

  return (
    <ScreenContainer>
      <EchoText testID={Tags.txtStickyResult}>{result}</EchoText>
      <SectionList
        style={styles.list}
        sections={SECTIONS}
        keyExtractor={(item, index) => `${index}-${item}`}
        // iOS は既定で貼り付くが Android は明示しないと貼り付かないので両方に立てる。
        stickySectionHeadersEnabled
        renderSectionHeader={({ section }) => (
          <EchoText testID={Tags.hdr(section.letter)} style={styles.header}>
            {section.title}
          </EchoText>
        )}
        renderItem={({ item, section }) => (
          <TaggedButton
            testID={Tags.rowS(section.letter, item)}
            label={`行 ${section.letter}${item}`}
            onPress={() => setResult(`sticky=${Tags.rowS(section.letter, item)}`)}
            style={styles.row}
          />
        )}
      />
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  list: {
    flex: 1,
  },
  header: {
    backgroundColor: '#e6e6e6',
    paddingHorizontal: 16,
    paddingVertical: 8,
    fontWeight: '600',
  },
  row: {
    marginHorizontal: 16,
    marginVertical: 2,
  },
});
