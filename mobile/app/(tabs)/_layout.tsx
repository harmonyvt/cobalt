import { Tabs } from 'expo-router';
import { Download, Save, Settings } from 'lucide-react-native';

import { THEME } from '@/lib/theme';
import { useAppColorScheme } from '@/lib/use-app-color-scheme';

export default function TabLayout() {
  const { colorScheme } = useAppColorScheme();
  const palette = THEME[colorScheme];

  return (
    <Tabs
      screenOptions={{
        tabBarActiveTintColor: palette.accent,
        tabBarInactiveTintColor: `${palette.mutedForeground}`,
        tabBarStyle: {
          backgroundColor: palette.card,
          borderTopColor: palette.border,
        },
        headerStyle: {
          backgroundColor: palette.card,
        },
        headerTintColor: palette.foreground,
        headerShadowVisible: false,
      }}>
      <Tabs.Screen
        name="index"
        options={{
          title: 'Save',
          tabBarIcon: ({ color, size }) => <Save color={color} size={size} />,
        }}
      />
      <Tabs.Screen
        name="downloads"
        options={{
          title: 'Downloads',
          tabBarIcon: ({ color, size }) => <Download color={color} size={size} />,
        }}
      />
      <Tabs.Screen
        name="settings"
        options={{
          title: 'Settings',
          tabBarIcon: ({ color, size }) => <Settings color={color} size={size} />,
        }}
      />
    </Tabs>
  );
}
