#!/bin/bash

# Add Cloudflare WARP routing for RU websites to an existing xray-vps-setup
# installation. Works for both standalone Xray and Marzban. Safe to re-run.

set -e

# Check if script started as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

COMPOSE_FILE="/opt/xray-vps-setup/docker-compose.yml"

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "Could not find $COMPOSE_FILE - is xray-vps-setup installed?"
  exit 1
fi

cd /opt/xray-vps-setup

# Detect variant and xray config path
if [ -f marzban/xray_config.json ]; then
  CFG="marzban/xray_config.json"
  MODE="marzban"
elif [ -f xray/config.json ]; then
  CFG="xray/config.json"
  MODE="xray"
else
  echo "Could not find xray config (xray/config.json or marzban/xray_config.json)"
  exit 1
fi
echo "Detected $MODE, xray config: $CFG"

# Check WARP reachability
if ! curl -I https://api.cloudflareclient.com --connect-timeout 10 > /dev/null 2>&1; then
  echo "Cloudflare WARP is unreachable from this server, aborting"
  exit 1
fi

# Install yq if missing
if ! command -v yq >/dev/null 2>&1; then
  ARCH=$(dpkg --print-architecture)
  wget -O /usr/bin/yq "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$ARCH" && chmod +x /usr/bin/yq
fi

# Install cloudflare-warp if missing
if ! command -v warp-cli >/dev/null 2>&1; then
  apt install gpg -y
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
  apt update
  apt install cloudflare-warp -y
fi

# Register and connect (idempotent)
if warp-cli status 2>/dev/null | grep -qi "connected"; then
  echo "WARP already connected"
else
  echo "y" | warp-cli registration new 2>/dev/null \
    || warp-cli --accept-tos registration new 2>/dev/null \
    || echo "registration skipped (may already be registered)"
  warp-cli mode proxy
  warp-cli proxy port 40000
  warp-cli connect
fi

# Add WARP outbound if missing
if [ -z "$(yq eval '.outbounds[] | select(.tag == "warp")' "$CFG")" ]; then
  yq eval '.outbounds += {"tag": "warp", "protocol": "socks", "settings": {"servers": [{"address": "127.0.0.1", "port": 40000}]}}' -i "$CFG"
  echo "Added WARP outbound"
else
  echo "WARP outbound already present"
fi

# Add WARP routing rule if missing
if [ -z "$(yq eval '.routing.rules[] | select(.outboundTag == "warp")' "$CFG")" ]; then
  yq eval '.routing.rules += {"outboundTag": "warp", "domain": ["geosite:category-ru", "regexp:.*\\.ru$", "regexp:.*\\.su$", "regexp:.*\\.xn--$"]}' -i "$CFG"
  echo "Added WARP routing rule"
else
  echo "WARP routing rule already present"
fi

# Restart stack
docker compose -f "$COMPOSE_FILE" down && docker compose -f "$COMPOSE_FILE" up -d

echo "Done. WARP is now used for RU websites."
echo "Verify WARP itself: curl -x socks5h://127.0.0.1:40000 https://ifconfig.me"
