import type { AppSettings } from '@/lib/settings/types';

export const DEFAULT_SETTINGS: AppSettings = {
  useCustomInstance: false,
  customInstanceUrl: '',
  apiKey: '',
  saveDefaults: {
    audioBitrate: '128',
    audioFormat: 'mp3',
    downloadMode: 'auto',
    filenameStyle: 'basic',
    videoQuality: '1080',
    disableMetadata: false,
    subtitleLang: 'none',
    youtubeVideoCodec: 'h264',
    youtubeVideoContainer: 'auto',
    youtubeDubLang: 'original',
    tiktokFullAudio: false,
    youtubeBetterAudio: false,
    allowH265: false,
    convertGif: true,
  },
};
