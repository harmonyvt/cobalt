export function createTurnstileHtml(sitekey: string) {
  return `
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta
      name="viewport"
      content="width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover"
    />
    <style>
      :root {
        color-scheme: dark;
        font-family: -apple-system, BlinkMacSystemFont, sans-serif;
      }
      body {
        margin: 0;
        min-height: 100vh;
        display: flex;
        align-items: center;
        justify-content: center;
        background: #111827;
        color: #f9fafb;
      }
      main {
        width: min(92vw, 24rem);
        border-radius: 20px;
        padding: 24px;
        background: rgba(17, 24, 39, 0.9);
        box-shadow: 0 20px 40px rgba(0, 0, 0, 0.35);
      }
      h1 {
        font-size: 22px;
        margin: 0 0 12px;
      }
      p {
        margin: 0 0 16px;
        line-height: 1.4;
        color: #d1d5db;
      }
    </style>
    <script>
      function postMessage(kind, value) {
        window.ReactNativeWebView?.postMessage(JSON.stringify({ kind, value }));
      }

      function renderTurnstile() {
        if (!window.turnstile) return;

        window.turnstile.render("#turnstile", {
          sitekey: "${sitekey}",
          callback: function(token) {
            postMessage("token", token);
          },
          "error-callback": function(code) {
            postMessage("error", code);
          },
          "expired-callback": function() {
            postMessage("expired", "expired");
          }
        });
      }

      window.onload = function() {
        if (window.turnstile) {
          renderTurnstile();
        } else {
          window.addEventListener("message", renderTurnstile, { once: true });
        }
      };
    </script>
    <script src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit" async defer></script>
  </head>
  <body>
    <main>
      <h1>Verify this mobile session</h1>
      <p>Complete the challenge to request a short-lived Cobalt bearer token.</p>
      <div id="turnstile"></div>
    </main>
  </body>
</html>`;
}
