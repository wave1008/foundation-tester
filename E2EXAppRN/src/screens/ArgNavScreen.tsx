import React from 'react';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';

import type { RootStackParamList } from '../navigation';
import { Tags } from '../tags';
import { ListRow, ScreenContainer } from '../ui';

type Props = NativeStackScreenProps<RootStackParamList, 'ArgNav'>;

export function ArgNavScreen({ navigation }: Props) {
  return (
    <ScreenContainer>
      {[1, 2, 3].map(n => (
        <ListRow
          key={n}
          testID={Tags.detailLink(n)}
          label={`詳細 ${n}`}
          onPress={() => navigation.navigate('Detail', { id: n })}
        />
      ))}
    </ScreenContainer>
  );
}
