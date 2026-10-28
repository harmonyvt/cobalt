import {
	bindings,
	defineConfig,
	defineContainer,
	exports,
	triggers,
} from "cf/config";

// Container application. Paths resolve relative to this file.
const cobaltContainer = defineContainer({
	name: "cobalt-api-cobaltcontainer",
	image: {
		// Mirrors the repo-root Dockerfile (see the header of ./Dockerfile).
		// Run ./prepare-git-info.sh before every deploy: the image copies
		// ./.gitinfo to /app/.git.
		dockerfile: "./Dockerfile",
		// repo root, so the image can COPY the whole monorepo
		buildContext: "../../..",
	},
	instanceType: "basic",
	// Container stdout/stderr (cobalt + the webp helper) to Workers Logs, for
	// debugging the studio save (2026-10-01).
	observability: { enabled: true, logs: { enabled: true } },
	// Single instance: tunnel state created by POST / lives in that process's
	// memory, so every request is routed to the one "main" instance.
	maxInstances: 1,
});

// The editor's render container (APP-API-CONTRACT.md section 31.8): a SEPARATE class from the cobalt container above (which is
// untouched), for ffmpeg renders of timeline projects. Image: ../editor (build context is that directory alone: no monorepo
// copy, no prepare-git-info.sh). Two instances at most ("r0" and "r1", named by src/edits.ts), one render each; they sleep
// when idle (EditRenderer.sleepAfter).
const editContainer = defineContainer({
	name: "cobalt-api-editrenderer",
	image: { dockerfile: "../editor/Dockerfile", buildContext: "../editor" },
	// 4 vCPU, 12 GiB, 20 GB disk (the inputs of one render are capped at 6 GiB, EDIT_MAX_INPUT_BYTES)
	instanceType: "standard-4",
	observability: { enabled: true, logs: { enabled: true } },
	maxInstances: 2,
});

export default defineConfig({
	worker: {
		name: "cobalt-api",
		compatibilityDate: "2026-09-01",
		entrypoint: "src/index.ts",
		workersDev: false,
		// Worker + Durable Object console output and exceptions to Workers Logs.
		observability: { enabled: true, logs: { enabled: true, invocationLogs: true } },
		previewUrls: false,
		// share.: the rich link pages of public files (src/share.ts, APP-API-CONTRACT.md section 22).
		// The Worker answers that host itself and never wakes the container for it.
		// studio.: the stage's canvas, store and Twitch webhooks (src/stage.ts, APP-API-CONTRACT.md section 30), also
		// answered by the Worker itself before the gate. (The host says "studio" for the app's tab; the code says stage.)
		domains: ["api.capybaraharmony.com", "share.capybaraharmony.com", "studio.capybaraharmony.com"],
		// Daily 03:23 UTC: delete telemetry rows and crash objects older than 30
		// days (src/telemetry.ts runTelemetryRetention, called from `scheduled`).
		// Every 15 minutes: the library search indexer (src/embed.ts drainIndexer:
		// passes of 8 posts for up to 10 minutes; it calls the Hugging Face Space
		// only when a post needs a vector).
		triggers: [
			triggers.scheduled({ schedule: "23 3 * * *" }),
			triggers.scheduled({ schedule: "*/15 * * * *" }),
		],
		env: {
			API_URL: bindings.text("https://api.capybaraharmony.com/"),
			CORS_URL: bindings.text("https://cobalt.capybaraharmony.com"),
			// INTERNAL key only (UUID): used between this Worker and the
			// container, never seen by clients. Uploaded with
			// `cf deploy --secrets-file`, never in this repo.
			COBALT_API_KEY: bindings.secret(),
			// Live Activity push (APP-API-CONTRACT.md section 8): the APNs auth key
			// (.p8, the whole PEM as one JSON string with \n escapes), its key id and
			// the Apple team id. From ~/.config/cobalt/secrets.json through
			// `--secrets-file` like COBALT_API_KEY. Read by the Worker (the
			// capability flag) and the Durable Object (signing and sending); NONE of
			// them goes into the container's envVars. Missing or empty: no pushes
			// and `features.live_activity_push` is false (the app updates locally).
			APNS_KEY_P8: bindings.secret(),
			APNS_KEY_ID: bindings.secret(),
			APNS_TEAM_ID: bindings.secret(),
			APNS_BUNDLE_ID: bindings.text("com.capybaraharmony.cobalt"),
			// Which way the DO reaches Apple: "worker" (fetch from the Durable
			// Object, HTTP/2 negotiated by the runtime) or "helper" (the container's
			// node:http2 relay, POST /apns; the DO still signs, no secret enters the
			// container). Flip it and redeploy if GET /live/selftest shows a
			// transport error. See ../README.md "Live Activities".
			APNS_VIA: bindings.text("worker"),
			// Hark notification bridge (APP-API-CONTRACT.md section 9): the owner's Hark
			// webhook URL, a SECRET (from ~/.config/cobalt/secrets.json through
			// `--secrets-file` like COBALT_API_KEY). Read by the Worker (the capability
			// flag) and the Durable Object (sending); it does NOT go into the container's
			// envVars. Missing, empty or not https: the bridge is off and
			// `features.notify_bridge` is false.
			HARK_WEBHOOK_URL: bindings.secret(),
			// Off since 2026-10-23: the owner doesn't want Hark pushes. "1" turns the bridge
			// back on (with the secret above); "0" keeps it off even while the secret is set.
			HARK_NOTIFY: bindings.text("0"),
			// Per-owner client keys (SHA-256 hashes), managed by the web
			// Worker. Schema: ../d1/migrations/0001_api_keys.sql
			DB: bindings.d1({
				name: "cobalt-keys",
				id: "42f18bb0-837a-47f7-b1e2-606eb705ab6c",
			}),
			// Animated WebP output (POST /webp). The bucket must exist before the
			// first deploy: `cf r2 bucket create cobalt-media` (needs R2 enabled
			// on the account) and a public custom domain, see ../README.md.
			MEDIA: bindings.r2({ name: "cobalt-media" }),
			MEDIA_BASE_URL: bindings.text("https://media.capybaraharmony.com/"),
			// Rich link pages (APP-API-CONTRACT.md section 22): https://media.../<name>.<ext> is shared as
			// <SHARE_BASE_URL><name>, a page whose Open Graph tags make Discord, iMessage, X and the rest
			// show the video or image. Must be one of `domains` above; empty turns the pages off.
			SHARE_BASE_URL: bindings.text("https://share.capybaraharmony.com/"),
			// Gallery links (APP-API-CONTRACT.md section 29.1): "1" swaps each video in Discord's gallery for a
			// 4 s silent WebP that plays by itself; "0" (owner's pick, 2026-10-20) shows the real videos.
			GALLERY_LOOPS: bindings.text("0"),
			// Edge-cache purge for the public bucket (APP-API-CONTRACT.md section 16): turning a
			// file private deletes its public object, then purges its URL here so the edge stops
			// serving it. MEDIA_ZONE_ID is the capybaraharmony.com zone id (not a secret);
			// MEDIA_PURGE_TOKEN is a token scoped to Zone > Cache Purge on that zone, a SECRET from
			// ~/.config/cobalt/secrets.json through `--secrets-file`. Missing or empty: the toggle
			// still works and answers `cache_cleared: null`.
			MEDIA_ZONE_ID: bindings.text("560c4ad4961a65fa19899b4dfa8b5702"),
			MEDIA_PURGE_TOKEN: bindings.secret(),
			// Library search (APP-API-CONTRACT.md section 21, deploy/huggingface/embed): the private
			// Hugging Face Space that runs EmbeddingGemma 2. EMBED_TOKEN (a Hugging Face token that can
			// call the private Space) and EMBED_KEY (the Space's own secret) are SECRETS from
			// ~/.config/cobalt/secrets.json. Missing or empty token: search is off
			// (`features.search: false`) and the indexer does nothing.
			EMBED_URL: bindings.text("https://capybaraharmony-cobalt-embed.hf.space"),
			// The same Space's id on the Hub: a sleeping Space that refuses the wake-up GET is restarted
			// through the Hub API with EMBED_TOKEN (embed.ts spaceClient). Empty: no restarts.
			EMBED_SPACE: bindings.text("capybaraharmony/cobalt-embed"),
			EMBED_TOKEN: bindings.secret(),
			EMBED_KEY: bindings.secret(),
			// Roast captions (APP-API-CONTRACT.md section 25): Claude Haiku writes a funny title and
			// description for every public file and gallery link. ANTHROPIC_API_KEY is a SECRET from
			// ~/.config/cobalt/secrets.json; missing or empty turns captions off. ROAST_BASE_URL (optional,
			// also from the secrets file) routes through Cloudflare AI Gateway:
			// https://gateway.ai.cloudflare.com/v1/<account>/<gateway>/anthropic
			ANTHROPIC_API_KEY: bindings.secret(),
			ROAST_BASE_URL: bindings.secret(),
			ROAST_MODEL: bindings.text("claude-haiku-5-5"),
			// Chat (APP-API-CONTRACT.md section 27): the model (same key as the captions), and the Worker
			// Loader the model's code runs in (a fresh Dynamic Worker per run, no network: src/chat-loader.ts).
			CHAT_MODEL: bindings.text("claude-haiku-5-5"),
			// How many files the chat AI may start making per thread per day (webps, slideshows, editor renders;
			// APP-API-CONTRACT.md section 33.7). Editor renders run on a standard-4 container, so each costs real money.
			CHAT_DAILY_RENDERS: bindings.text("10"),
			LOADER: bindings.workerLoader(),
			// Stage (APP-API-CONTRACT.md section 30): https://<stage host>/ , one of `domains` above; empty turns the stage
			// off (every /stage* route is a 404, `features.stage` false). The three Twitch values are SECRETS from
			// ~/.config/cobalt/secrets.json (`cf deploy` refuses while a declared one is missing; empty is fine and
			// leaves canvas and store working without Twitch): the app's client id and secret from dev.twitch.tv, and a
			// string of your own (10..100 ASCII chars, e.g. `openssl rand -hex 32`) that signs the EventSub webhooks.
			STAGE_BASE_URL: bindings.text("https://studio.capybaraharmony.com/"),
			TWITCH_CLIENT_ID: bindings.secret(),
			TWITCH_CLIENT_SECRET: bindings.secret(),
			TWITCH_EVENTSUB_SECRET: bindings.secret(),
			// Old Discord attachment links (APP-API-CONTRACT.md section 19.6): a Discord bot token, a SECRET from
			// ~/.config/cobalt/secrets.json. The Durable Object hands it to the container's helper (envVars), which
			// asks Discord to sign an unsigned or expired attachment link again. Empty: Discord links save as before and
			// `features.discord_refresh` is false. The bot needs no server and no permissions.
			DISCORD_BOT_TOKEN: bindings.secret(),
			// cobalt studio (POST /studio): PRIVATE copies of saved source
			// videos, originals/<session id>.<ext>. No public domain; only the
			// Worker reads it (GET /studio/<id>/source). Bucket already exists.
			ORIGINALS: bindings.r2({ name: "cobalt-originals" }),
			// Worker version id: part of the container env, so each deploy
			// restarts the running container once (see src/index.ts).
			VERSION: bindings.versionMetadata(),
			COBALT: bindings.durableObject({
				worker: "cobalt-api",
				exportName: "CobaltContainer",
			}),
			// Chat and captions call Anthropic through this Durable Object, pinned to North America
			// (src/model-fetch.ts): from some Cloudflare locations Anthropic answers 403.
			MODEL_RELAY: bindings.durableObject({
				worker: "cobalt-api",
				exportName: "ModelRelay",
			}),
			// The stage's canvas WebSockets and event fan-out (src/stage-room.ts): one instance, "main".
			STAGE_ROOM: bindings.durableObject({
				worker: "cobalt-api",
				exportName: "StageRoom",
			}),
			// The editor's render containers (src/edit-renderer.ts, APP-API-CONTRACT.md section 31): two named instances,
			// "r0" and "r1". Without this binding every /edits route is a 404 and `features.editor` is false. Needs
			// migration 0021 (../d1/migrations/0021_edits.sql). No new secret: the container takes the internal key
			// (COBALT_API_KEY) through envVars, and HARK_WEBHOOK_URL stays in the Worker.
			EDIT_RENDERER: bindings.durableObject({
				worker: "cobalt-api",
				exportName: "EditRenderer",
			}),
		},
		exports: {
			CobaltContainer: exports.durableObject({
				storage: "sqlite",
				container: cobaltContainer,
			}),
			ModelRelay: exports.durableObject({ storage: "sqlite" }),
			StageRoom: exports.durableObject({ storage: "sqlite" }),
			EditRenderer: exports.durableObject({
				storage: "sqlite",
				container: editContainer,
			}),
		},
	},
	containers: [cobaltContainer, editContainer],
});
