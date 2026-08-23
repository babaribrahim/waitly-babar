# Deliberately trivial: this app exists only to prove the CodeDeploy
# blue/green mechanism, not to be a real service. nginx serves the built-in
# "/" path, which doubles as the ALB health check — no separate endpoint
# needed.
FROM nginx:1.27-alpine

ARG COLOR=blue
ARG VERSION=v1

RUN printf '<!doctype html>\n<html>\n<head><meta charset="utf-8"><title>Waitly hello-world</title></head>\n<body style="font-family: system-ui, sans-serif; text-align: center; margin-top: 12vh;">\n<h1>Hello World - %s</h1>\n<p>version: %s</p>\n</body>\n</html>\n' "$COLOR" "$VERSION" > /usr/share/nginx/html/index.html

EXPOSE 80
