import React, { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import { Alert } from 'react-native';
import * as Sharing from 'expo-sharing';
import { Directory, File, Paths } from 'expo-file-system';

import {
  deleteDownload,
  insertDownload,
  listDownloads,
  updateDownload,
} from '@/lib/downloads/database';
import type { DownloadInput, DownloadRecord } from '@/lib/downloads/types';

type DownloadsContextValue = {
  ready: boolean;
  downloads: DownloadRecord[];
  refresh: () => Promise<void>;
  downloadFromResponse: (input: DownloadInput) => Promise<void>;
  retryDownload: (id: string) => Promise<void>;
  deleteRecord: (record: DownloadRecord) => Promise<void>;
  shareRecord: (record: DownloadRecord) => Promise<void>;
};

const DownloadsContext = createContext<DownloadsContextValue | undefined>(undefined);

function createId() {
  return `dl_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
}

function downloadsDirectory() {
  const directory = new Directory(Paths.document, 'cobalt-downloads');
  if (!directory.exists) {
    directory.create({ idempotent: true, intermediates: true });
  }

  return directory;
}

function sanitizeFilename(name: string) {
  return name.replace(/[<>:"/\\|?*\x00-\x1F]/g, '_');
}

export function DownloadsProvider({ children }: React.PropsWithChildren) {
  const [ready, setReady] = useState(false);
  const [downloads, setDownloads] = useState<DownloadRecord[]>([]);

  const refresh = useCallback(async () => {
    const rows = await listDownloads();
    setDownloads(rows);
    setReady(true);
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const downloadFromResponse = useCallback(
    async (input: DownloadInput) => {
      const now = new Date().toISOString();
      const id = createId();
      const record: DownloadRecord = {
        id,
        sourceUrl: input.sourceUrl,
        remoteUrl: input.remoteUrl,
        filename: sanitizeFilename(input.filename),
        status: 'queued',
        localUri: null,
        errorMessage: null,
        requestJson: JSON.stringify(input.request),
        responseJson: JSON.stringify(input.response),
        createdAt: now,
        updatedAt: now,
      };

      await insertDownload(record);
      await refresh();

      try {
        await updateDownload(id, { status: 'downloading', errorMessage: null });
        await refresh();

        const destination = new File(downloadsDirectory(), sanitizeFilename(input.filename));
        const file = await File.downloadFileAsync(input.remoteUrl, destination, {
          idempotent: true,
        });

        await updateDownload(id, {
          status: 'completed',
          localUri: file.uri,
          errorMessage: null,
        });
      } catch (error) {
        await updateDownload(id, {
          status: 'failed',
          errorMessage: error instanceof Error ? error.message : 'Download failed',
        });
      }

      await refresh();
    },
    [refresh]
  );

  const retryDownload = useCallback(
    async (id: string) => {
      const record = downloads.find((item) => item.id === id);
      if (!record) {
        return;
      }

      await downloadFromResponse({
        sourceUrl: record.sourceUrl,
        remoteUrl: record.remoteUrl,
        filename: record.filename,
        request: JSON.parse(record.requestJson),
        response: JSON.parse(record.responseJson),
      });
    },
    [downloadFromResponse, downloads]
  );

  const deleteRecord = useCallback(
    async (record: DownloadRecord) => {
      try {
        if (record.localUri) {
          const file = new File(record.localUri);
          if (file.exists) {
            file.delete();
          }
        }
      } catch {
        // Ignore local cleanup failures and remove the DB row.
      }

      await deleteDownload(record.id);
      await refresh();
    },
    [refresh]
  );

  const shareRecord = useCallback(async (record: DownloadRecord) => {
    if (!record.localUri) {
      Alert.alert('No file yet', 'This download has not completed yet.');
      return;
    }

    if (!(await Sharing.isAvailableAsync())) {
      Alert.alert('Sharing unavailable', 'This device does not support the system share sheet.');
      return;
    }

    await Sharing.shareAsync(record.localUri, {
      dialogTitle: record.filename,
    });
  }, []);

  const value = useMemo(
    () => ({
      ready,
      downloads,
      refresh,
      downloadFromResponse,
      retryDownload,
      deleteRecord,
      shareRecord,
    }),
    [deleteRecord, downloadFromResponse, downloads, ready, refresh, retryDownload, shareRecord]
  );

  return <DownloadsContext.Provider value={value}>{children}</DownloadsContext.Provider>;
}

export function useDownloads() {
  const context = useContext(DownloadsContext);
  if (!context) {
    throw new Error('useDownloads must be used inside DownloadsProvider');
  }

  return context;
}
