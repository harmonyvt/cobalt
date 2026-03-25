import {
  requestCobalt,
  type CobaltLocalProcessingResponse,
  type CobaltRedirectResponse,
  type CobaltSaveRequestBody,
  type CobaltTunnelResponse,
} from '@imput/cobalt-client';
import * as Clipboard from 'expo-clipboard';
import { Stack, useRouter } from 'expo-router';
import { LoaderCircle, ShieldCheck } from 'lucide-react-native';
import { useMemo, useState } from 'react';
import { Alert, ScrollView, View } from 'react-native';

import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Separator } from '@/components/ui/separator';
import { Switch } from '@/components/ui/switch';
import { Text } from '@/components/ui/text';
import { useDownloads } from '@/lib/downloads/provider';
import { setPendingPicker } from '@/lib/picker-state';
import { useSettings } from '@/lib/settings/provider';

export default function SaveScreen() {
  const router = useRouter();
  const downloads = useDownloads();
  const settings = useSettings();

  const [url, setUrl] = useState('');
  const [isSubmitting, setIsSubmitting] = useState(false);

  const saveDefaults = settings.settings.saveDefaults;

  const requestPreview = useMemo(
    () => ({
      audioFormat: saveDefaults.audioFormat,
      quality: saveDefaults.videoQuality,
      mode: saveDefaults.downloadMode,
      filename: saveDefaults.filenameStyle,
    }),
    [
      saveDefaults.audioFormat,
      saveDefaults.downloadMode,
      saveDefaults.filenameStyle,
      saveDefaults.videoQuality,
    ]
  );

  const createRequest = (): CobaltSaveRequestBody => ({
    url,
    ...saveDefaults,
    alwaysProxy: true,
    localProcessing: 'disabled',
  });

  const handlePaste = async () => {
    const clipboard = await Clipboard.getStringAsync();
    if (clipboard.trim().length > 0) {
      setUrl(clipboard.trim());
    }
  };

  const ensureAuthorized = async () => {
    const info = settings.serverInfo ?? (await settings.refreshServerInfo());

    if (
      info?.cobalt.turnstileSitekey &&
      !settings.settings.apiKey.trim() &&
      !settings.hasValidSession
    ) {
      router.push('/turnstile');
      return undefined;
    }

    return settings.currentAuthorization();
  };

  const handleDirectResponse = async (
    response: CobaltRedirectResponse | CobaltTunnelResponse,
    request: CobaltSaveRequestBody
  ) => {
    await downloads.downloadFromResponse({
      sourceUrl: request.url,
      remoteUrl: response.url,
      filename: response.filename,
      request,
      response,
    });

    router.push('/downloads');
  };

  const handleLocalProcessing = (_response: CobaltLocalProcessingResponse) => {
    Alert.alert(
      'This instance needs local processing',
      'Cobalt Mobile is configured for server-side delivery only. Use another instance or change the instance settings.'
    );
  };

  const handleSubmit = async () => {
    const trimmed = url.trim();
    if (!trimmed) {
      Alert.alert(
        'Paste a link first',
        'Enter a public media URL to send to your Cobalt instance.'
      );
      return;
    }

    setIsSubmitting(true);

    try {
      const request = {
        ...createRequest(),
        url: trimmed,
      };

      const authorization = await ensureAuthorized();
      if (settings.requiresTurnstile && !authorization) {
        Alert.alert(
          'Verification required',
          'Finish the Turnstile check first, then try this save again.'
        );
        return;
      }

      const response = await requestCobalt(settings.apiBase, request, authorization);

      if (!response) {
        Alert.alert('Instance unreachable', 'The configured Cobalt instance could not be reached.');
        return;
      }

      if (response.status === 'error') {
        if (response.error.code.includes('auth.jwt')) {
          router.push('/turnstile');
        }

        Alert.alert('Save failed', response.error.code);
        return;
      }

      if (response.status === 'redirect' || response.status === 'tunnel') {
        await handleDirectResponse(response, request);
        return;
      }

      if (response.status === 'picker') {
        setPendingPicker({ response, request });
        router.push('/picker');
        return;
      }

      if (response.status === 'local-processing') {
        handleLocalProcessing(response);
        return;
      }

      Alert.alert(
        'Unexpected response',
        'The server returned a response this app does not understand.'
      );
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <>
      <Stack.Screen options={{ title: 'Save' }} />
      <ScrollView className="flex-1 bg-background" contentContainerClassName="gap-4 px-4 pb-8 pt-5">
        <Card className="border-0 bg-transparent px-0 py-0 shadow-none">
          <CardHeader className="px-0">
            <CardTitle className="text-3xl">Cobalt Mobile</CardTitle>
            <CardDescription className="text-base">
              Paste a link, send it to Cobalt, and keep the file inside your mobile download queue.
            </CardDescription>
          </CardHeader>
        </Card>

        <Card className="bg-card/95">
          <CardHeader>
            <CardTitle>Link</CardTitle>
            <CardDescription>
              This app forces server-side delivery so it only accepts instances that return direct
              files or tunnels.
            </CardDescription>
          </CardHeader>
          <CardContent className="gap-4">
            <View className="gap-2">
              <Label nativeID="save-url">Media URL</Label>
              <Input
                aria-labelledby="save-url"
                autoCapitalize="none"
                autoCorrect={false}
                keyboardType="url"
                multiline
                numberOfLines={3}
                onChangeText={setUrl}
                placeholder="https://www.youtube.com/watch?v=..."
                value={url}
              />
            </View>

            <View className="flex-row gap-3">
              <Button className="flex-1" onPress={handlePaste} variant="outline">
                <Text>Paste</Text>
              </Button>
              <Button className="flex-1" onPress={handleSubmit}>
                {isSubmitting ? <LoaderCircle color="currentColor" size={16} /> : <Text>Save</Text>}
              </Button>
            </View>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Current defaults</CardTitle>
            <CardDescription>
              The mobile client uses your saved defaults, plus `alwaysProxy=true` and
              `localProcessing=disabled`.
            </CardDescription>
          </CardHeader>
          <CardContent className="gap-3">
            <View className="flex-row justify-between">
              <Text className="text-muted-foreground">Audio</Text>
              <Text>{requestPreview.audioFormat}</Text>
            </View>
            <View className="flex-row justify-between">
              <Text className="text-muted-foreground">Video quality</Text>
              <Text>{requestPreview.quality}</Text>
            </View>
            <View className="flex-row justify-between">
              <Text className="text-muted-foreground">Mode</Text>
              <Text>{requestPreview.mode}</Text>
            </View>
            <View className="flex-row justify-between">
              <Text className="text-muted-foreground">Filename</Text>
              <Text>{requestPreview.filename}</Text>
            </View>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Verification</CardTitle>
            <CardDescription>
              Use this only when the configured instance advertises a Turnstile site key.
            </CardDescription>
          </CardHeader>
          <CardContent className="gap-4">
            <View className="flex-row items-center justify-between">
              <View className="max-w-[82%] gap-1">
                <Text className="font-medium">Turnstile session</Text>
                <Text className="text-sm text-muted-foreground">
                  {settings.hasValidSession
                    ? 'A bearer token is cached and ready for protected instances.'
                    : 'No bearer session is cached yet.'}
                </Text>
              </View>
              <ShieldCheck color={settings.hasValidSession ? '#16a34a' : '#f97316'} size={18} />
            </View>
            <Button onPress={() => router.push('/turnstile')} variant="secondary">
              <Text>Open verification</Text>
            </Button>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Mobile-safe toggles</CardTitle>
            <CardDescription>
              These map directly onto Cobalt save options and are safe to change on the device.
            </CardDescription>
          </CardHeader>
          <CardContent className="gap-4">
            <View className="flex-row items-center justify-between">
              <View className="max-w-[80%] gap-1">
                <Text>Disable metadata</Text>
                <Text className="text-sm text-muted-foreground">
                  Skip ID3 and other embedded metadata when supported.
                </Text>
              </View>
              <Switch
                checked={!!saveDefaults.disableMetadata}
                onCheckedChange={(checked) =>
                  void settings.updateSaveDefaults({ disableMetadata: checked })
                }
              />
            </View>
            <Separator />
            <View className="flex-row items-center justify-between">
              <View className="max-w-[80%] gap-1">
                <Text>Prefer better YouTube audio</Text>
                <Text className="text-sm text-muted-foreground">
                  Ask the API for higher-quality YouTube audio when available.
                </Text>
              </View>
              <Switch
                checked={!!saveDefaults.youtubeBetterAudio}
                onCheckedChange={(checked) =>
                  void settings.updateSaveDefaults({ youtubeBetterAudio: checked })
                }
              />
            </View>
          </CardContent>
        </Card>
      </ScrollView>
    </>
  );
}
