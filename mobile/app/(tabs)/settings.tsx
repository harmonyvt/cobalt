import { Stack, useRouter } from 'expo-router';
import { useState } from 'react';
import { Alert, ScrollView, View } from 'react-native';

import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Separator } from '@/components/ui/separator';
import { Switch } from '@/components/ui/switch';
import { Text } from '@/components/ui/text';
import { useSettings } from '@/lib/settings/provider';

export default function SettingsScreen() {
  const router = useRouter();
  const settings = useSettings();
  const [customUrl, setCustomUrl] = useState(settings.settings.customInstanceUrl);
  const [apiKey, setApiKey] = useState(settings.settings.apiKey);

  const syncCustomUrl = async () => {
    await settings.updateSettings({ customInstanceUrl: customUrl });
    await settings.refreshServerInfo();
  };

  const syncApiKey = async () => {
    await settings.setApiKey(apiKey);
    await settings.refreshServerInfo();
  };

  return (
    <>
      <Stack.Screen options={{ title: 'Settings' }} />
      <ScrollView className="flex-1 bg-background" contentContainerClassName="gap-4 px-4 pb-8 pt-5">
        <Card>
          <CardHeader>
            <CardTitle>Instance</CardTitle>
            <CardDescription>
              Choose whether the app talks to the bundled default instance or your own Cobalt API.
            </CardDescription>
          </CardHeader>
          <CardContent className="gap-4">
            <View className="flex-row items-center justify-between">
              <View className="max-w-[80%] gap-1">
                <Text>Use custom instance</Text>
                <Text className="text-sm text-muted-foreground">
                  Turn this on to override the shipped API base URL.
                </Text>
              </View>
              <Switch
                checked={settings.settings.useCustomInstance}
                onCheckedChange={(checked) =>
                  void settings.updateSettings({ useCustomInstance: checked })
                }
              />
            </View>
            <Separator />
            <View className="gap-2">
              <Label>Custom API URL</Label>
              <Input
                autoCapitalize="none"
                autoCorrect={false}
                keyboardType="url"
                onChangeText={setCustomUrl}
                onEndEditing={() => void syncCustomUrl()}
                placeholder="https://your-cobalt-instance.example"
                value={customUrl}
              />
              <Text className="text-sm text-muted-foreground">
                Current base: {settings.apiBase}
              </Text>
            </View>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Authentication</CardTitle>
            <CardDescription>
              Use an API key when your instance owner provides one, or verify a Turnstile session
              when required.
            </CardDescription>
          </CardHeader>
          <CardContent className="gap-4">
            <View className="gap-2">
              <Label>API key</Label>
              <Input
                autoCapitalize="none"
                autoCorrect={false}
                onChangeText={setApiKey}
                onEndEditing={() => void syncApiKey()}
                placeholder="Api-Key value"
                value={apiKey}
              />
            </View>
            <View className="gap-1">
              <Text className="font-medium">Turnstile session</Text>
              <Text className="text-sm text-muted-foreground">
                {settings.hasValidSession
                  ? 'A bearer token is cached.'
                  : 'No bearer token is cached for this instance.'}
              </Text>
            </View>
            <View className="flex-row gap-3">
              <Button onPress={() => router.push('/turnstile')} variant="secondary">
                <Text>Verify</Text>
              </Button>
              <Button onPress={() => void settings.clearSession()} variant="outline">
                <Text>Reset session</Text>
              </Button>
            </View>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Save defaults</CardTitle>
            <CardDescription>
              Keep the mobile configuration intentionally small and safe for server-only delivery.
            </CardDescription>
          </CardHeader>
          <CardContent className="gap-4">
            <View className="flex-row items-center justify-between">
              <View className="max-w-[80%] gap-1">
                <Text>Prefer better YouTube audio</Text>
                <Text className="text-sm text-muted-foreground">
                  Ask Cobalt for improved YouTube audio when possible.
                </Text>
              </View>
              <Switch
                checked={!!settings.settings.saveDefaults.youtubeBetterAudio}
                onCheckedChange={(checked) =>
                  void settings.updateSaveDefaults({ youtubeBetterAudio: checked })
                }
              />
            </View>
            <Separator />
            <View className="flex-row items-center justify-between">
              <View className="max-w-[80%] gap-1">
                <Text>Disable metadata</Text>
                <Text className="text-sm text-muted-foreground">
                  Save cleaner files without embedded metadata when supported.
                </Text>
              </View>
              <Switch
                checked={!!settings.settings.saveDefaults.disableMetadata}
                onCheckedChange={(checked) =>
                  void settings.updateSaveDefaults({ disableMetadata: checked })
                }
              />
            </View>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Instance info</CardTitle>
            <CardDescription>Fetch the instance metadata exposed by `GET /`.</CardDescription>
          </CardHeader>
          <CardContent className="gap-4">
            <Button
              onPress={async () => {
                const info = await settings.refreshServerInfo();
                if (!info) {
                  Alert.alert(
                    'Instance unreachable',
                    'The configured API base did not return instance info.'
                  );
                }
              }}>
              <Text>Refresh info</Text>
            </Button>
            {settings.serverInfo ? (
              <View className="gap-2">
                <Text>Version: {settings.serverInfo.cobalt.version}</Text>
                <Text>Services: {settings.serverInfo.cobalt.services.join(', ')}</Text>
                <Text>Git: {settings.serverInfo.git.branch}</Text>
                <Text className="text-sm text-muted-foreground">
                  Turnstile sitekey:{' '}
                  {settings.serverInfo.cobalt.turnstileSitekey ?? 'not configured'}
                </Text>
              </View>
            ) : (
              <Text className="text-muted-foreground">No instance info cached yet.</Text>
            )}
          </CardContent>
        </Card>
      </ScrollView>
    </>
  );
}
