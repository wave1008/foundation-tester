import React, { useState } from 'react';

import { Tags } from '../tags';
import {
  EchoText,
  LabeledRow,
  ScreenContainer,
  TaggedButton,
  TaggedCheckbox,
  TaggedRadio,
  TaggedSlider,
  TaggedSwitch,
} from '../ui';

type Plan = 'A' | 'B' | 'C';

export function ControlsScreen() {
  const [notify, setNotify] = useState(false);
  const [agree, setAgree] = useState(false);
  const [plan, setPlan] = useState<Plan>('A');
  const [volume, setVolume] = useState(50);

  const reset = () => {
    setNotify(false);
    setAgree(false);
    setPlan('A');
    setVolume(50);
  };

  return (
    <ScreenContainer>
      {/* ラベル Text とコントロール本体を別要素にする(タップ対象は本体のみ) */}
      <LabeledRow label="通知">
        <TaggedSwitch testID={Tags.swNotify} value={notify} onValueChange={setNotify} accessibilityLabel="通知" />
      </LabeledRow>
      <EchoText testID={Tags.txtSwNotify}>{`notify=${notify ? 'on' : 'off'}`}</EchoText>
      <LabeledRow label="同意する">
        <TaggedCheckbox testID={Tags.cbAgree} checked={agree} onToggle={setAgree} />
      </LabeledRow>
      <EchoText testID={Tags.txtCbAgree}>{`agree=${agree}`}</EchoText>
      <LabeledRow label="プランA">
        <TaggedRadio testID={Tags.radioA} selected={plan === 'A'} onSelect={() => setPlan('A')} />
      </LabeledRow>
      <LabeledRow label="プランB">
        <TaggedRadio testID={Tags.radioB} selected={plan === 'B'} onSelect={() => setPlan('B')} />
      </LabeledRow>
      <LabeledRow label="プランC">
        <TaggedRadio testID={Tags.radioC} selected={plan === 'C'} onSelect={() => setPlan('C')} />
      </LabeledRow>
      <EchoText testID={Tags.txtRadio}>{`plan=${plan}`}</EchoText>
      {/* 0..100 を 25 刻みの5段(0/25/50/75/100)にする契約値 */}
      <TaggedSlider testID={Tags.sliderVolume} value={volume} min={0} max={100} step={25} onChange={setVolume} />
      <EchoText testID={Tags.txtSlider}>{`volume=${Math.round(volume)}`}</EchoText>
      {/* 無効でもアクセシビリティツリーから消さない(消えると isDisabled が「見つかりません」になる) */}
      <TaggedButton testID={Tags.btnAlwaysDisabled} label="無効ボタン" disabled onPress={() => {}} />
      <TaggedButton testID={Tags.btnToggleTarget} label="切替対象" disabled={!agree} onPress={() => {}} />
      <TaggedButton testID={Tags.btnControlsReset} label="コントロールリセット" onPress={reset} />
    </ScreenContainer>
  );
}
