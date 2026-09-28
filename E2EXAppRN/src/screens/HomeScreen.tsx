import React from 'react';
import { ScrollView } from 'react-native';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';

import type { RootStackParamList } from '../navigation';
import { Tags } from '../tags';
import { ListRow } from '../ui';

type Props = NativeStackScreenProps<RootStackParamList, 'Home'>;

const ITEMS: Array<{ testID: string; label: string; to: keyof RootStackParamList }> = [
  { testID: Tags.navPager, label: 'ページャ', to: 'Pager' },
  { testID: Tags.navSheet, label: 'ボトムシート', to: 'Sheet' },
  { testID: Tags.navMenu, label: 'メニュー', to: 'Menu' },
  { testID: Tags.navDate, label: '日付ピッカー', to: 'DatePicker' },
  { testID: Tags.navDrawer, label: 'ドロワー', to: 'Drawer' },
  { testID: Tags.navRefresh, label: '引っ張って更新', to: 'Refresh' },
  { testID: Tags.navSnackbar, label: 'スナックバー', to: 'Snackbar' },
  { testID: Tags.navGrid, label: 'グリッド', to: 'Grid' },
  { testID: Tags.navSwipe, label: 'スワイプで削除', to: 'Swipe' },
  { testID: Tags.navTabs, label: 'タブ', to: 'Tabs' },
  { testID: Tags.navAnim, label: 'アニメーション', to: 'Anim' },
  { testID: Tags.navTooltip, label: 'ツールチップ', to: 'Tooltip' },
  { testID: Tags.navChips, label: 'チップと分割ボタン', to: 'Chips' },
  { testID: Tags.navSearch, label: '検索バー', to: 'Search' },
  { testID: Tags.navDetail, label: '引数付き遷移', to: 'ArgNav' },
  { testID: Tags.navCollapse, label: '伸縮するヘッダ', to: 'Collapse' },
  { testID: Tags.navSticky, label: '貼り付く見出し', to: 'Sticky' },
  { testID: Tags.navTime, label: '時刻ピッカー', to: 'Time' },
  { testID: Tags.navDialogs, label: 'ダイアログ', to: 'Dialogs' },
  { testID: Tags.navContext, label: '長押しメニュー', to: 'Context' },
  { testID: Tags.navReorder, label: '並べ替え', to: 'Reorder' },
  { testID: Tags.navInputs, label: '入力の種類', to: 'Inputs' },
  { testID: Tags.navFab, label: 'FAB', to: 'Fab' },
  { testID: Tags.navExpand, label: '展開するリスト', to: 'Expand' },
  { testID: Tags.navStepper, label: 'ステッパーと進捗', to: 'Stepper' },
  { testID: Tags.navInfinite, label: '無限スクロール', to: 'Infinite' },
  { testID: Tags.navZoom, label: 'ピンチで拡大', to: 'Zoom' },
  { testID: Tags.navNative, label: '固有部品', to: 'Native' },
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
