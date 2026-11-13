#!/bin/bash

# XHTTP variant of Akiyamov/xray-vps-setup.
# Standalone Xray-core: VLESS + XHTTP + Reality (steal-self) on 443,
# Angie serves the fake Confluence page to non-clients.

set -e

export GIT_BRANCH="main"
export GIT_REPO="Akiyamov/xray-vps-setup"

# Check if script started as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

# Install idn
apt-get update
apt-get install idn sudo dnsutils wamerican gettext-base python3 -y

# Read domain input
read -ep "Enter your domain:"$'\n' input_domain

export VLESS_DOMAIN=$(echo $input_domain | idn)

SERVER_IPS=($(hostname -I))

RESOLVED_IP=$(dig +short $VLESS_DOMAIN | tail -n1)

if [ -z "$RESOLVED_IP" ]; then
  echo "Warning: Domain has no DNS record"
  read -ep "Are you sure? That domain has no DNS record. If you didn't add that you will have to restart xray and angie by yourself [y/N]"$'\n' prompt_response
  if [[ "$prompt_response" =~ ^([yY])$ ]]; then
    echo "Ok, proceeding without DNS verification"
  else
    echo "Come back later"
    exit 1
  fi
else
  MATCH_FOUND=false
  for server_ip in "${SERVER_IPS[@]}"; do
    if [ "$RESOLVED_IP" == "$server_ip" ]; then
      MATCH_FOUND=true
      break
    fi
  done

  if [ "$MATCH_FOUND" = true ]; then
    echo "✓ DNS record points to this server ($RESOLVED_IP)"
  else
    echo "Warning: DNS record exists but points to different IP"
    echo "  Domain resolves to: $RESOLVED_IP"
    echo "  This server's IPs: ${SERVER_IPS[*]}"
    read -ep "Continue anyway? [y/N]"$'\n' prompt_response
    if [[ "$prompt_response" =~ ^([yY])$ ]]; then
      echo "Ok, proceeding"
    else
      echo "Come back later"
      exit 1
    fi
  fi
fi

read -ep "Do you want to create a user to connect to server as non-root and forbid root access? Do this on first run only. [y/N] "$'\n' configure_ssh_input
if [[ ${configure_ssh_input,,} == "y" ]]; then
  # Read SSH port
  read -ep "Enter SSH port. Default 22, can't use ports: 80, 443 and 4123:"$'\n' input_ssh_port

  while [[ "$input_ssh_port" -eq "80" || "$input_ssh_port" -eq "443" || "$input_ssh_port" -eq "4123" ]]; do
    read -ep "No, ssh can't use $input_ssh_port as port, write again:"$'\n' input_ssh_port
  done
  # Read SSH Pubkey
  read -ep "Enter SSH public key:"$'\n' input_ssh_pbk
  echo "$input_ssh_pbk" > ./test_pbk
  ssh-keygen -l -f ./test_pbk
  PBK_STATUS=$(echo $?)
  if [ "$PBK_STATUS" -eq 255 ]; then
    echo "Can't verify the public key. Try again and make sure to include 'ssh-rsa' or 'ssh-ed25519' followed by 'user@pcname' at the end of the file."
    exit
  fi
  rm ./test_pbk
fi

configure_warp_input="n"
read -ep "Do you want to install WARP and use it on russian websites? [y/N] "$'\n' configure_warp_input
if [[ ${configure_warp_input,,} == "y" ]]; then
  if ! curl -I https://api.cloudflareclient.com --connect-timeout 10 > /dev/null 2>&1; then
    echo "Warp can't be used"
    configure_warp_input="n"
  fi
fi

configure_egress_input="n"
read -ep "Do you have a second IP to use for outbound traffic (different egress IP)? [y/N] "$'\n' configure_egress_input
if [[ ${configure_egress_input,,} == "y" ]]; then
  read -ep "Enter the outbound (egress) IP:"$'\n' input_egress_ip
fi

configure_ipdetect_input="n"
read -ep "Do you want to block IP/geo-detection services (so apps can't discover the egress IP)? [y/N] "$'\n' configure_ipdetect_input

# Check congestion protocol
if sysctl net.ipv4.tcp_congestion_control | grep bbr; then
    echo "BBR is already used"
else
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null
    echo "Enabled BBR"
fi

export ARCH=$(dpkg --print-architecture)

yq_install() {
  wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$ARCH -O /usr/bin/yq && chmod +x /usr/bin/yq
}

yq_install

docker_install() {
  curl -fsSL https://get.docker.com | sh
}

if ! command -v docker 2>&1 >/dev/null; then
    docker_install
fi

# Generate values for XRay
export SSH_USER=$(grep -E '^[a-z]{4,6}$' /usr/share/dict/words | shuf -n 1)
export SSH_USER_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13; echo)
export SSH_PORT=${input_ssh_port:-22}
export XRAY_PIK=$(docker run --rm ghcr.io/xtls/xray-core:26.3.27 x25519 | head -n1 | cut -d' ' -f 2)
export XRAY_PBK=$(docker run --rm ghcr.io/xtls/xray-core:26.3.27 x25519 -i $XRAY_PIK | tail -2 | head -1 | cut -d' ' -f 3)
export XRAY_UUID=$(docker run --rm ghcr.io/xtls/xray-core uuid)
export XRAY_PATH=$(openssl rand -hex 8)
export XRAY_SEND_THROUGH=${input_egress_ip:-0.0.0.0}

xray_setup() {
  mkdir -p /opt/xray-vps-setup/xray
  cd /opt/xray-vps-setup
  wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/confluence" | envsubst > ./index.html
  wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/compose-xray" | envsubst > ./docker-compose.yml
  wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/angie" | envsubst '$VLESS_DOMAIN' > ./angie.conf

  envsubst > ./xray/config.json <<'XRAYCFG'
{
  "log": {
    "loglevel": "none"
  },
  "inbounds": [
    {
      "tag": "VLESS XHTTP REALITY",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$XRAY_UUID",
            "email": "default"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "xver": 1,
          "dest": "127.0.0.1:4123",
          "serverNames": [
            "$VLESS_DOMAIN"
          ],
          "privateKey": "$XRAY_PIK",
          "publicKey": "$XRAY_PBK",
          "shortIds": [
            ""
          ]
        },
        "xhttpSettings": {
          "host": "$VLESS_DOMAIN",
          "path": "/$XRAY_PATH"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "domainStrategy": "UseIPv4",
        "sendThrough": "$XRAY_SEND_THROUGH"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "rules": [
      {
        "protocol": "bittorrent",
        "outboundTag": "block"
      }
    ],
    "domainStrategy": "IPIfNonMatch"
  },
  "dns": {
    "servers": [
      "1.1.1.1",
      "8.8.8.8"
    ],
    "queryStrategy": "UseIPv4",
    "disableFallback": false,
    "tag": "dns-aux"
  }
}
XRAYCFG
}

block_ip_geo_detect() {
  local cfg_path="$1"
  if ! wget -qO- https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/refs/heads/sing/geo/geosite/category-ip-geo-detect.json > /tmp/category-ip-geo-detect.json; then
    echo "Warning: could not download IP/geo-detection list, skipping"
    return 0
  fi
  CFG_PATH="$cfg_path" python3 - <<'PYEOF'
import json, os
with open('/tmp/category-ip-geo-detect.json') as f:
    data = json.load(f)
matchers = []
for rule in data.get('rules', []):
    for d in rule.get('domain', []):
        matchers.append('full:' + d)
    for d in rule.get('domain_suffix', []):
        matchers.append('domain:' + d)
with open(os.environ['CFG_PATH']) as f:
    cfg = json.load(f)
cfg.setdefault('routing', {}).setdefault('rules', [])
cfg['routing']['rules'].insert(0, {
    'type': 'field',
    'domain': matchers,
    'outboundTag': 'block'
})
with open(os.environ['CFG_PATH'], 'w') as f:
    json.dump(cfg, f, indent=2)
print('Blocked', len(matchers), 'IP/geo-detection domains')
PYEOF
}

xray_setup

if [[ ${configure_ipdetect_input,,} == "y" ]]; then
  block_ip_geo_detect "/opt/xray-vps-setup/xray/config.json"
fi

sshd_edit() {
  wget -qO- https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/00-disable-password | envsubst > /etc/ssh/sshd_config.d/00-disable-password.conf
  systemctl daemon-reload
  systemctl restart ssh
}

add_user() {
  useradd $SSH_USER -s /bin/bash
  usermod -aG sudo $SSH_USER
  echo $SSH_USER:$SSH_USER_PASS | chpasswd
  mkdir -p /home/$SSH_USER/.ssh
  touch /home/$SSH_USER/.ssh/authorized_keys
  echo $input_ssh_pbk >> /home/$SSH_USER/.ssh/authorized_keys
  chmod 700 /home/$SSH_USER/.ssh/
  chmod 600 /home/$SSH_USER/.ssh/authorized_keys
  chown $SSH_USER:$SSH_USER -R /home/$SSH_USER
  usermod -aG docker $SSH_USER
}

debconf-set-selections <<EOF
iptables-persistent iptables-persistent/autosave_v4 boolean true
iptables-persistent iptables-persistent/autosave_v6 boolean true
EOF
apt-get install iptables-persistent netfilter-persistent -y

# Configure iptables (UDP 443 added for XHTTP HTTP/3)
edit_iptables() {
  iptables -A INPUT -p icmp -j ACCEPT
  iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
  iptables -A INPUT -p tcp -m state --state NEW -m tcp --dport $SSH_PORT -j ACCEPT
  iptables -A INPUT -p tcp -m tcp --dport 80 -j ACCEPT
  iptables -A INPUT -p tcp -m tcp --dport 443 -j ACCEPT
  iptables -A INPUT -p udp -m udp --dport 443 -j ACCEPT
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT
  iptables -P INPUT DROP
}

if [[ ${configure_ssh_input,,} == "y" ]]; then
  echo "New user for ssh: $SSH_USER, password for user: $SSH_USER_PASS. New port for SSH: $SSH_PORT."
  add_user
  sshd_edit
  edit_iptables
fi
netfilter-persistent save

# WARP Install function
warp_install() {
  apt install gpg -y
  echo "If this fails then warp won't be added to routing and everything will work without it"
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
  apt update
  apt install cloudflare-warp -y

  echo "y" | warp-cli registration new
  export TRY_WARP=$(echo $?)
  if [[ $TRY_WARP != 0 ]]; then
    echo "Couldn't connect to WARP"
    exit 0
  else
    warp-cli mode proxy
    warp-cli proxy port 40000
    warp-cli connect
    export XRAY_CONFIG_WARP="/opt/xray-vps-setup/xray/config.json"
    yq eval \
    '.outbounds += {"tag": "warp","protocol": "socks","settings": {"servers": [{"address": "127.0.0.1","port": 40000}]}}' \
    -i $XRAY_CONFIG_WARP
    yq eval \
    '.routing.rules += {"outboundTag": "warp", "domain": ["geosite:category-ru", "regexp:.*\\.xn--$", "regexp:.*\\.ru$", "regexp:.*\\.su$"]}' \
    -i $XRAY_CONFIG_WARP
    docker compose -f /opt/xray-vps-setup/docker-compose.yml down && docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d
  fi
}

end_script() {
  if [[ ${configure_warp_input,,} == "y" ]]; then
    warp_install
  fi

  docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d

  xray_config=$(envsubst <<'XRAYOUT'
{
  "tag": "default",
  "protocol": "vless",
  "settings": {
    "vnext": [
      {
        "address": "$VLESS_DOMAIN",
        "port": 443,
        "users": [
          {
            "id": "$XRAY_UUID",
            "encryption": "none"
          }
        ]
      }
    ]
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "reality",
    "realitySettings": {
      "serverName": "$VLESS_DOMAIN",
      "fingerprint": "chrome",
      "publicKey": "$XRAY_PBK",
      "shortId": ""
    },
    "xhttpSettings": {
      "host": "$VLESS_DOMAIN",
      "path": "/$XRAY_PATH",
      "mode": "auto"
    }
  }
}
XRAYOUT
)

  singbox_config=$(envsubst <<'SINGBOXOUT'
{
  "type": "vless",
  "server": "$VLESS_DOMAIN",
  "server_port": 443,
  "uuid": "$XRAY_UUID",
  "tls": {
    "enabled": true,
    "insecure": false,
    "server_name": "$VLESS_DOMAIN",
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    },
    "reality": {
      "enabled": true,
      "public_key": "$XRAY_PBK",
      "short_id": ""
    }
  },
  "transport": {
    "type": "xhttp",
    "mode": "auto",
    "host": "$VLESS_DOMAIN",
    "path": "/$XRAY_PATH"
  }
}
SINGBOXOUT
)

  final_msg="Clipboard string format:
vless://$XRAY_UUID@$VLESS_DOMAIN:443?type=xhttp&security=reality&pbk=$XRAY_PBK&fp=chrome&sni=$VLESS_DOMAIN&sid=&path=%2F$XRAY_PATH&host=$VLESS_DOMAIN&mode=auto#XHTTP-Reality

XRay outbound config:
$xray_config

Sing-box outbound config:
$singbox_config

Plain data:
PBK: $XRAY_PBK, UUID: $XRAY_UUID, path: /$XRAY_PATH, sendThrough: $XRAY_SEND_THROUGH
"

  clear
  echo "$final_msg"
  if [[ ${configure_ssh_input,,} == "y" ]]; then
    echo "SSH user: $SSH_USER, SSH password: $SSH_USER_PASS, SSH port: $SSH_PORT"
  fi
}

end_script
set +e
