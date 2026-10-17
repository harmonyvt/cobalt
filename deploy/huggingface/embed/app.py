"""The cobalt library's embedding server (README.md).

A private Hugging Face Space running EmbeddingGemma 2 (text and image encoders only). The API
Worker (deploy/cloudflare/api/src/embed.ts) calls it for two things:

- documents: one vector per library post, from its title text and its poster image;
- queries: one vector per search, from the words typed.

Both land in the same space, so a text query finds a post by what its poster shows.
"""

import hmac
import io
import os
import threading
from typing import Literal, Optional

import httpx
import torch
from fastapi import FastAPI, Header, HTTPException
from PIL import Image
from pydantic import BaseModel, Field

MODEL_ID = os.environ.get("EMBED_MODEL", "google/embeddinggemma-2")
# Optional shared secret (a Space secret). The Space being private already makes the Hugging
# Face proxy demand a token; this second check keeps the server closed if it is ever made public.
EMBED_KEY = os.environ.get("EMBED_KEY", "")
# Posters are fetched only from here: the server never fetches an arbitrary URL.
IMAGE_PREFIX = os.environ.get("ALLOWED_IMAGE_PREFIX", "https://media.capybaraharmony.com/")
MAX_IMAGE_BYTES = 8 * 1024 * 1024
MAX_INPUTS = 16
DIMS = (128, 256, 512, 768)

app = FastAPI(title="cobalt-embed")
_model = None
_lock = threading.Lock()


def model():
    global _model
    with _lock:
        if _model is None:
            from sentence_transformers import SentenceTransformer

            # Text and image only: the audio encoder (300M) is never loaded. float32: CPUs here
            # have no bfloat16 and float16 breaks this model (README of the model).
            _model = SentenceTransformer(
                MODEL_ID,
                device="cpu",
                config_kwargs={"audio_config": None},
                model_kwargs={"torch_dtype": torch.float32},
            )
        return _model


@app.on_event("startup")
def warm() -> None:
    # Load in the background so the Space reports "running" quickly; the first call waits.
    threading.Thread(target=model, daemon=True).start()


class Item(BaseModel):
    title: Optional[str] = Field(default=None, max_length=400)
    text: str = Field(default="", max_length=4000)
    image_url: Optional[str] = Field(default=None, max_length=1000)


class EmbedRequest(BaseModel):
    kind: Literal["document", "query"]
    dims: int = 256
    inputs: list[Item]


def fetch_image(url: str) -> Optional[Image.Image]:
    if not url.startswith(IMAGE_PREFIX):
        return None
    try:
        with httpx.Client(timeout=15, follow_redirects=False) as c:
            with c.stream("GET", url) as r:
                if r.status_code != 200:
                    return None
                buf = bytearray()
                for chunk in r.iter_bytes():
                    buf.extend(chunk)
                    if len(buf) > MAX_IMAGE_BYTES:
                        return None
        img = Image.open(io.BytesIO(bytes(buf)))
        img.seek(0)  # an animated WebP or GIF: its first frame
        return img.convert("RGB")
    except Exception:
        return None


def clean(s: Optional[str]) -> str:
    # The prompt format uses "|" as its separator.
    return " ".join((s or "").replace("|", " ").split())


@app.get("/")
def health() -> dict:
    return {"status": "ok", "model": MODEL_ID, "ready": _model is not None}


@app.post("/embed")
def embed(req: EmbedRequest, x_embed_key: Optional[str] = Header(default=None)) -> dict:
    if EMBED_KEY and not hmac.compare_digest(x_embed_key or "", EMBED_KEY):
        raise HTTPException(status_code=401, detail="unauthorized")
    if req.dims not in DIMS:
        raise HTTPException(status_code=400, detail="dims")
    if not 1 <= len(req.inputs) <= MAX_INPUTS:
        raise HTTPException(status_code=400, detail="inputs")

    m = model()
    vectors: list[list[float]] = []
    images: list[bool] = []
    for it in req.inputs:
        if req.kind == "query":
            v = m.encode(
                clean(it.text),
                prompt_name="SearchQuery",
                truncate_dim=req.dims,
                normalize_embeddings=True,
            )
            used = False
        else:
            doc = f"title: {clean(it.title) or 'none'} | text: {clean(it.text)}"
            img = fetch_image(it.image_url) if it.image_url else None
            if img is not None:
                v = m.encode(
                    {"text": f"{doc} <|image|>", "image": [img]},
                    truncate_dim=req.dims,
                    normalize_embeddings=True,
                )
            else:
                v = m.encode(doc, truncate_dim=req.dims, normalize_embeddings=True)
            used = img is not None
        vectors.append([round(float(x), 6) for x in v])
        images.append(used)
    return {"model": MODEL_ID, "dims": req.dims, "vectors": vectors, "images": images}
