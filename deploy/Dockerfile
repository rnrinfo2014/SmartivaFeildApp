# syntax=docker/dockerfile:1
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app
COPY backend/requirements.lock ./requirements.lock
# Optional session CA is available only during installation, never copied into
# the image. Ordinary VPS builds use the image's standard certificate trust.
RUN --mount=type=secret,id=proxy_ca \
    if [ -f /run/secrets/proxy_ca ]; then export PIP_CERT=/run/secrets/proxy_ca; fi; \
    pip install --no-cache-dir -r requirements.lock
RUN groupadd --gid 10001 fieldops && useradd --uid 10001 --gid fieldops --create-home fieldops \
    && mkdir -p /var/lib/smartiva/audio && chown -R fieldops:fieldops /var/lib/smartiva
COPY --chown=fieldops:fieldops backend/app ./app
USER fieldops
EXPOSE 8000
CMD ["uvicorn", "app.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000", "--no-access-log", "--no-proxy-headers"]
