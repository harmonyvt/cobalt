# Wallpaper maker (iPhone, iPad, Duo)

App only: no server route, no D1 migration, no APP-API-CONTRACT section. Mockup:
`/mnt/project-files/wallpapers/mockup.html` (project files).

## 1. What iOS allows (checked 2026-11-21)

- No app can set the wallpaper. The maker saves to Photos; the owner opens the photo, taps share, then
  "use as wallpaper".
- A Live Photo wallpaper moves on the Lock Screen only. It plays once when the phone wakes and then holds its key
  photo. Short, steady clips work best; iOS may say "motion not available" for a shaky clip.
- iOS keeps its clock on top of a Live Photo wallpaper. The 3D / depth effect (the subject over the clock) is iOS's
  own, works on stills only, finds the subject itself, and takes no depth map from an app. So the maker's depth edits
  are drawn into the pixels: blur and drift behind a sharp subject.
- The Mac is out of scope for now (Harmony, 2026-11-21): the menu items are iOS only.

## 2. Entry points

`make wallpaper…` in the library's context menu (the post's face file) and in the viewer's `more` menu (the file in
view). Any file the device has or can fetch: videos, animated webps and gifs, pictures. Opens full screen.

## 3. The sheet (`Cobalt/Screens/Wallpaper/WallpaperSheet.swift`)

- Wide (680 pt and up: the Duo spread, iPad): the Lock Screen preview on the left, the controls on the right.
  Narrow: preview on top.
- The preview is a Lock Screen with the date and clock where iOS puts them. "both screens" shows the Duo spread with
  the hinge.
- Range: one slider picks where the 3 s start; the clip ends on the still the Lock Screen keeps (its last frame). A
  picture makes a still.
- Depth: Vision's foreground mask (`VNGenerateForegroundInstanceMaskRequest`) is the subject; "subject in" and
  "subject out" brushes correct it; "find subject" turns the mask off (strokes alone). "show depth" swaps the preview
  for the depth map (subject white, background a dark gradient). Sliders: brush size, background blur, drift (Live
  Photo only), edge softness.
- `make it` writes the files on device and saves them to Photos, in the album "capystore wallpapers" with full Photos
  access (else straight into the library), then shows "open photos".

## 4. Files (`CobaltKit/Sources/CobaltKit/Wallpaper/`)

- `WallpaperSource`: frames from a video (AVFoundation), an animated webp/gif (ImageIO) or a picture, recognised by
  content.
- `WallpaperRenderer`: mask (Vision + strokes + softness), compose (background smeared under the subject, blurred,
  drifting on a full sine so the first and last frames are unmoved), depth map.
- `LivePhotoWriter` / `LivePhotoMovie`: HEIC still with maker note 17 = identifier; HEVC QuickTime movie with
  `com.apple.quicktime.content.identifier` and a `still-image-time` sample on the last frame; 30 fps, longest side
  1920 px. Frames are written one at a time.
- `WallpaperMaker`: range rules (1 to 3 s), Vision on every frame when the look needs a mask, the Duo cut (left and
  right halves with 18/762 of the width taken out for the hinge), two Live Photos for a Duo pair.

## 5. Tests

`CobaltKitTests/WallpaperTests.swift`: range and frame times, the Duo cut, a gif opened as animated, a real Live
Photo written (identifier in both files, a metadata track, ~2 s), a Duo pair, strokes painting the mask.
