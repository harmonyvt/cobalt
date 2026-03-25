import { Stack } from 'expo-router';
import { ScrollView } from 'react-native';

import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Text } from '@/components/ui/text';

export default function Modal() {
  return (
    <>
      <Stack.Screen options={{ title: 'About' }} />
      <ScrollView className="flex-1 bg-background" contentContainerClassName="px-4 pb-8 pt-5">
        <Card>
          <CardHeader>
            <CardTitle>Cobalt Mobile</CardTitle>
            <CardDescription>
              Expo React Native client for talking to Cobalt instances from iOS and Android.
            </CardDescription>
          </CardHeader>
          <CardContent className="gap-3">
            <Text>
              This build keeps the mobile client server-only. It supports direct/tunnel downloads,
              picker responses, custom instances, API keys, and Turnstile-backed bearer sessions.
            </Text>
          </CardContent>
        </Card>
      </ScrollView>
    </>
  );
}
