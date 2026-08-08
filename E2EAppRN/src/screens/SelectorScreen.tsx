import React, { useState } from 'react';
import { View } from 'react-native';

import { Tags } from '../tags';
import { EchoText, ScreenContainer, TaggedButton } from '../ui';

// tap のセレクタ記法(#id / ラベル / *部分一致* / .型[n] / .型#id / && / ||)を網羅する画面。
// 序数(戻る(1) 許可(2) 通知を許可(3) 項目(4,5,6) 共通ラベル(7) 別名(8) 結果クリア(9) タブ(10-12))
// を崩さないよう、この JSX 順のままにする。
export function SelectorScreen() {
  const [result, setResult] = useState('-');

  return (
    <ScreenContainer>
      <EchoText testID={Tags.selectorResult}>{`result=${result}`}</EchoText>
      {/* 「許可」⊂「通知を許可」の部分一致衝突は契約で意図的に作られた検証材料 */}
      <TaggedButton testID={Tags.btnAllow} label="許可" onPress={() => setResult('allow')} />
      <TaggedButton
        testID={Tags.btnAllowNotification}
        label="通知を許可"
        onPress={() => setResult('allow_notification')}
      />
      {/* 同一ラベル「項目」の3連。ラベル指定は曖昧解決不能 = 序数セレクタの検証材料。 */}
      <TaggedButton testID={Tags.btnItem1} label="項目" onPress={() => setResult('item1')} />
      <TaggedButton testID={Tags.btnItem2} label="項目" onPress={() => setResult('item2')} />
      <TaggedButton testID={Tags.btnItem3} label="項目" onPress={() => setResult('item3')} />
      <EchoText testID={Tags.txtSharedLabel}>共通ラベル</EchoText>
      <TaggedButton testID={Tags.btnSharedLabel} label="共通ラベル" onPress={() => setResult('shared')} />
      {/* btn_alias_old は存在しない: #btn_alias_old||#btn_alias_new のフォールバック連鎖検証用 */}
      <TaggedButton testID={Tags.btnAliasNew} label="別名ボタン" onPress={() => setResult('alias')} />
      <TaggedButton testID={Tags.btnSelectorReset} label="結果クリア" onPress={() => setResult('-')} />
      {/* scrollTo / requireVisible の検証材料: 初期表示では絶対に画面内に入らない余白 */}
      <View style={{ height: 700 }} />
      <EchoText testID={Tags.txtOffscreen}>画面外テキスト</EchoText>
    </ScreenContainer>
  );
}
