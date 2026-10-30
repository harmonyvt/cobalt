<script lang="ts">
    import { onMount, tick } from "svelte";

    import { t, INTERNAL_locale } from "$lib/i18n/translations";
    import { hapticConfirm } from "$lib/haptics";
    import {
        getMcp,
        setMcpMode,
        rotateMcpLink,
        type McpMode,
        type McpSettings,
        type McpResult,
    } from "$lib/api/mcp";

    import CopyIcon from "$components/misc/CopyIcon.svelte";
    import SettingsCategory from "$components/settings/SettingsCategory.svelte";

    import IconRefresh from "@tabler/icons-svelte/IconRefresh.svelte";

    type LoadState = "loading" | "ready" | "expired" | "unavailable" | "failed";
    type Pending = McpMode | "rotate";

    const MODES: McpMode[] = ["off", "public", "private"];

    let loadState: LoadState = "loading";
    let loadError = "";
    let settings: McpSettings | null = null;

    let pending: Pending | null = null;
    let working = false;
    let actionError = "";

    let revealed: string | null = null;
    let revealedIsNew = false;
    let copied = false;
    let copyFailed = false;
    let copiedPublic = false;

    let linkBox: HTMLElement;
    let confirmButton: HTMLButtonElement;

    $: mode = settings?.mode ?? "public";
    $: publicUrl = settings?.public_url ?? "https://api.capybaraharmony.com/mcp";
    $: claudeCode = `claude mcp add --transport http capystore ${publicUrl} --header "Authorization: Bearer <key>"`;

    const errorText = (res: McpResult<unknown>) => {
        if (res.ok) return "";
        if (res.reason === "unavailable") return $t("mcp.error.network");
        if (res.reason === "api" && res.code === "not_private") return $t("mcp.error.not_private");
        return $t("mcp.error.unknown");
    };

    const formatDate = (ms: number) => {
        const diff = ms - Date.now();
        const abs = Math.abs(diff);
        const locale = $INTERNAL_locale || undefined;
        try {
            if (abs < 60_000) return $t("apikeys.time.now");
            const rtf = new Intl.RelativeTimeFormat(locale, { numeric: "auto" });
            if (abs < 3_600_000) return rtf.format(Math.round(diff / 60_000), "minute");
            if (abs < 86_400_000) return rtf.format(Math.round(diff / 3_600_000), "hour");
            if (abs < 30 * 86_400_000) return rtf.format(Math.round(diff / 86_400_000), "day");
            return new Date(ms).toLocaleDateString(locale, { year: "numeric", month: "short", day: "numeric" });
        } catch {
            return new Date(ms).toDateString();
        }
    };

    const load = async () => {
        loadState = "loading";
        const res = await getMcp();
        if (res.ok) {
            settings = res.data;
            loadState = "ready";
            return;
        }
        if (res.reason === "expired") loadState = "expired";
        else if (res.reason === "unavailable") loadState = "unavailable";
        else {
            loadError = errorText(res);
            loadState = "failed";
        }
    };

    // which words the confirm box shows
    $: confirmKey =
        pending === "public" && mode === "private"
            ? "leave_private"
            : pending;

    const ask = async (next: Pending) => {
        if (working) return;
        if (next !== "rotate" && next === mode) return;
        actionError = "";
        pending = next;
        await tick();
        confirmButton?.focus();
    };

    const cancel = () => {
        pending = null;
        actionError = "";
    };

    const confirm = async () => {
        if (!pending || working) return;
        working = true;
        actionError = "";
        const res = pending === "rotate" ? await rotateMcpLink() : await setMcpMode(pending);
        working = false;
        if (!res.ok) {
            if (res.reason === "expired") {
                loadState = "expired";
                return;
            }
            actionError = errorText(res);
            return;
        }
        hapticConfirm();
        const wasRotate = pending === "rotate";
        pending = null;
        settings = res.data.settings;
        if (res.data.link_url) {
            revealed = res.data.link_url;
            revealedIsNew = wasRotate;
            copied = false;
            copyFailed = false;
            await tick();
            linkBox?.focus();
        }
    };

    const selectBox = () => {
        const range = document.createRange();
        range.selectNodeContents(linkBox);
        const selection = window.getSelection();
        selection?.removeAllRanges();
        selection?.addRange(range);
    };

    const copyLink = async () => {
        if (!revealed) return;
        try {
            await navigator.clipboard.writeText(revealed);
            copyFailed = false;
            copied = true;
            setTimeout(() => (copied = false), 1500);
        } catch {
            copied = false;
            copyFailed = true;
            selectBox();
        }
    };

    const copyPublic = async () => {
        try {
            await navigator.clipboard.writeText(publicUrl);
            copiedPublic = true;
            setTimeout(() => (copiedPublic = false), 1500);
        } catch {
            copiedPublic = false;
        }
    };

    const dismissReveal = () => {
        revealed = null;
        copied = false;
        copyFailed = false;
    };

    onMount(load);
</script>

<SettingsCategory sectionId="mcp" title={$t("mcp.title")}>
    <div class="subtext description">{$t("mcp.description")}</div>

    {#if loadState === "loading"}
        <div class="notice" role="status">{$t("mcp.loading")}</div>
    {:else if loadState === "expired"}
        <div class="notice" role="alert">
            <span>{$t("mcp.expired")}</span>
            <button class="button active" on:click={() => location.reload()}>
                <IconRefresh />
                {$t("mcp.reload")}
            </button>
        </div>
    {:else if loadState === "unavailable"}
        <div class="subtext quiet" role="status">{$t("mcp.unavailable")}</div>
    {:else if loadState === "failed"}
        <div class="notice" role="alert">
            <span>{$t("mcp.load_failed")} {loadError}</span>
            <button class="button" on:click={load}>{$t("mcp.retry")}</button>
        </div>
    {:else}
        <div class="modes" role="radiogroup" aria-label={$t("mcp.how")}>
            {#each MODES as m}
                <button
                    class="button mode"
                    class:active={mode === m}
                    role="radio"
                    aria-checked={mode === m}
                    disabled={working}
                    on:click={() => ask(m)}
                >
                    <span class="mode-name">{$t(`mcp.mode.${m}`)}</span>
                    <span class="mode-detail">{$t(`mcp.mode.${m}.detail`)}</span>
                </button>
            {/each}
        </div>

        {#if pending}
            <div class="box confirm" role="group" aria-labelledby="mcp-confirm-title">
                <h4 id="mcp-confirm-title">{$t(`mcp.confirm.${confirmKey}.title`)}</h4>
                <div class="subtext">{$t(`mcp.confirm.${confirmKey}.body`)}</div>
                {#if actionError}
                    <div class="subtext error" role="alert">{actionError}</div>
                {/if}
                <div class="row">
                    <button
                        class="button"
                        class:danger={pending === "off" || pending === "rotate" || confirmKey === "leave_private"}
                        class:active={pending === "private" || (pending === "public" && confirmKey !== "leave_private")}
                        bind:this={confirmButton}
                        disabled={working}
                        on:click={confirm}
                    >
                        {working ? $t("mcp.working") : $t(`mcp.confirm.${confirmKey}.action`)}
                    </button>
                    <button class="button" disabled={working} on:click={cancel}>{$t("mcp.cancel")}</button>
                </div>
            </div>
        {/if}

        {#if revealed}
            <div class="box reveal" role="group" aria-labelledby="mcp-reveal-title">
                <h4 id="mcp-reveal-title">
                    {revealedIsNew ? $t("mcp.reveal.title_new") : $t("mcp.reveal.title")}
                </h4>
                <div class="subtext">{$t("mcp.reveal.warning")}</div>
                <div class="link-row">
                    <code
                        class="code-box grow"
                        bind:this={linkBox}
                        tabindex="-1"
                        aria-label={$t("mcp.reveal.title")}>{revealed}</code>
                    <button class="button copy-button" on:click={copyLink} aria-label={$t("mcp.reveal.copy")}>
                        <CopyIcon check={copied} regularIcon />
                        <span>{copied ? $t("mcp.reveal.copied") : $t("mcp.reveal.copy")}</span>
                    </button>
                </div>
                <div class="subtext" role="status">
                    {#if copyFailed}{$t("mcp.reveal.copy_failed")}{/if}
                </div>
                <button class="button active done" on:click={dismissReveal}>{$t("mcp.reveal.done")}</button>
            </div>
        {/if}

        {#if mode === "off"}
            <div class="box">
                <h4>{$t("mcp.off.title")}</h4>
                <div class="subtext">{$t("mcp.off.body")}</div>
            </div>
        {:else if mode === "public"}
            <div class="box">
                <h4>{$t("mcp.public.title")}</h4>
                <div class="link-row">
                    <code class="code-box grow">{publicUrl}</code>
                    <button class="button copy-button" on:click={copyPublic}>
                        <CopyIcon check={copiedPublic} regularIcon />
                        <span>{copiedPublic ? $t("mcp.public.copied") : $t("mcp.public.copy")}</span>
                    </button>
                </div>
                <div class="subtext">{$t("mcp.public.header")}</div>
                <code class="code-box small">Authorization: Bearer &lt;key&gt;</code>
                <div class="subtext">{$t("mcp.public.claude_code")}</div>
                <code class="code-box small">{claudeCode}</code>
                <div class="subtext">{$t("mcp.public.claude_ai")}</div>
            </div>
        {:else if settings?.link}
            <div class="box">
                <h4>{$t("mcp.private.title")}</h4>
                <div class="link-row">
                    <code class="code-box grow muted">{settings.link.hint}</code>
                    <span class="subtext hidden-tag">{$t("mcp.private.hidden")}</span>
                </div>
                <dl class="facts">
                    <div>
                        <dt>{$t("mcp.private.last_used")}</dt>
                        <dd>
                            {settings.link.last_used_at ? formatDate(settings.link.last_used_at) : $t("mcp.private.never")}
                        </dd>
                    </div>
                    <div>
                        <dt>{$t("mcp.private.used_by")}</dt>
                        <dd>{settings.link.used_by ?? "—"}</dd>
                    </div>
                    <div>
                        <dt>{$t("mcp.private.calls_today")}</dt>
                        <dd>{settings.link.calls_today}</dd>
                    </div>
                    <div>
                        <dt>{$t("mcp.private.made")}</dt>
                        <dd>{formatDate(settings.link.made_at)}</dd>
                    </div>
                </dl>
                <div class="row">
                    <button class="button active" disabled={working} on:click={() => ask("rotate")}>
                        {$t("mcp.private.rotate")}
                    </button>
                </div>
                <div class="subtext">{$t("mcp.private.rotate_hint")}</div>
                <div class="subtext">{$t("mcp.private.public_off")}</div>
            </div>
        {/if}

        <div class="box">
            <h4>{$t("mcp.steps.title")}</h4>
            <ol class="subtext steps">
                <li>{$t("mcp.steps.1")}</li>
                <li>{$t("mcp.steps.2")}</li>
                <li>{$t("mcp.steps.3")}</li>
            </ol>
        </div>
    {/if}
</SettingsCategory>

<style>
    .description {
        margin-top: -3px;
    }

    .notice,
    .box,
    .mode {
        background: var(--button);
        box-shadow: var(--button-box-shadow);
        border-radius: var(--border-radius);
    }

    .notice {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 12px;
        padding: var(--padding) 16px;
        font-size: 13px;
        font-weight: 500;
        line-height: 1.4;
    }

    .notice :global(svg) {
        height: 19px;
        width: 19px;
        stroke-width: 1.8px;
        flex-shrink: 0;
    }

    .quiet {
        padding: 0 var(--padding);
    }

    .modes {
        display: grid;
        grid-template-columns: repeat(3, minmax(0, 1fr));
        gap: 6px;
    }

    @media screen and (max-width: 640px) {
        .modes {
            grid-template-columns: minmax(0, 1fr);
        }
    }

    .mode {
        display: flex;
        flex-direction: column;
        align-items: flex-start;
        justify-content: flex-start;
        gap: 4px;
        padding: 12px 14px;
        text-align: left;
        min-height: 44px;
    }

    .mode-name {
        font-size: 14px;
        font-weight: 500;
    }

    .mode-detail {
        font-size: 12px;
        line-height: 1.4;
        opacity: 0.75;
    }

    .box {
        display: flex;
        flex-direction: column;
        gap: 10px;
        padding: 16px;
    }

    .box h4 {
        margin: 0;
    }

    .box .subtext {
        padding: 0;
    }

    .error {
        color: var(--red);
    }

    .row {
        display: flex;
        flex-wrap: wrap;
        gap: 6px;
    }

    .row .button {
        padding: 10px 16px;
        font-weight: 500;
    }

    .link-row {
        display: flex;
        align-items: center;
        gap: 6px;
    }

    .code-box {
        font-family: "IBM Plex Mono", monospace;
        font-size: 13px;
        background: var(--primary);
        color: var(--secondary);
        border-radius: var(--border-radius);
        box-shadow: 0 0 0 1px var(--input-border) inset;
        padding: 10px 12px;
        word-break: break-all;
        line-height: 1.4;
        user-select: all;
        -webkit-user-select: all;
    }

    .code-box.small {
        display: block;
        font-size: 12px;
    }

    .code-box.muted {
        user-select: none;
        -webkit-user-select: none;
        opacity: 0.8;
    }

    .grow {
        flex: 1;
        min-width: 0;
    }

    .code-box:focus-visible {
        outline: var(--focus-ring);
        outline-offset: var(--focus-ring-offset);
    }

    .copy-button {
        padding: 0 12px;
        min-height: 40px;
        flex-shrink: 0;
        font-size: 13px;
        font-weight: 500;
        background: var(--button-elevated);
        box-shadow: none;
    }

    .hidden-tag {
        flex-shrink: 0;
    }

    .facts {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 6px;
        margin: 0;
    }

    .facts div {
        background: var(--primary);
        border-radius: var(--border-radius);
        padding: 8px 12px;
        display: flex;
        flex-direction: column;
        gap: 2px;
    }

    .facts dt {
        font-size: 11.5px;
        color: var(--gray);
    }

    .facts dd {
        margin: 0;
        font-size: 13px;
        font-weight: 500;
        word-break: break-word;
    }

    .done {
        width: max-content;
        padding: 10px 16px;
        font-weight: 500;
    }

    .box .steps {
        margin: 0;
        padding-left: 22px;
        line-height: 1.8;
    }

    .danger {
        background: var(--red);
        color: var(--white);
        box-shadow: none;
    }

    @media (hover: hover) {
        .danger:hover {
            background: var(--dark-red);
        }
    }
</style>
