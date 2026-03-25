import '../global.css';

import { ThemeProvider } from '@react-navigation/native';
import { Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { PortalHost } from '@rn-primitives/portal';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { DownloadsProvider } from '@/lib/downloads/provider';
import { SettingsProvider } from '@/lib/settings/provider';
import { useAppColorScheme } from '@/lib/use-app-color-scheme';
import { NAV_THEME } from '@/lib/theme';

export const unstable_settings = {
  initialRouteName: '(tabs)',
};

export default function RootLayout() {
  const { colorScheme, isDarkColorScheme } = useAppColorScheme();

  return (
    <SafeAreaProvider>
      <ThemeProvider value={NAV_THEME[colorScheme]}>
        <SettingsProvider>
          <DownloadsProvider>
            <StatusBar style={isDarkColorScheme ? 'light' : 'dark'} />
            <Stack screenOptions={{ contentStyle: { backgroundColor: 'transparent' } }}>
              <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
              <Stack.Screen
                name="picker"
                options={{
                  presentation: 'modal',
                  title: 'Choose media',
                }}
              />
              <Stack.Screen
                name="turnstile"
                options={{
                  presentation: 'modal',
                  title: 'Verify session',
                }}
              />
              <Stack.Screen name="modal" options={{ presentation: 'modal' }} />
            </Stack>
            <PortalHost />
          </DownloadsProvider>
        </SettingsProvider>
      </ThemeProvider>
    </SafeAreaProvider>
  );
}
