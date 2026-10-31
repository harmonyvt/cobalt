<script lang="ts">
    import { onMount } from "svelte";

    import settings from "$lib/state/settings";
    import { t, INTERNAL_locale } from "$lib/i18n/translations";
    import {
        accountsAvailable,
        getMe,
        listSessions,
        revokeSession,
        signOut,
        signOutOthers,
        signedOut,
        type AccountResult,
        type Me,
        type Session,
    } from "$lib/api/accounts";

    import SettingsCategory from "$components/settings/SettingsCategory.svelte";

    import IconBrowser from "@tabler/icons-svelte/IconBrowser.svelte";
    import IconDeviceDesktop from "@tabler/icons-svelte/IconDeviceDesktop.svelte";
    import IconDeviceMobile from "@tabler/icons-svelte/IconDeviceMobile.svelte";
    import IconDeviceTablet from "@tabler/icons-svelte/IconDeviceTablet.svelte";

    type LoadState = "loading" | "hidden" | "ready" | "failed";

    let loadState: LoadState = "loading";
    let loadError = "";
    let me: Me | null = null;
    let sessions: Session[] = [];

    let confirming: string | null = null; // session id, "others" or "self"
    let busy = false;
    let error = "";
    let notice = "";

    // the account section only exists on the fork's api (features.accounts)
    // and when this browser holds a key
    $: hasKey =
        $settings.processing.enableCustomApiKey &&
        $settings.processing.customApiKey.length > 0;

    const icons: Record<string, typeof IconBrowser> = {
        ios: IconDeviceMobile,
        ipados: IconDeviceTablet,
        mac: IconDeviceDesktop,
        web: IconBrowser,
    };

    const formatDate = (ms: number) => {
        const diff = ms - Date.now();
        const abs = Math.abs(diff);
        const locale = $INTERNAL_locale || undefined;

        try {
            if (abs < 60_000) return $t("account.time.now");
            const rtf = new Intl.RelativeTimeFormat(locale, { numeric: "auto" });
            if (abs < 3_600_000) return rtf.format(Math.round(diff / 60_000), "minute");
            if (abs < 86_400_000) return rtf.format(Math.round(diff / 3_600_000), "hour");
            if (abs < 30 * 86_400_000) return rtf.format(Math.round(diff / 86_400_000), "day");
            return new Date(ms).toLocaleDateString(locale, {
                year: "numeric",
                month: "short",
                day: "numeric",
            });
        } catch {
            return new Date(ms).toDateString();
        }
    };

    const failText = (res: Extract<AccountResult<unknown>, { ok: false }>) =>
        res.reason === "signed_out"
            ? $t("account.error.signed_out")
            : res.reason === "unavailable"
              ? $t("account.error.network")
              : $t("account.error.unknown");

    const load = async () => {
        if (!hasKey) {
            loadState = "hidden";
            return;
        }

        loadState = "loading";
        if (!(await accountsAvailable())) {
            loadState = "hidden";
            return;
        }

        const [meRes, listRes] = await Promise.all([getMe(), listSessions()]);

        if (!meRes.ok || !listRes.ok) {
            const bad = (!meRes.ok ? meRes : listRes) as Extract<
                AccountResult<unknown>,
                { ok: false }
            >;
            loadError = failText(bad);
            loadState = "failed";
            return;
        }

        me = meRes.data;
        sessions = listRes.data.sessions;
        loadState = "ready";
    };

    const revoke = async (s: Session) => {
        if (busy) return;
        busy = true;
        error = "";
        notice = "";

        const res = await revokeSession(s.id);
        busy = false;

        if (res.ok || (!res.ok && res.reason === "api" && res.code === "error.api.auth.session.not_found")) {
            confirming = null;
            if (s.current) {
                await signOut();
                return;
            }
            sessions = sessions.filter((x) => x.id !== s.id);
            return;
        }

        error = failText(res);
    };

    const others = async () => {
        if (busy) return;
        busy = true;
        error = "";

        const res = await signOutOthers();
        busy = false;

        if (res.ok) {
            sessions = sessions.filter((s) => s.current);
            confirming = null;
            notice = $t("account.devices.others.done");
            return;
        }

        error = failText(res);
    };

    const leave = async () => {
        if (busy) return;
        busy = true;
        await signOut();
        busy = false;
        confirming = null;
    };

    // signing out hides the section; signing back in brings it back
    let wasSignedOut = $signedOut;
    $: if ($signedOut !== wasSignedOut) {
        wasSignedOut = $signedOut;
        if ($signedOut) {
            loadState = "hidden";
            sessions = [];
            me = null;
        } else {
            load();
        }
    }

    // the key can arrive after this page opened (automatic sign-in at startup)
    let hadKey = hasKey;
    $: if (hasKey !== hadKey) {
        hadKey = hasKey;
        if (hasKey) load();
    }

    onMount(load);

    $: others_count = sessions.filter((s) => !s.current).length;
</script>

{#if loadState !== "hidden"}
    <SettingsCategory sectionId="account" title={$t("account.title")}>
        <div class="subtext description">{$t("account.description")}</div>

        {#if loadState === "loading"}
            <div class="notice" role="status">{$t("account.loading")}</div>
        {:else if loadState === "failed"}
            <div class="notice" role="alert">
                <span>{$t("account.load_failed")} {loadError}</span>
                <button class="button" on:click={load}>{$t("account.retry")}</button>
            </div>
        {:else if me}
            <div class="card who">
                <div class="who-label subtext">{$t("account.signed_in_as")}</div>
                <div class="who-name">
                    {me.caller.email ?? $t("account.no_email")}
                </div>
                <div class="subtext">{$t("account.through_access")}</div>
            </div>

            <h4 class="list-title">{$t("account.devices.title")}</h4>

            {#if sessions.length === 0}
                <div class="subtext">{$t("account.devices.empty")}</div>
            {:else}
                <ul class="list">
                    {#each sessions as s (s.id)}
                        <li class="card item" class:confirming={confirming === s.id}>
                            <div class="row">
                                <svelte:component
                                    this={icons[s.platform] ?? IconBrowser}
                                    class="platform-icon"
                                />
                                <div class="main">
                                    <div class="name">
                                        <span>{s.device}</span>
                                        {#if s.current}
                                            <span class="badge">
                                                {$t("account.devices.this_browser")}
                                            </span>
                                        {/if}
                                    </div>
                                    <div class="meta subtext">
                                        <span>
                                            {$t("account.devices.last_used", {
                                                value: formatDate(s.last_used_at),
                                            })}
                                        </span>
                                        {#if s.country}<span>{s.country}</span>{/if}
                                    </div>
                                </div>
                                {#if !s.current && confirming !== s.id}
                                    <button
                                        class="button"
                                        aria-label="{$t('account.devices.sign_out')} {s.device}"
                                        on:click={() => {
                                            confirming = s.id;
                                            error = "";
                                        }}
                                    >
                                        {$t("account.devices.sign_out")}
                                    </button>
                                {/if}
                            </div>
                            {#if confirming === s.id}
                                <div class="confirm" role="alertdialog">
                                    <div>
                                        {$t("account.devices.sign_out.confirm", {
                                            value: s.device,
                                        })}
                                    </div>
                                    <div class="confirm-buttons">
                                        <button class="button" disabled={busy} on:click={() => (confirming = null)}>
                                            {$t("account.cancel")}
                                        </button>
                                        <button class="button danger" disabled={busy} on:click={() => revoke(s)}>
                                            {$t("account.confirm")}
                                        </button>
                                    </div>
                                </div>
                            {/if}
                        </li>
                    {/each}
                </ul>
            {/if}

            <div class="subtext">{$t("account.devices.hint")}</div>

            {#if others_count > 0}
                {#if confirming === "others"}
                    <div class="card confirm" role="alertdialog">
                        <div>{$t("account.devices.others.confirm")}</div>
                        <div class="confirm-buttons">
                            <button class="button" disabled={busy} on:click={() => (confirming = null)}>
                                {$t("account.cancel")}
                            </button>
                            <button class="button danger" disabled={busy} on:click={others}>
                                {$t("account.confirm")}
                            </button>
                        </div>
                    </div>
                {:else}
                    <button
                        class="button action"
                        on:click={() => {
                            confirming = "others";
                            error = "";
                            notice = "";
                        }}
                    >
                        {$t("account.devices.others")}
                    </button>
                {/if}
            {/if}

            {#if notice}<div class="subtext" role="status">{notice}</div>{/if}
            {#if error}<div class="error" role="alert">{error}</div>{/if}

            {#if confirming === "self"}
                <div class="card confirm" role="alertdialog">
                    <div>{$t("account.sign_out.confirm")}</div>
                    <div class="confirm-buttons">
                        <button class="button" disabled={busy} on:click={() => (confirming = null)}>
                            {$t("account.cancel")}
                        </button>
                        <button class="button danger" disabled={busy} on:click={leave}>
                            {$t("account.confirm")}
                        </button>
                    </div>
                </div>
            {:else}
                <button
                    class="button danger action"
                    on:click={() => {
                        confirming = "self";
                        error = "";
                    }}
                >
                    {$t("account.sign_out")}
                </button>
            {/if}
        {/if}
    </SettingsCategory>
{/if}

<style>
    .description {
        margin-top: -3px;
    }

    .card,
    .notice {
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
    }

    .who {
        display: flex;
        flex-direction: column;
        gap: 2px;
        padding: 12px 16px;
    }

    .who .subtext {
        padding: 0;
    }

    .who-name {
        font-weight: 500;
        font-size: 14px;
        overflow-wrap: anywhere;
    }

    .list-title {
        margin: 8px 0 0;
        font-size: 13px;
        font-weight: 500;
        color: var(--gray);
    }

    .list {
        list-style: none;
        margin: 0;
        padding: 0;
        display: flex;
        flex-direction: column;
        gap: 6px;
    }

    .item {
        display: flex;
        flex-direction: column;
        gap: 10px;
        padding: 12px 16px;
    }

    .row {
        display: flex;
        align-items: center;
        gap: 12px;
    }

    .row :global(.platform-icon) {
        height: 22px;
        width: 22px;
        stroke-width: 1.6px;
        flex-shrink: 0;
    }

    .main {
        flex: 1;
        min-width: 0;
        display: flex;
        flex-direction: column;
        gap: 2px;
    }

    .name {
        display: flex;
        align-items: center;
        gap: 8px;
        font-size: 14px;
        font-weight: 500;
        flex-wrap: wrap;
    }

    .badge {
        font-size: 11px;
        font-weight: 500;
        padding: 1px 7px;
        border-radius: 99px;
        background: var(--secondary);
        color: var(--primary);
    }

    .meta {
        display: flex;
        gap: 10px;
        flex-wrap: wrap;
        padding: 0;
        font-size: 12px;
    }

    .confirm {
        display: flex;
        flex-direction: column;
        gap: 10px;
        font-size: 13px;
    }

    .card.confirm {
        padding: 12px 16px;
    }

    .confirm-buttons {
        display: flex;
        gap: 8px;
        flex-wrap: wrap;
    }

    .action {
        align-self: flex-start;
        padding: 10px 16px;
        font-weight: 500;
    }

    .danger {
        color: var(--red);
    }

    .error {
        color: var(--red);
        font-size: 13px;
        font-weight: 500;
        padding: 0 var(--padding);
    }
</style>
