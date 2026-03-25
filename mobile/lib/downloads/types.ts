import type { CobaltSaveRequestBody } from '@imput/cobalt-client';

export type DownloadStatus = 'queued' | 'downloading' | 'completed' | 'failed';

export type DownloadRecord = {
  id: string;
  sourceUrl: string;
  remoteUrl: string;
  filename: string;
  status: DownloadStatus;
  localUri?: string | null;
  errorMessage?: string | null;
  requestJson: string;
  responseJson: string;
  createdAt: string;
  updatedAt: string;
};

export type DownloadInput = {
  sourceUrl: string;
  remoteUrl: string;
  filename: string;
  request: CobaltSaveRequestBody;
  response: unknown;
};
