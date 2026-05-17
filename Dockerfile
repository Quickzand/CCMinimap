FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=5055

WORKDIR /app

COPY server/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY server /app
COPY computercraft /app/computercraft
COPY waypoints.json /app/waypoints.json

RUN useradd --create-home --shell /usr/sbin/nologin appuser && \
    mkdir -p /cache && \
    chown -R appuser:appuser /cache /app

USER appuser

EXPOSE 5055

CMD ["gunicorn", "--bind", "0.0.0.0:5055", "--workers", "2", "--threads", "4", "--timeout", "30", "app:app"]
