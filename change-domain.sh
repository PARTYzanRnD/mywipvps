#!/bin/bash

# Change the VLESS domain of an existing xray-vps-setup installation.
# Works for both standalone Xray and Marzban. Usage: bash change-domain.sh [new-domain]

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

if [ -n "$1" ]; then
  input_domain="$1"
else
  read -ep "Enter new domain:"$'\n' input_domain
fi
NEW_DOMAIN=$(echo "$input_domain" | idn 2>/dev/null || echo "$input_domain")

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

# Detect current domain from angie server_name
OLD_DOMAIN=$(grep -m1 'server_name' angie.conf | sed -E 's/.*server_name[[:space:]]+//; s/;//; s/[[:space:]]//g')
if [ -z "$OLD_DOMAIN" ]; then
  echo "Could not detect current domain"
  exit 1
fi

echo "Detected $MODE"
echo "Current domain: $OLD_DOMAIN"
echo "New domain:     $NEW_DOMAIN"

# DNS check (warning only)
if command -v dig >/dev/null 2>&1; then
  RESOLVED_IP=$(dig +short "$NEW_DOMAIN" | tail -n1)
  SERVER_IPS=($(hostname -I))
  if [ -n "$RESOLVED_IP" ]; then
    ok=false
    for ip in "${SERVER_IPS[@]}"; do [ "$RESOLVED_IP" = "$ip" ] && ok=true; done
    if [ "$ok" = true ]; then
      echo "DNS OK: $NEW_DOMAIN -> $RESOLVED_IP"
    else
      echo "Warning: $NEW_DOMAIN resolves to $RESOLVED_IP (server IPs: ${SERVER_IPS[*]})"
      echo "         Point the A record to this server or the TLS cert won't renew."
    fi
  else
    echo "Warning: $NEW_DOMAIN has no DNS record yet. Point it to this server first."
  fi
fi

# Replace domain in config files
OLD_ESC=$(printf '%s' "$OLD_DOMAIN" | sed 's/\./\\./g')
sed -i "s/$OLD_ESC/$NEW_DOMAIN/g" angie.conf
sed -i "s/$OLD_ESC/$NEW_DOMAIN/g" "$CFG"
if [ "$MODE" = "marzban" ]; then
  sed -i "s/$OLD_ESC/$NEW_DOMAIN/g" marzban/.env
fi
echo "Updated domain in config files"

# Restart stack
docker compose -f docker-compose.yml down && docker compose -f docker-compose.yml up -d

# Marzban: update hosts via local API (no DNS/cert needed)
if [ "$MODE" = "marzban" ]; then
  sleep 5
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Warning: python3 not found, update host address/SNI manually in the panel"
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
        export NEW_DOMAIN
        python3 <<'PYEOF' > /tmp/marz_hosts_upd.json
import json, os
d = os.environ['NEW_DOMAIN']
hosts = json.load(open('/tmp/marz_hosts.json'))
for hl in hosts.values():
    for h in hl:
        h['address'] = d
        h['sni'] = d
        h['host'] = d
print(json.dumps(hosts))
PYEOF
        curl -s -o /dev/null -X PUT "http://127.0.0.1:8000/api/hosts" \
          -H "Authorization: Bearer $PANEL_TOKEN" \
          -H "Content-Type: application/json" -d @/tmp/marz_hosts_upd.json
        echo "Updated Marzban hosts address/SNI to $NEW_DOMAIN"
      else
        echo "Warning: could not fetch Marzban hosts (HTTP $HTTP), update address/SNI in the panel"
      fi
    else
      echo "Warning: could not authenticate to Marzban API, update host address/SNI in the panel"
    fi
  fi
fi

echo "Done. Domain changed to $NEW_DOMAIN."
echo "Note: client profiles still use the old domain - regenerate subscriptions or update 'address' to $NEW_DOMAIN."
