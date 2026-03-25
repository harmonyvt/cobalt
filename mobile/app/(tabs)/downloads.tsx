import { Stack } from 'expo-router';
import { Alert, FlatList, RefreshControl, View } from 'react-native';

import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Separator } from '@/components/ui/separator';
import { Text } from '@/components/ui/text';
import { useDownloads } from '@/lib/downloads/provider';

export default function DownloadsScreen() {
  const { deleteRecord, downloads, ready, refresh, retryDownload, shareRecord } = useDownloads();

  return (
    <>
      <Stack.Screen options={{ title: 'Downloads' }} />
      <FlatList
        className="flex-1 bg-background"
        contentContainerClassName="gap-4 px-4 pb-8 pt-5"
        data={downloads}
        keyExtractor={(item) => item.id}
        refreshControl={<RefreshControl refreshing={!ready} onRefresh={() => void refresh()} />}
        ListEmptyComponent={
          <Card>
            <CardHeader>
              <CardTitle>No downloads yet</CardTitle>
              <CardDescription>
                Completed saves appear here with their local file path and retry/share actions.
              </CardDescription>
            </CardHeader>
          </Card>
        }
        renderItem={({ item }) => (
          <Card>
            <CardHeader>
              <CardTitle numberOfLines={1}>{item.filename}</CardTitle>
              <CardDescription>{item.status.toUpperCase()}</CardDescription>
            </CardHeader>
            <CardContent className="gap-4">
              <View className="gap-1">
                <Text className="text-xs uppercase text-muted-foreground">Source</Text>
                <Text className="text-sm" numberOfLines={2}>
                  {item.sourceUrl}
                </Text>
              </View>
              {item.localUri ? (
                <View className="gap-1">
                  <Text className="text-xs uppercase text-muted-foreground">Local file</Text>
                  <Text className="text-sm" numberOfLines={2}>
                    {item.localUri}
                  </Text>
                </View>
              ) : null}
              {item.errorMessage ? (
                <>
                  <Separator />
                  <View className="gap-1">
                    <Text className="text-xs uppercase text-destructive">Last error</Text>
                    <Text className="text-sm">{item.errorMessage}</Text>
                  </View>
                </>
              ) : null}
              <View className="flex-row flex-wrap gap-3">
                <Button onPress={() => void retryDownload(item.id)} variant="secondary">
                  <Text>Retry</Text>
                </Button>
                <Button
                  disabled={!item.localUri}
                  onPress={() => void shareRecord(item)}
                  variant="outline">
                  <Text>Share</Text>
                </Button>
                <Button
                  onPress={() =>
                    Alert.alert('Delete record', 'Remove this download from local history?', [
                      { text: 'Cancel', style: 'cancel' },
                      {
                        text: 'Delete',
                        style: 'destructive',
                        onPress: () => void deleteRecord(item),
                      },
                    ])
                  }
                  variant="destructive">
                  <Text>Delete</Text>
                </Button>
              </View>
            </CardContent>
          </Card>
        )}
      />
    </>
  );
}
