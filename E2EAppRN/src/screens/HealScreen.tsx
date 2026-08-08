import React, { useState } from 'react';

import { Tags } from '../tags';
import { EchoText, LabeledRow, ScreenContainer, TaggedButton, TaggedSwitch } from '../ui';

type Tapped = 'v1' | 'v2' | '-';

// `--heal` とヒールキャッシュの E2E 用。ラベルは不変・id だけが切り替わる。schemaV1 は
// App 側(AppShell)が保持する制御値(ナビゲーションを跨いで最新値を再表示するため)。
// Flutter 版は「testID の変更だけでは a11y ツリーに反映されず key で強制再生成が要る」罠を
// 踏んだ実績があるが、RN は毎レンダーで全 native props を宣言的に diff するため、
// testID の切替だけで反映されるはず(要実機確認)。
export function HealScreen({
  schemaV1,
  onSchemaChange,
}: {
  schemaV1: boolean;
  onSchemaChange: (v: boolean) => void;
}) {
  const [tapped, setTapped] = useState<Tapped>('-');

  return (
    <ScreenContainer>
      <LabeledRow label="旧ID(v1)を使う">
        <TaggedSwitch
          testID={Tags.swHealSchema}
          value={schemaV1}
          onValueChange={onSchemaChange}
          accessibilityLabel="旧ID(v1)を使う"
        />
      </LabeledRow>
      <EchoText testID={Tags.txtHealSchema}>{`schema=${schemaV1 ? 'v1' : 'v2'}`}</EchoText>
      <TaggedButton
        testID={schemaV1 ? Tags.btnHealV1 : Tags.btnHealV2}
        label="修復対象"
        onPress={() => setTapped(schemaV1 ? 'v1' : 'v2')}
      />
      <EchoText testID={Tags.txtHealResult}>{`tapped=${tapped}`}</EchoText>
      <TaggedButton testID={Tags.btnHealReset} label="修復結果クリア" onPress={() => setTapped('-')} />
    </ScreenContainer>
  );
}
