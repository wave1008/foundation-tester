import React from 'react';

import { AppInfo, Tags } from '../tags';
import { EchoText, ScreenContainer } from '../ui';

export function AboutScreen() {
  return (
    <ScreenContainer>
      <EchoText testID={Tags.txtAboutMarker}>E2E について</EchoText>
      <EchoText testID={Tags.txtAboutApp}>{`app=${AppInfo.appId}`}</EchoText>
      <EchoText testID={Tags.txtAboutVersion}>{`version=${AppInfo.version}`}</EchoText>
    </ScreenContainer>
  );
}
