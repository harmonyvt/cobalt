// Capystore's accent is the web app's blue (`--blue` in web/src/app.css, #2f8af9).
// Green and red are the same tokens the web app uses for success and failure.

export const ACCENT = "#2f8af9";
export const OK = "#30bd1b";
export const BAD = "#ed2236";

/** Toolbar badge. A count uses the accent; a finished save is green; a failure is red. */
export function badgeColor(mark?: string): string {
    if (mark === "!") return BAD;
    if (mark === "✓") return OK;
    return ACCENT;
}
