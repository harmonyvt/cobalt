import { bindings, defineConfig } from "cf/config";

export default defineConfig({
	worker: {
		name: "cobalt-web",
		compatibilityDate: "2026-09-01",
		entrypoint: "src/index.ts",
		workersDev: false,
		previewUrls: false,
		assets: {
			notFoundHandling: "404-page",
			// Only the key-management API, the cobalt studio page, the library
			// (page + /api/library) and the telemetry logs (page + /api/logs) run the Worker; everything else is served
			// straight from the static assets.
			runWorkerFirst: [
				"/api/keys",
				"/api/keys/*",
				"/studio",
				"/studio/*",
				"/library",
				"/library/*",
				"/api/library",
				"/api/library/*",
				"/logs",
				"/api/logs",
				"/api/logs/*",
			],
		},
		domains: [
			"cobalt.capybaraharmony.com",
		],
		env: {
			ASSETS: bindings.assets(),
			// Owner-managed API keys (SHA-256 hashes). The API Worker binds the
			// same database. Schema: ../d1/migrations/0001_api_keys.sql
			DB: bindings.d1({
				name: "cobalt-keys",
				id: "42f18bb0-837a-47f7-b1e2-606eb705ab6c",
			}),
			// Cloudflare Access (Zero Trust) application protecting this hostname.
			ACCESS_TEAM_DOMAIN: bindings.text("harmonyvt.cloudflareaccess.com"),
			ACCESS_AUD: bindings.text("9afe49f50618965d109d9205999018b35bf49ec1847cd6465afb6330fc009b66"),
			OWNER_EMAIL: bindings.text("maskeowl@icloud.com"),
			// The only Origin allowed to create or revoke keys (and to change the library).
			WEB_ORIGIN: bindings.text("https://cobalt.capybaraharmony.com"),
			// Library (see ../LIBRARY-CONTRACT.md). Public files: R2 cobalt-media,
			// served at MEDIA_BASE_URL. Private files: R2 cobalt-originals
			// (studio saves at originals/, uploads at uploads/). Both buckets
			// already exist (the API Worker binds the same ones).
			MEDIA: bindings.r2({ name: "cobalt-media" }),
			MEDIA_BASE_URL: bindings.text("https://media.capybaraharmony.com/"),
			ORIGINALS: bindings.r2({ name: "cobalt-originals" }),
			// Service binding to the API Worker; the library calls it with the
			// internal key in x-cobalt-service instead of an owner API key.
			API: bindings.worker({ worker: "cobalt-api" }),
			// INTERNAL key shared with the API Worker, never sent to the browser.
			// Uploaded with `cf deploy --secrets-file ~/.config/cobalt/secrets.json`.
			COBALT_API_KEY: bindings.secret(),
		},
	},
});
