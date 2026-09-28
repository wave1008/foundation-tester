import React, { useState } from 'react';
import { ScrollView } from 'react-native';
import { List } from 'react-native-paper';

import { Tags } from '../tags';
import { EchoText, ScreenContainer } from '../ui';

const GROUPS = [
  {
    testID: Tags.groupFruit,
    key: 'fruit',
    title: '果物',
    items: [
      { testID: Tags.itemFruit(1), n: 1, label: 'りんご' },
      { testID: Tags.itemFruit(2), n: 2, label: 'みかん' },
      { testID: Tags.itemFruit(3), n: 3, label: 'ぶどう' },
    ],
  },
  {
    testID: Tags.groupVeg,
    key: 'veg',
    title: '野菜',
    items: [
      { testID: Tags.itemVeg(1), n: 1, label: 'にんじん' },
      { testID: Tags.itemVeg(2), n: 2, label: 'たまねぎ' },
      { testID: Tags.itemVeg(3), n: 3, label: 'キャベツ' },
    ],
  },
  {
    testID: Tags.groupDrink,
    key: 'drink',
    title: '飲み物',
    items: [
      { testID: Tags.itemDrink(1), n: 1, label: '水' },
      { testID: Tags.itemDrink(2), n: 2, label: 'お茶' },
      { testID: Tags.itemDrink(3), n: 3, label: 'コーヒー' },
    ],
  },
];

export function ExpandScreen() {
  const [expanded, setExpanded] = useState<Record<string, boolean>>({});
  const [result, setResult] = useState('expand=none');

  return (
    <ScreenContainer>
      <EchoText testID={Tags.txtExpandResult}>{result}</EchoText>
      <ScrollView>
        {GROUPS.map(group => (
          <List.Accordion
            key={group.key}
            testID={group.testID}
            title={group.title}
            expanded={!!expanded[group.key]}
            onPress={() => setExpanded(prev => ({ ...prev, [group.key]: !prev[group.key] }))}
          >
            {group.items.map(item => (
              <List.Item
                key={item.n}
                testID={item.testID}
                title={item.label}
                onPress={() => setResult(`expand=item_${group.key}_${item.n}`)}
              />
            ))}
          </List.Accordion>
        ))}
      </ScrollView>
    </ScreenContainer>
  );
}
