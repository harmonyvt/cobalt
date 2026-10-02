<script lang="ts">
    import { onMount, tick } from "svelte";

    import settings, { updateSetting } from "$lib/state/settings";
    import { t, INTERNAL_locale } from "$lib/i18n/translations";
    import { hapticConfirm } from "$lib/haptics";
    import {
        listKeys,
        createKey,
        revokeKey,
        type ApiKey,
        type CreatedApiKey,
        type KeysError,
    } from "$lib/api/keys";

    import CopyIcon from "$components/misc/CopyIcon.svelte";
    import SettingsCategory from "$components/settings/SettingsCategory.svelte";

    import IconPlus from "@tabler/icons-svelte/IconPlus.svelte";
    import IconRefresh from "@tabler/icons-svelte/IconRefresh.svelte";

    type LoadState = "loading" | "ready" | "expired" | "unavailable" | "failed";

    let loadState: LoadState = "loading";
    let loadError = "";
    let keys: ApiKey[] = [];

    let showForm = false;
    let name = "";
    let nameTouched = false;
    let creating = false;
    let createError = "";

    let created: CreatedApiKey | null = null;
    let copied = false;
    let copyFailed = false;

    let confirmingId: string | null = null;
    let revokingId: string | null = null;
    let revokeError = "";

    let nameInput: HTMLInputElement;
    let keyBox: HTMLElement;

    $: browserKey = $settings.processing.customApiKey;
    $: browserHasKey =
        $settings.processing.enableCustomApiKey && browserKey.length > 0;
    $: browserPrefix = browserKey.slice(0, 8);

    $: trimmedName = name.trim();
    $: nameValid = trimmedName.length >= 1 && trimmedName.length <= 40;

    // the reveal checkbox mirrors what settings actually hold
    $: usedHere =
        created !== null &&
        $settings.processing.enableCustomApiKey &&
        $settings.processing.customApiKey === created.key;

    // a short guess like "mac · chrome" for the name field
    const guessDevice = () => {
        if (typeof navigator === "undefined") return "";
        const ua = navigator.userAgent;

        const os = /iPhone|iPad|iPod/.test(ua)
            ? "ios"
            : /Android/.test(ua)
              ? "android"
              : /Mac OS X|Macintosh/.test(ua)
                ? "mac"
                : /Windows/.test(ua)
                  ? "windows"
                  : /CrOS/.test(ua)
                    ? "chromeos"
                    : /Linux/.test(ua)
                      ? "linux"
                      : "";

        const browser = /Edg\//.test(ua)
            ? "edge"
            : /OPR\/|Opera/.test(ua)
              ? "opera"
              : /Firefox\/|FxiOS/.test(ua)
                ? "firefox"
                : /Chrome\/|CriOS/.test(ua)
                  ? "chrome"
                  : /Safari\//.test(ua)
                    ? "safari"
                    : "";

        return [os, browser].filter(Boolean).join(" · ").slice(0, 40);
    };

    const formatDate = (ms: number) => {
        const date = new Date(ms);
        const diff = ms - Date.now();
        const abs = Math.abs(diff);
        const locale = $INTERNAL_locale || undefined;

        try {
            if (abs < 60_000) return $t("apikeys.time.now");

            const rtf = new Intl.RelativeTimeFormat(locale, { numeric: "auto" });
            if (abs < 3_600_000) return rtf.format(Math.round(diff / 60_000), "minute");
            if (abs < 86_400_000) return rtf.format(Math.round(diff / 3_600_000), "hour");
            if (abs < 30 * 86_400_000) return rtf.format(Math.round(diff / 86_400_000), "day");

            return date.toLocaleDateString(locale, {
                year: "numeric",
                month: "short",
                day: "numeric",
            });
        } catch {
            return date.toDateString();
        }
    };

    const errorText = (e: KeysError) => {
        if (e.reason === "unavailable") return $t("apikeys.error.network");
        if (e.reason === "expired") return $t("apikeys.error.unauthorized");

        const known = [
            "unauthorized",
            "forbidden",
            "bad_request",
            "not_found",
            "too_many_keys",
            "server_error",
        ];
        return known.includes(e.code)
            ? $t(`apikeys.error.${e.code}`)
            : $t("apikeys.error.unknown");
    };

    const load = async () => {
        loadState = "loading";
        const res = await listKeys();

        if (res.ok) {
            keys = res.data;
            loadState = "ready";

            if (!browserHasKey && !created) {
                openForm();
            }
            return;
        }

        if (res.reason === "expired") {
            loadState = "expired";
        } else if (res.reason === "unavailable") {
            loadState = "unavailable";
        } else {
            loadError = errorText(res);
            loadState = "failed";
        }
    };

    const openForm = () => {
        name = guessDevice();
        nameTouched = false;
        createError = "";
        showForm = true;
    };

    const openFormAndFocus = async () => {
        openForm();
        await tick();
        nameInput?.focus();
        nameInput?.select();
    };

    const closeForm = () => {
        showForm = false;
        createError = "";
    };

    const applyToBrowser = (key: string) => {
        updateSetting({
            processing: { enableCustomApiKey: true, customApiKey: key },
        });
    };

    const create = async () => {
        nameTouched = true;
        if (!nameValid || creating) return;

        creating = true;
        createError = "";

        const useHere = !browserHasKey;
        const res = await createKey(trimmedName);
        creating = false;

        if (!res.ok) {
            if (res.reason === "expired") {
                loadState = "expired";
                return;
            }
            createError = errorText(res);
            return;
        }

        hapticConfirm();

        created = res.data;
        copied = false;
        copyFailed = false;
        showForm = false;

        const { key: _key, ...listed } = res.data;
        keys = [listed, ...keys];

        // apply right away: the key is only shown once, so a reload before
        // pressing "done" must not leave this browser without it
        if (useHere) applyToBrowser(res.data.key);

        await tick();
        keyBox?.focus();
    };

    const toggleUseHere = (e: Event) => {
        if (!created) return;

        if ((e.currentTarget as HTMLInputElement).checked) {
            applyToBrowser(created.key);
        } else if ($settings.processing.customApiKey === created.key) {
            updateSetting({
                processing: { enableCustomApiKey: false, customApiKey: "" },
            });
        }
    };

    const copyKey = async () => {
        if (!created) return;

        try {
            await navigator.clipboard.writeText(created.key);
            copyFailed = false;
            copied = true;
            setTimeout(() => (copied = false), 1500);
        } catch {
            copied = false;
            copyFailed = true;
            // let the person copy by hand
            const range = document.createRange();
            range.selectNodeContents(keyBox);
            const selection = window.getSelection();
            selection?.removeAllRanges();
            selection?.addRange(range);
        }
    };

    const dismissCreated = () => {
        created = null;
        copied = false;
        copyFailed = false;
    };

    const revoke = async (key: ApiKey) => {
        if (revokingId) return;

        revokingId = key.id;
        revokeError = "";
        const res = await revokeKey(key.id);
        revokingId = null;

        if (!res.ok && res.reason === "expired") {
            loadState = "expired";
            return;
        }

        if (res.ok || (res.reason === "api" && res.code === "not_found")) {
            keys = keys.filter((k) => k.id !== key.id);
            confirmingId = null;
            return;
        }

        revokeError = errorText(res);
    };

    const isBrowserKey = (key: ApiKey) =>
        browserKey.length > 0 && key.prefix === browserPrefix;

    onMount(load);
</script>

<SettingsCategory sectionId="api-keys" title={$t("apikeys.title")}>
    <div class="subtext description">{$t("apikeys.description")}</div>

    {#if loadState === "loading"}
        <div class="notice" role="status">{$t("apikeys.loading")}</div>
    {:else if loadState === "expired"}
        <div class="notice" role="alert">
            <span>{$t("apikeys.expired")}</span>
            <button class="button active" on:click={() => location.reload()}>
                <IconRefresh />
                {$t("apikeys.reload")}
            </button>
        </div>
    {:else if loadState === "unavailable"}
        <div class="subtext quiet" role="status">
            {$t("apikeys.unavailable")}
        </div>
    {:else if loadState === "failed"}
        <div class="notice" role="alert">
            <span>{$t("apikeys.load_failed")} {loadError}</span>
            <button class="button" on:click={load}>
                {$t("apikeys.retry")}
            </button>
        </div>
    {:else}
        {#if !browserHasKey && !created}
            <div class="first-run">
                <div class="first-run-text">
                    <h4>{$t("apikeys.first_run.title")}</h4>
                    <div class="subtext">{$t("apikeys.first_run.body")}</div>
                </div>
                {#if !showForm}
                    <button
                        class="button active create-main"
                        on:click={openFormAndFocus}
                    >
                        <IconPlus />
                        {$t("apikeys.create_for_browser")}
                    </button>
                {/if}
            </div>
        {/if}

        {#if created}
            <div class="reveal" role="group" aria-labelledby="created-title">
                <h4 id="created-title">{$t("apikeys.created.title")}</h4>
                <div class="subtext warning">
                    {$t("apikeys.created.warning")}
                </div>

                <div class="key-row">
                    <code
                        class="key-box"
                        bind:this={keyBox}
                        tabindex="-1"
                        aria-label={$t("apikeys.created.title")}
                    >{created.key}</code>
                    <button
                        class="button copy-button"
                        on:click={copyKey}
                        aria-label={$t("apikeys.created.copy")}
                    >
                        <CopyIcon check={copied} regularIcon />
                        <span class="copy-label">
                            {copied
                                ? $t("apikeys.created.copied")
                                : $t("apikeys.created.copy")}
                        </span>
                    </button>
                </div>
                <div class="subtext" role="status">
                    {#if copyFailed}{$t("apikeys.created.copy_failed")}{/if}
                </div>

                <div class="header-hint">
                    <span class="subtext">{$t("apikeys.created.header")}</span>
                    <code class="header-code"
                        >Authorization: Api-Key {created.key}</code
                    >
                </div>

                <label class="check-row">
                    <input
                        type="checkbox"
                        checked={usedHere}
                        on:change={toggleUseHere}
                    />
                    <span>{$t("apikeys.created.use_here")}</span>
                </label>
                {#if usedHere}
                    <div class="subtext saved" role="status">
                        {$t("apikeys.created.use_here.saved")}
                    </div>
                {/if}

                <button class="button active done" on:click={dismissCreated}>
                    {$t("apikeys.created.done")}
                </button>
            </div>
        {/if}

        {#if showForm}
            <form class="create-form" on:submit|preventDefault={create}>
                <label for="apikey-name">{$t("apikeys.name.label")}</label>
                <div class="input-row">
                    <div class="input-container" class:invalid={nameTouched && !nameValid}>
                        <input
                            id="apikey-name"
                            class="input-box"
                            bind:this={nameInput}
                            bind:value={name}
                            on:input={() => (nameTouched = true)}
                            maxlength="40"
                            spellcheck="false"
                            autocomplete="off"
                            autocapitalize="off"
                            aria-invalid={nameTouched && !nameValid}
                            aria-describedby="apikey-name-hint"
                            disabled={creating}
                        />
                    </div>
                    <button
                        class="button active"
                        type="submit"
                        disabled={creating || !nameValid}
                    >
                        {creating
                            ? $t("apikeys.creating")
                            : browserHasKey
                              ? $t("apikeys.create_button")
                              : $t("apikeys.create_for_browser")}
                    </button>
                    {#if browserHasKey || created}
                        <button
                            class="button"
                            type="button"
                            on:click={closeForm}
                            disabled={creating}
                        >
                            {$t("apikeys.cancel")}
                        </button>
                    {/if}
                </div>
                <div id="apikey-name-hint" class="subtext">
                    {nameTouched && !nameValid
                        ? $t("apikeys.name.error")
                        : $t("apikeys.name.hint")}
                </div>
                {#if createError}
                    <div class="error" role="alert">{createError}</div>
                {/if}
            </form>
        {:else if browserHasKey || created}
            <button class="button create-secondary" on:click={openFormAndFocus}>
                <IconPlus />
                {$t("apikeys.create_another")}
            </button>
        {/if}

        <div class="list-section">
            <h4 class="list-title">{$t("apikeys.list.title")}</h4>

            {#if keys.length === 0}
                <div class="subtext">{$t("apikeys.list.empty")}</div>
            {:else}
                <ul class="key-list">
                    {#each keys as key (key.id)}
                        <li class="key-item" class:confirming={confirmingId === key.id}>
                            <div class="key-main">
                                <div class="key-title">
                                    <span class="key-name">{key.name}</span>
                                    {#if isBrowserKey(key)}
                                        <span class="badge">
                                            {$t("apikeys.list.this_browser")}
                                        </span>
                                    {/if}
                                </div>
                                <div class="key-meta">
                                    <code class="prefix">{key.prefix}…</code>
                                    <span>
                                        {$t("apikeys.list.created", {
                                            value: formatDate(key.created_at),
                                        })}
                                    </span>
                                    <span>
                                        {key.last_used_at === null
                                            ? $t("apikeys.list.never")
                                            : $t("apikeys.list.last_used", {
                                                  value: formatDate(key.last_used_at),
                                              })}
                                    </span>
                                </div>
                            </div>

                            {#if confirmingId !== key.id}
                                <button
                                    class="button revoke"
                                    aria-label="{$t('apikeys.revoke')} {key.name}"
                                    on:click={() => {
                                        confirmingId = key.id;
                                        revokeError = "";
                                    }}
                                >
                                    {$t("apikeys.revoke")}
                                </button>
                            {:else}
                                <div class="confirm" role="alertdialog" aria-label={$t("apikeys.revoke")}>
                                    <div class="confirm-text">
                                        {$t("apikeys.revoke.confirm", {
                                            value: key.name,
                                        })}
                                        {#if isBrowserKey(key)}
                                            <strong>
                                                {$t("apikeys.revoke.confirm_here")}
                                            </strong>
                                        {/if}
                                    </div>
                                    {#if revokeError}
                                        <div class="error" role="alert">
                                            {revokeError}
                                        </div>
                                    {/if}
                                    <div class="confirm-buttons">
                                        <button
                                            class="button"
                                            disabled={revokingId === key.id}
                                            on:click={() => (confirmingId = null)}
                                        >
                                            {$t("apikeys.cancel")}
                                        </button>
                                        <button
                                            class="button danger"
                                            disabled={revokingId === key.id}
                                            on:click={() => revoke(key)}
                                        >
                                            {revokingId === key.id
                                                ? $t("apikeys.revoking")
                                                : $t("apikeys.revoke.confirm_button")}
                                        </button>
                                    </div>
                                </div>
                            {/if}
                        </li>
                    {/each}
                </ul>
            {/if}
        </div>
    {/if}
</SettingsCategory>

<style>
    .description {
        margin-top: -3px;
    }

    .notice,
    .first-run,
    .reveal,
    .create-form,
    .key-item {
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

    .notice :global(svg),
    .create-main :global(svg),
    .create-secondary :global(svg) {
        height: 19px;
        width: 19px;
        stroke-width: 1.8px;
        flex-shrink: 0;
    }

    .quiet {
        padding: 0 var(--padding);
    }

    .first-run {
        display: flex;
        flex-direction: column;
        align-items: flex-start;
        gap: 12px;
        padding: 16px;
    }

    .first-run-text {
        display: flex;
        flex-direction: column;
        gap: 4px;
    }

    .first-run-text .subtext {
        padding: 0;
    }

    .create-main {
        padding: 10px 16px;
        font-weight: 500;
    }

    .create-secondary {
        width: max-content;
        padding: 8px 14px;
    }

    /* reveal box */
    .reveal {
        display: flex;
        flex-direction: column;
        gap: 10px;
        padding: 16px;
    }

    .reveal .subtext {
        padding: 0;
    }

    .warning {
        color: var(--secondary);
    }

    .key-row {
        display: flex;
        gap: 6px;
    }

    .key-box,
    .header-code {
        font-family: "IBM Plex Mono", monospace;
        font-size: 13px;
        background: var(--primary);
        color: var(--secondary);
        border-radius: var(--border-radius);
        box-shadow: 0 0 0 1px var(--input-border) inset;
        padding: 10px 12px;
        user-select: all;
        -webkit-user-select: all;
        word-break: break-all;
        line-height: 1.4;
    }

    .key-box {
        flex: 1;
        min-width: 0;
    }

    .key-box:focus-visible {
        outline: var(--focus-ring);
        outline-offset: var(--focus-ring-offset);
    }

    .copy-button {
        padding: 0 12px;
        flex-shrink: 0;
        font-size: 13px;
        font-weight: 500;
        background: var(--button-elevated);
        box-shadow: none;
    }

    .header-hint {
        display: flex;
        flex-direction: column;
        gap: 6px;
    }

    .header-code {
        display: block;
        font-size: 12px;
    }

    .check-row {
        display: flex;
        align-items: center;
        gap: 8px;
        font-size: 14px;
        font-weight: 500;
        cursor: pointer;
        width: max-content;
        max-width: 100%;
    }

    .check-row input {
        width: 18px;
        height: 18px;
        margin: 0;
        accent-color: var(--secondary);
        cursor: pointer;
    }

    .check-row input:focus-visible {
        outline: var(--focus-ring);
        outline-offset: 2px;
    }

    .saved {
        margin-top: -6px;
    }

    .done {
        width: max-content;
        padding: 8px 18px;
    }

    /* create form */
    .create-form {
        display: flex;
        flex-direction: column;
        gap: 8px;
        padding: 16px;
    }

    .create-form label {
        font-size: 12.5px;
        font-weight: 500;
    }

    .create-form .subtext {
        padding: 0;
    }

    .input-row {
        display: flex;
        gap: 6px;
        flex-wrap: wrap;
    }

    .input-row > .button {
        padding: 0 16px;
        min-height: 40px;
        font-size: 13px;
        font-weight: 500;
    }

    .input-container {
        flex: 1 1 200px;
        min-width: 0;
        display: flex;
        border-radius: var(--border-radius);
        background: var(--primary);
        box-shadow: 0 0 0 1px var(--input-border) inset;
    }

    .input-container:focus-within {
        box-shadow: 0 0 0 2px var(--secondary) inset;
    }

    .input-container.invalid {
        box-shadow: 0 0 0 2px var(--red) inset;
    }

    .input-box {
        flex: 1;
        min-width: 0;
        background: transparent;
        color: var(--secondary);
        border: none;
        outline: none;
        padding: 11.5px 16px;
        font-size: 13px;
        font-weight: 500;
    }

    button[disabled] {
        opacity: 0.5;
        pointer-events: none;
    }

    .error {
        color: var(--red);
        font-size: 12.5px;
        font-weight: 500;
        line-height: 1.4;
    }

    /* list */
    .list-section {
        display: flex;
        flex-direction: column;
        gap: 8px;
        margin-top: 4px;
    }

    .list-title {
        padding: 0 var(--padding);
        color: var(--gray);
        font-size: 12.5px;
        font-weight: 500;
    }

    .list-section > .subtext {
        padding-inline: var(--padding);
    }

    .key-list {
        list-style: none;
        margin: 0;
        padding: 0;
        display: flex;
        flex-direction: column;
        gap: 6px;
    }

    .key-item {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 12px;
        padding: 12px 16px;
    }

    .key-item.confirming {
        flex-direction: column;
        align-items: stretch;
    }

    .key-main {
        display: flex;
        flex-direction: column;
        gap: 4px;
        min-width: 0;
    }

    .key-title {
        display: flex;
        align-items: center;
        gap: 8px;
        flex-wrap: wrap;
    }

    .key-name {
        font-size: 14.5px;
        font-weight: 500;
        overflow-wrap: anywhere;
    }

    .badge {
        font-size: 11px;
        font-weight: 500;
        padding: 2px 8px;
        border-radius: 99px;
        background: var(--secondary);
        color: var(--primary);
        white-space: nowrap;
    }

    .key-meta {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: 2px 12px;
        font-size: 12.5px;
        font-weight: 500;
        color: var(--gray);
    }

    .prefix {
        font-family: "IBM Plex Mono", monospace;
        font-size: 12px;
    }

    .revoke {
        flex-shrink: 0;
        padding: 6px 12px;
        font-size: 13px;
        background: var(--button-elevated);
        box-shadow: none;
    }

    .confirm {
        display: flex;
        flex-direction: column;
        gap: 10px;
    }

    .confirm-text {
        font-size: 13px;
        font-weight: 500;
        line-height: 1.45;
        display: flex;
        flex-direction: column;
        gap: 6px;
    }

    .confirm-buttons {
        display: flex;
        gap: 6px;
        flex-wrap: wrap;
    }

    .confirm-buttons .button {
        padding: 8px 14px;
        font-size: 13px;
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

    @media screen and (max-width: 750px) {
        .key-item:not(.confirming) {
            flex-wrap: wrap;
        }

        .key-row {
            flex-direction: column;
        }

        .copy-button {
            min-height: 40px;
            justify-content: center;
        }

        .notice {
            flex-direction: column;
            align-items: flex-start;
        }
    }
</style>
