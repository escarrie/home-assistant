FROM python:3.12-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends tini tzdata \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY mail2md.py /app/mail2md.py

ENV MAIL_DIR=/data/mail \
    OUTPUT_DIR=/data/markdown \
    PYTHONUNBUFFERED=1 \
    TZ=Europe/Brussels

# Utilisateur non-root par défaut (surchargé par `user:` dans le compose).
USER 1000:1000

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["python", "/app/mail2md.py"]
