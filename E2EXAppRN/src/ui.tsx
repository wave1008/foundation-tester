import React from 'react';
import {
  Pressable,
  StyleProp,
  StyleSheet,
  Text,
  TextStyle,
  View,
  ViewStyle,
} from 'react-native';

// ボタンは Pressable + accessible + accessibilityRole="button" + testID + accessibilityLabel
// (E2EAppRN と同じ作法)。内側 Text は a11y から隠し、button と同ラベルの子ノードが
// 別に出るのを防ぐ(Android の button 内 staticText 問題は fleetest ホスト側で畳み込み済みだが、
// 増やさないに越したことはない)。
export function TaggedButton({
  testID,
  label,
  onPress,
  disabled = false,
  style,
}: {
  testID?: string;
  label: string;
  onPress: () => void;
  disabled?: boolean;
  style?: StyleProp<ViewStyle>;
}) {
  return (
    <Pressable
      testID={testID}
      accessible
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityState={{ disabled }}
      disabled={disabled}
      onPress={onPress}
      style={[styles.button, disabled && styles.buttonDisabled, style]}
    >
      <Text
        style={styles.buttonLabel}
        importantForAccessibility="no-hide-descendants"
        accessibilityElementsHidden
      >
        {label}
      </Text>
    </Pressable>
  );
}

export function EchoText({
  testID,
  style,
  children,
}: {
  testID: string;
  style?: StyleProp<TextStyle>;
  children: string;
}) {
  return (
    <Text testID={testID} style={style}>
      {children}
    </Text>
  );
}

/** ホーム/ドロワー/メニュー等の行全体を押せる List item。 */
export function ListRow({
  testID,
  label,
  onPress,
}: {
  testID: string;
  label: string;
  onPress: () => void;
}) {
  return (
    <Pressable
      testID={testID}
      accessible
      accessibilityRole="button"
      accessibilityLabel={label}
      onPress={onPress}
      style={styles.listRow}
    >
      <Text
        style={styles.listRowLabel}
        importantForAccessibility="no-hide-descendants"
        accessibilityElementsHidden
      >
        {label}
      </Text>
    </Pressable>
  );
}

export function ScreenContainer({
  children,
  style,
}: {
  children: React.ReactNode;
  style?: StyleProp<ViewStyle>;
}) {
  return <View style={[styles.screen, style]}>{children}</View>;
}

/** react-navigation の headerTitle に渡す。契約の #txt_screen_title。 */
export function ScreenTitle({ children }: { children?: React.ReactNode }) {
  return (
    <Text testID="txt_screen_title" style={styles.title}>
      {children}
    </Text>
  );
}

export const styles = StyleSheet.create({
  screen: {
    flex: 1,
    padding: 16,
    gap: 8,
    backgroundColor: '#ffffff',
  },
  title: {
    fontSize: 17,
    fontWeight: '600',
  },
  button: {
    minHeight: 44,
    paddingHorizontal: 16,
    justifyContent: 'center',
    alignItems: 'center',
    backgroundColor: '#e6e6e6',
    borderRadius: 6,
  },
  buttonDisabled: {
    opacity: 0.4,
  },
  buttonLabel: {
    fontSize: 15,
  },
  listRow: {
    minHeight: 56,
    justifyContent: 'center',
    paddingHorizontal: 16,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#cccccc',
  },
  listRowLabel: {
    fontSize: 16,
  },
});
