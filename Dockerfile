FROM python:3.12-slim

# ffmpeg is the whole point; ca-certificates for HTTPS stream + R2 access.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg ca-certificates tzdata \
 && rm -rf /var/lib/apt/lists/*

ENV PYTHONUNBUFFERED=1 \
    TZ=America/Chicago \
    SPOOL_DIR=/tmp/spool \
    WORK_DIR=/tmp/work

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY recorder/ ./recorder/
COPY config/ ./config/

# Render sends SIGTERM on deploy/restart. supervisor.py traps it, closes the
# ffmpeg segments cleanly and flushes pending uploads before exiting, so a
# redeploy costs at most the few seconds it takes to drain.
STOPSIGNAL SIGTERM
CMD ["python", "-u", "recorder/supervisor.py"]
