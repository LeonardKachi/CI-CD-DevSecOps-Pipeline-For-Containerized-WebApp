# syntax=docker/dockerfile:1

# Base image
# - Pinned to an exact version, never "latest", so every build is repeatable
#   and a vulnerability scan always refers to the same contents.
# - "nginx-unprivileged" runs as a non-root user and listens on port 8080.
# - "alpine-slim" ships the smallest package set, so there is less to patch
#   and less for an attacker to use.
ARG NGINX_VERSION=1.31.7
FROM nginxinc/nginx-unprivileged:${NGINX_VERSION}-alpine-slim

# Upgrade Alpine packages to include available security fixes.
# This runs as root during the image build.
USER root
RUN apk upgrade --no-cache

LABEL org.opencontainers.image.title="2048 WebApp" \
      org.opencontainers.image.description="Hardened Nginx container serving the 2048 game" \
      org.opencontainers.image.authors="Kachi (github.com/LeonardKachi)" \
      org.opencontainers.image.source="https://github.com/LeonardKachi/CI-CD-DevSecOps-Pipeline-For-Containerized-WebApp"

# Our own Nginx config: security headers, hidden server version, /health endpoint.
COPY docker/nginx.conf /etc/nginx/nginx.conf

# The game files. They stay owned by root, so the nginx user can read them
# but can never modify the site it is serving.
COPY app/ /usr/share/nginx/html/

# Run as a non-root user. A numeric ID lets ECS and scanners verify it.
USER 101

# Unprivileged ports only (above 1024). The load balancer forwards to this port.
EXPOSE 8080

# Used by local runs and the Jenkins test stage. ECS and the load balancer
# run their own health checks against the same /health path.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/health || exit 1

CMD ["nginx", "-g", "daemon off;"]
