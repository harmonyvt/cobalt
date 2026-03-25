import type { CobaltSaveRequestBody, CobaltServerInfo, CobaltSession } from '@imput/cobalt-client';

export type SaveDefaults = Pick<
  CobaltSaveRequestBody,
  | 'audioBitrate'
  | 'audioFormat'
  | 'downloadMode'
  | 'filenameStyle'
  | 'videoQuality'
  | 'disableMetadata'
  | 'subtitleLang'
  | 'youtubeVideoCodec'
  | 'youtubeVideoContainer'
  | 'youtubeDubLang'
  | 'tiktokFullAudio'
  | 'youtubeBetterAudio'
  | 'allowH265'
  | 'convertGif'
>;

export type AppSettings = {
  useCustomInstance: boolean;
  customInstanceUrl: string;
  apiKey: string;
  saveDefaults: SaveDefaults;
};

export type SettingsContextValue = {
  ready: boolean;
  settings: AppSettings;
  apiBase: string;
  serverInfo?: CobaltServerInfo;
  session?: CobaltSession;
  requiresTurnstile: boolean;
  hasValidSession: boolean;
  updateSettings: (patch: Partial<AppSettings>) => Promise<void>;
  updateSaveDefaults: (patch: Partial<SaveDefaults>) => Promise<void>;
  setApiKey: (value: string) => Promise<void>;
  refreshServerInfo: () => Promise<CobaltServerInfo | undefined>;
  completeTurnstile: (token: string) => Promise<{ ok: boolean; message?: string }>;
  clearSession: () => Promise<void>;
  currentAuthorization: () => string | undefined;
};
