import React from 'react';
import { Platform } from 'react-native';

import { Tags } from '../tags';
import { EchoText, ScreenContainer, TaggedButton } from '../ui';

export function LifecycleScreen({
  launchCount,
  sessionCount,
  lastDeeplink,
  onSessionIncrement,
  onResetLaunch,
}: {
  launchCount: number;
  sessionCount: number;
  lastDeeplink: string;
  onSessionIncrement: () => void;
  onResetLaunch: () => void;
}) {
  return (
    <ScreenContainer>
      <EchoText testID={Tags.txtLaunchCount}>{`launch=${launchCount}`}</EchoText>
      <EchoText testID={Tags.txtSessionCount}>{`session=${sessionCount}`}</EchoText>
      <TaggedButton testID={Tags.btnSessionInc} label="セッション+1" onPress={onSessionIncrement} />
      <TaggedButton testID={Tags.btnResetPersisted} label="永続カウンタをリセット" onPress={onResetLaunch} />
      <EchoText testID={Tags.txtPlatform}>{`platform=${Platform.OS === 'ios' ? 'iOS' : 'Android'}`}</EchoText>
      <EchoText testID={Tags.txtLastDeeplink}>{`deeplink=${lastDeeplink}`}</EchoText>
    </ScreenContainer>
  );
}
