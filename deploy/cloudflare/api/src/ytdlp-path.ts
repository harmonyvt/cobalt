// The yt-dlp box's own path (src/ytdlp.ts), kept apart so code that runs under plain node (the ops, the tests) never
// imports the Containers library. POST it to start the box and wait for its port: 204.
export const YTDLP_START_PATH = "/__start";
