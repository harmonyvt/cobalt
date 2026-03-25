export type CobaltErrorResponse = {
    status: "error";
    error: {
        code: string;
        context?: {
            service?: string;
            limit?: number;
        };
    };
};

export type CobaltPickerItem = {
    type: "photo" | "video" | "gif";
    url: string;
    thumb?: string;
};

export type CobaltPickerResponse = {
    status: "picker";
    picker: CobaltPickerItem[];
    audio?: string;
    audioFilename?: string;
};

export type CobaltRedirectResponse = {
    status: "redirect";
    url: string;
    filename: string;
};

export type CobaltTunnelResponse = {
    status: "tunnel";
    url: string;
    filename: string;
};

export type CobaltFileMetadata = Record<
    | "album"
    | "composer"
    | "genre"
    | "copyright"
    | "title"
    | "artist"
    | "album_artist"
    | "track"
    | "date"
    | "sublanguage",
    string | undefined
>;

export type CobaltLocalProcessingType = "merge" | "mute" | "audio" | "gif" | "remux" | "proxy";

export type CobaltLocalProcessingResponse = {
    status: "local-processing";
    type: CobaltLocalProcessingType;
    service: string;
    tunnel: string[];
    output: {
        type: string;
        filename: string;
        metadata?: CobaltFileMetadata;
        subtitles?: boolean;
    };
    audio?: {
        copy: boolean;
        format: string;
        bitrate: string;
        cover?: boolean;
        cropCover?: boolean;
    };
    isHLS?: boolean;
};

export type CobaltAPIResponse =
    | CobaltErrorResponse
    | CobaltPickerResponse
    | CobaltRedirectResponse
    | CobaltTunnelResponse
    | CobaltLocalProcessingResponse;

export type CobaltServerInfo = {
    cobalt: {
        version: string;
        url: string;
        startTime: string;
        turnstileSitekey?: string;
        services: string[];
    };
    git: {
        branch: string;
        commit: string;
        remote: string;
    };
};

export type CobaltServerInfoResponse = CobaltServerInfo | CobaltErrorResponse;

export type CobaltSession = {
    token: string;
    exp: number;
};

export type CobaltSessionResponse = CobaltSession | CobaltErrorResponse;

export type CobaltSaveRequestBody = {
    url: string;
    audioBitrate?: "320" | "256" | "128" | "96" | "64" | "8";
    audioFormat?: "best" | "mp3" | "ogg" | "wav" | "opus";
    downloadMode?: "auto" | "audio" | "mute";
    filenameStyle?: "classic" | "pretty" | "basic" | "nerdy";
    videoQuality?: "max" | "4320" | "2160" | "1440" | "1080" | "720" | "480" | "360" | "240" | "144";
    disableMetadata?: boolean;
    alwaysProxy?: boolean;
    localProcessing?: "disabled" | "preferred" | "forced";
    subtitleLang?: string;
    youtubeVideoCodec?: "h264" | "av1" | "vp9";
    youtubeVideoContainer?: "auto" | "mp4" | "webm" | "mkv";
    youtubeDubLang?: string;
    convertGif?: boolean;
    allowH265?: boolean;
    tiktokFullAudio?: boolean;
    youtubeBetterAudio?: boolean;
    youtubeHLS?: boolean;
};

export declare const cobaltFileMetadataKeys: readonly string[];
export declare function normalizeApiBase(url: string): string;
export declare function createCobaltError(code: string, context?: CobaltErrorResponse["error"]["context"]): CobaltErrorResponse;
export declare function isCobaltError(value: unknown): value is CobaltErrorResponse;
export declare function withAbsoluteSessionExpiry(session: CobaltSession, nowSeconds?: number): CobaltSession;
export declare function createAuthorizationHeader(input?: { apiKey?: string; bearerToken?: string }): string | undefined;
export declare function getCobaltServerInfo(apiBase: string): Promise<CobaltServerInfoResponse | undefined>;
export declare function createCobaltSession(apiBase: string, turnstileToken?: string): Promise<CobaltSessionResponse | undefined>;
export declare function requestCobalt(apiBase: string, requestBody: CobaltSaveRequestBody, authorization?: string): Promise<CobaltAPIResponse | undefined>;
export declare function probeCobaltTunnel(url: string): Promise<number>;
