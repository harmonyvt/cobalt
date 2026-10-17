---
title: cobalt-embed
emoji: 🔎
colorFrom: indigo
colorTo: gray
sdk: docker
app_port: 7860
pinned: false
license: apache-2.0
---

# cobalt-embed

The embedding server behind the cobalt library's search (`GET /library/search` on the API Worker,
`deploy/cloudflare/APP-API-CONTRACT.md` section 21). It runs Google's
[EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2) on CPU, with the text and image
encoders only, and turns each library post (its title text plus its poster) and each search query into
a 256-number vector in the same space.

## Create the Space (once, by the owner)

1. On huggingface.co: **New Space**, name `cobalt-embed`, SDK **Docker** (blank), hardware
   **CPU basic**, visibility **Private**. Docker Spaces need a Hugging Face PRO account (a free account
   gets 402 Payment Required). The live one is `capybaraharmony/cobalt-embed`, created 2026-10-17.
2. Upload the four files in this folder (`README.md`, `Dockerfile`, `requirements.txt`, `app.py`), or push
   them with git. The first build downloads the model and takes several minutes.
3. Space settings > **Variables and secrets**: add the secret `EMBED_KEY` (any long random string).
4. Make a Hugging Face access token with **read** access (Settings > Access Tokens); the private
   Space's proxy lets requests with it through.
5. Add to `~/.config/cobalt/secrets.json` next to `COBALT_API_KEY`:
   `"EMBED_TOKEN": "<hf token>"` and `"EMBED_KEY": "<the same EMBED_KEY>"`, then deploy the API
   (`deploy/cobalt-deploy api`). `EMBED_URL` in `deploy/cloudflare/api/cloudflare.config.ts` must match
   the Space's URL (`https://<owner>-cobalt-embed.hf.space`).

Without `EMBED_TOKEN` the API leaves search off (`features.search: false`) and indexes nothing.

## Contract

`POST /embed`, headers `Authorization: Bearer <hf token>` (the private Space's proxy) and
`x-embed-key: <EMBED_KEY>`:

```json
{ "kind": "document" | "query", "dims": 256,
  "inputs": [ { "title": "…", "text": "…", "image_url": "https://media.capybaraharmony.com/…" } ] }
```

→ `{ "model": "google/embeddinggemma-2", "dims": 256, "vectors": [[…]], "images": [true] }`.
At most 16 inputs. Documents are encoded as `title: <title> | text: <text>` plus the image; queries
with the model's `SearchQuery` prompt. Vectors are L2-normalized after truncation, so a dot product is
the cosine. Images are fetched only from `ALLOWED_IMAGE_PREFIX` (default the public media domain);
anything else, or a failed fetch, embeds the text alone and reports `false` in `images`.

`GET /` → `{ "status": "ok", "model", "ready" }` (`ready` turns true once the model is loaded).

A CPU basic Space sleeps after a stretch without traffic; the first call after that waits while it boots.
