// Terminal text as plain data, for the terminal view (box_run, box_pull). No DOM here, so test/mcp-app-terminal.test.ts
// runs it under node. Command output is untrusted: these functions only split and classify it; the view puts every piece
// in through textContent, never as HTML.

// ANSI SGR colours the panel draws (classes a30..a37, a90..a97 in style.css); 256-colour codes 0..15 map onto them
const FG = (n) => (n >= 30 && n <= 37) || (n >= 90 && n <= 97);
// ESC [ params final (CSI), ESC ] ... BEL or ESC \ (OSC), or ESC and one more character
const ESC_RE = /\x1b\[([0-9;:?]*)([ -\/]*[@-~])|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b[\s\S]?/g;
// what is left of the control characters after the sequences are gone (tab stays)
const CTRL_RE = /[\x00-\x08\x0b-\x1f\x7f]/g;

// one SGR sequence applied to the state { fg, b, d, u }
function sgr(st, params) {
    const p = params === "" ? [0] : params.split(/[;:]/).map((x) => (x === "" ? 0 : Number(x)));
    for (let i = 0; i < p.length; i++) {
        const c = p[i];
        if (c === 0) Object.assign(st, { fg: null, b: false, d: false, u: false });
        else if (c === 1) st.b = true;
        else if (c === 2) st.d = true;
        else if (c === 4) st.u = true;
        else if (c === 22) st.b = st.d = false;
        else if (c === 24) st.u = false;
        else if (FG(c)) st.fg = c;
        else if (c === 39) st.fg = null;
        else if (c === 38 || c === 48) {
            // 38;5;n or 38;2;r;g;b (and the same for the background, which is not drawn): skip their numbers
            if (p[i + 1] === 5) {
                const n = p[i + 2];
                if (c === 38) st.fg = n >= 0 && n < 8 ? 30 + n : n >= 8 && n < 16 ? 82 + n : null;
                i += 2;
            } else if (p[i + 1] === 2) {
                if (c === 38) st.fg = null;
                i += 4;
            }
        }
        // backgrounds (40-47, 100-107, 49), italics, blink, inverse: not drawn
    }
}
const clsOf = (st) => [st.fg ? "a" + st.fg : "", st.b ? "ab" : "", st.d ? "ad" : "", st.u ? "au" : ""].filter(Boolean).join(" ");

// one line (no \n, no \r) into runs of { t: text, c: class names }; `st` carries over to the next line, as in a terminal
function ansiRuns(line, st, emit) {
    const out = [];
    let last = 0;
    const put = (t) => {
        t = t.replace(CTRL_RE, "");
        if (!t) return;
        const c = clsOf(st);
        const prev = out[out.length - 1];
        if (prev && prev.c === c) prev.t += t;
        else out.push({ t, c });
    };
    ESC_RE.lastIndex = 0;
    let m;
    while ((m = ESC_RE.exec(line))) {
        put(line.slice(last, m.index));
        last = ESC_RE.lastIndex;
        if (m[2] === "m") sgr(st, m[1]);
    }
    put(line.slice(last));
    return emit ? out : null;
}

// Output text into lines of runs. A line overwritten with \r (a progress bar) keeps its last non-empty part; \r\n is a
// plain line end; a final newline makes no empty last line; colours carry across lines until reset.
function ansiLines(text) {
    if (typeof text !== "string" || text === "") return [];
    const st = { fg: null, b: false, d: false, u: false };
    const lines = text.replace(/\r+\n/g, "\n").split("\n");
    if (lines[lines.length - 1] === "") lines.pop();
    return lines.map((line) => {
        const parts = line.split("\r");
        let keep = parts.length - 1;
        while (keep > 0 && parts[keep].replace(ESC_RE, "") === "") keep--;
        // the overwritten parts still change the colour state
        for (let i = 0; i < keep; i++) ansiRuns(parts[i], st, false);
        const runs = ansiRuns(parts[keep], st, true);
        for (let i = keep + 1; i < parts.length; i++) ansiRuns(parts[i], st, false);
        return runs;
    });
}

// the same text with no colours, as a person would copy it from a terminal
const plainText = (text) => ansiLines(text).map((l) => l.map((r) => r.t).join("")).join("\n");

// workbench-rules' Clip marks a stream cut past 8 KB with this line
const isCutLine = (runs) => runs.length === 1 && /^… \(\d+ bytes cut\) …$/.test(runs[0].t);

// a size the way `ls -lh` writes it: 96, 412K, 1.8M, 28M (powers of 1024, rounded up, one decimal under 10)
function lsSize(n) {
    if (typeof n !== "number" || !isFinite(n) || n < 0) return "";
    if (n < 1024) return String(Math.round(n));
    const units = ["K", "M", "G", "T"];
    let v = n / 1024;
    let i = 0;
    while (v >= 1024 && i < units.length - 1) {
        v /= 1024;
        i++;
    }
    if (v < 10) {
        const r = Math.ceil(v * 10) / 10;
        return (r >= 10 ? String(Math.ceil(r)) : r.toFixed(1)) + units[i];
    }
    return Math.ceil(v) + units[i];
}

// A command into runs for a light highlight: the program (after a start, |, &&, || or ;) "cm", a flag "fl", a quoted
// string "st", the rest plain.
function cmdRuns(cmd) {
    const out = [];
    const re = /("(?:[^"\\]|\\.)*"?|'[^']*'?)|(\s+)|(\|\||&&|[|;&])|([^\s"'|;&]+)/g;
    let start = true;
    let m;
    while ((m = re.exec(String(cmd || "")))) {
        if (m[1]) out.push({ t: m[1], c: "st" });
        else if (m[2]) out.push({ t: m[2], c: "" });
        else if (m[3]) {
            out.push({ t: m[3], c: "" });
            start = true;
        } else {
            const w = m[4];
            const c = start && !/=/.test(w) ? "cm" : /^-{1,2}[A-Za-z]/.test(w) ? "fl" : "";
            if (c === "cm") start = false;
            out.push({ t: w, c });
        }
        if (m[1]) start = false;
    }
    return out;
}
