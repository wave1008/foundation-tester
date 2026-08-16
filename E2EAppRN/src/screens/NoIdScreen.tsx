import React, { useState } from 'react';
import { Switch, Text, View } from 'react-native';

import { ScreenContainer, TaggedButton } from '../ui';

// 契約: E2EAppCMP/docs/ui-contract.md「ID なし画面」。この画面の要素には testID を一切
// 付けない(方向セレクタだけで操作・検証できることを保証するための画面)。行の高さ48以上・
// 行間の余裕は帯判定(:right が隣の行のスイッチを拾わない)のため。
export function NoIdScreen() {
  const [notify, setNotify] = useState(false);
  const [location, setLocation] = useState(false);
  const [qty, setQty] = useState(0);

  return (
    <ScreenContainer scrollable={false}>
      <Text>設定</Text>
      {/* lineHeight はスイッチの高さに合わせる: iOS の Text は a11y frame が視覚枠より
          約10pt 下に報告され、素の高さだと :rightSwitch の帯判定がスイッチ中心を外す
          (2026-08-08 実測。cannot resolve になった) */}
      <View style={{ minHeight: 48, flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
        <Text style={{ lineHeight: 31 }}>通知</Text>
        <Switch value={notify} onValueChange={setNotify} />
      </View>
      <Text>{`notify=${notify ? 'on' : 'off'}`}</Text>
      <View style={{ minHeight: 48, flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
        <Text style={{ lineHeight: 31 }}>位置情報</Text>
        <Switch value={location} onValueChange={setLocation} />
      </View>
      <Text>{`location=${location ? 'on' : 'off'}`}</Text>
      <View style={{ minHeight: 48, flexDirection: 'row', alignItems: 'center', gap: 16 }}>
        <TaggedButton label="変更" onPress={() => setQty(q => Math.max(0, q - 1))} />
        <Text>数量</Text>
        <TaggedButton label="変更" onPress={() => setQty(q => q + 1)} />
      </View>
      <Text>{`qty=${qty}`}</Text>
    </ScreenContainer>
  );
}
