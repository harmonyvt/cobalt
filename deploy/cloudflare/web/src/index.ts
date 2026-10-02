import { handleKeys, type Env } from "./keys";
import { handleLibrary } from "./library";
import { handleStudio } from "./studio";

export type { Env };

// `assets.runWorkerFirst` routes only /api/keys(/*), /studio(/*), /library(/*) and
// /api/library(/*) here; every other request is answered by the static assets
// without invoking this Worker.
// The fallthrough below is a safety net in case that routing is ever widened.
export default {
    async fetch(request: Request, env: Env): Promise<Response> {
        const { pathname } = new URL(request.url);
        if (pathname === "/api/keys" || pathname.startsWith("/api/keys/")) {
            return handleKeys(request, env);
        }
        if (pathname === "/studio" || pathname.startsWith("/studio/")) {
            return handleStudio(request, env);
        }
        if (
            pathname === "/library" ||
            pathname.startsWith("/library/") ||
            pathname === "/api/library" ||
            pathname.startsWith("/api/library/")
        ) {
            return handleLibrary(request, env);
        }
        return env.ASSETS.fetch(request);
    },
} satisfies ExportedHandler<Env>;
