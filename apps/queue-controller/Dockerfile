FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Accepted but unused: scripts/deploy.py is shared across services and
# always passes --build-arg COLOR=/VERSION=.
ARG VERSION
ARG COLOR

EXPOSE 80

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "80"]
