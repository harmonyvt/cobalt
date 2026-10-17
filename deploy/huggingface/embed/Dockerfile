# Hugging Face Docker Space: the cobalt library's embedding server (README.md).
FROM python:3.12-slim

RUN useradd -m -u 1000 user
WORKDIR /app

# CPU-only torch keeps the image small (a free Space has no GPU).
RUN pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY --chown=user app.py .
USER user
ENV HF_HOME=/home/user/.cache/huggingface \
    OMP_NUM_THREADS=2
EXPOSE 7860
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "7860", "--workers", "1"]
