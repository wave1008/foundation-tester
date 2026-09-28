import React, { useState } from 'react';
import { StyleSheet } from 'react-native';
import { createDrawerNavigator, useDrawerStatus } from '@react-navigation/drawer';
import type { DrawerNavigationProp } from '@react-navigation/drawer';

import { Tags } from '../tags';
import { EchoText, ScreenContainer, TaggedButton } from '../ui';

type DrawerParamList = { DrawerHome: undefined };
const Drawer = createDrawerNavigator<DrawerParamList>();

const ITEMS: Array<{ testID: string; key: string; label: string }> = [
  { testID: Tags.drawerItemInbox, key: 'inbox', label: '受信箱' },
  { testID: Tags.drawerItemSent, key: 'sent', label: '送信済み' },
  { testID: Tags.drawerItemTrash, key: 'trash', label: 'ゴミ箱' },
];

function DrawerHomeContent({
  navigation,
  result,
}: {
  navigation: DrawerNavigationProp<DrawerParamList>;
  result: string;
}) {
  const status = useDrawerStatus();
  return (
    <ScreenContainer>
      <TaggedButton
        testID={Tags.btnOpenDrawer}
        label="ドロワーを開く"
        onPress={() => navigation.openDrawer()}
      />
      <EchoText testID={Tags.txtDrawerResult}>{result}</EchoText>
      <EchoText testID={Tags.txtDrawerState}>{`drawerOpen=${status === 'open'}`}</EchoText>
    </ScreenContainer>
  );
}

function DrawerContentBody({
  navigation,
  onSelect,
}: {
  navigation: DrawerNavigationProp<DrawerParamList>;
  onSelect: (key: string) => void;
}) {
  return (
    <ScreenContainer style={styles.drawerContent}>
      <EchoText testID={Tags.txtDrawerHeader} style={styles.header}>
        ドロワー見出し
      </EchoText>
      {ITEMS.map(item => (
        <TaggedButton
          key={item.key}
          testID={item.testID}
          label={item.label}
          onPress={() => {
            onSelect(item.key);
            navigation.closeDrawer();
          }}
        />
      ))}
    </ScreenContainer>
  );
}

export function DrawerScreen() {
  const [result, setResult] = useState('drawer=none');

  return (
    <Drawer.Navigator
      screenOptions={{ headerShown: false }}
      drawerContent={props => (
        <DrawerContentBody
          navigation={props.navigation as DrawerNavigationProp<DrawerParamList>}
          onSelect={key => setResult(`drawer=${key}`)}
        />
      )}
    >
      <Drawer.Screen name="DrawerHome">
        {props => (
          <DrawerHomeContent
            navigation={props.navigation as DrawerNavigationProp<DrawerParamList>}
            result={result}
          />
        )}
      </Drawer.Screen>
    </Drawer.Navigator>
  );
}

const styles = StyleSheet.create({
  drawerContent: {
    paddingTop: 48,
  },
  header: {
    fontSize: 16,
    fontWeight: '600',
  },
});
