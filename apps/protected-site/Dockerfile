# ECR Public's mirror of the official image, not docker.io directly -
# CodeBuild's shared egress IPs hit Docker Hub's anonymous-pull rate
# limit (429 Too Many Requests) often enough to be a real, seen-in-CI
# problem, not a theoretical one. ECR Public isn't subject to it.
FROM public.ecr.aws/docker/library/python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 80

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "80"]
