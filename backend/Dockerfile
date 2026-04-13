# Stage 1: Install Python dependencies (build stage with pip)
FROM mcr.microsoft.com/azurelinux/base/python:3.12 AS python-builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --target=/app/deps -r requirements.txt

# Stage 2: Minimal runtime (distroless — no shell, no package manager)
FROM mcr.microsoft.com/azurelinux/distroless/python:3.12-nonroot
WORKDIR /app
ENV PYTHONPATH=/app/deps:/app/src

COPY --from=python-builder /app/deps /app/deps
COPY src/ ./src/

EXPOSE 8000

ENTRYPOINT ["python3", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
