#!/bin/bash

# Migrate an existing Akiyamov xray-vps-setup (VLESS+Reality+TCP+Vision)
# to XHTTP, preserving Reality keys, UUID and domain.
# Works for standalone Xray and Marzban. Safe to re-run (skips if already XHTTP).

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

cd /opt/xray-vps-setup 2>/dev/null || { echo "/opt/xray-vps-setup not found"; exit 1; }

# Detect variant
if [ -f marzban/xray_config.json ]; then
  MODE="marzban"; CFG="marzban/xray_config.json"
elif [ -f xray/config.json ]; then
  MODE="xray"; CFG="xray/config.json"
else
  echo "Could not find xray config (xray/config.json or marzban/xray_config.json)"
  exit 1
fi
echo "Detected $MODE"

# Install yq if missing
if ! command -v yq >/dev/null 2>&1; then
  ARCH=$(dpkg --print-architecture)
  wget -O /usr/bin/yq "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$ARCH" && chmod +x /usr/bin/yq
fi

# Skip if already XHTTP
CUR_NET=$(yq eval '.inbounds[0].streamSettings.network' "$CFG" | tr -d '"')
if [ "$CUR_NET" = "xhttp" ]; then
  echo "Already using XHTTP, nothing to do"
  exit 0
fi
echo "Current transport: $CUR_NET"

# Extract domain
DOMAIN=$(yq eval '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CFG" | tr -d '"')
if [ -z "$DOMAIN" ]; then
  echo "Could not detect domain (serverNames)"
  exit 1
fi

# Generate XHTTP path
XHTTP_PATH=$(openssl rand -hex 8)
echo "Domain:    $DOMAIN"
echo "XHTTP path: /$XHTTP_PATH"

# Backup config
cp "$CFG" "$CFG.bak.$(date +%s)"
echo "Backup saved to $CFG.bak.*"

# Switch transport: tcp -> xhttp, drop flow, add xhttpSettings
yq eval '.inbounds[0].streamSettings.network = "xhttp"' -i "$CFG"
yq eval 'del(.inbounds[0].settings.clients[].flow)' -i "$CFG"
yq eval '.inbounds[0].streamSettings.xhttpSettings = {"host": "'"$DOMAIN"'", "path": "/'"$XHTTP_PATH"'"}' -i "$CFG"
echo "Updated xray config transport to XHTTP"

# Restart stack
docker compose -f docker-compose.yml down && docker compose -f docker-compose.yml up -d

# Marzban: update hosts path/security via local API
if [ "$MODE" = "marzban" ]; then
  sleep 5
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Warning: python3 not found, set host path to /$XHTTP_PATH manually in the panel"
  else
    MARZBAN_USER=$(grep -m1 '^SUDO_USERNAME' marzban/.env | cut -d'"' -f2)
    MARZBAN_PASS=$(grep -m1 '^SUDO_PASSWORD' marzban/.env | cut -d'"' -f2)
    PANEL_TOKEN=$(curl -sf -X POST "http://127.0.0.1:8000/api/admin/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-urlencode "username=$MARZBAN_USER" \
      --data-urlencode "password=$MARZBAN_PASS" \
      | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])" 2>/dev/null || echo "")
    if [ -n "$PANEL_TOKEN" ] && [ "$PANEL_TOKEN" != "null" ]; then
      HTTP=$(curl -s -o /tmp/marz_hosts.json -w "%{http_code}" \
        "http://127.0.0.1:8000/api/hosts" -H "Authorization: Bearer $PANEL_TOKEN" || echo "000")
      if [ "$HTTP" = "200" ]; then
        export XHTTP_PATH
        python3 <<'PYEOF' > /tmp/marz_hosts_upd.json
import json, os
p = '/' + os.environ['XHTTP_PATH']
hosts = json.load(open('/tmp/marz_hosts.json'))
for hl in hosts.values():
    for h in hl:
        h['path'] = p
        h['security'] = 'inbound_default'
        h['fingerprint'] = 'chrome'
print(json.dumps(hosts))
PYEOF
        curl -s -o /dev/null -X PUT "http://127.0.0.1:8000/api/hosts" \
          -H "Authorization: Bearer $PANEL_TOKEN" \
          -H "Content-Type: application/json" -d @/tmp/marz_hosts_upd.json
        echo "Updated Marzban hosts path to /$XHTTP_PATH"
      else
        echo "Warning: could not fetch Marzban hosts (HTTP $HTTP), set host path to /$XHTTP_PATH in the panel"
      fi
    else
      echo "Warning: could not authenticate to Marzban API, set host path to /$XHTTP_PATH in the panel"
    fi
  fi
fi

# Standalone: print new client configs
if [ "$MODE" = "xray" ]; then
  UUID=$(yq eval '.inbounds[0].settings.clients[0].id' "$CFG" | tr -d '"')
  PBK=$(yq eval '.inbounds[0].streamSettings.realitySettings.publicKey' "$CFG" | tr -d '"')
  cat <<EOF

Clipboard string:
vless://$UUID@$DOMAIN:443?type=xhttp&security=reality&pbk=$PBK&fp=chrome&sni=$DOMAIN&sid=&path=%2F$XHTTP_PATH&host=$DOMAIN&mode=auto#XHTTP-Reality

Xray outbound config:
{
  "tag": "default",
  "protocol": "vless",
  "settings": {
    "vnext": [
      {
        "address": "$DOMAIN",
        "port": 443,
        "users": [
          { "id": "$UUID", "encryption": "none" }
        ]
      }
    ]
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "reality",
    "realitySettings": {
      "serverName": "$DOMAIN",
      "fingerprint": "chrome",
      "publicKey": "$PBK",
      "shortId": ""
    },
    "xhttpSettings": {
      "host": "$DOMAIN",
      "path": "/$XHTTP_PATH",
      "mode": "auto"
    }
  }
}

Sing-box outbound config:
{
  "type": "vless",
  "server": "$DOMAIN",
  "server_port": 443,
  "uuid": "$UUID",
  "tls": {
    "enabled": true,
    "insecure": false,
    "server_name": "$DOMAIN",
    "utls": { "enabled": true, "fingerprint": "chrome" },
    "reality": { "enabled": true, "public_key": "$PBK", "short_id": "" }
  },
  "transport": {
    "type": "xhttp",
    "mode": "auto",
    "host": "$DOMAIN",
    "path": "/$XHTTP_PATH"
  }
}

Plain data:
PBK: $PBK, UUID: $UUID, path: /$XHTTP_PATH
EOF
fi

echo ""
echo "Done. Transport switched to XHTTP ($MODE)."
if [ "$MODE" = "marzban" ]; then
  echo "Users must re-fetch their subscriptions (hosts now use path /$XHTTP_PATH)."
else
  echo "Update your client to the XHTTP config above - old TCP profiles no longer work."
fi
