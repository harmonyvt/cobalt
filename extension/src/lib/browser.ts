// The slice of the WebExtension API this extension uses. Chrome's `chrome` and Safari's `browser`
// are both promise-based for these calls. Content scripts and the popup talk to the background;
// they never see the session token.

export type StorageArea = {
    get(keys?: string | string[] | null): Promise<Record<string, unknown>>;
    set(items: Record<string, unknown>): Promise<void>;
    remove(keys: string | string[]): Promise<void>;
};

export type Ext = {
    runtime: {
        /** Undefined once the extension was reloaded or removed under a running content script. */
        id?: string;
        getURL(path: string): string;
        sendMessage(message: unknown): Promise<unknown>;
        openOptionsPage?(): Promise<void>;
        onMessage: {
            addListener(
                fn: (message: unknown, sender: { tab?: { id?: number } }, sendResponse?: (reply: unknown) => void) => boolean | Promise<unknown> | unknown,
            ): void;
        };
    };
    storage: {
        local: StorageArea;
        session?: StorageArea;
        onChanged: {
            addListener(fn: (changes: Record<string, { newValue?: unknown }>, area: string) => void): void;
        };
    };
    identity?: {
        getRedirectURL(path?: string): string;
        launchWebAuthFlow(details: { url: string; interactive?: boolean }): Promise<string>;
    };
    tabs: {
        create(props: { url: string }): Promise<{ id?: number }>;
        sendMessage(tabId: number, message: unknown): Promise<unknown>;
    };
    alarms?: {
        create(name: string, info: { periodInMinutes?: number; delayInMinutes?: number }): void;
        onAlarm: { addListener(fn: (alarm: { name: string }) => void): void };
    };
    action?: {
        setBadgeText(details: { text: string }): Promise<void> | void;
        setBadgeBackgroundColor(details: { color: string }): Promise<void> | void;
    };
    /** Absent on a browser that has no context-menu API (some Safari builds). */
    contextMenus?: {
        create(props: { id: string; title: string; contexts: string[] }): void;
        onClicked: {
            addListener(fn: (info: { menuItemId?: string | number; srcUrl?: string; linkUrl?: string; pageUrl?: string }, tab?: { id?: number }) => void): void;
        };
    };
};

export function getExt(): Ext | null {
    const g = globalThis as { browser?: Ext; chrome?: Ext };
    return g.browser ?? g.chrome ?? null;
}
