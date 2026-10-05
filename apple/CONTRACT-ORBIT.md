# cobalt for apple: home orbit + focus contract (owner decisions, 2026-10-02)

Supersedes the orbit geometry in `CONTRACT.md` §5.1/§6 and the provisional `RingOrbitGeometry`.
Design source: `apple/mockup/Orbit2-C.dc.html` ("2d · option c · rainbow arcs", chosen by the owner),
generator and harness in the session scratchpad `orbit-build/` (gen.js, test2.js, geom2.js).

## 1. Orbit: 2D rainbow arcs (chosen)
- Flat, top-down, no perspective/3D: concentric semicircular bands centred on the two glass circles
  at the bottom centre of the content area; hairline paths; screen bottom cuts the lower half.
- Each band is a conveyor: planets glide along the arc from one end to the other and fade back in
  at the start; inner bands faster; neighbouring bands alternate direction (one constant switches
  this to all-same-direction if the owner asks). Planet size varies by band only (inner = newest =
  slightly larger), never by position; inner bands draw on top; items spaced to minimise overlap.
- Population: offline store, newest first, band capacities grow with radius; fewer media → fewer
  bands; ≥90 % of items on screen at every count; ≥36 pt short side on iPhone at 35 items.
- Newest planet always lands in view (ring 0 eases while a planet is born); inner bands spread
  outward while the star grows so its rings never cover planets.
- Autoplay tiers, Reduce Motion / Low Power / visibility pausing, VoiceOver container: unchanged.
- **File-type badge on every planet (owner, 2026-10-02):** a small glass capsule in the planet's
  top-right corner with the lowercase file type from the stored file (`mp4`, `webp`, `mov`, `gif`,
  `png`, `jpg`…; from the file extension / UTType, never guessed from the post). Inset ~4 pt, Plex
  Mono at caption size scaled by band; on planets whose short side is under ~40 pt it collapses to a
  tiny type dot/symbol (`film` for video, `sparkles` for webp, `photo` for image) so it never covers
  the frame; it stays upright, rides with the planet, and stays legible over bright frames (glass +
  contrast checked). The focused planet shows it too, and the shimmer's result badges (webp, link)
  sit beside it, not on top of it. Not in the VoiceOver label twice (the container summary covers it).
- Implementation: a `RainbowArcsGeometry: OrbitGeometry` (the seam already in `OrbitView.swift`),
  set as `CurrentOrbitGeometry`. Port the maths from `gen.js` (2D engine: arc conveyor, band
  capacities, ring-0 hold, star room-making), not by eye.

## 1b. Owner annotations on the demo (2026-10-03)
- **No empty middle**: the bands spread evenly over the whole orbit area (title → rail/circles);
  the gap between neighbouring bands never exceeds ~1.5× the median band spacing at any item
  count (3, 7, 14, 16, 24, 35) or state (rest, capsule states). Fewer items = fewer bands, but the
  bands still spread over the full height (planet size by band adapts).
- **Star in the middle**: the star is born at the visual centre of the orbit area (inside the
  innermost band, vertically centred between the title and the rail), not just above the circles;
  its morph travels from there into the newest slot. Implosion happens there too.

## 2b. Result hierarchy (owner annotation, 2026-10-03)
Supersedes the result layout of §2.5: exactly ONE prominent button per screen.
- One grouped glass card under the planet: title row (service · ref, length · size · bytes), then a
  row per link — webp link (`sparkles`, "webp link", size in pixels · bytes) and video link (`link`,
  "video link", shortened host…name) — each with trailing compact icon-only glass buttons
  **copy** (`doc.on.doc`, bounce → `checkmark`) and **share** (`square.and.arrow.up`), 44 pt hit
  targets, accessibility labels "copy webp link" etc. No big "copy link" pills inside rows.
- Primary (`.glassProminent`, full width): **copy webp link** when a webp exists, else the next
  sensible action (convert to webp / public share) — never two prominent buttons.
- Secondary row (equal-width compact glass buttons, one line each, icon + word): **another webp**
  (`sparkles`), **save to photos** (`photo.badge.arrow.down`), **close** (`xmark`).
- Consistent 12 pt spacing, one corner-radius family, nothing overlapping the tab bar.

## 2c. Progress, not tabs (owner, 2026-10-03)
Owner: "this doesn't make sense, it looks like tabs and there is no sense of progression; in the
whole video it wasn't obvious what anything was doing." The 4-cell step rail is styled like a
segmented control (iOS: a choice), so it reads as tabs. Superseded everywhere (home, share sheet,
Live Activity / Lock Screen / Dynamic Island) by ONE progress card:
- **Headline** (plain language, what is happening now): "downloading from <service>" / "uploading
  your file", "saving to your library", "reading the video", "making your webp", "packing the webp",
  "publishing the video" (public share); failure/cancel keep their existing copy.
- **Detail line** with real numbers only: bytes "2.1 of 4.3 MB", frames "frame 42 of 150", read
  "frame 4 of 9", waking "waking the server · 4 s" (+ footnote-size "it sleeps when idle" once),
  elapsed seconds otherwise.
- **Linear progress bar** (`ProgressView(value:total:)` styled monochrome): determinate when the
  server/phone reports bytes or frames, indeterminate (system indeterminate style or a calm sweep)
  otherwise; never fake percentages.
- **Stepper**: small dots joined by a line for the 4 steps (fetch|upload, save, read, webp) — done
  = filled with `checkmark`, current = ring + pulse, upcoming = hollow; tiny lowercase step names
  under the dots where width allows; text "step 2 of 4" for clarity and VoiceOver. No capsule/pill
  backgrounds, no selected-segment look, not interactive (`.accessibilityElement(children: .combine)`,
  value = "step 2 of 4, saving to your library, 2.1 of 4.3 MB").
- The star's growth mirrors the same progress value; both read as one story.
- Live Activity: Lock Screen = headline + detail + bar + stepper; Dynamic Island compact = step
  glyph + a tiny circular progress (`ProgressView(.circular)` determinate when known); expanded =
  headline, detail, bar.

## 2d. Crop (owner, 2026-10-04)
"crop into videos and create a webp from them": a spatial crop in addition to the time trim.
- Wire: `crop` = normalized rect `{ "x": 0..1, "y": 0..1, "w": 0..1, "h": 0..1 }` in the source's
  DISPLAY orientation (after rotation metadata), optional on `POST /studio/<sid>/render`. Absent =
  no crop (backward compatible). Server converts to pixels, rounds to even numbers, clamps inside
  the frame, rejects w/h under 64 px (`error.webp.invalid_params`), and applies ffmpeg `crop` BEFORE
  the scale; output width = min(requested width, cropped width), height keeps the crop's aspect.
- UI: a **crop** button (`crop`, secondary) in the focus convert/trim stage opens a crop editor ON
  the hero preview (the playing video): a rectangle with corner + edge handles (≥44 pt targets),
  drag inside to move, pinch to scale, rule-of-thirds grid while adjusting, dimmed outside area;
  aspect presets as a native segmented picker or menu: original, 1:1, 4:5, 9:16, 16:9, free; live
  readout of the output size ("480×480"); **done** and **reset**. The crop persists with the trim for
  that run and is shown as a small badge ("crop 1:1") next to the trim readout; "make webp" sends it.
- The result tile/planet shows the cropped webp's real aspect. Reduce Motion respected; haptic on
  snapping to an aspect preset. Mac: same editor with pointer drag + the inspector holding presets.

## 2. After the morph: focus (new state, owner's request)
"after the video is generated and morphed it should be in focus, elevated, with options to public
share and convert to webp, and both go through a shimmer transformation at the end."
1. **Focus**: when the star's morph lands (pipeline `.ready`), the new planet lifts out of its band
   into focus: scales to a hero size (≈ 60 % of the content width on iPhone, capped by height, real
   aspect ratio), centred above the circles, elevated (Liquid Glass bezel, soft shadow/glow,
   specular highlight), autoplaying muted (tap = sound); title/meta under it (service · ref,
   length · size in pixels). The orbit behind dims (~40 %) and slows (~0.3×) but keeps moving.
   The work card is not shown in focus; the planet IS the card.
2. **Choices** (icon-first glass buttons under the planet): primary pair **public share**
   (`link.badge.plus`) and **convert to webp** (`sparkles`); secondary **save to photos**
   (`photo.badge.arrow.down`) and **close** (`xmark`). On plain cobalt / legacy fork the
   unavailable ones hide (capabilities).
3. **Convert to webp**: clip ≤ 10 s → renders the whole clip at once; > 10 s → the trim timeline
   slides in under the focused planet (bracket on the first 10 s, rubber band + tick unchanged),
   then "make webp". While rendering, the decoded-frame progress shows ON the planet: a row of frame
   ticks along its bottom edge lighting up per decoded frame, then the planet breathes while packing
   (open-ended, no fake percent).
4. **Public share**: hosts the original (`runHostOriginal`) with an indeterminate glass sweep on
   the planet's edge while publishing.
5. **Shimmer transformation** at the end of either: a diagonal specular light sweep crosses the
   planet (~0.8 s), then
   - webp: the planet's content crossfades into the animated webp, a `webp` badge (`sparkles`)
     settles on its corner;
   - share: a `link` badge settles on its corner;
   and the result actions appear under it: **copy link** (`doc.on.doc`, bounce → `checkmark`
   "copied") and **share** (`square.and.arrow.up`, system share sheet). `.sensoryFeedback(.success)`.
   Both paths can be done in turn; each adds its badge.
6. **Return**: close (or swipe down) springs the planet back into the newest slot of band 0,
   carrying its badges; the orbit brightens and resumes speed.
7. **Failure** during convert/share: the planet stays in focus, the badge area shows a small
   implosion pulse, and the compact inline error sits under it with retry; never the full-screen
   implosion (that is for the star before it becomes a video).
8. **Reduce Motion**: no lift animation (crossfade into focus), shimmer → brief highlight
   crossfade, no breathing; Low Power: no glow animation.
9. Wide layouts: focus happens in the content column; on iPad/Mac the trim inspector may host the
   quality picker, but the planet stays the focus.
