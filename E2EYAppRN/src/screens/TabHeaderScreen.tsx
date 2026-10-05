import React, { useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { MaterialTabBar, MaterialTabItem, Tabs, useCurrentTabScrollY } from 'react-native-collapsible-tab-view';
import { runOnJS, useAnimatedReaction } from 'react-native-reanimated';

import { Tags } from '../tags';
import { EchoText, TaggedButton } from '../ui';

const HEADER_HEIGHT = 200;
const ROWS = Array.from({ length: 40 }, (_, n) => n);

const TABS = [
  { name: 'posts', title: '投稿', prefix: 'post', rowLabel: '投稿' },
  { name: 'media', title: 'メディア', prefix: 'media', rowLabel: 'メディア' },
  { name: 'likes', title: 'いいね', prefix: 'like', rowLabel: 'いいね' },
];

// 見出しが一部でも見えていれば expanded(スクロール量が見出しの高さ未満)
function HeaderWatcher({ onState }: { onState: (collapsed: boolean) => void }) {
  const y = useCurrentTabScrollY();
  useAnimatedReaction(
    () => y.value >= HEADER_HEIGHT - 1,
    (cur, prev) => {
      if (cur !== prev) runOnJS(onState)(cur);
    },
  );
  return null;
}

export function TabHeaderScreen() {
  const [result, setResult] = useState('tabhdr=none');
  const [tab, setTab] = useState('posts');
  const [collapsed, setCollapsed] = useState(false);

  return (
    <View style={styles.root}>
      <View style={styles.echo}>
        <EchoText testID={Tags.txtTabhdrResult}>{result}</EchoText>
        <EchoText testID={Tags.txtTabhdrTab}>{`tab=${tab}`}</EchoText>
        <EchoText testID={Tags.txtTabhdrHeader}>{`header=${collapsed ? 'collapsed' : 'expanded'}`}</EchoText>
      </View>
      <Tabs.Container
        headerHeight={HEADER_HEIGHT}
        onTabChange={({ tabName }) => setTab(String(tabName))}
        renderHeader={() => (
          <View style={styles.header}>
            <HeaderWatcher onState={setCollapsed} />
            <Text testID={Tags.txtProfileHeader} style={styles.headerTitle}>
              プロフィール見出し
            </Text>
            <TaggedButton testID={Tags.btnFollow} label="フォロー" onPress={() => setResult('tabhdr=follow')} />
          </View>
        )}
        renderTabBar={props => (
          <MaterialTabBar
            {...props}
            TabItemComponent={p => (
              <MaterialTabItem
                {...p}
                testID={Tags.tab(String(p.name))}
                accessibilityRole="tab"
                accessibilityLabel={TABS.find(t => t.name === p.name)?.title}
              />
            )}
          />
        )}
      >
        {TABS.map(t => (
          <Tabs.Tab key={t.name} name={t.name} label={t.title}>
            <Tabs.FlatList
              data={ROWS}
              keyExtractor={(n: number) => String(n)}
              renderItem={({ item }: { item: number }) => (
                <TaggedButton
                  testID={Tags.item(t.prefix, item)}
                  label={`${t.rowLabel} ${String(item).padStart(2, '0')}`}
                  onPress={() => setResult(`tabhdr=${Tags.item(t.prefix, item)}`)}
                  style={styles.row}
                />
              )}
            />
          </Tabs.Tab>
        ))}
      </Tabs.Container>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#ffffff' },
  echo: { padding: 8, gap: 2 },
  header: {
    height: HEADER_HEIGHT,
    justifyContent: 'center',
    alignItems: 'center',
    gap: 12,
    backgroundColor: '#e0e7ff',
  },
  headerTitle: { fontSize: 20, fontWeight: '600' },
  row: { height: 48, marginVertical: 2, marginHorizontal: 8 },
});
