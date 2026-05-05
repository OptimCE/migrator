# ---------- stage 1: build ----------
FROM python:3.12-slim AS builder

WORKDIR /build
COPY requirements.txt .

RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---------- stage 2: runtime ----------
FROM python:3.12-slim

RUN groupadd -r app && useradd -r -g app -d /app -s /sbin/nologin app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY --from=builder /install /usr/local

# Bake the migration manifest, SQL files, and database.config into the image.
# Each image release ships its target schema version; running the container brings
# every database in database.config up to that version.
COPY migrator.py .
COPY database.config .
COPY migrations/ migrations/

RUN chown -R app:app /app
USER app

ENTRYPOINT ["python", "migrator.py"]
CMD []
