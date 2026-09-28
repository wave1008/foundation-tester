import React from 'react';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';

import type { RootStackParamList } from '../navigation';
import { Tags } from '../tags';
import { EchoText, ScreenContainer, TaggedButton } from '../ui';

type Props = NativeStackScreenProps<RootStackParamList, 'Detail'>;

export function DetailScreen({ route, navigation }: Props) {
  const { id } = route.params;
  return (
    <ScreenContainer>
      <EchoText testID={Tags.txtDetailId}>{`id=${id}`}</EchoText>
      <TaggedButton
        testID={Tags.btnDetailNext}
        label="次の詳細"
        onPress={() => navigation.push('Detail', { id: id + 1 })}
      />
    </ScreenContainer>
  );
}
