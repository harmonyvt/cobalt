import { Stack, useRouter } from 'expo-router';
import { FlatList, Image, View } from 'react-native';

import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Text } from '@/components/ui/text';
import { useDownloads } from '@/lib/downloads/provider';
import { getPendingPicker, setPendingPicker } from '@/lib/picker-state';

export default function PickerScreen() {
  const router = useRouter();
  const downloads = useDownloads();
  const pending = getPendingPicker();

  if (!pending) {
    return (
      <>
        <Stack.Screen options={{ title: 'Choose media' }} />
        <View className="flex-1 items-center justify-center bg-background px-6">
          <Card className="w-full max-w-xl">
            <CardHeader>
              <CardTitle>No picker state</CardTitle>
              <CardDescription>
                Start a new save request first so the app has picker items to display.
              </CardDescription>
            </CardHeader>
          </Card>
        </View>
      </>
    );
  }

  return (
    <>
      <Stack.Screen options={{ title: 'Choose media' }} />
      <FlatList
        className="flex-1 bg-background"
        contentContainerClassName="gap-4 px-4 pb-8 pt-5"
        data={pending.response.picker}
        keyExtractor={(item) => `${item.type}:${item.url}`}
        renderItem={({ item }) => (
          <Card>
            <CardHeader>
              <CardTitle>{item.type.toUpperCase()}</CardTitle>
              <CardDescription numberOfLines={2}>{item.url}</CardDescription>
            </CardHeader>
            <CardContent className="gap-4">
              {item.thumb ? (
                <Image
                  source={{ uri: item.thumb }}
                  style={{ aspectRatio: 1.4, borderRadius: 16, width: '100%' }}
                />
              ) : null}
              <Button
                onPress={async () => {
                  await downloads.downloadFromResponse({
                    sourceUrl: pending.request.url,
                    remoteUrl: item.url,
                    filename: `${item.type}-${Date.now()}`,
                    request: pending.request,
                    response: item,
                  });
                  setPendingPicker(undefined);
                  router.replace('/downloads');
                }}>
                <Text>Download this item</Text>
              </Button>
            </CardContent>
          </Card>
        )}
        ListFooterComponent={
          pending.response.audio ? (
            <Card>
              <CardHeader>
                <CardTitle>Background audio</CardTitle>
                <CardDescription>
                  Some slideshow-style posts include a shared audio track you can download
                  separately.
                </CardDescription>
              </CardHeader>
              <CardContent>
                <Button
                  onPress={async () => {
                    await downloads.downloadFromResponse({
                      sourceUrl: pending.request.url,
                      remoteUrl: pending.response.audio!,
                      filename: pending.response.audioFilename ?? `audio-${Date.now()}.mp3`,
                      request: pending.request,
                      response: { audio: pending.response.audio },
                    });
                    setPendingPicker(undefined);
                    router.replace('/downloads');
                  }}
                  variant="secondary">
                  <Text>Download audio</Text>
                </Button>
              </CardContent>
            </Card>
          ) : null
        }
      />
    </>
  );
}
