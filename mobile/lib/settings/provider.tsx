import {
  createAuthorizationHeader,
  createCobaltSession,
  getCobaltServerInfo,
  normalizeApiBase,
  withAbsoluteSessionExpiry,
  type CobaltServerInfo,
} from '@imput/cobalt-client';
import React, { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';

import { DEFAULT_SETTINGS } from '@/lib/settings/defaults';
import {
  clearSessionStorage,
  loadSession,
  loadSettings,
  persistSession,
  persistSettings,
} from '@/lib/settings/storage';
import type { AppSettings, SaveDefaults, SettingsContextValue } from '@/lib/settings/types';

const SettingsContext = createContext<SettingsContextValue | undefined>(undefined);

const DEFAULT_API_BASE = normalizeApiBase(
  process.env.EXPO_PUBLIC_DEFAULT_API_URL ?? 'https://api.cobalt.tools/'
);

function isSessionValid(session?: { exp: number }) {
  if (!session) {
    return false;
  }

  return session.exp - 2 > Math.floor(Date.now() / 1000);
}

export function SettingsProvider({ children }: React.PropsWithChildren) {
  const [ready, setReady] = useState(false);
  const [settings, setSettings] = useState<AppSettings>(DEFAULT_SETTINGS);
  const [serverInfo, setServerInfo] = useState<CobaltServerInfo | undefined>();
  const [session, setSession] = useState<{ token: string; exp: number } | undefined>();

  useEffect(() => {
    let alive = true;

    Promise.all([loadSettings(), loadSession()]).then(([loadedSettings, loadedSession]) => {
      if (!alive) {
        return;
      }

      setSettings(loadedSettings);
      setSession(isSessionValid(loadedSession) ? loadedSession : undefined);
      setReady(true);
    });

    return () => {
      alive = false;
    };
  }, []);

  const apiBase = useMemo(() => {
    if (settings.useCustomInstance && settings.customInstanceUrl.trim().length > 0) {
      try {
        return normalizeApiBase(settings.customInstanceUrl.trim());
      } catch {
        return DEFAULT_API_BASE;
      }
    }

    return DEFAULT_API_BASE;
  }, [settings.customInstanceUrl, settings.useCustomInstance]);

  const hasValidSession = isSessionValid(session);

  const updateSettings = useCallback(async (patch: Partial<AppSettings>) => {
    setSettings((current) => {
      const next = {
        ...current,
        ...patch,
        saveDefaults: {
          ...current.saveDefaults,
          ...patch.saveDefaults,
        },
      };

      void persistSettings(next);
      return next;
    });
  }, []);

  const updateSaveDefaults = useCallback(
    async (patch: Partial<SaveDefaults>) => {
      await updateSettings({
        saveDefaults: patch as SaveDefaults,
      });
    },
    [updateSettings]
  );

  const setApiKey = useCallback(
    async (value: string) => {
      await updateSettings({ apiKey: value });
    },
    [updateSettings]
  );

  const refreshServerInfo = useCallback(async () => {
    const response = await getCobaltServerInfo(apiBase);
    if (!response || 'status' in response) {
      return undefined;
    }

    setServerInfo(response);
    return response;
  }, [apiBase]);

  useEffect(() => {
    if (!ready) {
      return;
    }

    void refreshServerInfo();
  }, [apiBase, ready, refreshServerInfo]);

  const clearSession = useCallback(async () => {
    setSession(undefined);
    await clearSessionStorage();
  }, []);

  const completeTurnstile = useCallback(
    async (token: string) => {
      const response = await createCobaltSession(apiBase, token);

      if (!response) {
        return { ok: false, message: 'The server could not be reached.' };
      }

      if ('status' in response) {
        return { ok: false, message: response.error.code };
      }

      const absolute = withAbsoluteSessionExpiry(response);
      setSession(absolute);
      await persistSession(absolute);
      return { ok: true };
    },
    [apiBase]
  );

  const currentAuthorization = useCallback(() => {
    if (settings.apiKey.trim().length > 0) {
      return createAuthorizationHeader({ apiKey: settings.apiKey.trim() });
    }

    if (hasValidSession && session) {
      return createAuthorizationHeader({ bearerToken: session.token });
    }

    return undefined;
  }, [hasValidSession, session, settings.apiKey]);

  const value = useMemo<SettingsContextValue>(
    () => ({
      ready,
      settings,
      apiBase,
      serverInfo,
      session,
      requiresTurnstile:
        !!serverInfo?.cobalt.turnstileSitekey && settings.apiKey.trim().length === 0,
      hasValidSession,
      updateSettings,
      updateSaveDefaults,
      setApiKey,
      refreshServerInfo,
      completeTurnstile,
      clearSession,
      currentAuthorization,
    }),
    [
      apiBase,
      clearSession,
      completeTurnstile,
      currentAuthorization,
      hasValidSession,
      ready,
      refreshServerInfo,
      serverInfo,
      session,
      setApiKey,
      settings,
      updateSaveDefaults,
      updateSettings,
    ]
  );

  return <SettingsContext.Provider value={value}>{children}</SettingsContext.Provider>;
}

export function useSettings() {
  const context = useContext(SettingsContext);
  if (!context) {
    throw new Error('useSettings must be used inside SettingsProvider');
  }

  return context;
}
