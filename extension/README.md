# Save to Capystore

A Manifest V3 extension that puts a **Save to Capystore** button on posts in X, YouTube, Twitch clips and Instagram. One codebase loads unpacked in Chrome and is wrapped by the Safari app in `apple/` (`CapystoreSafari`).

It is for Harmony, sideloaded. There is no store listing. The background service worker is the only thing that calls the API. It sends `credentials: "omit"`, so it does not read the cookies of X, YouTube, Twitch, Instagram, or Capystore.

## Before the extension can sign in

The approve page and the Safari poll need a deploy of the web Worker and the API Worker, and one new D1 migration. **That migration is not applied by this change.** Apply it yourself, then deploy:

```sh
cd deploy/cloudflare/web && npx cf d1 migrations apply 42f18bb0-837a-47f7-b1e2-606eb705ab6c --dir ../d1/migrations
```

`0039_extension_pairings.sql` is the file. Chrome's redirect sign-in reuses the existing `auth_handoffs` table, so it works once the web Worker that serves `/connect/extension` is deployed. Safari's poll needs `0039` as well. Until that table exists, `POST /auth/extension/begin` answers 503.

## Sign in

The extension does not ask you to paste an API key.

1. Click the toolbar button and choose **Sign in**.
2. Capystore opens on `/connect/extension`. Cloudflare Access runs first if it needs to.
3. The page names the session from the browser you are in, for example **Browser extension – Chrome on Mac**.
4. Click **Approve**.

Chrome finishes through `chrome.identity.launchWebAuthFlow`: the page redirects to `https://<extension-id>.chromiumapp.org/` with a one-time code, and the extension trades that code at `POST /auth/exchange` (PKCE). Safari cannot complete that redirect, so the extension opens a normal tab, you approve, and the extension polls `POST /auth/extension/poll` until the session exists. If the Chrome redirect throws, Chrome uses the same poll.

The session is an ordinary device session (`platform: "extension"`, 90-day sliding expiry). It shows up in Settings → Account on the web and in the Apple app, and you can sign it out there. **Sign out** in the popup revokes it too. A 401 sends the extension back to signed out.

Sessions are not cut down to a smaller permission. The same is true of the share extension. This one is separate from the web app and the Apple apps, and revoking it does not sign those out.

## What the button saves

The button is injected on each post, including posts in a feed, not only the permalink. The URL it sends is that post's URL (the status, the watch or Shorts id, the clip, the `/p/` or `/reel/`), not the page you are scrolling. `POST /studio` is sent with `origin: "extension"` and `queue: true`. Those saves do not appear in `GET /studio/recent` (that list stays the share sheet's). The popup keeps the recent list for this browser.

The capybara on the button and in the popup is the fluffy capy sprite sheet: idle, saving, saved, error, and sleeping. Sleeping is signed out or offline. The toolbar icon is the idle head. The 16px icon is a tighter crop of the 128px head, because the supplied 16px icon was soft.

Per-site switches are on the popup's **Sites** button (the options page).

## Chrome

From the repo root:

```sh
cd extension
npm ci
npm test
npm run build
```

In Chrome:

1. Open `chrome://extensions`.
2. Turn on **Developer mode**.
3. **Load unpacked** and choose the `extension/dist` folder (the folder that contains `manifest.json`, not `extension/` itself).
4. Pin **Save to Capystore**.
5. Click it and sign in.

`npm run build` has to be run again after a code change, and the extension reloaded on `chrome://extensions`.

## Safari

This machine has no Xcode, so the Safari app is not built here. On a Mac, from the repo root, after the same `npm run build`:

```sh
cd apple
xcodegen generate
xcodebuild \
  -project Cobalt.xcodeproj \
  -scheme CapystoreSafari \
  -destination 'platform=macOS' \
  -derivedDataPath .build/safari \
  CODE_SIGNING_ALLOWED=NO \
  build
open .build/safari/Build/Products/Debug/CapystoreSafari.app
```

`CapystoreSafari` is its own app. It is not embedded in the Cobalt iOS or Mac app, so a TestFlight build of Cobalt does not include it. The extension target's run script copies `extension/dist` into the appex. If that folder is missing, the build stops and says to run `npm run build`.

Then in Safari:

1. Settings → Advanced → **Show features for web developers**.
2. Develop → **Allow Unsigned Extensions**.
3. Settings → Extensions → turn on **Save to Capystore**.
4. Click the toolbar button and sign in. Approve the tab that opens. The popup picks up the session when the poll succeeds.

The container app's window repeats those enable steps. Rebuild `extension/dist` before `xcodebuild` whenever the extension code changes. `xcodegen generate` is only needed again when `apple/project.yml` changes.

## Tests

`npm test` in `extension/` checks URL extraction against fixture HTML (including an open shadow root, the way YouTube hides anchors), the save and poll loop, both sign-in paths, and that the manifest does not request cookies.

The API and web Worker tests cover `POST /auth/extension/begin`, `POST /auth/extension/poll`, the approve page, and `origin: "extension"` staying out of `GET /studio/recent`. From `deploy/cloudflare/api` and `deploy/cloudflare/web`: `npm test`.
