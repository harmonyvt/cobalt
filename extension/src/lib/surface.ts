// The in-page button. Styles live in the button's shadow root, and the host element
// is pinned with inline !important, so a site's `button { background: white }` or
// `span { border-radius: 999px }` cannot turn the capybara into a disc.

import { ACCENT, BAD, OK } from "./brand";
import { spriteCss } from "./view";

export type SurfaceKind = "icon" | "pill" | "rail";

const ARC_R = 15.5;
const ARC_C = (2 * Math.PI * ARC_R).toFixed(3);

export function themeFromSignals(s: { hint: string; scheme: string; luminance: number | null; prefersDark: boolean }): "dark" | "light" {
    const hinted = themeToken(s.hint);
    if (hinted) return hinted;
    const scheme = themeToken(s.scheme);
    if (scheme) return scheme;
    if (s.luminance !== null) return s.luminance < 0.45 ? "dark" : "light";
    return s.prefersDark ? "dark" : "light";
}

function themeToken(value: string): "dark" | "light" | null {
    const v = value.toLowerCase();
    const dark = /(^|[^a-z])dark([^a-z]|$)/.test(v);
    const light = /(^|[^a-z])light([^a-z]|$)/.test(v);
    if (dark && !light) return "dark";
    if (light && !dark) return "light";
    return null;
}

function readLuminance(el: Element | null): number | null {
    if (!el || typeof getComputedStyle !== "function") return null;
    const c = getComputedStyle(el).backgroundColor;
    const m = /rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:[,\s/]+([\d.]+%?))?\s*\)/.exec(c);
    if (!m) return null;
    const alpha = m[4] === undefined ? 1 : m[4].endsWith("%") ? Number(m[4]) / 100 : Number(m[4]);
    if (!(alpha > 0.35)) return null;
    const lin = (channel: number) => (channel <= 0.03928 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4);
    const [r, g, b] = [Number(m[1]), Number(m[2]), Number(m[3])].map((v) => lin(v / 255));
    return 0.2126 * r! + 0.7152 * g! + 0.0722 * b!;
}

/** Site theme first (data-theme, color-scheme, the page's own background), then the OS preference. */
export function pageTheme(doc: Document): "dark" | "light" {
    const root = doc.documentElement;
    const hint = `${root.getAttribute("data-theme") ?? ""} ${root.getAttribute("data-color-mode") ?? ""} ${root.className ?? ""}`;
    let scheme = "";
    try {
        scheme = getComputedStyle(root).colorScheme || "";
    } catch {
        scheme = "";
    }
    const luminance = readLuminance(doc.body) ?? readLuminance(root);
    let prefersDark = false;
    try {
        prefersDark = doc.defaultView?.matchMedia("(prefers-color-scheme: dark)").matches === true;
    } catch {
        prefersDark = false;
    }
    return themeFromSignals({ hint, scheme, luminance, prefersDark });
}

const FONT = '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif';

export function buttonCss(kind: SurfaceKind): string {
    const hit = kind === "rail" ? 40 : kind === "pill" ? 28 : 34;
    const glyph = kind === "rail" ? spriteCss(46, 32) : kind === "pill" ? spriteCss(34, 24) : spriteCss(42, 30);
    return `
:host { all: initial; }
.cs-root, .cs-root * { box-sizing: border-box; }
.cs-root {
  all: initial;
  position: relative;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  color: var(--cs-fg);
  font-family: ${FONT};
  line-height: 1.2;
  -webkit-font-smoothing: antialiased;
}
.cs-root[data-theme="dark"] {
  color-scheme: dark;
  --cs-accent: ${ACCENT};
  --cs-ok: ${OK};
  --cs-bad: ${BAD};
  --cs-fg: #e7e9ea;
  --cs-hover: rgba(231, 233, 234, 0.12);
  --cs-toast-bg: rgba(22, 24, 28, 0.72);
  --cs-toast-fg: #f7f8f8;
  --cs-toast-line: rgba(255, 255, 255, 0.14);
  --cs-tip-bg: rgba(22, 24, 28, 0.94);
  --cs-tip-fg: #f7f8f8;
  --cs-shadow: 0 8px 28px rgba(0, 0, 0, 0.38);
}
.cs-root[data-theme="light"] {
  color-scheme: light;
  --cs-accent: ${ACCENT};
  --cs-ok: #248a18;
  --cs-bad: ${BAD};
  --cs-fg: #0f1419;
  --cs-hover: rgba(15, 20, 25, 0.08);
  --cs-toast-bg: rgba(255, 255, 255, 0.78);
  --cs-toast-fg: #0f1419;
  --cs-toast-line: rgba(15, 20, 25, 0.1);
  --cs-tip-bg: rgba(255, 255, 255, 0.96);
  --cs-tip-fg: #0f1419;
  --cs-shadow: 0 8px 28px rgba(15, 20, 25, 0.16);
}
.cs-btn {
  all: unset;
  position: relative;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 4px;
  width: ${hit}px;
  height: ${hit}px;
  padding: 0;
  border-radius: 999px;
  background: transparent;
  color: inherit;
  cursor: pointer;
  -webkit-appearance: none;
  appearance: none;
  -webkit-tap-highlight-color: transparent;
}
.cs-btn.pill {
  width: auto;
  height: 36px;
  padding: 0 12px 0 6px;
  border-radius: 999px;
}
.cs-btn:hover, .cs-btn:focus-visible { background: var(--cs-hover); outline: none; }
.cs-root.error .cs-btn { background: color-mix(in srgb, var(--cs-bad) 18%, transparent); }
.cs-hit {
  position: relative;
  width: ${hit}px;
  height: ${hit}px;
  display: grid;
  place-items: center;
  pointer-events: none;
}
.cs-btn.pill .cs-hit { width: 28px; height: 28px; }
.cs-glyph { position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%); pointer-events: none; }
.cs-word {
  font: 600 13px/1 ${FONT};
  color: inherit;
  pointer-events: none;
}
.cs-arc {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  overflow: visible;
  pointer-events: none;
  opacity: 0;
}
.cs-root.busy .cs-arc, .cs-root.saved .cs-arc { opacity: 1; }
.cs-track, .cs-value { fill: none; stroke-width: 2; }
.cs-track { stroke: var(--cs-fg); opacity: 0.2; }
.cs-root.spin .cs-track, .cs-root.saved .cs-track { opacity: 0; }
.cs-value {
  stroke: var(--cs-accent);
  stroke-linecap: round;
  stroke-dasharray: ${ARC_C};
  stroke-dashoffset: calc(${ARC_C} * (1 - var(--p, 0) / 100));
  transform-box: fill-box;
  transform-origin: center;
  transform: rotate(-90deg);
  transition: stroke-dashoffset 320ms cubic-bezier(.2, .8, .2, 1);
}
.cs-root.no-ease .cs-value { transition: none; }
.cs-root.spin .cs-value {
  stroke-dasharray: 26 71.389;
  stroke-dashoffset: 0;
  animation: cs-spin 0.9s linear infinite;
}
.cs-root.saved .cs-value { stroke: var(--cs-ok); opacity: 0; transition: opacity 200ms ease 160ms; }
.cs-check {
  position: absolute;
  right: -1px;
  bottom: -1px;
  width: 14px;
  height: 14px;
  border-radius: 999px;
  background: var(--cs-ok);
  color: #fff;
  opacity: 0;
  transform: scale(0.45);
  pointer-events: none;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.35);
}
.cs-check path {
  fill: none;
  stroke: currentColor;
  stroke-width: 2.2;
  stroke-linecap: round;
  stroke-linejoin: round;
  stroke-dasharray: 16;
  stroke-dashoffset: 16;
}
.cs-root.saved .cs-check {
  opacity: 1;
  transform: scale(1);
  transition: transform 220ms cubic-bezier(.2, 1.5, .35, 1), opacity 120ms ease;
}
.cs-root.saved .cs-check path { stroke-dashoffset: 0; transition: stroke-dashoffset 240ms ease 70ms; }
.cs-root.saved .cs-btn { animation: cs-pop 280ms ease; }
.cs-root.error .cs-btn { animation: cs-shake 420ms ease; }
.cs-tip {
  position: fixed;
  z-index: 2147483646;
  padding: 4px 7px;
  border-radius: 6px;
  background: var(--cs-tip-bg);
  color: var(--cs-tip-fg);
  font: 11px/1.2 ${FONT};
  white-space: nowrap;
  pointer-events: none;
  opacity: 0;
  box-shadow: var(--cs-shadow);
}
.cs-root.show-tip .cs-tip { opacity: 1; }
.cs-toast {
  position: fixed;
  z-index: 2147483646;
  display: inline-flex;
  align-items: center;
  gap: 8px;
  width: max-content;
  max-width: min(320px, calc(100vw - 16px));
  margin: 0;
  padding: 6px 10px 6px 7px;
  border-radius: 999px;
  background: var(--cs-toast-bg);
  color: var(--cs-toast-fg);
  border: 1px solid var(--cs-toast-line);
  box-shadow: var(--cs-shadow);
  backdrop-filter: blur(16px) saturate(1.35);
  -webkit-backdrop-filter: blur(16px) saturate(1.35);
  font: 12px/1.25 ${FONT};
  white-space: nowrap;
  opacity: 0;
  pointer-events: none;
  translate: 0 6px;
  transition: opacity 180ms ease, translate 180ms ease;
}
.cs-root.place-left .cs-toast { translate: -6px 0; }
.cs-root.place-above .cs-toast { translate: 0 -6px; }
.cs-toast.cs-in { opacity: 1; translate: 0 0; pointer-events: auto; }
.cs-toast[hidden] { display: none !important; }
.cs-toast.has-code {
  white-space: normal;
  border-radius: 14px;
  align-items: flex-start;
  flex-wrap: wrap;
  padding-top: 8px;
  padding-bottom: 8px;
}
.cs-mark { width: 16px; height: 16px; flex: none; display: block; }
.cs-mark svg { display: block; width: 16px; height: 16px; }
.cs-mark svg[hidden] { display: none !important; }
.cs-mark-work { color: var(--cs-accent); transform-origin: center; animation: cs-spin 0.9s linear infinite; }
.cs-line { overflow: hidden; text-overflow: ellipsis; min-width: 0; }
.cs-bar {
  width: 44px;
  height: 2px;
  flex: none;
  border-radius: 999px;
  background: color-mix(in srgb, var(--cs-toast-fg) 18%, transparent);
  overflow: hidden;
}
.cs-bar[hidden] { display: none !important; }
.cs-bar i {
  display: block;
  height: 100%;
  width: 0;
  border-radius: inherit;
  background: var(--cs-accent);
  transition: width 320ms cubic-bezier(.2, .8, .2, 1);
}
.cs-bar.indet i { width: 40%; animation: cs-indet 1.05s ease-in-out infinite; }
.cs-actions { display: inline-flex; align-items: center; gap: 10px; flex: none; }
.cs-actions:empty { display: none; }
.cs-toast button {
  all: unset;
  cursor: pointer;
  color: var(--cs-accent);
  font: 600 12px/1 ${FONT};
  padding: 1px 0;
  border-radius: 4px;
}
.cs-toast button:hover, .cs-toast button:focus-visible { text-decoration: underline; outline: none; }
.cs-code {
  flex-basis: 100%;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 11px;
  line-height: 1.3;
  color: color-mix(in srgb, var(--cs-toast-fg) 68%, transparent);
}
@keyframes cs-spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }
@keyframes cs-pop {
  0% { transform: scale(1); }
  40% { transform: scale(1.07); }
  100% { transform: scale(1); }
}
@keyframes cs-shake {
  0%, 100% { transform: translateX(0); }
  20% { transform: translateX(-2px); }
  40% { transform: translateX(2px); }
  60% { transform: translateX(-1.5px); }
  80% { transform: translateX(1px); }
}
@keyframes cs-indet {
  0% { transform: translateX(-120%); }
  100% { transform: translateX(280%); }
}
@media (prefers-reduced-motion: reduce) {
  .cs-value, .cs-bar i, .cs-toast, .cs-check, .cs-check path, .cs-mark-work { transition: none !important; animation: none !important; }
  .cs-root.spin .cs-value, .cs-root.saved .cs-btn, .cs-root.error .cs-btn, .cs-bar.indet i { animation: none !important; }
  .cs-bar.indet i { transform: none; width: 45%; }
  .cs-root.saved .cs-check { transform: none; }
}
${glyph}`;
}

/** Layout for the light-DOM host. Inline shieldHost() is what actually beats the page. */
export function hostCss(): string {
    return `.capystore-save{all:initial !important;display:flex !important;align-items:center !important;align-self:center !important;vertical-align:middle !important;position:relative !important;box-sizing:border-box !important;width:max-content !important;max-width:max-content !important;min-width:0 !important;flex:0 0 auto !important;justify-content:flex-start !important;margin:0 !important;padding:0 !important;border:0 !important;border-radius:0 !important;background:transparent !important;background-color:transparent !important;box-shadow:none !important;outline:none !important;line-height:0 !important;z-index:2 !important;pointer-events:auto !important;float:none !important;opacity:1 !important;filter:none !important}
.capystore-save.row{width:auto !important;max-width:none !important;flex:1 1 0% !important;justify-content:flex-start !important}
.capystore-save.rail{width:auto !important;max-width:none !important;flex:0 0 auto !important;justify-content:center !important}`;
}

/** Pin the host so a page rule like `#rail > span` cannot paint a disc behind the button. */
export function shieldHost(host: HTMLElement, fit?: "row" | "rail"): void {
    const set = (name: string, value: string) => host.style.setProperty(name, value, "important");
    if (host.dataset.shielded !== "1") {
        set("all", "initial");
        host.dataset.shielded = "1";
    }
    set("display", "flex");
    set("align-items", "center");
    set("align-self", "center");
    set("vertical-align", "middle");
    set("position", "relative");
    set("box-sizing", "border-box");
    set("justify-content", fit === "rail" ? "center" : "flex-start");
    set("width", fit === "row" ? "auto" : "max-content");
    set("max-width", fit === "row" ? "none" : "max-content");
    set("min-width", "0");
    set("flex", fit === "row" ? "1 1 0%" : "0 0 auto");
    set("margin", "0");
    set("padding", "0");
    set("border", "0");
    set("border-radius", "0");
    set("background", "transparent");
    set("background-color", "transparent");
    set("box-shadow", "none");
    set("outline", "none");
    set("line-height", "0");
    set("z-index", "2");
    set("pointer-events", "auto");
    set("float", "none");
    set("opacity", "1");
    set("filter", "none");
}
