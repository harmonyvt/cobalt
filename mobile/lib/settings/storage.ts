import * as SecureStore from 'expo-secure-store';

import { DEFAULT_SETTINGS } from '@/lib/settings/defaults';
import type { AppSettings } from '@/lib/settings/types';

const SETTINGS_KEY = 'cobalt-mobile:settings:v1';
const SESSION_KEY = 'cobalt-mobile:session:v1';

export async function loadSettings() {
  const stored = await SecureStore.getItemAsync(SETTINGS_KEY);
  if (!stored) {
    return DEFAULT_SETTINGS;
  }

  try {
    return {
      ...DEFAULT_SETTINGS,
      ...JSON.parse(stored),
      saveDefaults: {
        ...DEFAULT_SETTINGS.saveDefaults,
        ...JSON.parse(stored).saveDefaults,
      },
    } as AppSettings;
  } catch {
    return DEFAULT_SETTINGS;
  }
}

export async function persistSettings(settings: AppSettings) {
  await SecureStore.setItemAsync(SETTINGS_KEY, JSON.stringify(settings));
}

export async function loadSession() {
  const stored = await SecureStore.getItemAsync(SESSION_KEY);
  if (!stored) {
    return undefined;
  }

  try {
    return JSON.parse(stored) as { token: string; exp: number };
  } catch {
    return undefined;
  }
}

export async function persistSession(session: { token: string; exp: number }) {
  await SecureStore.setItemAsync(SESSION_KEY, JSON.stringify(session));
}

export async function clearSessionStorage() {
  await SecureStore.deleteItemAsync(SESSION_KEY);
}
