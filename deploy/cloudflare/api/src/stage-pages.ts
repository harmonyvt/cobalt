// The two public pages of stage (APP-API-CONTRACT.md section 30): the 1080p stream canvas that OBS loads as a
// Browser Source (30.5), and the viewer store (30.7), plus the tiny page the store becomes while it is locked.
// Pure strings, no I/O. Each page is self-contained (inline CSS and JS); the only external requests are the
// IBM Plex Mono stylesheet and font files. Only `stageBaseUrl` and the Twitch client id are ever interpolated,
// both HTML-escaped into data attributes; titles and names come from JSON at runtime and go in with textContent.
// The scripts are written with String.raw so a regex or an escape in them reaches the browser unchanged: keep
// backticks and dollar-brace out of the script text.

const FONT_LINKS =
    '<link rel="preconnect" href="https://fonts.googleapis.com">' +
    '<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>' +
    '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&amp;display=swap">';

const esc = (s: string): string =>
    s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

const withSlash = (u: string): string => (u.endsWith("/") ? u : u + "/");

// ---------------------------------------------------------------------------------------------------------------
// The canvas (30.5, 30.6)
// ---------------------------------------------------------------------------------------------------------------

const LIVE_CSS = String.raw`
html,body{margin:0;height:100%;overflow:hidden;background:transparent}
body{font-family:'IBM Plex Mono',ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color:#e1e1e1}
#stage{position:absolute;left:0;top:0;width:1920px;height:1080px;overflow:hidden;transform-origin:0 0;background:#000}
#stage.clear,#stage.off{background:transparent}
body[data-preview="1"] #stage.off{background:#000}
#stage.off .layer{display:none!important}
.tile{position:absolute;display:none;background:#0b0b0b;box-shadow:0 8px 30px rgba(0,0,0,.55)}
.tile img,.tile video{display:block;width:100%;height:100%;object-fit:cover}
.tile.pop{animation:pop .55s cubic-bezier(.2,.9,.3,1.15) both}
.tile.out{opacity:0;transition:opacity .45s ease-out}
@keyframes pop{from{opacity:0;transform:scale(.82)}to{opacity:1;transform:scale(1)}}
#spot{position:absolute;display:none;z-index:100000;box-shadow:0 30px 90px rgba(0,0,0,.8)}
#spot.spotin{animation:spot .7s cubic-bezier(.2,.9,.3,1.1) both}
@keyframes spot{from{opacity:0;transform:scale(.7) rotate(-2deg)}to{opacity:1;transform:scale(1) rotate(0)}}
#spmedia{position:relative;box-sizing:border-box;border:5px solid #2f8af9;background:#000;overflow:hidden}
#spmedia img,#spmedia video{display:block;width:100%;height:100%;object-fit:cover}
#spcap{background:#000;padding:14px 18px 16px;display:flex;flex-direction:column;gap:6px;border:5px solid #2f8af9;border-top:0}
#spby{display:flex;align-items:center;gap:10px;font-size:18px;color:#8f8f8f}
#sppin{margin-left:auto;color:#f0b44c;display:none}
#sptitle{font-size:24px;font-weight:500;color:#fff;line-height:1.25;word-break:break-word}
#chaosrow{position:absolute;left:0;right:0;top:40px;display:none;justify-content:center;z-index:100002;pointer-events:none}
#chaos{background:#000;border:2px solid #f0b44c;border-radius:999px;padding:12px 28px;display:flex;align-items:center;gap:14px;font-size:22px;font-weight:600;color:#f0b44c;white-space:nowrap;animation:slide .45s cubic-bezier(.2,.9,.3,1) both}
#chaosdot{width:12px;height:12px;border-radius:50%;background:#f0b44c;display:inline-block;animation:pulse 1.2s ease-in-out infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.35}}
#toast{position:absolute;left:48px;bottom:48px;z-index:100001;background:rgba(0,0,0,.86);border:1px solid #383838;border-radius:14px;padding:18px 24px;display:none;gap:16px;align-items:center;max-width:760px}
#toast.in{animation:slide .45s cubic-bezier(.2,.9,.3,1) both}
@keyframes slide{from{opacity:0;transform:translateY(30px)}to{opacity:1;transform:translateY(0)}}
#toast .col{display:flex;flex-direction:column;gap:4px;min-width:0}
#tl1{font-size:22px;color:#fff;word-break:break-word}
#tl1 b{font-weight:600}
#tl1 .m{color:#8f8f8f}
#tl1 .a{color:#b69cff;font-weight:600}
#tl2{font-size:18px;color:#c4c4c4;word-break:break-word}
#hint{position:absolute;right:40px;bottom:40px;z-index:100001;background:rgba(0,0,0,.82);border-radius:12px;padding:12px 18px;font-size:18px;color:#e1e1e1;display:none}
#hint b{color:#fff;font-weight:600}
body[data-ambient="1"] #toast,body[data-ambient="1"] #hint,body[data-ambient="1"] #chaosrow,body[data-ambient="1"] #spcap{display:none!important}
`;

const LIVE_BODY = String.raw`
<div id="stage" class="off" aria-hidden="true">
  <div id="tiles" class="layer"></div>
  <div id="spot" class="layer">
    <div id="spmedia"><img id="spimg" alt=""><video id="spvid" playsinline muted preload="auto"></video></div>
    <div id="spcap">
      <div id="spby">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#2f8af9" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M11 5 6 9H2v6h4l5 4V5z"></path><path d="M15.5 8.5a5 5 0 0 1 0 7"></path><path d="M19 5a10 10 0 0 1 0 14"></path></svg>
        <span id="spwho"></span>
        <span id="sppin">pinned</span>
      </div>
      <div id="sptitle"></div>
    </div>
  </div>
  <div id="chaosrow" class="layer"><div id="chaos"><span id="chaosdot"></span><span id="chaostext"></span></div></div>
  <div id="toast" class="layer">
    <svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke="#b69cff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" style="flex:none"><path d="M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9z"></path><path d="M19 15l.8 2.2L22 18l-2.2.8L19 21l-.8-2.2L16 18l2.2-.8z"></path></svg>
    <div class="col"><div id="tl1"></div><div id="tl2"></div></div>
  </div>
  <div id="hint" class="layer"></div>
</div>
`;

const LIVE_JS = String.raw`
(function () {
  'use strict';
  var body = document.body;
  var PREVIEW = body.getAttribute('data-preview') === '1' || /[?&]preview=1(&|$)/.test(location.search);
  var CLEAR_BG = /[?&]bg=(clear|transparent)(&|$)/.test(location.search);
  // ambient: the wallpaper and screensaver mode. Silent, always playing (on air or not), only the tiles and the
  // spotlight: no toast, store hint, chaos pill or spotlight caption.
  var AMBIENT = /[?&]ambient=1(&|$)/.test(location.search);
  var SILENT = PREVIEW || AMBIENT;
  // 1080 logical px tall; as wide as the window's shape (1920 at 16:9, what OBS uses), so no window is letterboxed
  var W = 1920, H = 1080, MAX_SLOTS = 100, MAX_POOL = 2000;
  var BASE = location.pathname.replace(/\/+$/, '');

  var $ = function (id) { return document.getElementById(id); };
  var stage = $('stage'), tilesEl = $('tiles'), spotEl = $('spot'), spMedia = $('spmedia');
  var spImg = $('spimg'), spVid = $('spvid'), spWho = $('spwho'), spPin = $('sppin'), spTitle = $('sptitle');
  var chaosRow = $('chaosrow'), chaosText = $('chaostext');
  var toastEl = $('toast'), tl1 = $('tl1'), tl2 = $('tl2'), hintEl = $('hint');
  if (CLEAR_BG) stage.className += ' clear';
  if (AMBIENT) body.setAttribute('data-ambient', '1');

  var DEFAULTS = {
    on_air: false, density: 30, tile_seconds: 10, tile_scale: 1, spotlight_auto: true,
    spotlight_seconds: 20, sound: true, sound_all: false, play_through: false, video_max: 12, store_hint: true, store_url: null
  };
  var cfg = merge(DEFAULTS, {});
  var pool = [];
  var slots = [];
  var zc = 1;
  var spot = null;          // the spotlight on screen
  var spotRect = null;      // where it is, so new tiles do not land under it
  var chaosUntil = 0, chaosBy = '';
  var clockOffset = 0;      // server time minus this clock, only used when they disagree by seconds
  var stopped = false;
  var tickT = 0, toastT = 0;
  var ws = null, wsBackoff = 1000, stateBackoff = 1000, stateBusy = false, stateAgain = false, stateRetryT = 0, wsT = 0, pingT = 0, pongT = 0;
  var wasOnAir = false;

  function merge(a, b) {
    var o = {}, k;
    for (k in a) if (Object.prototype.hasOwnProperty.call(a, k)) o[k] = a[k];
    for (k in b) if (Object.prototype.hasOwnProperty.call(b, k) && b[k] !== undefined) o[k] = b[k];
    return o;
  }
  function now() { return Date.now() + clockOffset; }
  function rand(a, b) { return a + Math.random() * (b - a); }
  function num(v, d) { return typeof v === 'number' && isFinite(v) ? v : d; }
  function clamp(v, a, b) { return Math.max(a, Math.min(b, v)); }
  function fit() {
    var iw = window.innerWidth, ih = window.innerHeight;
    if (iw > 0 && ih > 0) W = clamp(Math.round(H * iw / ih), 960, 5760);
    stage.style.width = W + 'px';
    var s = Math.min(iw / W, ih / H);
    if (!(s > 0)) s = 1;
    stage.style.transform = 'scale(' + s + ')';
    stage.style.left = Math.round((window.innerWidth - W * s) / 2) + 'px';
    stage.style.top = Math.round((window.innerHeight - H * s) / 2) + 'px';
  }
  function restartAnim(el, cls, delay) {
    el.classList.remove(cls);
    el.style.animationDelay = delay ? delay + 'ms' : '0ms';
    void el.offsetWidth;
    el.classList.add(cls);
  }
  function playVideo(v, onBlocked) {
    var p;
    try { p = v.play(); } catch (e) { if (onBlocked) onBlocked(); return; }
    if (p && p.catch) p.catch(function () { if (onBlocked) onBlocked(); });
  }
  function dropVideo(v) {
    if (!v.getAttribute('src')) return;
    try { v.pause(); } catch (e) {}
    v.removeAttribute('src');
    v.removeAttribute('poster');
    try { v.load(); } catch (e) {}
  }
  function validItem(it) {
    return it && typeof it === 'object' && typeof it.id === 'string' && typeof it.url === 'string' && /^https?:\/\//i.test(it.url) &&
      (it.kind === 'image' || it.kind === 'video');
  }
  function aspect(it) {
    var w = num(it.width, 0), h = num(it.height, 0);
    return w > 0 && h > 0 ? w / h : 1;
  }
  function effDensity() {
    return chaosUntil > now() ? MAX_SLOTS : clamp(Math.round(num(cfg.density, 30)), 5, MAX_SLOTS);
  }

  // ---- the scatter ---------------------------------------------------------------------------------------------
  // A fixed set of slots. Filling a slot builds a fresh tile and keeps the old one up until the new picture or video
  // is ready, so a change never flashes black. New tiles go where the canvas is emptiest (best of a few random
  // spots, scored on a coarse coverage grid), so the scatter covers the screen instead of piling up.
  var GX = 32, GY = 18, SPOTS = 16, HOLD_MAX = 180000, START_GRACE = 15000, READY_WAIT = 8000;
  function makeSlot() { return { cur: null, next: null, born: 0, fails: 0 }; }
  function slotAt(i) {
    while (slots.length <= i) slots.push(makeSlot());
    return slots[i];
  }
  function busy(s) { return !!(s.cur || s.next); }
  function slotItem(s) { return s.next ? s.next.item : s.cur ? s.cur.item : null; }
  function tileLife() { return Math.max(3000, num(cfg.tile_seconds, 10) * 1000); }
  function tileSound() { return audible() && !!cfg.sound_all; }
  function makeView(it) {
    var el = document.createElement('div');
    el.className = 'tile';
    var img = document.createElement('img');
    img.alt = '';
    img.decoding = 'async';
    var vid = document.createElement('video');
    vid.muted = true; vid.defaultMuted = true; vid.loop = true; vid.playsInline = true;
    vid.setAttribute('muted', ''); vid.setAttribute('playsinline', ''); vid.setAttribute('webkit-playsinline', '');
    vid.preload = 'none';
    vid.style.display = 'none';
    img.style.display = 'none';
    el.appendChild(img);
    el.appendChild(vid);
    el.style.visibility = 'hidden';
    tilesEl.appendChild(el);
    return { el: el, img: img, vid: vid, item: it, playing: false, ready: false, started: false, ended: false, shownAt: 0, x: 0, y: 0, w: 0, h: 0 };
  }
  function discard(v) {
    if (!v) return;
    dropVideo(v.vid);
    v.img.removeAttribute('src');
    if (v.el.parentNode) v.el.parentNode.removeChild(v.el);
  }
  // the old tile fades out over the one that replaced it, then goes
  function retire(v) {
    if (!v) return;
    try { v.vid.pause(); } catch (e) {}
    v.el.classList.add('out');
    setTimeout(function () { discard(v); }, 500);
  }
  function playingCount(except) {
    var n = 0;
    for (var i = 0; i < slots.length; i++) {
      var s = slots[i];
      if (s.cur && s.cur.playing && s !== except) n++;
      if (s.next && s.next.playing) n++;
    }
    return n;
  }
  function views() {
    var out = [];
    for (var i = 0; i < slots.length; i++) {
      if (slots[i].cur) out.push(slots[i].cur);
      if (slots[i].next) out.push(slots[i].next);
    }
    return out;
  }
  // how many tiles (and the spotlight, which hides what is under it) cover each cell, leaving out one slot
  function coverage(except) {
    var g = [], i, n = GX * GY;
    for (i = 0; i < n; i++) g.push(0);
    var add = function (x, y, w, h, wt) {
      var cw = W / GX, ch = H / GY;
      var c0 = Math.max(0, Math.ceil(x / cw - 0.5)), c1 = Math.min(GX - 1, Math.floor((x + w) / cw - 0.5));
      var r0 = Math.max(0, Math.ceil(y / ch - 0.5)), r1 = Math.min(GY - 1, Math.floor((y + h) / ch - 0.5));
      for (var r = r0; r <= r1; r++) for (var c = c0; c <= c1; c++) g[r * GX + c] += wt;
    };
    for (i = 0; i < slots.length; i++) {
      var s = slots[i];
      if (s === except) continue;
      if (s.cur) add(s.cur.x, s.cur.y, s.cur.w, s.cur.h, 1);
      if (s.next) add(s.next.x, s.next.y, s.next.w, s.next.h, 1);
    }
    if (spot && spotRect) add(spotRect.x, spotRect.y, spotRect.w, spotRect.h, 2);
    return g;
  }
  function score(g, x, y, w, h) {
    var cw = W / GX, ch = H / GY, sc = 0;
    var c0 = Math.max(0, Math.ceil(x / cw - 0.5)), c1 = Math.min(GX - 1, Math.floor((x + w) / cw - 0.5));
    var r0 = Math.max(0, Math.ceil(y / ch - 0.5)), r1 = Math.min(GY - 1, Math.floor((y + h) / ch - 0.5));
    for (var r = r0; r <= r1; r++) for (var c = c0; c <= c1; c++) {
      var k = g[r * GX + c];
      sc += k === 0 ? 1 : k === 1 ? 0.12 : 0;
    }
    return sc;
  }
  // a spot for a w×h tile that may hang 8% off an edge: the emptiest of a few candidates, half of them random and
  // half centred on a cell nothing covers yet
  function placeView(v, except) {
    var g = coverage(except), best = null, bestScore = -1, holes = [], i;
    for (i = 0; i < g.length; i++) if (g[i] === 0) holes.push(i);
    var x0 = -0.08 * v.w, x1 = W - 0.92 * v.w, y0 = -0.08 * v.h, y1 = H - 0.92 * v.h;
    for (i = 0; i < SPOTS; i++) {
      var x, y;
      if (holes.length && i % 2 === 1) {
        var cell = holes[Math.floor(Math.random() * holes.length)];
        x = ((cell % GX) + 0.5) * (W / GX) - v.w * rand(0.25, 0.75);
        y = (Math.floor(cell / GX) + 0.5) * (H / GY) - v.h * rand(0.25, 0.75);
        x = clamp(x, x0, Math.max(x0, x1));
        y = clamp(y, y0, Math.max(y0, y1));
      } else {
        x = x0 + Math.random() * Math.max(0, x1 - x0);
        y = y0 + Math.random() * Math.max(0, y1 - y0);
      }
      var sc = score(g, x, y, v.w, v.h) + Math.random() * 0.01;
      if (sc > bestScore) { bestScore = sc; best = { x: x, y: y }; }
    }
    v.x = best.x; v.y = best.y;
  }
  function sizeView(v, area, f) {
    var a = aspect(v.item);
    var w = Math.sqrt(area * a) * f;
    var h = w / a;
    if (h > 900) { h = 900; w = h * a; }
    if (w > W * 0.9) { w = W * 0.9; h = w / a; }
    v.w = w; v.h = h;
  }
  function drawView(v) {
    var st = v.el.style;
    st.left = Math.round(v.x) + 'px'; st.top = Math.round(v.y) + 'px';
    st.width = Math.round(v.w) + 'px'; st.height = Math.round(v.h) + 'px';
  }
  function pickItem(avoidSpot) {
    if (!pool.length) return null;
    var onScreen = {}, i, it = null, si;
    for (i = 0; i < slots.length; i++) { si = slotItem(slots[i]); if (si) onScreen[si.id] = 1; }
    if (avoidSpot && spot) onScreen[spot.item.id] = 1;
    for (i = 0; i < 8; i++) {
      it = pool[Math.floor(Math.random() * pool.length)];
      if (!onScreen[it.id]) return it;
    }
    return it;
  }
  function hideSlot(s) {
    discard(s.next);
    s.next = null;
    if (s.cur) { var v = s.cur; s.cur = null; discard(v); }
  }
  function fillSlot(s, delay) {
    var it = pickItem(true);
    if (!it) { hideSlot(s); return; }
    if (s.next) { discard(s.next); s.next = null; }
    var v = makeView(it);
    s.next = v;
    s.born = now();
    var d = effDensity();
    var scale = clamp(num(cfg.tile_scale, 1), 0.5, 1.6);
    var area = Math.min(900 * 700, Math.max(90 * 90, (W * H * 1.8 / d) * scale * scale));
    var f = rand(0.75, 1.3);
    sizeView(v, area, f);
    placeView(v, s);
    zc += 1;
    if (zc > 90000) renumber();
    v.el.style.zIndex = String(zc);
    v.el.style.display = 'block';
    drawView(v);
    var waitT = 0;
    var ready = function () {
      if (s.next !== v || v.ready) return;
      clearTimeout(waitT);
      v.ready = true;
      var old = s.cur;
      s.cur = v; s.next = null;
      s.fails = 0;
      v.shownAt = now();
      v.el.style.visibility = '';
      restartAnim(v.el, 'pop', delay || 0);
      retire(old);
    };
    var failed = function () { viewFailed(s, v); };
    // a file that is slow to arrive is shown anyway rather than holding the old tile forever
    waitT = setTimeout(ready, READY_WAIT);
    var refit = function (nw, nh) {
      if (!(nw > 0 && nh > 0) || num(v.item.width, 0) > 0) return;
      var cx = v.x + v.w / 2, cy = v.y + v.h / 2;
      v.item = merge(v.item, { width: nw, height: nh });
      sizeView(v, area, f);
      v.x = cx - v.w / 2; v.y = cy - v.h / 2;
      drawView(v);
    };
    if (it.kind === 'video') {
      if (playingCount(s) < clamp(num(cfg.video_max, 12), 0, 24)) {
        v.playing = true;
        v.vid.style.display = 'block';
        v.vid.preload = 'auto';
        v.vid.loop = !cfg.play_through;
        if (it.poster_url) v.vid.poster = it.poster_url;
        v.vid.onloadeddata = ready;
        v.vid.onplaying = function () { v.started = true; ready(); };
        v.vid.onerror = failed;
        v.vid.onloadedmetadata = function () { refit(v.vid.videoWidth, v.vid.videoHeight); };
        v.vid.onended = function () { viewEnded(s, v); };
        v.vid.muted = !tileSound();
        v.vid.src = it.url;
        playVideo(v.vid, function () {
          // sound needs a page the browser lets play it (OBS does): else muted rather than not at all
          if (v.vid.muted) return;
          v.vid.muted = true;
          playVideo(v.vid);
        });
      } else if (it.poster_url) {
        v.img.style.display = 'block';
        v.img.onload = ready;
        v.img.onerror = failed;
        v.img.src = it.poster_url;
      } else {
        v.vid.style.display = 'block';
        v.vid.preload = 'metadata';
        v.vid.onloadeddata = ready;
        v.vid.onerror = failed;
        v.vid.onloadedmetadata = function () { refit(v.vid.videoWidth, v.vid.videoHeight); ready(); };
        v.vid.src = it.url;
      }
    } else {
      v.img.style.display = 'block';
      v.img.onload = function () { refit(v.img.naturalWidth, v.img.naturalHeight); ready(); };
      v.img.onerror = failed;
      v.img.src = it.url;
    }
  }
  function viewFailed(s, v) {
    if (s.next !== v && s.cur !== v) return;
    if (s.next === v) s.next = null;
    if (s.cur === v) s.cur = null;
    discard(v);
    if (s.fails >= 3) return;
    s.fails += 1;
    setTimeout(function () {
      if (stopped || !cfg.on_air || busy(s)) return;
      if (slots.indexOf(s) < effDensity()) fillSlot(s, 0);
    }, 1000);
  }
  // a video tile that played to its end: with play_through, one past its tile life goes now; else it plays again
  function viewEnded(s, v) {
    if (s.cur !== v) return;
    v.ended = true;
    if (cfg.play_through && now() - v.shownAt >= tileLife() && !s.next && cfg.on_air && pool.length) {
      fillSlot(s, 0);
      return;
    }
    try { v.vid.currentTime = 0; } catch (e) {}
    playVideo(v.vid, function () {});
  }
  // play_through keeps a playing video up until it has ended once (at most 3 minutes; one that never starts lets go
  // after 15 s)
  function holds(v, t) {
    if (!cfg.play_through || !v.playing || v.ended) return false;
    if (t - v.shownAt >= HOLD_MAX) return false;
    return v.started || v.vid.currentTime > 0 || t - v.shownAt < START_GRACE;
  }
  function renumber() {
    var act = views();
    act.sort(function (a, b) { return (parseInt(a.el.style.zIndex, 10) || 0) - (parseInt(b.el.style.zIndex, 10) || 0); });
    for (var i = 0; i < act.length; i++) act[i].el.style.zIndex = String(i + 1);
    zc = act.length + 1;
  }
  function syncSlots(stagger) {
    var d = cfg.on_air ? effDensity() : 0;
    var n = 0, i, s;
    if (cfg.on_air && pool.length) {
      for (i = 0; i < d; i++) {
        s = slotAt(i);
        if (!busy(s)) { fillSlot(s, stagger ? Math.min(2400, n * 35) : 0); n += 1; }
      }
    }
    for (i = (cfg.on_air && pool.length ? d : 0); i < slots.length; i++) if (busy(slots[i])) hideSlot(slots[i]);
  }
  function enforceVideoMax() {
    var max = clamp(num(cfg.video_max, 12), 0, 24), over = playingCount(null) - max;
    if (over <= 0) return;
    var vids = slots.filter(function (s) { return s.cur && s.cur.playing && !s.next; });
    vids.sort(function (a, b) { return a.born - b.born; });
    for (var i = 0; i < over && i < vids.length; i++) fillSlot(vids[i], 0);
  }
  // the switches that change tiles already up: sound for every video, and whether a video loops or ends
  function applyTileVideo() {
    var vs = views(), loud = tileSound();
    for (var i = 0; i < vs.length; i++) {
      var v = vs[i];
      if (!v.playing) continue;
      v.vid.loop = !cfg.play_through;
      if (v.vid.muted === !loud) continue;
      v.vid.muted = !loud;
      if (loud) (function (vv) {
        playVideo(vv.vid, function () { vv.vid.muted = true; playVideo(vv.vid); });
      })(v);
    }
  }
  // one tile changes per beat: the oldest that has lived its tile life and is not holding a video that is still
  // playing through
  function tick() {
    if (!cfg.on_air || !pool.length) return;
    var d = effDensity(), t = now(), life = tileLife(), pick = null, i, s;
    for (i = 0; i < d; i++) {
      s = slotAt(i);
      if (!busy(s)) { pick = s; break; }
      if (s.next) continue;
      if (t - s.born < life) continue;
      if (holds(s.cur, t)) continue;
      if (!pick || s.born < pick.born) pick = s;
    }
    if (pick) fillSlot(pick, 0);
  }
  function schedule() {
    clearTimeout(tickT);
    if (stopped) return;
    var ms = Math.max(80, tileLife() / effDensity());
    tickT = setTimeout(function () { tick(); schedule(); }, ms);
  }
  function shuffle() {
    var d = effDensity(), n = 0;
    for (var i = 0; i < slots.length; i++) {
      if (!busy(slots[i])) continue;
      if (i >= d) { hideSlot(slots[i]); continue; }
      fillSlot(slots[i], Math.min(1200, n * 25));
      n += 1;
    }
    syncSlots(true);
  }

  // ---- the spotlight -------------------------------------------------------------------------------------------
  function audible() { return !!cfg.sound && !SILENT; }
  function norm(c) {
    if (AMBIENT) c.on_air = true;
    return c;
  }
  function clearSpot() {
    spot = null;
    spotRect = null;
    dropVideo(spVid);
    spImg.removeAttribute('src');
    spotEl.style.display = 'none';
  }
  function setSpot(raw) {
    if (!raw || !validItem(raw.item)) return;
    var it = raw.item;
    var a = aspect(it);
    var w = Math.sqrt(560 * 640 * a), h = w / a;
    if (h > 700) { h = 700; w = h * a; }
    if (w > 900) { w = 900; h = w / a; }
    var x = rand(100, Math.max(101, W - w - 100));
    var y = rand(60, Math.max(70, H - h - 250));
    var at = num(raw.at, now());
    var me = {
      item: it, by: typeof raw.by === 'string' && raw.by ? raw.by : null, action: raw.action || null,
      pinnedUntil: num(raw.pinned_until, 0), at: at, base: raw.action ? at : now(),
      shownAt: now(), playedOnce: false, isVideo: it.kind === 'video'
    };
    clearSpot();
    spot = me;
    spotRect = { x: x, y: y, w: w, h: h + (AMBIENT ? 0 : 90) };
    spotEl.style.left = Math.round(x) + 'px';
    spotEl.style.top = Math.round(y) + 'px';
    spotEl.style.width = Math.round(w) + 'px';
    spMedia.style.width = Math.round(w) + 'px';
    spMedia.style.height = Math.round(h) + 'px';
    spWho.textContent = me.by ? 'summoned by @' + me.by : 'spotlight · picked at random';
    spTitle.textContent = it.title || '';
    spImg.alt = it.title || '';
    spotEl.style.display = 'block';
    if (it.kind === 'video') {
      spImg.style.display = 'none';
      spVid.style.display = 'block';
      spVid.loop = false;
      spVid.muted = !audible();
      if (it.poster_url) spVid.poster = it.poster_url;
      spVid.onended = function () {
        if (spot !== me) return;
        me.playedOnce = true;
        try { spVid.currentTime = 0; } catch (e) {}
        playVideo(spVid, function () {});
      };
      spVid.onerror = function () { if (spot === me) me.playedOnce = true; };
      spVid.src = it.url;
      playVideo(spVid, function () {
        if (spot !== me || spVid.muted) return;
        spVid.muted = true;
        playVideo(spVid);
      });
    } else {
      spVid.style.display = 'none';
      spImg.style.display = 'block';
      spImg.src = it.url;
    }
    if (!num(it.width, 0) || !num(it.height, 0)) {
      var refit = function (nw, nh) {
        if (spot !== me || !(nw > 0 && nh > 0)) return;
        var na = nw / nh, ww = Math.sqrt(560 * 640 * na), hh = ww / na;
        if (hh > 700) { hh = 700; ww = hh * na; }
        if (ww > 900) { ww = 900; hh = ww / na; }
        spotRect = { x: x, y: y, w: ww, h: hh + (AMBIENT ? 0 : 90) };
        spotEl.style.width = Math.round(ww) + 'px';
        spMedia.style.width = Math.round(ww) + 'px';
        spMedia.style.height = Math.round(hh) + 'px';
      };
      spImg.onload = function () { refit(spImg.naturalWidth, spImg.naturalHeight); };
      spVid.onloadedmetadata = function () { refit(spVid.videoWidth, spVid.videoHeight); };
    }
    showPinned();
    restartAnim(spotEl, 'spotin', 0);
  }
  function showPinned() {
    spPin.style.display = spot && spot.pinnedUntil > now() ? 'block' : 'none';
  }
  function pickAutoSpot() {
    var it = null, i;
    if (pool.length) {
      for (i = 0; i < 8; i++) {
        it = pool[Math.floor(Math.random() * pool.length)];
        if (!spot || it.id !== spot.item.id || pool.length === 1) break;
      }
    }
    if (it) setSpot({ item: it, by: null, action: null, at: now() });
    else clearSpot();
  }
  function spotTick() {
    if (stopped || !cfg.on_air) return;
    var t = now();
    if (!spot) { if (cfg.spotlight_auto && pool.length) pickAutoSpot(); return; }
    showPinned();
    if (spot.pinnedUntil > t) return;
    if (t < spot.base + num(cfg.spotlight_seconds, 20) * 1000) return;
    if (spot.isVideo && !spot.playedOnce) {
      var started = spVid.readyState >= 2 || spVid.currentTime > 0;
      if (started || t - spot.shownAt < 15000) return;
    }
    if (cfg.spotlight_auto && pool.length) pickAutoSpot(); else clearSpot();
  }

  // ---- toast, chaos pill, store hint ---------------------------------------------------------------------------
  function showToast(t) {
    if (!t || typeof t !== 'object' || !cfg.on_air || AMBIENT) return;
    var by = typeof t.by === 'string' ? t.by : '';
    var action = typeof t.action === 'string' ? t.action : '';
    var cost = num(t.cost, 0);
    while (tl1.firstChild) tl1.removeChild(tl1.firstChild);
    var b = document.createElement('b');
    b.textContent = '@' + by;
    tl1.appendChild(b);
    var m = document.createElement('span');
    m.className = 'm';
    m.textContent = cost > 0 ? ' spent ' + cost + ' on ' : ' tried ';
    tl1.appendChild(m);
    var a = document.createElement('span');
    a.className = 'a';
    a.textContent = action;
    tl1.appendChild(a);
    var detail = typeof t.detail === 'string' ? t.detail : '';
    tl2.textContent = detail;
    tl2.style.display = detail ? 'block' : 'none';
    toastEl.style.display = 'flex';
    restartAnim(toastEl, 'in', 0);
    clearTimeout(toastT);
    toastT = setTimeout(function () { toastEl.style.display = 'none'; }, 5000);
  }
  function chaosTick() {
    var t = now();
    if (chaosUntil > t && cfg.on_air) {
      var left = Math.ceil((chaosUntil - t) / 1000);
      var txt = 'chaos mode · ' + left + 's' + (chaosBy ? ' · thanks @' + chaosBy : '');
      if (chaosText.textContent !== txt) chaosText.textContent = txt;
      if (chaosRow.style.display !== 'flex') chaosRow.style.display = 'flex';
    } else {
      if (chaosRow.style.display !== 'none') chaosRow.style.display = 'none';
      if (chaosUntil && chaosUntil <= t) {
        chaosUntil = 0; chaosBy = '';
        syncSlots(false);
        schedule();
      }
    }
  }
  function applyHint() {
    var url = typeof cfg.store_url === 'string' ? cfg.store_url : '';
    if (cfg.store_hint && url && !SILENT && cfg.on_air) {
      hintEl.textContent = 'spend points: ';
      var b = document.createElement('b');
      b.textContent = url.replace(/^https?:\/\//i, '').replace(/\/+$/, '');
      hintEl.appendChild(b);
      hintEl.style.display = 'block';
    } else {
      hintEl.style.display = 'none';
    }
  }

  // ---- applying settings and state ------------------------------------------------------------------------------
  function applyCfg(prev) {
    var onAir = !!cfg.on_air;
    stage.className = (onAir ? '' : 'off') + (CLEAR_BG ? ' clear' : '');
    if (!onAir) {
      for (var i = 0; i < slots.length; i++) if (busy(slots[i])) hideSlot(slots[i]);
      clearSpot();
      toastEl.style.display = 'none';
      chaosRow.style.display = 'none';
      wasOnAir = false;
      schedule();
      applyHint();
      return;
    }
    var starting = !wasOnAir;
    wasOnAir = true;
    syncSlots(starting);
    if (prev && prev.video_max !== cfg.video_max) enforceVideoMax();
    if (prev && (prev.sound !== cfg.sound || prev.sound_all !== cfg.sound_all || prev.play_through !== cfg.play_through)) applyTileVideo();
    if (prev && prev.sound !== cfg.sound && spot && spot.isVideo) {
      spVid.muted = !audible();
      if (spVid.paused) playVideo(spVid);
    }
    if (!spot && cfg.spotlight_auto) spotTick();
    schedule();
    applyHint();
  }
  function takeChaos(until, by) {
    until = num(until, 0);
    if (until > chaosUntil) { chaosUntil = until; if (by) chaosBy = by; }
  }
  function applyState(st) {
    var prev = cfg;
    var stg = st && st.stage && typeof st.stage === 'object' ? st.stage : {};
    cfg = norm(merge(DEFAULTS, stg));
    var list = st && Array.isArray(st.pool) ? st.pool : [];
    var next = [];
    for (var i = 0; i < list.length && next.length < MAX_POOL; i++) if (validItem(list[i])) next.push(list[i]);
    pool = next;
    var ch = st && (st.chaos !== undefined ? st.chaos : (st.chaos_until !== undefined ? { until: st.chaos_until, by: st.chaos_by } : stg.chaos_until !== undefined ? { until: stg.chaos_until, by: stg.chaos_by } : undefined));
    if (ch && typeof ch === 'object') takeChaos(ch.until, ch.by); else if (typeof ch === 'number') takeChaos(ch, '');
    var sp = st && st.spotlight;
    if (sp && validItem(sp.item) && cfg.on_air) {
      var key = sp.item.id + ':' + num(sp.at, 0);
      if (spot && spot.item.id + ':' + spot.at === key) {
        spot.pinnedUntil = num(sp.pinned_until, 0);
        showPinned();
      } else if (!spot || !spot.action || num(sp.at, 0) > spot.at) {
        setSpot(sp);
      }
    }
    applyCfg(prev);
  }
  function stop() {
    stopped = true;
    cfg = merge(DEFAULTS, {});
    pool = [];
    clearTimeout(tickT); clearTimeout(stateRetryT); clearTimeout(wsT); clearTimeout(toastT); clearInterval(pingT); clearTimeout(pongT);
    for (var i = 0; i < slots.length; i++) if (busy(slots[i])) hideSlot(slots[i]);
    clearSpot();
    chaosUntil = 0;
    toastEl.style.display = 'none';
    chaosRow.style.display = 'none';
    hintEl.style.display = 'none';
    stage.className = 'off' + (CLEAR_BG ? ' clear' : '');
    if (ws) { try { ws.onclose = null; ws.close(); } catch (e) {} ws = null; }
  }

  // ---- state and websocket ---------------------------------------------------------------------------------------
  function loadState() {
    if (stopped) return;
    if (stateBusy) { stateAgain = true; return; }
    stateBusy = true;
    clearTimeout(stateRetryT);
    var failed = function () {
      stateBusy = false;
      if (stopped) return;
      stateRetryT = setTimeout(loadState, stateBackoff);
      stateBackoff = Math.min(stateBackoff * 2, 30000);
    };
    var req;
    try { req = fetch(BASE + '/state', { cache: 'no-store' }); } catch (e) { failed(); return; }
    req.then(function (res) {
      if (res.status === 404) { stateBusy = false; stop(); return null; }
      if (!res.ok) throw new Error('state ' + res.status);
      var date = Date.parse(res.headers.get('date') || '');
      if (date === date) {
        var off = date - Date.now();
        clockOffset = Math.abs(off) > 3000 ? off : 0;
      }
      return res.json();
    }).then(function (st) {
      if (st === null || st === undefined) return;
      stateBusy = false;
      stateBackoff = 1000;
      if (stopped) return;
      applyState(st);
      if (stateAgain) { stateAgain = false; loadState(); }
    }).catch(failed);
  }
  function connect() {
    if (stopped) return;
    var url = (location.protocol === 'https:' ? 'wss:' : 'ws:') + '//' + location.host + BASE + '/ws';
    var sock;
    try { sock = new WebSocket(url); } catch (e) { retryWs(); return; }
    ws = sock;
    sock.onopen = function () { wsBackoff = 1000; beat(sock); loadState(); };
    sock.onmessage = function (m) {
      // anything from the room proves the socket is alive, the answer to our ping included
      clearTimeout(pongT);
      if (m.data === 'pong') return;
      var ev;
      try { ev = JSON.parse(m.data); } catch (e) { return; }
      if (ev && typeof ev === 'object') onEvent(ev);
    };
    sock.onclose = function () { if (ws === sock) { ws = null; clearInterval(pingT); clearTimeout(pongT); retryWs(); } };
    sock.onerror = function () {};
  }
  // Heartbeat: the room answers "ping" with "pong" without waking up. A connection a NAT or a laptop lid killed
  // never fires onclose, so with no sign of life 10 s after a ping the socket is dropped and made again (the
  // reconnect loads the state, which catches up whatever was missed).
  function beat(sock) {
    clearInterval(pingT); clearTimeout(pongT);
    pingT = setInterval(function () {
      if (ws !== sock || sock.readyState !== 1) return;
      try { sock.send('ping'); } catch (e) {}
      clearTimeout(pongT);
      pongT = setTimeout(function () { dead(sock); }, 10000);
    }, 30000);
  }
  function dead(sock) {
    if (ws !== sock) return;
    clearInterval(pingT); clearTimeout(pongT);
    sock.onopen = null; sock.onmessage = null; sock.onclose = null; sock.onerror = function () {};
    try { sock.close(); } catch (e) {}
    ws = null;
    retryWs();
  }
  function retryWs() {
    if (stopped) return;
    clearTimeout(wsT);
    wsT = setTimeout(connect, wsBackoff);
    wsBackoff = Math.min(wsBackoff * 2, 30000);
    loadState();
  }
  function onEvent(ev) {
    switch (ev.type) {
      case 'settings':
        if (ev.stage && typeof ev.stage === 'object') {
          var prev = cfg;
          cfg = norm(merge(cfg, ev.stage));
          applyCfg(prev);
        }
        break;
      case 'pool':
        loadState();
        break;
      case 'summon':
        if (cfg.on_air && ev.spotlight) setSpot(ev.spotlight);
        showToast(ev.toast);
        break;
      case 'chaos':
        takeChaos(ev.until, ev.toast && ev.toast.by);
        if (cfg.on_air) { syncSlots(true); schedule(); chaosTick(); }
        showToast(ev.toast);
        break;
      case 'shuffle':
        if (cfg.on_air) shuffle();
        showToast(ev.toast);
        break;
      case 'pin':
        if (spot) { spot.pinnedUntil = num(ev.pinned_until, 0); showPinned(); }
        showToast(ev.toast);
        break;
      case 'unpin':
        if (spot) { spot.pinnedUntil = 0; showPinned(); }
        break;
      case 'skip':
        if (cfg.on_air) { if (cfg.spotlight_auto) pickAutoSpot(); else clearSpot(); }
        break;
      case 'toast':
        // a refunded summon (nothing matched): just the toast, the canvas is unchanged
        showToast(ev.toast);
        break;
      case 'rotated':
        stop();
        break;
      default:
        break;
    }
  }

  fit();
  window.addEventListener('resize', fit);
  setInterval(spotTick, 500);
  setInterval(chaosTick, 250);
  setInterval(loadState, 5 * 60 * 1000);
  loadState();
  connect();
})();
`;

export function livePage(o: { stageBaseUrl: string; preview: boolean }): string {
    return (
        '<!doctype html>\n<html lang="en"><head><meta charset="utf-8">' +
        '<meta name="viewport" content="width=device-width,initial-scale=1">' +
        '<meta name="robots" content="noindex,nofollow">' +
        '<title>stage</title>' +
        FONT_LINKS +
        `<style>${LIVE_CSS}</style></head>` +
        `<body data-page="live" data-preview="${o.preview ? "1" : "0"}" data-stage-base="${esc(withSlash(o.stageBaseUrl))}">` +
        LIVE_BODY +
        `<script>${LIVE_JS}</script></body></html>\n`
    );
}

// ---------------------------------------------------------------------------------------------------------------
// The store (30.7)
// ---------------------------------------------------------------------------------------------------------------

const STORE_CSS = String.raw`
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:#000;color:#e1e1e1;font-family:'IBM Plex Mono',ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:14px}
a{color:#8ab8ff}a:hover{color:#c9dcff}
button,input{font-family:inherit}
button{cursor:pointer}
:focus-visible{outline:2px solid #8ab8ff;outline-offset:2px}
[hidden]{display:none!important}
.wrap{max-width:1200px;margin:0 auto;padding:0 16px 140px;display:flex;flex-direction:column;gap:36px}
@media (min-width:700px){.wrap{padding-left:20px;padding-right:20px}}
header{display:flex;flex-wrap:wrap;align-items:center;gap:12px;padding:20px 0;border-bottom:1px solid #282828}
.brand{font-weight:600;font-size:16px}
.live{display:inline-flex;align-items:center;gap:6px;padding:4px 10px;border-radius:999px;background:#2a1215;color:#ff5c6c;font-size:12px;font-weight:500}
.live i{width:7px;height:7px;border-radius:50%;background:#ff5c6c;display:inline-block}
.grow{flex:1}
.btn{min-height:44px;border:0;border-radius:11px;padding:0 18px;font-size:14px;font-weight:600;display:inline-flex;align-items:center;justify-content:center;gap:10px;text-decoration:none}
.twitch{background:#9146ff;color:#fff}
.twitch:hover{background:#a35cff;color:#fff}
.ghost{background:transparent;color:#8f8f8f;font-weight:400;font-size:13px;padding:0 12px}
.chip{display:inline-flex;align-items:center;gap:8px;padding:6px 12px 6px 6px;border-radius:999px;background:#191919}
.chip b{width:28px;height:28px;border-radius:50%;background:#231d36;color:#b69cff;display:inline-flex;align-items:center;justify-content:center;font-weight:600}
.muted{color:#8f8f8f}
.note{color:#f0b44c;font-size:13px;margin:0}
section{display:flex;flex-direction:column;gap:14px}
h1{margin:0;font-size:clamp(24px,5.4vw,34px);font-weight:600;line-height:1.2;max-width:760px}
h2{margin:0;font-size:18px;font-weight:600}
.lede{margin:0;color:#8f8f8f;max-width:680px;line-height:1.6}
.lede b{color:#e1e1e1}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px;list-style:none;margin:0;padding:0}
.step{background:#191919;border-radius:16px;padding:16px;display:flex;flex-direction:column;gap:6px}
.step .n{color:#8f8f8f;font-size:12px}
.step .t{font-weight:500}
.step .d{color:#8f8f8f;font-size:13px}
.reward{border:1px solid #282828;border-radius:16px;padding:16px;display:flex;flex-direction:column;gap:8px}
.reward .top{display:flex;align-items:baseline;justify-content:space-between;gap:8px}
.reward .name{font-weight:600;color:#b69cff}
.reward .cost{font-weight:500;white-space:nowrap}
.reward .desc{color:#c4c4c4;font-size:13px;line-height:1.5}
.reward .cd{color:#8f8f8f;font-size:12px}
.mine{display:flex;flex-direction:column;background:#191919;border-radius:16px;padding:4px 16px}
.row{display:flex;flex-wrap:wrap;align-items:center;gap:12px;padding:12px 0;border-bottom:1px solid #282828}
.row:last-child{border-bottom:0}
.row .th{width:44px;height:44px;border-radius:8px;background:#0f0f0f;object-fit:cover;flex:none}
.row .tt{flex:1 1 180px;min-width:0;word-break:break-word}
.row .st{font-size:13px;color:#8f8f8f}
.row .st.ok{color:#30bd1b}
.poolhead{display:flex;flex-wrap:wrap;align-items:baseline;gap:10px}
.pill{padding:3px 10px;border-radius:999px;background:#2a2418;color:#f0b44c;font-size:12.5px}
label.search{display:flex;flex-direction:column;gap:6px;color:#8f8f8f;font-size:12.5px}
label.search input{height:46px;border-radius:12px;border:1px solid #383838;background:#0f0f0f;color:#e1e1e1;padding:0 14px;font-size:16px;width:100%;max-width:520px}
.msg{color:#8f8f8f;padding:24px 0}
.masonry{columns:4 200px;column-gap:16px}
@media (max-width:560px){.masonry{columns:2 140px;column-gap:12px}}
.card{break-inside:avoid;margin:0 0 16px;background:#191919;border-radius:16px;overflow:hidden}
@media (max-width:560px){.card{margin-bottom:12px}}
.card .pic{position:relative;background:#0f0f0f}
.card .pic img,.card .pic video{display:block;width:100%;height:100%;object-fit:cover}
.card .code{position:absolute;left:10px;top:10px;background:rgba(0,0,0,.72);color:#fff;border-radius:7px;padding:3px 8px;font-size:12px;font-weight:600;letter-spacing:.06em}
.card .kind{position:absolute;right:10px;top:10px;background:rgba(0,0,0,.72);color:#c4c4c4;border-radius:7px;padding:3px 8px;font-size:11px}
.card .meta{padding:12px;display:flex;flex-direction:column;gap:10px}
.card .title{font-size:13px;line-height:1.45;word-break:break-word}
.card .go{min-height:44px;border-radius:11px;border:0;background:#e1e1e1;color:#000;font-size:13.5px;font-weight:600}
.card .go:hover{background:#fff}
#more{height:1px}
footer{color:#8f8f8f;font-size:12.5px;border-top:1px solid #282828;padding-top:18px;line-height:1.6}
#bar{position:fixed;left:50%;bottom:20px;transform:translateX(-50%);width:min(640px,calc(100% - 32px));background:#191919;border:1px solid #383838;border-radius:16px;padding:14px;display:flex;flex-wrap:wrap;align-items:center;gap:12px;box-shadow:0 20px 60px rgba(0,0,0,.7);animation:up .35s cubic-bezier(.2,.9,.3,1) both;z-index:10}
@keyframes up{from{opacity:0;transform:translate(-50%,24px)}to{opacity:1;transform:translate(-50%,0)}}
#bar img{width:48px;height:48px;object-fit:cover;border-radius:9px;background:#0f0f0f}
#bar .txt{flex:1 1 200px;min-width:0;display:flex;flex-direction:column;gap:3px}
#bar .a{font-weight:600}
#bar .b{color:#8f8f8f;font-size:12.5px}
#bar .x{width:44px;height:44px;border-radius:11px;border:0;background:#282828;color:#e1e1e1;display:inline-flex;align-items:center;justify-content:center}
.gone{padding:40px 16px;color:#8f8f8f}
`;

const TWITCH_SVG =
    '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 3h17v11l-5 5h-4l-3 3H7v-3H3V6z"></path><path d="M11 8v4"></path><path d="M16 8v4"></path></svg>';

const STORE_BODY_TOP = String.raw`
<div class="wrap" id="app">
  <header>
    <span class="brand">capystore studio</span>
    <span class="live" id="live" hidden><i></i>live now</span>
    <div class="grow"></div>
    @@ACCOUNT@@
  </header>
  <p class="note" id="notice" role="status" hidden></p>

  <section aria-labelledby="how">
    <h1 id="how">spend channel points to put stuff on stream.</h1>
    <p class="lede">everything here is in tonight's pool. find something, copy its code, then redeem <b>summon</b> in twitch chat and paste the code. it lands big in the middle of the screen with your name on it.</p>
    <ol class="grid">
      <li class="step"><span class="n">1</span><span class="t">find something below</span><span class="d">search works by meaning, so "sad dog" finds sad dogs.</span></li>
      <li class="step"><span class="n">2</span><span class="t">tap summon to copy its code</span><span class="d">three letters, like K7Q.</span></li>
      <li class="step"><span class="n">3</span><span class="t">redeem summon in twitch</span><span class="d">paste the code, or just type words and we'll find the best match.</span></li>
    </ol>
  </section>

  <section aria-labelledby="rw" id="rewards" hidden>
    <h2 id="rw">rewards</h2>
    <div class="grid" id="rewardlist"></div>
  </section>

  <section aria-labelledby="mine" id="minesec" hidden>
    <h2 id="mine">your summons</h2>
    <div class="mine" id="minelist"></div>
  </section>

  <section aria-labelledby="pool">
    <div class="poolhead">
      <h2 id="pool">tonight's pool</h2>
      <span class="pill" id="poolname" hidden></span>
      <span class="muted" id="poolcount"></span>
    </div>
    <label class="search">search the pool
      <input type="search" id="q" maxlength="60" placeholder="try cat, bird or anime" autocomplete="off" autocapitalize="off" spellcheck="false" enterkeyhint="search">
    </label>
    <div class="msg" id="empty" hidden></div>
    <p class="note" id="poolerr" role="status" hidden></p>
    <div class="masonry" id="grid"></div>
    <div id="more"></div>
  </section>

  <footer>only what's in tonight's pool shows here. signing in just tells this page who you are; it never touches your points. points are spent on twitch.</footer>
</div>
<div id="bar" role="status" hidden>
  <img id="barimg" alt="">
  <div class="txt"><span class="a" id="barcode"></span><span class="b" id="barhelp"></span></div>
  <a class="btn twitch" id="barchat" href="#" target="_blank" rel="noopener" hidden>open chat</a>
  <button type="button" class="x" id="barx" aria-label="close"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12"></path><path d="M18 6 6 18"></path></svg></button>
</div>
<noscript><p class="gone">this page needs javascript.</p></noscript>
`;

const ACCOUNT_BLOCK = `<div id="account"></div>`;

const STORE_JS = String.raw`
(function () {
  'use strict';
  var body = document.body;
  var $ = function (id) { return document.getElementById(id); };
  var channel = null;
  var seq = 0, nextOffset = 0, done = false, loading = false, curQ = '', total = 0, ctl = null;
  var gridEl = $('grid'), emptyEl = $('empty'), moreEl = $('more');

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = text;
    return e;
  }
  function enc(s) { return encodeURIComponent(s); }
  function notice(t) {
    var n = $('notice');
    n.textContent = t || '';
    n.hidden = !t;
  }
  function poolErr(t) {
    var n = $('poolerr');
    n.textContent = t || '';
    n.hidden = !t;
  }
  function gone() {
    document.title = 'nothing here.';
    body.innerHTML = '';
    body.appendChild(el('p', 'gone', 'nothing here.'));
  }
  function getJson(url, headers, signal) {
    return fetch(url, { headers: headers || {}, signal: signal, cache: 'no-store' }).then(function (res) {
      return res.json().catch(function () { return null; }).then(function (j) { return { status: res.status, json: j }; });
    });
  }
  function ago(ms) {
    var s = Math.max(0, (Date.now() - ms) / 1000);
    if (s < 60) return 'just now';
    var m = Math.floor(s / 60);
    if (m < 60) return m + 'm ago';
    var h = Math.floor(m / 60);
    if (h < 48) return h + 'h ago';
    return Math.floor(h / 24) + 'd ago';
  }
  function cooldown(sec) {
    if (!sec) return 'none';
    if (sec < 120) return sec + ' s';
    if (sec < 7200) return Math.round(sec / 60) + ' min';
    return Math.round(sec / 3600) + ' h';
  }
  var DESCS = {
    summon: 'your pick takes the spotlight, big, with sound and your name.',
    chaos: '100 things on screen at once for 30 seconds.',
    shuffle: 'wipe the canvas and refill it from the pool.',
    pin: 'keep the current spotlight up for 2 more minutes.'
  };

  // ---- rewards -----------------------------------------------------------------------------------------------
  function loadRewards() {
    getJson('/store/api/rewards').then(function (r) {
      if (r.status !== 200 || !r.json) return;
      channel = typeof r.json.channel === 'string' && r.json.channel ? r.json.channel : null;
      updateChat();
      var list = Array.isArray(r.json.rewards) ? r.json.rewards : [];
      var box = $('rewardlist');
      box.innerHTML = '';
      for (var i = 0; i < list.length; i++) {
        var w = list[i];
        var c = el('div', 'reward');
        var top = el('div', 'top');
        top.appendChild(el('span', 'name', String(w.title || w.action || '')));
        top.appendChild(el('span', 'cost', Number(w.cost || 0).toLocaleString('en-US') + ' pts'));
        c.appendChild(top);
        c.appendChild(el('span', 'desc', DESCS[w.action] || String(w.prompt || '')));
        c.appendChild(el('span', 'cd', 'cooldown ' + cooldown(Number(w.cooldown_seconds || 0))));
        box.appendChild(c);
      }
      $('rewards').hidden = list.length === 0;
    }).catch(function () {});
  }

  // ---- pool ----------------------------------------------------------------------------------------------------
  function thumbNode(it) {
    var u = it.thumb_url || '';
    var box = el('div', 'pic');
    box.style.aspectRatio = (it.width > 0 && it.height > 0) ? (it.width + ' / ' + it.height) : '1 / 1';
    if (it.kind === 'video' && /\.(mp4|webm|mov|m4v)(\?|$)/i.test(u)) {
      var v = document.createElement('video');
      v.muted = true; v.playsInline = true; v.preload = 'metadata';
      v.setAttribute('muted', ''); v.setAttribute('playsinline', '');
      v.src = u;
      box.appendChild(v);
    } else {
      var img = document.createElement('img');
      img.alt = it.title || '';
      img.loading = 'lazy';
      img.decoding = 'async';
      img.src = u;
      box.appendChild(img);
    }
    box.appendChild(el('span', 'code', String(it.code || '')));
    if (it.kind === 'video') box.appendChild(el('span', 'kind', 'video'));
    return box;
  }
  function card(it) {
    var c = el('div', 'card');
    c.appendChild(thumbNode(it));
    var meta = el('div', 'meta');
    meta.appendChild(el('span', 'title', it.title || ''));
    var b = el('button', 'go', 'summon');
    b.type = 'button';
    b.setAttribute('aria-label', 'summon ' + (it.title || it.code || ''));
    b.addEventListener('click', function () { summon(it); });
    meta.appendChild(b);
    c.appendChild(meta);
    return c;
  }
  function loadPool(reset) {
    if (reset) {
      seq += 1;
      if (ctl) { try { ctl.abort(); } catch (e) {} }
      ctl = null;
      loading = false;
      nextOffset = 0;
      done = false;
      gridEl.innerHTML = '';
      emptyEl.hidden = true;
    }
    if (loading || done) return;
    loading = true;
    var mine = seq;
    var url = '/store/api/pool?limit=40&offset=' + nextOffset + (curQ ? '&q=' + enc(curQ) : '');
    var signal;
    if (typeof AbortController === 'function') { ctl = new AbortController(); signal = ctl.signal; }
    getJson(url, null, signal).then(function (r) {
      if (mine !== seq) return;
      loading = false;
      if (r.status === 404) { gone(); return; }
      if (r.status !== 200 || !r.json) throw new Error('pool ' + r.status);
      var j = r.json;
      $('live').hidden = !j.on_air;
      var pn = $('poolname');
      pn.textContent = String(j.pool_name || '');
      pn.hidden = !j.pool_name;
      total = Number(j.total || 0);
      $('poolcount').textContent = total ? (total + (total === 1 ? ' file' : ' files')) : '';
      var items = Array.isArray(j.items) ? j.items : [];
      for (var i = 0; i < items.length; i++) gridEl.appendChild(card(items[i]));
      nextOffset = typeof j.next === 'number' ? j.next : 0;
      done = typeof j.next !== 'number';
      if (!gridEl.firstChild) {
        emptyEl.textContent = curQ ? "nothing matches that. summon still works with words; we'll pick the closest thing." : 'nothing in the pool right now.';
        emptyEl.hidden = false;
      }
      poolErr('');
      checkMore();
    }).catch(function (e) {
      if (mine !== seq) return;
      loading = false;
      if (e && e.name === 'AbortError') return;
      poolErr("couldn't load the pool. trying again\u2026");
      setTimeout(function () { if (mine === seq && !done) loadPool(false); }, 4000);
    });
  }
  function checkMore() {
    if (done || loading) return;
    var r = moreEl.getBoundingClientRect();
    if (r.top < window.innerHeight + 600) loadPool(false);
  }
  if ('IntersectionObserver' in window) {
    new IntersectionObserver(function (es) {
      for (var i = 0; i < es.length; i++) if (es[i].isIntersecting) loadPool(false);
    }, { rootMargin: '600px 0px' }).observe(moreEl);
  } else {
    window.addEventListener('scroll', checkMore, { passive: true });
    window.addEventListener('resize', checkMore);
  }
  var qT = 0;
  $('q').addEventListener('input', function () {
    var v = this.value.trim();
    clearTimeout(qT);
    qT = setTimeout(function () {
      if (v === curQ) return;
      curQ = v;
      loadPool(true);
    }, 300);
  });

  // ---- summon: copy the code, show the bar ------------------------------------------------------------------
  function legacyCopy(t) {
    var ta = document.createElement('textarea');
    ta.value = t;
    ta.setAttribute('readonly', '');
    ta.style.cssText = 'position:fixed;top:0;left:0;width:1px;height:1px;opacity:0';
    document.body.appendChild(ta);
    ta.select();
    try { ta.setSelectionRange(0, t.length); } catch (e) {}
    var ok = false;
    try { ok = document.execCommand('copy'); } catch (e) {}
    document.body.removeChild(ta);
    return ok;
  }
  function copyText(t) {
    if (navigator.clipboard && navigator.clipboard.writeText && window.isSecureContext) {
      return navigator.clipboard.writeText(t).then(function () { return true; }, function () { return legacyCopy(t); });
    }
    return Promise.resolve(legacyCopy(t));
  }
  function updateChat() {
    var a = $('barchat');
    if (channel) {
      a.href = 'https://www.twitch.tv/popout/' + enc(channel) + '/chat?popout=';
      a.hidden = false;
    } else {
      a.hidden = true;
    }
  }
  function summon(it) {
    var code = String(it.code || '');
    copyText(code).then(function (ok) {
      var img = $('barimg');
      img.onerror = function () { img.style.visibility = 'hidden'; };
      img.style.visibility = '';
      img.src = it.thumb_url || '';
      $('barcode').textContent = ok ? 'copied ' + code : 'code ' + code;
      $('barhelp').textContent = ok ? 'now redeem summon in twitch chat and paste it.' : "couldn't copy. redeem summon in twitch chat and type it.";
      updateChat();
      $('bar').hidden = false;
    });
  }
  $('barx').addEventListener('click', function () { $('bar').hidden = true; });
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') $('bar').hidden = true; });

  @@TWITCH@@

  loadRewards();
  loadPool(true);
})();
`;

// Sign in with Twitch (30.7): the implicit grant, entirely in the browser. Present only when a client id is set.
const STORE_TWITCH_JS = String.raw`
  var CLIENT = body.getAttribute('data-twitch-client') || '';
  var BASE = body.getAttribute('data-stage-base') || (location.origin + '/');
  var REDIRECT = BASE + 'store';
  var KEY_STATE = 'stage.twitch.state', KEY_TOKEN = 'stage.twitch.token';
  var token = '';
  var user = null;
  var mem = {};
  function ssGet(k) { try { return sessionStorage.getItem(k) || mem[k] || ''; } catch (e) { return mem[k] || ''; } }
  function ssSet(k, v) { mem[k] = v; try { sessionStorage.setItem(k, v); } catch (e) {} }
  function ssDel(k) { delete mem[k]; try { sessionStorage.removeItem(k); } catch (e) {} }

  function randomState() {
    var a = new Uint8Array(16), s = '', i;
    if (window.crypto && crypto.getRandomValues) crypto.getRandomValues(a);
    else for (i = 0; i < a.length; i++) a[i] = Math.floor(Math.random() * 256);
    for (i = 0; i < a.length; i++) s += (a[i] < 16 ? '0' : '') + a[i].toString(16);
    return s;
  }
  function signIn() {
    var st = randomState();
    ssSet(KEY_STATE, st);
    location.href = 'https://id.twitch.tv/oauth2/authorize?response_type=token&client_id=' + enc(CLIENT) +
      '&redirect_uri=' + enc(REDIRECT) + '&scope=&state=' + st;
  }
  function signOut() {
    var t = token;
    token = ''; user = null;
    ssDel(KEY_TOKEN); ssDel(KEY_STATE);
    if (t) {
      try {
        fetch('https://id.twitch.tv/oauth2/revoke', { method: 'POST', body: new URLSearchParams({ client_id: CLIENT, token: t }) }).catch(function () {});
      } catch (e) {}
    }
    render();
  }
  function takeFragment() {
    var h = location.hash;
    if (!h || h.length < 2) return;
    var p = new URLSearchParams(h.slice(1));
    if (!p.has('access_token') && !p.has('error')) return;
    var tok = p.get('access_token') || '', st = p.get('state') || '';
    try { history.replaceState(null, '', location.pathname + location.search); } catch (e) {}
    var want = ssGet(KEY_STATE);
    ssDel(KEY_STATE);
    if (tok && want && st === want) ssSet(KEY_TOKEN, tok);
    else notice(p.has('error') ? 'sign-in was cancelled.' : "sign-in didn't check out. try again.");
  }
  function render() {
    var box = $('account');
    box.innerHTML = '';
    if (user) {
      var chip = el('span', 'chip');
      chip.appendChild(el('b', '', (user.login || '?').charAt(0)));
      chip.appendChild(document.createTextNode('@' + user.login));
      box.appendChild(chip);
      var out = el('button', 'btn ghost', 'sign out');
      out.type = 'button';
      out.addEventListener('click', signOut);
      box.appendChild(out);
    } else if (token) {
      box.appendChild(el('span', 'muted', 'signing in…'));
    } else {
      var b = el('button', 'btn twitch');
      b.type = 'button';
      b.innerHTML = '@@TWITCH_SVG@@';
      b.appendChild(document.createTextNode('sign in with twitch'));
      b.addEventListener('click', signIn);
      box.appendChild(b);
    }
    box.style.display = 'flex';
    box.style.alignItems = 'center';
    box.style.gap = '8px';
    if (!user) $('minesec').hidden = true;
  }
  function statusOf(s) {
    if (s.status === 'done') {
      var fresh = Date.now() - Number(s.created_at || 0) < 60000;
      return { text: fresh ? 'on stream now' : 'played ' + ago(Number(s.created_at || 0)), ok: fresh };
    }
    if (s.status === 'refunded') {
      var why = { off_air: 'stream was off air', no_match: 'nothing matched', no_effect: 'nothing to act on', disabled: 'summon was off' }[s.reason] || '';
      return { text: 'refunded' + (why ? ' · ' + why : ''), ok: false };
    }
    return { text: "didn't go through", ok: false };
  }
  function renderMine(list) {
    var box = $('minelist');
    box.innerHTML = '';
    for (var i = 0; i < list.length; i++) {
      var s = list[i], it = s.item;
      var row = el('div', 'row');
      var th = document.createElement('img');
      th.className = 'th';
      th.alt = '';
      if (it && it.thumb_url) th.src = it.thumb_url; else th.style.visibility = 'hidden';
      row.appendChild(th);
      row.appendChild(el('span', 'tt', it ? (it.title || it.code || '') : (s.input ? '"' + s.input + '"' : 'a summon')));
      var st = statusOf(s);
      row.appendChild(el('span', 'st' + (st.ok ? ' ok' : ''), st.text));
      box.appendChild(row);
    }
    if (!list.length) box.appendChild(el('div', 'msg', 'no summons yet.'));
    $('minesec').hidden = false;
  }
  function loadMe() {
    if (!token) return;
    getJson('/store/api/me', { Authorization: 'Bearer ' + token }).then(function (r) {
      if (r.status === 401) {
        token = ''; user = null; ssDel(KEY_TOKEN);
        notice('your twitch session ended. sign in again.');
        render();
        return;
      }
      if (r.status !== 200 || !r.json || !r.json.user) { render(); return; }
      user = r.json.user;
      render();
      renderMine(Array.isArray(r.json.summons) ? r.json.summons : []);
    }).catch(function () { render(); });
  }
  takeFragment();
  token = ssGet(KEY_TOKEN);
  render();
  loadMe();
`;

export function storePage(o: { stageBaseUrl: string; twitchClientId: string | null }): string {
    const client = o.twitchClientId && o.twitchClientId.trim() ? o.twitchClientId.trim() : null;
    const top = STORE_BODY_TOP.replace("@@ACCOUNT@@", client ? ACCOUNT_BLOCK : "");
    const js = STORE_JS.replace("@@TWITCH@@", () => (client ? STORE_TWITCH_JS.replace("@@TWITCH_SVG@@", () => TWITCH_SVG) : ""));
    return (
        '<!doctype html>\n<html lang="en"><head><meta charset="utf-8">' +
        '<meta name="viewport" content="width=device-width,initial-scale=1">' +
        '<meta name="robots" content="noindex,nofollow">' +
        '<title>studio store</title>' +
        FONT_LINKS +
        `<style>${STORE_CSS}</style></head>` +
        `<body data-page="store" data-stage-base="${esc(withSlash(o.stageBaseUrl))}"${client ? ` data-twitch-client="${esc(client)}"` : ""}>` +
        top +
        `<script>${js}</script></body></html>\n`
    );
}

// The store while it is locked (30.4): says nothing else, runs nothing, carries no client id.
export function storeLockedPage(): string {
    return (
        '<!doctype html>\n<html lang="en"><head><meta charset="utf-8">' +
        '<meta name="viewport" content="width=device-width,initial-scale=1">' +
        '<meta name="robots" content="noindex,nofollow">' +
        '<title>nothing here.</title>' +
        '<style>html,body{height:100%;margin:0;background:#000;color:#8f8f8f}' +
        'body{display:flex;align-items:center;justify-content:center;font:14px ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}</style>' +
        '</head><body><p>nothing here.</p></body></html>\n'
    );
}
