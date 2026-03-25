import { Stack, useRouter } from 'expo-router';
import { useState } from 'react';
import { Alert, View } from 'react-native';
import { WebView } from 'react-native-webview';

import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Text } from '@/components/ui/text';
import { useSettings } from '@/lib/settings/provider';
import { createTurnstileHtml } from '@/lib/turnstile-html';

type TurnstileMessage = {
  kind: 'token' | 'error' | 'expired';
  value: string;
};

export default function TurnstileScreen() {
  const router = useRouter();
  const settings = useSettings();
  const [busy, setBusy] = useState(false);

  const sitekey = settings.serverInfo?.cobalt.turnstileSitekey;

  if (!sitekey) {
    return (
      <>
        <Stack.Screen options={{ title: 'Verify session' }} />
        <View className="flex-1 items-center justify-center bg-background px-6">
          <Card className="w-full max-w-xl">
            <CardHeader>
              <CardTitle>No Turnstile configured</CardTitle>
              <CardDescription>
                The current Cobalt instance did not advertise a Turnstile site key.
              </CardDescription>
            </CardHeader>
            <CardContent>
              <Button onPress={() => router.back()} variant="secondary">
                <Text>Close</Text>
              </Button>
            </CardContent>
          </Card>
        </View>
      </>
    );
  }

  return (
    <>
      <Stack.Screen options={{ title: 'Verify session' }} />
      <WebView
        originWhitelist={['*']}
        source={{ html: createTurnstileHtml(sitekey) }}
        onMessage={async (event) => {
          let payload: TurnstileMessage | undefined;
          try {
            payload = JSON.parse(event.nativeEvent.data) as TurnstileMessage;
          } catch {
            payload = undefined;
          }

          if (!payload) {
            return;
          }

          if (payload.kind === 'token') {
            setBusy(true);
            const result = await settings.completeTurnstile(payload.value);
            setBusy(false);

            if (result.ok) {
              Alert.alert(
                'Session ready',
                'A bearer token is now cached for this Cobalt instance.'
              );
              router.back();
              return;
            }

            Alert.alert('Verification failed', result.message ?? 'The token exchange failed.');
            return;
          }

          if (payload.kind === 'expired') {
            Alert.alert('Challenge expired', 'Reload the verification screen and try again.');
            return;
          }

          Alert.alert('Turnstile error', payload.value);
        }}
      />
      {busy ? (
        <View className="absolute inset-x-0 bottom-8 items-center">
          <Card>
            <CardContent className="px-5 py-4">
              <Text>Requesting bearer token…</Text>
            </CardContent>
          </Card>
        </View>
      ) : null}
    </>
  );
}
