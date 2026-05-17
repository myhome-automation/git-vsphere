# Custom nginx image with the home-lab path-based proxy config baked in.
# Self-contained — runs anywhere without needing a volume-mounted conf.
#
# Build:
#   cd nginx-proxy/
#   podman build -t quay.io/<your-org>/nginx-homelab-proxy:1.0 .
#
# Push (after `podman login quay.io`):
#   bash push.sh quay.io/<your-org>/nginx-homelab-proxy:1.0
#
# Run (HA pair: two containers on different host ports):
#   podman run -d --restart=always --name nginx-1 -p 80:80   quay.io/<your-org>/nginx-homelab-proxy:1.0
#   podman run -d --restart=always --name nginx-2 -p 8080:80 quay.io/<your-org>/nginx-homelab-proxy:1.0

FROM docker.io/library/nginx:1.27-alpine

LABEL org.opencontainers.image.title="home-lab-nginx-proxy" \
      org.opencontainers.image.description="Path-based reverse proxy for k3s + homelab services" \
      org.opencontainers.image.source="https://github.com/myhome-automation/git-vsphere"

# Bake in the proxy config — overrides the default vhost.
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Image health check — nginx is up if the landing page returns 200.
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -q --spider http://127.0.0.1/ || exit 1

EXPOSE 80
