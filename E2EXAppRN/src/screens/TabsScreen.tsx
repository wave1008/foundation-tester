import React, { useState } from 'react';
import { StyleSheet, View } from 'react-native';
import { NavigationContainer, NavigationIndependentTree } from '@react-navigation/native';
import { createMaterialTopTabNavigator } from '@react-navigation/material-top-tabs';
import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';

import { Tags } from '../tags';
import { EchoText, ScreenContainer } from '../ui';

// 3画面ともタブ切替そのものが検証対象で、遷移先の中身は空でよい。echo は画面外の1箇所に置く
// (Navigator の Screen はタブごとに個別マウントされるため、echo を Screen 側に置くと
// 複数の txt_tab_content が木に同時に存在しうる = 単一 #id 前提の契約と噛み合わない)。
//
// 3つの Navigator は兄弟として並ぶため、そのままだと react-navigation の
// EnsureSingleNavigator(親 Screen ごとに1つしか Navigator を許さない仕組み)が
// 「Another navigator is already registered for this container」を投げてクラッシュする。
// 各 Navigator を NavigationIndependentTree + 専用 NavigationContainer で包み、
// それぞれ独立したツリーにする(react-navigation 公式の「同一画面に複数 Navigator」対処)。
function Blank() {
  return <View style={styles.blank} />;
}

const TopTab = createMaterialTopTabNavigator();
const ScrollTab = createMaterialTopTabNavigator();
const BottomTab = createBottomTabNavigator();

export function TabsScreen() {
  const [tabContent, setTabContent] = useState('A');
  const [stabContent, setStabContent] = useState('01');
  const [navbarResult, setNavbarResult] = useState('navbar=home');

  return (
    <ScreenContainer>
      <EchoText testID={Tags.txtTabContent}>{`content=${tabContent}`}</EchoText>
      <View style={styles.topTabHost}>
        <NavigationIndependentTree>
          <NavigationContainer>
            <TopTab.Navigator screenOptions={{ swipeEnabled: false }}>
              <TopTab.Screen
                name="A"
                component={Blank}
                options={{ tabBarLabel: 'タブA', tabBarButtonTestID: Tags.tabA }}
                listeners={{ tabPress: () => setTabContent('A') }}
              />
              <TopTab.Screen
                name="B"
                component={Blank}
                options={{ tabBarLabel: 'タブB', tabBarButtonTestID: Tags.tabB }}
                listeners={{ tabPress: () => setTabContent('B') }}
              />
              <TopTab.Screen
                name="C"
                component={Blank}
                options={{ tabBarLabel: 'タブC', tabBarButtonTestID: Tags.tabC }}
                listeners={{ tabPress: () => setTabContent('C') }}
              />
            </TopTab.Navigator>
          </NavigationContainer>
        </NavigationIndependentTree>
      </View>

      <EchoText testID={Tags.txtStabContent}>{`scroll-tab=${stabContent}`}</EchoText>
      <View testID={Tags.stabRow} style={styles.scrollTabHost}>
        <NavigationIndependentTree>
          <NavigationContainer>
            <ScrollTab.Navigator
              screenOptions={{ swipeEnabled: false }}
              tabBarPosition="top"
              initialLayout={{ width: 0 }}
            >
              {Array.from({ length: 12 }, (_, i) => i + 1).map(n => {
                const id = String(n).padStart(2, '0');
                return (
                  <ScrollTab.Screen
                    key={id}
                    name={`Item${id}`}
                    component={Blank}
                    options={{ tabBarLabel: `項目タブ${id}`, tabBarButtonTestID: Tags.stab(n) }}
                    listeners={{ tabPress: () => setStabContent(id) }}
                  />
                );
              })}
            </ScrollTab.Navigator>
          </NavigationContainer>
        </NavigationIndependentTree>
      </View>

      <EchoText testID={Tags.txtNavbarResult}>{navbarResult}</EchoText>
      <View style={styles.bottomTabHost}>
        <NavigationIndependentTree>
          <NavigationContainer>
            <BottomTab.Navigator screenOptions={{ headerShown: false }}>
              <BottomTab.Screen
                name="Home"
                component={Blank}
                options={{ tabBarLabel: 'ホーム', tabBarButtonTestID: Tags.navbarHome }}
                listeners={{ tabPress: () => setNavbarResult('navbar=home') }}
              />
              <BottomTab.Screen
                name="Search"
                component={Blank}
                options={{ tabBarLabel: '探す', tabBarButtonTestID: Tags.navbarSearch }}
                listeners={{ tabPress: () => setNavbarResult('navbar=search') }}
              />
              <BottomTab.Screen
                name="Settings"
                component={Blank}
                options={{ tabBarLabel: '設定', tabBarButtonTestID: Tags.navbarSettings }}
                listeners={{ tabPress: () => setNavbarResult('navbar=settings') }}
              />
            </BottomTab.Navigator>
          </NavigationContainer>
        </NavigationIndependentTree>
      </View>
    </ScreenContainer>
  );
}

// react-native-tab-view(material-top-tabs の内部エンジン)はコンテナの実測幅が必要。
// 固定の高さコンテナを与え、initialLayout でズレを避ける。
const styles = StyleSheet.create({
  blank: { flex: 1 },
  topTabHost: { height: 90 },
  scrollTabHost: { height: 90 },
  bottomTabHost: { height: 140 },
});
