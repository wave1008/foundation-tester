import React from 'react';
import { ScrollView } from 'react-native';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';

import type { RootStackParamList } from '../navigation';
import { ListRow } from '../ui';

type Props = NativeStackScreenProps<RootStackParamList, 'Home'>;

const ITEMS: Array<{ testID: string; label: string; to: keyof RootStackParamList }> = [
  { testID: 'nav_nested', label: '入れ子スクロール', to: 'Nested' },
  { testID: 'nav_chat', label: '反転チャット', to: 'Chat' },
  { testID: 'nav_loading', label: '読み込みの状態', to: 'Loading' },
  { testID: 'nav_swipe_actions', label: 'スワイプの操作', to: 'SwipeActions' },
  { testID: 'nav_select', label: '選択モード', to: 'Select' },
  { testID: 'nav_links', label: '文中リンク', to: 'Links' },
  { testID: 'nav_pin', label: 'PIN と OTP', to: 'Pin' },
  { testID: 'nav_back_guard', label: '戻るの横取り', to: 'BackGuard' },
  { testID: 'nav_player', label: '引き伸ばせるシート', to: 'Player' },
  { testID: 'nav_hide_bars', label: 'スクロールで隠れるバー', to: 'HideBars' },
  { testID: 'nav_tab_header', label: '折りたたみヘッダとタブ', to: 'TabHeader' },
  { testID: 'nav_staggered', label: '高さの揃わないグリッド', to: 'Staggered' },
];

export function HomeScreen({ navigation }: Props) {
  return (
    <ScrollView>
      {ITEMS.map(item => (
        <ListRow
          key={item.testID}
          testID={item.testID}
          label={item.label}
          onPress={() => navigation.navigate(item.to as never)}
        />
      ))}
    </ScrollView>
  );
}
