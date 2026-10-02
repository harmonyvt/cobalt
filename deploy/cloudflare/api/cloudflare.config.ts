import {
	bindings,
	defineConfig,
	defineContainer,
	exports,
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

export default defineConfig({
	worker: {
		name: "cobalt-api",
		compatibilityDate: "2026-09-01",
		entrypoint: "src/index.ts",
		workersDev: false,
		// Worker + Durable Object console output and exceptions to Workers Logs.
		observability: { enabled: true, logs: { enabled: true, invocationLogs: true } },
		previewUrls: false,
		domains: ["api.capybaraharmony.com"],
		env: {
			API_URL: bindings.text("https://api.capybaraharmony.com/"),
			CORS_URL: bindings.text("https://cobalt.capybaraharmony.com"),
			// INTERNAL key only (UUID): used between this Worker and the
			// container, never seen by clients. Uploaded with
			// `cf deploy --secrets-file`, never in this repo.
			COBALT_API_KEY: bindings.secret(),
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
		},
		exports: {
			CobaltContainer: exports.durableObject({
				storage: "sqlite",
				container: cobaltContainer,
			}),
		},
	},
	containers: [cobaltContainer],
});
