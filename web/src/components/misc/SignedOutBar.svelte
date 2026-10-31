<script lang="ts">
    import { onMount } from "svelte";

    import { t } from "$lib/i18n/translations";
    import { ensureSignedIn, signedOut, signInAgain } from "$lib/api/accounts";

    import IconCloudOff from "@tabler/icons-svelte/IconCloudOff.svelte";

    let working = false;

    onMount(ensureSignedIn);

    const signIn = async () => {
        working = true;
        await signInAgain();
        working = false;
    };
</script>

{#if $signedOut}
    <div id="signed-out-bar" role="alert">
        <IconCloudOff />
        <span class="text">{$t("account.signed_out.bar")}</span>
        <button class="button active" disabled={working} on:click={signIn}>
            {working
                ? $t("account.signed_out.working")
                : $t("account.signed_out.button")}
        </button>
    </div>
{/if}

<style>
    #signed-out-bar {
        position: fixed;
        top: 0;
        left: 0;
        right: 0;
        z-index: 100;
        display: flex;
        align-items: center;
        justify-content: center;
        gap: 10px;
        padding: calc(env(safe-area-inset-top) + 6px) 12px 6px;
        background: var(--orange, #f5a623);
        color: #000;
        font-size: 13px;
        font-weight: 500;
    }

    #signed-out-bar :global(svg) {
        height: 18px;
        width: 18px;
        stroke-width: 1.8px;
        flex-shrink: 0;
    }

    .text {
        min-width: 0;
    }

    button {
        padding: 5px 12px;
        font-size: 13px;
        flex-shrink: 0;
    }
</style>
