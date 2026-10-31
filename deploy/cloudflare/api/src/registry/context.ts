// One context for every op call (APP-API-CONTRACT.md 33): the deps worker.ts builds for its routes, built once per call.
import { appDeps, embedFrom, shareBaseFrom, type ContainerStub, type StageEdge } from "../deps";
import { KEY_ID_HEADER } from "../headers";
import type { EdgeDeps } from "../studio-edge";
import type { WorkerEnv } from "../worker";
import type { OpContext } from "./op";
import type { Registry } from "./registry";

// What every call shares; the caller-specific fields come on top (`forCall`).
export type OpBase = Pick<OpContext, "env" | "db" | "now" | "mediaBaseUrl" | "shareBaseUrl" | "edge" | "container" | "registry" | "app" | "embed" | "stageEdge">;

export function opBase(env: WorkerEnv, container: ContainerStub, edge: EdgeDeps, registry: Registry, stageEdge: StageEdge = {}): OpBase {
    let app: ReturnType<OpContext["app"]> | undefined;
    let embed: ReturnType<OpContext["embed"]> | undefined;
    return {
        env,
        db: env.DB,
        now: edge.now,
        mediaBaseUrl: env.MEDIA_BASE_URL,
        shareBaseUrl: shareBaseFrom(env),
        edge,
        container,
        registry,
        stageEdge,
        app: () => (app ??= appDeps(env, container, edge)),
        embed: () => (embed === undefined ? (embed = embedFrom(env)) : embed),
    };
}

export function forCall(
    base: OpBase,
    who: Pick<OpContext, "keyId" | "caller"> & Partial<Pick<OpContext, "request" | "url" | "query" | "params" | "chat" | "country">>,
): OpContext {
    return {
        ...base,
        ...who,
        query: who.query ?? who.url?.searchParams ?? new URLSearchParams(),
        params: who.params ?? {},
        // The main Durable Object with this call's key id; the caller's own key never travels.
        durableObject: (path, init = {}) => {
            const headers = new Headers(init.headers);
            headers.delete("Authorization");
            if (who.keyId) headers.set(KEY_ID_HEADER, who.keyId);
            return base.container.fetch(new Request(`https://do.internal${path}`, { ...init, headers }));
        },
    };
}
