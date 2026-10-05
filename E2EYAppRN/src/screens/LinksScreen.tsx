import React, { useState } from 'react';
import { Pressable, StyleSheet, Text } from 'react-native';

import { Tags } from '../tags';
import { EchoText, ScreenContainer } from '../ui';

export function LinksScreen() {
  const [result, setResult] = useState('link=none');
  const link = (v: string) => () => setResult(`link=${v}`);

  // 入れ子の Text の onPress(Bluesky の RichText と同じ作り)。リンクは accessibilityRole="link"
  return (
    <ScreenContainer>
      <EchoText testID={Tags.txtLinksResult}>{result}</EchoText>
      <Text testID={Tags.txtTerms} style={styles.text}>
        続行すると
        <Text accessibilityRole="link" style={styles.link} onPress={link('terms')}>
          利用規約
        </Text>
        と
        <Text accessibilityRole="link" style={styles.link} onPress={link('privacy')}>
          プライバシーポリシー
        </Text>
        に同意したものとみなされます。
      </Text>
      <Text testID={Tags.txtPost} style={styles.text}>
        <Text accessibilityRole="link" style={styles.link} onPress={link('mention:alice')}>
          @alice
        </Text>
        {' さんが '}
        <Text accessibilityRole="link" style={styles.link} onPress={link('url')}>
          https://example.com/a
        </Text>
        {' を共有しました'}
      </Text>
      {/* 行の Pressable は accessible={false}: accessible のままだと iOS は子の Text(と文中リンク)を
          1要素へ畳み込み、`こちら` が木から消える */}
      <Pressable testID={Tags.rowWithLink} accessible={false} onPress={link('row')} style={styles.row}>
        <Text style={styles.text}>
          {'お知らせ: 詳細は'}
          <Text accessibilityRole="link" style={styles.link} onPress={link('inner')}>
            こちら
          </Text>
        </Text>
      </Pressable>
    </ScreenContainer>
  );
}

const styles = StyleSheet.create({
  text: { fontSize: 13, lineHeight: 20 },
  link: { color: '#1d4ed8', textDecorationLine: 'underline' },
  row: { minHeight: 56, justifyContent: 'center', backgroundColor: '#f2f2f2', paddingHorizontal: 8 },
});
