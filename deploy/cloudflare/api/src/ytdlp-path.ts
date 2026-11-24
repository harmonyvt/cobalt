// The yt-dlp box's own path (src/ytdlp.ts), kept apart so code that runs under plain node (the ops, the tests) never
// imports the Containers library. POST it to start the box and wait for its port: 204.
export const YTDLP_START_PATH = "/__start";
// GET YTDLP_STATE_PATH: `{ "running": boolean }`, whether the box's container is up (the studio shows a cold start as `waking`)
export const YTDLP_STATE_PATH = "/__state";
