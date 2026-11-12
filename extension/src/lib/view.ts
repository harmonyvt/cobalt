// What the popup shows. The token never appears here.

export type SpriteState = "idle" | "saving" | "saved" | "error" | "sleeping";

export type RecentSave = {
    url: string;
    status: "saving" | "saved" | "error";
    at: number;
    studioUrl?: string;
    error?: string;
};

export type PopupInput = {
    signedIn: boolean;
    offline: boolean;
    device: string | null;
    saving: boolean;
    recent: RecentSave[];
};

export type PopupView = {
    sprite: SpriteState;
    heading: string;
    detail: string;
    showSignIn: boolean;
    showSignOut: boolean;
};

export function popupView(input: PopupInput): PopupView {
    if (!input.signedIn) {
        return {
            sprite: "sleeping",
            heading: "Signed out",
            detail: "Sign in to save posts to Capystore.",
            showSignIn: true,
            showSignOut: false,
        };
    }
    if (input.offline) {
        return {
            sprite: "sleeping",
            heading: "Offline",
            detail: input.device ?? "Browser extension",
            showSignIn: false,
            showSignOut: true,
        };
    }
    if (input.saving) {
        return {
            sprite: "saving",
            heading: "Saving",
            detail: input.device ?? "Browser extension",
            showSignIn: false,
            showSignOut: true,
        };
    }
    return {
        sprite: "idle",
        heading: input.device ?? "Signed in",
        detail: "Buttons are on X, YouTube, Twitch and Instagram.",
        showSignIn: false,
        showSignOut: true,
    };
}

export const SITES = [
    { id: "x", label: "X" },
    { id: "youtube", label: "YouTube" },
    { id: "twitch", label: "Twitch clips" },
    { id: "instagram", label: "Instagram" },
] as const;

export type SiteId = (typeof SITES)[number]["id"];

export type SiteToggles = Record<SiteId, boolean>;

export const DEFAULT_SITES: SiteToggles = { x: true, youtube: true, twitch: true, instagram: true };

export function normalizeSites(raw: unknown): SiteToggles {
    const o = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {};
    return {
        x: o.x !== false,
        youtube: o.youtube !== false,
        twitch: o.twitch !== false,
        instagram: o.instagram !== false,
    };
}

// Sprite sheet: 134×94 cells, 6 columns × 5 rows. Empty cells at the end of a row are not played.
export const SPRITE = {
    cell: { w: 134, h: 94 },
    cols: 6,
    rows: 5,
    states: {
        idle: { row: 0, frames: 6, ms: 1800 },
        saving: { row: 1, frames: 6, ms: 900 },
        saved: { row: 2, frames: 4, ms: 1100 },
        error: { row: 3, frames: 4, ms: 1200 },
        sleeping: { row: 4, frames: 3, ms: 1600 },
    },
} as const;

export function spriteCss(w = 32, h = 22): string {
    const frames = Object.entries(SPRITE.states)
        .map(([name, s]) => {
            const y = -s.row * h;
            return `@keyframes capy-${name}{from{background-position:0 ${y}px}to{background-position:${-s.frames * w}px ${y}px}}
.capy.${name}{animation:capy-${name} ${s.ms}ms steps(${s.frames}) infinite}`;
        })
        .join("");
    return `.capy{width:${w}px;height:${h}px;background-repeat:no-repeat;background-size:${w * SPRITE.cols}px ${h * SPRITE.rows}px;flex:none}${frames}
@media (prefers-reduced-motion: reduce){.capy{animation:none}}`;
}

export type StoredSession = { key: string; id: string; device: string };

export function publicAuth(session: StoredSession | null, offline: boolean): { signedIn: boolean; offline: boolean; device: string | null } {
    return { signedIn: session !== null, offline, device: session?.device ?? null };
}
