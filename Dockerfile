# ZITLAS FastAPI backend — Railway production image.
#
# Builds ONLY the FastAPI service; Flutter (mobile/) is not part of this
# container. The root .dockerignore limits the build context to what the
# backend reads at runtime, and the COPY lines below name those same paths, so
# the image does not depend on the context being clean.
# See railway.json for the deploy configuration.

FROM python:3.14.3-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# ── Dependencies (their own layer: cached until a requirements file changes) ─
COPY requirements.txt ./requirements.txt
COPY backend/requirements.txt ./backend/requirements.txt

# CPU-only PyTorch first. sentence-transformers (the RAG embedding model in
# services/kb_manager.py) depends on torch, and the default PyPI torch is the
# CUDA build — it pulls well over a gigabyte of NVIDIA libraries into the
# image. Railway runs on CPU, where the CPU build computes the same
# embeddings.
# The requirements are then installed with that CPU build pinned as a
# constraint, so pip fails rather than swap in another torch, and the last
# step fails the build if a CUDA-enabled torch or any NVIDIA / triton package
# is in the image.
RUN pip install torch --index-url https://download.pytorch.org/whl/cpu \
 && pip freeze | grep -i '^torch==' > /tmp/torch-cpu.txt \
 && pip install -r backend/requirements.txt -c /tmp/torch-cpu.txt \
 && python -c "import sys, torch, importlib.metadata as md; cuda = [d.metadata['Name'] for d in md.distributions() if (d.metadata['Name'] or '').lower().startswith(('nvidia-', 'triton', 'cuda-'))]; sys.exit('CUDA build in the image: torch.version.cuda=%s, packages=%s' % (torch.version.cuda, cuda) if (torch.version.cuda or cuda) else 0)" \
 && rm /tmp/torch-cpu.txt

# ── Application: exactly the paths the backend reads at runtime ─────────────
COPY backend/ ./backend/
COPY frontend/website/ ./frontend/website/
COPY food_profiles/ ./food_profiles/
# The NEW food dataset — the only one services/food_engine.py serves. The OLD
# 4,520-food dataset is deliberately not in the image: the engine refuses it.
COPY food_dataset/zitlas_food_database_enriched_canonical.json ./food_dataset/
# The three Personal Coaching Program banners main.py serves to the website.
COPY ["mobile/assets/images/10 program.png", "mobile/assets/images/1 month program.png", "mobile/assets/images/3 month.png", "./mobile/assets/images/"]

# Railway assigns the port through $PORT.
EXPOSE 8000

# railway.json's startCommand runs the same command; this is the image default.
CMD ["sh", "-c", "cd backend && exec uvicorn main:app --host 0.0.0.0 --port ${PORT:-8000}"]
