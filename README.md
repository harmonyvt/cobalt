<div align="center">
    <br/>
    <p>
        <img src="web/static/favicon.png" title="cobalt" alt="cobalt logo" width="100" />
    </p>
    <p>
        best way to save what you love
        <br/>
        <a href="https://cobalt.tools">
            cobalt.tools
        </a>
    </p>
    <p>
        <a href="https://discord.gg/pQPt8HBUPu">
            💬 community discord server
        </a>
        <br/>
        <a href="https://x.com/justusecobalt">
            🐦 twitter
        </a>
        <a href="https://bsky.app/profile/cobalt.tools">
            🦋 bluesky
        </a>
    </p>
    <br/>
</div>

cobalt is a media downloader that doesn't piss you off. it's friendly, efficient, and doesn't have ads, trackers, paywalls or other nonsense.

paste the link, get the file, move on. that simple, just how it should be.

### cobalt monorepo
this monorepo includes source code for api, frontend, and related packages:
- [api tree & readme](/api/)
- [web tree & readme](/web/)
- [packages tree](/packages/)

it also includes documentation in the [docs tree](/docs/):
- [how to run a cobalt instance](/docs/run-an-instance.md)
- [how to protect a cobalt instance](/docs/protect-an-instance.md)
- [cobalt api instance environment variables](/docs/api-env-variables.md)
- [cobalt api documentation](/docs/api.md)

### local development
from the repo root:
- `pnpm dev` starts the api, web client, and metro for the installed Expo development client.
- `pnpm dev:ios` starts the full stack, generates native iOS files if needed, and launches the iOS development build.
- `pnpm dev:android` starts the full stack, generates native Android files if needed, and launches the Android development build.
- `pnpm dev:api`, `pnpm dev:web`, and `pnpm dev:mobile` start each app individually.

mobile now uses `expo-dev-client` instead of Expo Go. The first `pnpm dev:ios` / `pnpm mobile:ios` run builds and installs the development client locally, and later `pnpm dev` / `pnpm mobile:start` runs reconnect metro to that installed app.

the local defaults are:
- api: `http://localhost:9000`
- web: `http://localhost:5173`
- mobile default api: `http://localhost:9000`

to point web and mobile at a LAN-reachable local api for physical device testing, override `COBALT_DEV_API_URL`:
- `COBALT_DEV_API_URL=http://192.168.1.50:9000 pnpm dev`

to avoid port conflicts, you can also override `COBALT_DEV_API_PORT` and `COBALT_DEV_WEB_PORT`.

### ethics
cobalt is a tool that makes downloading public content easier. it takes **zero liability**.
the end user is responsible for what they download, how they use and distribute that content.
cobalt never caches any content, it [works like a fancy proxy](/api/src/stream/).

cobalt is in no way a piracy tool and cannot be used as such.
it can only download free & publicly accessible content.
same content can be downloaded via dev tools of any modern web browser.

### contributing
if you're considering contributing to cobalt, first of all, thank you! check the [contribution guidelines here](/CONTRIBUTING.md) before getting started, they'll help you do your best right away.

### thank you
cobalt is sponsored by [royalehosting.net](https://royalehosting.net/?partner=cobalt). a part of our infrastructure is hosted on their network. we really appreciate their kindness and support!

### licenses
for relevant licensing information, see the [api](api/README.md) and [web](web/README.md) READMEs.
unless specified otherwise, the remainder of this repository is licensed under [AGPL-3.0](LICENSE).
