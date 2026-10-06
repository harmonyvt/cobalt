// Reference model for apple/CONTRACT-GALLERY.md (owner interview 2026-10-07). Plain ES5-compatible JS so the
// boards can inline it verbatim and node can test it. Geometry of the borderless gallery image, slideshow
// lengths and caps, frame sizes, and the labelled estimates.
var GM = (function () {
  var MAX_LONG = 30000, MAX_PIXELS = 40e6, CROP_TOL = 0.004;
  function even(n) { n = Math.floor(n); return Math.max(2, n - (n % 2)); }
  function commonAspect(sizes) {
    var seen = {}, best = null;
    sizes.forEach(function (s) { var k = s.w + 'x' + s.h; seen[k] = (seen[k] || 0) + 1; if (!best || seen[k] > seen[best.k]) best = { k: k, w: s.w, h: s.h }; });
    return best.w / best.h;
  }
  function rowCounts(n, N) {
    var r = Math.ceil(n / N), base = Math.floor(n / r), extra = n - base * r, out = [];
    for (var i = 0; i < r; i++) out.push(i < extra ? base + 1 : base);
    return out;
  }
  // sizes: [{w,h}] photos in the chosen order. layout: 'strip' | 'grid2' | 'grid3' | 'row'.
  // Returns {width, height, cells:[{i,x,y,w,h,crop,up}], scaled}. No gaps, no borders: the cells tile the canvas exactly.
  // grid width: 2160 at most, and no wider than the fullest row's photos side by side (never upscales a full row);
  // a cell in a shorter row is wider, so its photo may be drawn larger than its own pixels: `up` = that factor (0 = not).
  function layout(sizes, kind) {
    if (!sizes || sizes.length < 2) throw new Error('needs 2 photos');
    var n = sizes.length;
    function build(scaleTo) {
      var cells = [], W, H;
      if (kind === 'strip') {
        W = scaleTo; H = 0;
        sizes.forEach(function (s, i) { var h = even(Math.round(W * s.h / s.w)); cells.push({ i: i, x: 0, y: H, w: W, h: h, crop: false, up: 0 }); H += h; });
      } else if (kind === 'row') {
        H = scaleTo; W = 0;
        sizes.forEach(function (s, i) { var w = even(Math.round(H * s.w / s.h)); cells.push({ i: i, x: W, y: 0, w: w, h: H, crop: false, up: 0 }); W += w; });
      } else {
        var N = kind === 'grid3' ? 3 : 2, A = commonAspect(sizes), k0 = 0;
        W = scaleTo; H = 0;
        rowCounts(n, N).forEach(function (k) {
          var cw = even(W / k), last = W - (k - 1) * cw, rh = even(Math.round(cw / A)), x = 0;
          for (var j = 0; j < k; j++) {
            var w = j === k - 1 ? last : cw, s = sizes[k0 + j], ca = w / rh, a = s.w / s.h;
            var up = Math.max(w / s.w, rh / s.h);
            cells.push({ i: k0 + j, x: x, y: H, w: w, h: rh, crop: Math.abs(a - ca) / ca >= CROP_TOL, up: up > 1.01 ? Math.round(up * 10) / 10 : 0 });
            x += w;
          }
          H += rh; k0 += k;
        });
      }
      return { width: W, height: H, cells: cells };
    }
    var minW = Math.min.apply(null, sizes.map(function (s) { return s.w; }));
    var minH = Math.min.apply(null, sizes.map(function (s) { return s.h; }));
    var base = kind === 'strip' ? even(Math.min(1080, minW)) : kind === 'row' ? even(Math.min(1080, minH))
      : even(Math.min(2160, rowCounts(n, kind === 'grid3' ? 3 : 2)[0] * minW));
    var r = build(base);
    var long = Math.max(r.width, r.height), px = r.width * r.height;
    if (long > MAX_LONG || px > MAX_PIXELS) {
      var s = Math.min(MAX_LONG / long, Math.sqrt(MAX_PIXELS / px));
      r = build(even(base * s));
      r.scaled = true;
    } else r.scaled = false;
    return r;
  }
  // about 0.17-0.37 MB per megapixel measured on synthetic stills (ffmpeg -q:v 3); the estimate uses 0.3
  function jpegMB(w, h) { return Math.round(w * h / 1e6 * 0.3 * 10) / 10; }

  // ---- slideshow ----
  var FADE = 0.3, WEBP_MAX = 60, MP4_MAX = 180, MOTION_MAX = 60;
  // items: [{t:'photo'|'video'|'gif', len?}] in play order; sec: one value for every photo (0.5-10, step 0.5)
  function length(items, sec) {
    var t = 0, motion = 0, photos = 0;
    items.forEach(function (it) { if (it.t === 'photo') { t += sec; photos++; } else { t += it.len; motion += it.len; } });
    return { total: Math.round(t * 10) / 10, motion: Math.round(motion * 10) / 10, photos: photos };
  }
  // what may be made: {ok, why, fitSec} per format
  function check(items, sec, format) {
    var L = length(items, sec), cap = format === 'webp' ? WEBP_MAX : MP4_MAX;
    if (items.length < 2) return { ok: false, why: 'few' };
    if (L.motion > MOTION_MAX + 0.5) return { ok: false, why: 'motion', L: L };
    if (L.total > cap + 0.5) {
      var fit = L.photos ? Math.floor(((cap - L.motion) / L.photos) * 2) / 2 : 0;
      return { ok: false, why: 'long', L: L, cap: cap, fitSec: fit >= 0.5 ? fit : null };
    }
    return { ok: true, L: L };
  }
  // frame of a slideshow: mp4 1080 on the short side (server's slideshowFrame); webp: the webp width (320|480) across
  function frame(sizes, choice, format, webpWidth) {
    var A = choice === '9:16' ? 9 / 16 : choice === '1:1' ? 1 : commonAspect(sizes);
    if (format === 'webp') { var w = webpWidth || 480; return { w: w, h: even(w / A) }; }
    if (choice === '9:16') return { w: 1080, h: 1920 };
    if (choice === '1:1') return { w: 1080, h: 1080 };
    // the server's slideshowFrame (studio.ts): the most common size, 1080 on the short side, 1920 at most on the long
    var seen = {}, best = null;
    sizes.forEach(function (s) { var k = s.w + 'x' + s.h; seen[k] = (seen[k] || 0) + 1; if (!best || seen[k] > seen[best.k]) best = { k: k, w: s.w, h: s.h }; });
    var sc = Math.min(1080 / Math.min(best.w, best.h), 1920 / Math.max(best.w, best.h));
    return { w: even(best.w * sc), h: even(best.h * sc) };
  }
  var QF = { low: 0.7, med: 1, high: 1.5 }; // quality factor: an assumption, not measured
  // webp KB: measured at 480x600 q75 on synthetic stills: 31 KB a still, 161 KB a crossfade (4 frames);
  // video 132 KB/s at 480x560 q75 (the owner's 9.6 s clip, deploy/cloudflare/README.md)
  function webpKB(items, fade, fr, q) {
    var f = fr.w * fr.h / (480 * 600), fv = fr.w * fr.h / (480 * 560), qf = QF[q || 'med'], kb = 0;
    items.forEach(function (it) { kb += it.t === 'photo' ? 31 * f : 132 * fv * it.len; });
    if (fade) kb += 161 * f * (items.length - 1);
    return Math.round(kb * qf);
  }
  // mp4 MB (CONTRACT-GALLERY 6.5): 0.025 MB/s for stills, 0.25 MB/s for video at 1080x1350, scaled by pixels
  function mp4MB(items, sec, fr) {
    var f = fr.w * fr.h / (1080 * 1350), mb = 0;
    items.forEach(function (it) { mb += it.t === 'photo' ? 0.025 * sec * f : 0.25 * it.len * f; });
    return Math.round(mb * 10) / 10;
  }
  function fmt(x) { if (x >= 60) { var m = Math.floor(x / 60), r = Math.round(x - m * 60); if (r === 60) { m++; r = 0; } return m + ':' + (r < 10 ? '0' : '') + r; } return (Math.round(x * 10) / 10).toFixed(1) + ' s'; }
  function size(kb) { return kb >= 1000 ? (Math.round(kb / 100) / 10).toFixed(1) + ' MB' : Math.round(kb) + ' KB'; }
  return { even: even, layout: layout, rowCounts: rowCounts, commonAspect: commonAspect, jpegMB: jpegMB, length: length, check: check, frame: frame, webpKB: webpKB, mp4MB: mp4MB, fmt: fmt, size: size, WEBP_MAX: WEBP_MAX, MP4_MAX: MP4_MAX };
})();
if (typeof module !== 'undefined') module.exports = GM;
