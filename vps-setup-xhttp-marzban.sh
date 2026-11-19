#!/bin/bash

# XHTTP + Marzban variant of Akiyamov/xray-vps-setup.
# Marzban panel manages users; Xray serves VLESS + XHTTP + Reality (steal-self)
# on 443, Angie serves the fake Confluence page to non-clients and proxies the panel.

set -e

export GIT_BRANCH="main"
export GIT_REPO="Akiyamov/xray-vps-setup"

write_xray_config() {
  "$@" <<'XRAYCFG'
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
        "clients": [],
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

ip_geo_detect_url=https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/refs/heads/sing/geo/geosite/category-ip-geo-detect.json

add_ip_geo_detect_rule() {
  python3 - "$1" "$2" <<'PY'
import json, sys

config_path, list_path = sys.argv[1:]
with open(list_path) as f:
    categories = json.load(f)
matchers = [
    prefix + name
    for rule in categories.get("rules", [])
    for key, prefix in (("domain", "full:"), ("domain_suffix", "domain:"))
    for name in rule.get(key, [])
]
if not matchers:
    sys.exit("IP/geo-detection list contains no domains")
with open(config_path) as f:
    cfg = json.load(f)
cfg.setdefault("routing", {}).setdefault("rules", []).insert(0, {
    "type": "field",
    "domain": matchers,
    "outboundTag": "block",
})
with open(config_path, "w") as f:
    json.dump(cfg, f, indent=2)
print("Blocked", len(matchers), "IP/geo-detection domains")
PY
}

# The reuse path exits before the fresh install can modify the host.
reuse_fail() {
  printf 'Marzban --reuse: %s\n' "$*" >&2
  exit 1
}

reuse_read() {
  printf '%s' "$1" >&"$prompt_fd"
  IFS= read -r -u "$prompt_fd" "$2" || reuse_fail 'input ended before all installation options were entered'
}

reuse_ask() {
  local answer
  while true; do
    reuse_read "$1 [y/N] " answer
    case ${answer,,} in
      y|yes) return 0 ;;
      n|no|'') return 1 ;;
    esac
    printf 'Please enter y or n.\n' >&"$prompt_fd"
  done
}

reuse_local_egress() {
  ip -j address show | python3 -c '
import ipaddress, json, sys

try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError:
    sys.exit(1)
for interface in json.load(sys.stdin):
    for info in interface.get("addr_info", []):
        if info.get("scope") == "global" and ipaddress.ip_address(info["local"]) == address:
            print(address)
            sys.exit(0)
sys.exit(1)
' "$1"
}

reuse_prompt_options() {
  local egress_input
  if [[ -z $prompt_fd ]]; then
    printf 'Marzban --reuse: no controlling terminal. Using system-selected egress and leaving WARP routing and IP/geo-detection blocking disabled.\n' >&2
    return 0
  fi
  if reuse_ask 'Use the existing WARP proxy for Russian domains?'; then
    use_warp=yes
  fi
  if reuse_ask 'Use a separate egress IP for direct Xray traffic?'; then
    reuse_read 'Enter an IP address assigned to this host: ' egress_input
    command -v ip >/dev/null || reuse_fail 'the ip command is required to check the egress address'
    egress=$(reuse_local_egress "$egress_input") || reuse_fail 'the egress address must be a usable IP assigned to this host'
  fi
  if reuse_ask 'Block IP and geolocation detection services?'; then
    block_ip_detect=yes
  fi
  if [[ $use_warp == yes ]] &&
    ! reuse_curl --fail --noproxy '' --max-time 12 --socks5-hostname 127.0.0.1:40000 \
      https://www.cloudflare.com/cdn-cgi/trace | grep -qx 'warp=on'; then
    reuse_fail 'WARP was requested but the SOCKS proxy on 127.0.0.1:40000 is not connected to WARP'
  fi
}

reuse_configure_xray() {
  local config=$1 list=$work/ip-geo-detect.json
  if [[ -n $egress || $use_warp == yes ]]; then
    python3 - "$config" "$egress" "$use_warp" <<'PY'
import ipaddress, json, sys

path, egress, warp = sys.argv[1:]
with open(path) as f:
    cfg = json.load(f)
if egress:
    direct = next(outbound for outbound in cfg["outbounds"] if outbound["tag"] == "direct")
    direct["settings"].pop("sendThrough", None)
    direct["sendThrough"] = egress
    if ipaddress.ip_address(egress).version == 6:
        direct["settings"]["domainStrategy"] = "UseIPv6"
        cfg["dns"]["queryStrategy"] = "UseIPv6"
if warp == "yes":
    cfg["outbounds"].append({
        "tag": "warp",
        "protocol": "socks",
        "settings": {"servers": [{"address": "127.0.0.1", "port": 40000}]},
    })
    cfg["routing"]["rules"].append({
        "type": "field",
        "domain": ["geosite:category-ru", "domain:ru", "domain:su", "domain:xn--p1ai"],
        "outboundTag": "warp",
    })
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
PY
  fi
  if [[ $block_ip_detect == yes ]]; then
    reuse_curl --fail --show-error --location --max-time 20 --output "$list" "$ip_geo_detect_url" &&
      add_ip_geo_detect_rule "$config" "$list" ||
      reuse_fail 'could not load the requested IP/geo-detection block list'
    rm -- "$list"
  fi
}

reuse_compose() {
  local variant=$1
  shift
  "${compose[@]}" --env-file /dev/null -p "$project-$variant" -f "$work/$variant.json" "$@"
}

reuse_discover() {
  local running
  local -a ids
  running=$(docker ps -q --no-trunc) || return 1
  if [[ -z $running ]]; then
    printf 'Marzban --reuse: no running Docker containers found.\n' >&2
    return 1
  fi
  mapfile -t ids <<< "$running"
  docker inspect "${ids[@]}" | python3 -c '
import json, os, sys

def fail(message):
    sys.exit("Marzban --reuse: " + message)

def mounts(container, path):
    return [m for m in container["Mounts"] if
            m["Destination"] == path or m["Destination"].startswith(path + "/")]

def image(container):
    return container["Config"]["Image"].split("@")[0].rsplit("/", 1)[-1].split(":")[0]

def host_network(container):
    return container["HostConfig"]["NetworkMode"] == "host"

containers = json.load(sys.stdin)
caddies = []
for container in containers:
    labels = container["Config"].get("Labels") or {}
    if image(container) != "caddy" and labels.get("com.docker.compose.service") != "caddy":
        continue
    found = mounts(container, "/run/marzban")
    if host_network(container) and len(found) == 1:
        mount = found[0]
        if mount["Type"] == "bind" and mount["Destination"] == "/run/marzban":
            caddies.append((container, mount["Source"]))
if len(caddies) != 1:
    fail("expected exactly one running host-network Caddy with a bind mount at /run/marzban")
caddy, source = caddies[0]
data = os.path.realpath(source)
if data != source or not os.path.isabs(data) or data == "/" or any(c in data for c in "\n\r$"):
    fail("Caddy socket bind mount has an unsupported source path")

old = []
for container in containers:
    for bindings in (container["HostConfig"].get("PortBindings") or {}).values():
        if any(binding["HostPort"] == "443" for binding in bindings or []):
            fail("a Docker container publishes port 443")
    if container["Id"] == caddy["Id"]:
        continue
    for mount in container["Mounts"]:
        if not mount["RW"] or mount["Type"] not in ("bind", "volume"):
            continue
        mounted = os.path.realpath(mount["Source"])
        if os.path.commonpath([mounted, data]) not in (mounted, data):
            continue
        if (image(container) != "marzban" or not host_network(container)
                or mount["Type"] != "bind" or mounted != data
                or mount["Destination"] != "/var/lib/marzban"):
            fail("another running container can write to the shared Marzban directory")
        old.append(container)
if len(old) > 1:
    fail("multiple running Marzban containers share the Caddy socket directory")

print(caddy["Id"], data, sep="\n")
if old:
    policy = old[0]["HostConfig"]["RestartPolicy"]
    name = policy["Name"] or "no"
    if name == "on-failure" and policy["MaximumRetryCount"]:
        name += ":" + str(policy["MaximumRetryCount"])
    print(old[0]["Id"], name, sep="\n")
'
}

reuse_listener() {
  local container=$1 process=$2 port=$3 binding=$4 listeners pids
  listeners=$(ss -H -ltnp "sport = :$port") || return 1
  if [[ -z $container ]]; then
    [[ -z $listeners ]]
    return
  fi
  pids=$(docker top "$container" -eo pid) || return 1
  python3 -c '
import re, sys
process, binding, *pids = sys.argv[1:]
rows = sys.stdin.read().splitlines()
if not rows:
    sys.exit(1)
for row in rows:
    fields = row.split(maxsplit=5)
    if len(fields) != 6 or fields[3] not in binding.split(","):
        sys.exit(1)
    owners = re.findall(r"\(\"([^\"]+)\",pid=(\d+),fd=\d+\)", fields[5])
    if not owners or len(owners) != fields[5].count("pid="):
        sys.exit(1)
    if any(name != process or pid not in pids for name, pid in owners):
        sys.exit(1)
' "$process" "$binding" $pids <<< "$listeners"
}

reuse_xray_listener() {
  reuse_listener "$1" xray 443 '0.0.0.0:443,*:443,[::]:443'
}

reuse_caddy_config() {
  docker exec "$caddy" caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null |
    python3 -c '
import json, sys

def objects(item):
    if isinstance(item, dict):
        yield item
        for value in item.values():
            yield from objects(value)
    elif isinstance(item, list):
        for value in item:
            yield from objects(value)

cfg = json.load(sys.stdin)
for server in cfg["apps"]["http"]["servers"].values():
    if server.get("listen") != ["127.0.0.1:4123"]:
        continue
    if [w.get("wrapper") for w in server.get("listener_wrappers", [])][:2] != ["proxy_protocol", "tls"]:
        continue
    for route in objects(server.get("routes", [])):
        if not any(sys.argv[1] in match.get("host", []) for match in route.get("match", [])):
            continue
        upstreams = {item["dial"] for item in objects(route.get("handle", [])) if "dial" in item}
        if {"127.0.0.1:18089", "unix//run/marzban/marzban.socket"} <= upstreams:
            sys.exit(0)
sys.exit(1)
' "$domain" 2>/dev/null
}

reuse_curl() {
  curl --disable --noproxy '*' --silent --connect-timeout 2 --max-time 4 "$@"
}

reuse_photo_health() {
  reuse_curl --fail "$@" | python3 -c 'import json, sys; sys.exit(json.load(sys.stdin).get("status") != "ok")' 2>/dev/null
}

reuse_panel_ready() {
  local status
  status=$(reuse_curl --output /dev/null --write-out '%{http_code}' "$@") && [[ $status == 401 ]]
}

reuse_wait() {
  local attempt
  for ((attempt=0; attempt<30; attempt++)); do
    "$@" && return 0
    sleep 1
  done
  return 1
}

reuse_write_compose() {
  local variant=$1 network=$2 source=$3 restart=$4
  python3 - "$network" "$source" "$restart" "$project-$variant" "$domain" "$image_id" \
    "$dashboard_path" "$subscription_path" > "$work/$variant.json" <<'PY'
import json, sys

network, source, restart, name, domain, image, dashboard, subscription = sys.argv[1:]
volumes = [
    (source, "/var/lib/marzban", False),
    ("./xray", "/usr/local/bin/xray", True),
    ("./xray_config.json", "/code/xray_config.json", True),
]
json.dump({"services": {"marzban": {
    "image": image,
    "container_name": name,
    "network_mode": network,
    "restart": restart,
    "environment": {
        "SQLALCHEMY_DATABASE_URL": "sqlite:////var/lib/marzban/db.sqlite3",
        "UVICORN_UDS": "/var/lib/marzban/marzban.socket",
        "XRAY_JSON": "/code/xray_config.json",
        "DASHBOARD_PATH": dashboard,
        "XRAY_SUBSCRIPTION_PATH": subscription,
        "XRAY_SUBSCRIPTION_URL_PREFIX": "https://" + domain,
    },
    "volumes": [
        {"type": "bind", "source": src, "target": dst, "read_only": ro}
        for src, dst, ro in volumes
    ],
}}}, sys.stdout, indent=2)
PY
}

reuse_seed_panel() {
  local socket=$work/stage-data/marzban.socket token
  local api=(--unix-socket "$socket" --fail)
  docker exec --env-file "$work/admin.env" "$project-stage" \
    marzban-cli admin import-from-env --yes >/dev/null 2>&1 || return 1
  token=$(reuse_curl "${api[@]}" --data-binary "@$work/login-form" http://localhost/api/admin/token |
    python3 -c 'import json, re, sys; token = json.load(sys.stdin)["access_token"]; sys.exit(1) if not re.fullmatch(r"[\w.-]+", token) else print(token)' 2>/dev/null) || return 1
  printf 'Authorization: Bearer %s\n' "$token" > "$work/auth-header" || return 1
  reuse_curl "${api[@]}" -H "@$work/auth-header" http://localhost/api/hosts |
    python3 -c '
import json, sys
domain, path = sys.argv[1:]
hosts = json.load(sys.stdin)
if not any(hosts.values()):
    sys.exit(1)
for entries in hosts.values():
    for host in entries:
        host.update(address=domain, sni=domain, host=domain, path=path,
                    security="inbound_default", fingerprint="chrome")
json.dump(hosts, sys.stdout)
' "$domain" "/$XRAY_PATH" 2>/dev/null > "$work/hosts.json" || return 1
  reuse_curl "${api[@]}" -o /dev/null -X PUT -H "@$work/auth-header" \
    -H 'Content-Type: application/json' --data-binary "@$work/hosts.json" http://localhost/api/hosts
}

reuse_cleanup() {
  local result=$1 file rollback_ok=1 remaining
  trap - EXIT
  trap '' INT TERM HUP
  set +e
  if [[ -L $root/current && $(readlink "$root/current") == "$work" ]]; then
    exit "$result"
  fi
  if [[ -n $xray_source ]]; then
    docker rm -v "$xray_source" >/dev/null 2>&1
  fi
  rm -f -- "$work/login-form" "$work/auth-header"
  if [[ -L $pending && $(readlink "$pending") == "$work" ]]; then
    printf 'Marzban --reuse: switching failed, restoring the previous state.\n' >&2
    if ! docker rm -f "$candidate" >/dev/null 2>&1; then
      remaining=$(docker ps -aq --filter "id=$candidate" 2>/dev/null) && [[ -z $remaining ]] || rollback_ok=0
    fi
    if ((rollback_ok && activated)); then
      for file in "${db_files[@]}" marzban.socket; do
        if [[ -e $data/$file || -L $data/$file || -S $data/$file ]]; then
          mv -T -- "$data/$file" "$work/failed/$file" || rollback_ok=0
        fi
      done
    fi
    if ((rollback_ok)); then
      for file in "${db_files[@]}"; do
        if [[ -f $work/backup/$file ]]; then
          mv -T -- "$work/backup/$file" "$data/$file" || rollback_ok=0
        fi
      done
      if ((rollback_ok)) && [[ -n $old ]]; then
        docker update --restart "$old_policy" "$old" >/dev/null 2>&1 &&
          docker start "$old" >/dev/null 2>&1 &&
          reuse_wait reuse_xray_listener "$old" &&
          reuse_wait reuse_panel_ready --unix-socket "$data/marzban.socket" http://localhost/api/admin ||
          rollback_ok=0
      fi
    fi
    if ((rollback_ok)) && rm -- "$pending"; then
      printf 'Marzban --reuse: previous state restored.\n' >&2
    else
      printf 'Marzban --reuse: rollback incomplete, recovery files are in %s.\n' "$work" >&2
    fi
  elif ((result != 0)); then
    if [[ -f $work/stage.json ]]; then
      reuse_compose stage rm --stop --force >/dev/null 2>&1
    fi
    if [[ -f $work/live.json ]]; then
      reuse_compose live rm --stop --force >/dev/null 2>&1
    fi
  fi
  exit "$result"
}

marzban_reuse() (
  set +x
  set -eo pipefail
  umask 077
  local domain=${1:-} tool endpoint discovery caddy data old old_policy current data_device
  local work project image_id candidate='' activated=0 keys password file xray_source=''
  local prompt_fd='' use_warp=no block_ip_detect=no egress=''
  local dashboard_path=/dashboard/ subscription_path=sub paths
  local base=/opt/xray-vps-setup
  local root=$base/marzban-reuse pending=$base/marzban-reuse/pending
  local image=gozargah/marzban:v0.8.4 xray_image=ghcr.io/xtls/xray-core:26.3.27
  local -a compose topology db_files=(db.sqlite3 db.sqlite3-wal db.sqlite3-shm db.sqlite3-journal)
  local domain_pattern='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
  (($# <= 1)) || reuse_fail "usage: $0 --reuse [domain]"
  # Bash may be reading this script from stdin. Read answers from the terminal.
  if ! { exec {prompt_fd}<>/dev/tty; } 2>/dev/null; then
    prompt_fd=''
  fi
  if [[ -z $domain ]]; then
    [[ -n $prompt_fd ]] || reuse_fail 'pass the Caddy domain as an argument when running without a terminal'
    reuse_read 'Enter the existing Caddy domain: ' domain
  fi
  domain=${domain,,}
  domain=${domain%.}
  [[ ${#domain} -le 253 && $domain =~ $domain_pattern ]] || reuse_fail 'enter a valid DNS name (use Punycode for IDN)'
  for tool in docker curl ss flock openssl python3; do
    command -v "$tool" >/dev/null || reuse_fail "required command is missing: $tool"
  done
  if [[ -n ${DOCKER_HOST:-} && -z ${DOCKER_CONTEXT:-} ]]; then
    endpoint=$DOCKER_HOST
  else
    endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null) ||
      reuse_fail 'cannot determine the Docker endpoint'
  fi
  [[ $endpoint == unix:///* ]] || reuse_fail 'a local Unix-socket Docker endpoint is required'
  export DOCKER_HOST="$endpoint"
  unset DOCKER_CONTEXT
  docker info >/dev/null 2>&1 || reuse_fail 'local Docker is unavailable'
  if docker compose version >/dev/null 2>&1; then
    compose=(docker compose)
  elif docker-compose version >/dev/null 2>&1; then
    compose=(docker-compose)
  else
    reuse_fail 'Docker Compose is unavailable'
  fi

  install -d -m 700 -- "$root"
  exec 9>"$root/lock"
  flock -n 9 || reuse_fail 'another reuse operation holds the lock'
  [[ ! -e $pending && ! -L $pending ]] || reuse_fail "an interrupted switch needs recovery: $pending"

  discovery=$(reuse_discover) || reuse_fail 'cannot identify a safe Caddy and Marzban topology'
  mapfile -t topology <<< "$discovery"
  caddy=${topology[0]} data=${topology[1]} old=${topology[2]:-} old_policy=${topology[3]:-}
  [[ -d $data ]] || reuse_fail 'the Caddy socket bind source does not exist'
  reuse_listener "$caddy" caddy 4123 '127.0.0.1:4123' ||
    reuse_fail 'Caddy does not exclusively own the expected loopback TCP 4123 listener'
  reuse_xray_listener "$old" || reuse_fail 'TCP 443 is not free or exclusively owned by the matching Marzban Xray'
  reuse_caddy_config || reuse_fail 'Caddy does not declare the requested domain, PROXY/TLS listener and both expected upstreams'
  reuse_photo_health http://127.0.0.1:18089/api/health ||
    reuse_fail 'the local PhotoHunt API is not healthy'
  local photo_url=https://$domain/photohunt/api/health
  local panel_url=https://$domain/api/admin
  local -a via_caddy=(--haproxy-protocol --connect-to "$domain:443:127.0.0.1:4123")
  reuse_photo_health "${via_caddy[@]}" "$photo_url" ||
    reuse_fail 'Caddy failed the local PhotoHunt check with verified TLS and PROXY protocol'
  if [[ -n $old ]]; then
    [[ -f $data/db.sqlite3 ]] &&
      reuse_panel_ready --unix-socket "$data/marzban.socket" http://localhost/api/admin &&
      reuse_panel_ready "${via_caddy[@]}" "$panel_url" ||
      reuse_fail 'the existing Marzban SQLite database or API is unavailable'
  fi
  if [[ -L $root/current ]]; then
    current=$(readlink "$root/current")
    [[ -n $old && -f $current/container && $old == "$(<"$current/container")" ]] ||
      reuse_fail "a previous reuse project exists but is not active: $current"
    reuse_photo_health "$photo_url" || reuse_fail 'the active project failed the public PhotoHunt health check'
    printf 'Marzban --reuse: existing project is healthy. Files: %s\n' "$current"
    exit 0
  fi
  if [[ -n $old ]]; then
    paths=$(docker exec "$old" python -c '
import re, sys
from config import DASHBOARD_PATH, SQLALCHEMY_DATABASE_URL, UVICORN_UDS, XRAY_SUBSCRIPTION_PATH

if (SQLALCHEMY_DATABASE_URL != "sqlite:////var/lib/marzban/db.sqlite3"
        or UVICORN_UDS != "/var/lib/marzban/marzban.socket"
        or not re.fullmatch(r"/[a-zA-Z0-9_/-]+", DASHBOARD_PATH)
        or not re.fullmatch(r"[a-zA-Z0-9_/-]+", XRAY_SUBSCRIPTION_PATH)):
    sys.exit(1)
print(DASHBOARD_PATH, XRAY_SUBSCRIPTION_PATH)
' 2>/dev/null) || reuse_fail 'the existing Marzban does not use the expected SQLite and socket settings or has unsupported panel paths'
    read -r dashboard_path subscription_path <<< "$paths"
  fi
  [[ $root != "$data" && $root != "$data/"* && $data != "$root/"* ]] ||
    reuse_fail 'the shared data and reuse project directories must not overlap'
  data_device=$(stat -c %d -- "$data") || reuse_fail 'cannot inspect the shared data filesystem'
  [[ $data_device == "$(stat -c %d -- "$root")" ]] ||
    reuse_fail 'the shared data directory and backup location must be on the same filesystem'

  reuse_prompt_options
  if [[ -n $prompt_fd ]]; then
    exec {prompt_fd}>&-
  fi

  work=$(mktemp -d "$root/run.XXXXXXXXXX")
  project=marzban-reuse-${work##*.}
  project=${project,,}
  trap 'reuse_cleanup "$?"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  mkdir -- "$work/stage-data" "$work/backup" "$work/failed"
  printf 'Marzban --reuse: preparing and testing a separate project.\n'
  docker pull "$image" >/dev/null 2>&1 && docker pull "$xray_image" >/dev/null 2>&1 ||
    reuse_fail 'could not pull the pinned Marzban and Xray images'
  image_id=$(docker image inspect --format '{{index .RepoDigests 0}}' "$image" 2>/dev/null) ||
    reuse_fail 'could not resolve the Marzban image digest'
  [[ $image_id == *@sha256:* ]] || reuse_fail 'the Marzban image has no registry digest'
  xray_source=$(docker create "$xray_image") || reuse_fail 'could not stage the Xray binary'
  docker cp "$xray_source:/usr/local/bin/xray" "$work/xray" || reuse_fail 'could not copy the Xray binary'
  docker rm -v "$xray_source" >/dev/null
  xray_source=''
  chmod 700 "$work/xray"
  keys=$(docker run --rm --network none "$xray_image" x25519 2>/dev/null) ||
    reuse_fail 'Xray could not generate a REALITY key pair'
  export VLESS_DOMAIN="$domain" XRAY_SEND_THROUGH=0.0.0.0
  export XRAY_PIK XRAY_PBK XRAY_PATH
  XRAY_PIK=$(sed -n 's/^PrivateKey: //p' <<< "$keys")
  XRAY_PBK=$(sed -n 's/^Password (PublicKey): //p' <<< "$keys")
  [[ $XRAY_PIK =~ ^[A-Za-z0-9_-]{43}$ && $XRAY_PBK =~ ^[A-Za-z0-9_-]{43}$ ]] ||
    reuse_fail 'Xray returned an unexpected REALITY key format'
  XRAY_PATH=$(openssl rand -hex 8)
  write_xray_config python3 -c 'import os, sys; sys.stdout.write(os.path.expandvars(sys.stdin.read()))' > "$work/xray_config.json"
  unset keys XRAY_PIK XRAY_PBK
  reuse_configure_xray "$work/xray_config.json"
  password=$(openssl rand -hex 24)
  printf 'SUDO_USERNAME=admin\nSUDO_PASSWORD=%s\n' "$password" > "$work/admin.env"
  printf 'username=admin&password=%s' "$password" > "$work/login-form"
  unset password

  reuse_write_compose stage none "$work/stage-data" no
  reuse_write_compose live host "$data" unless-stopped
  reuse_compose stage config --quiet && reuse_compose live config --quiet ||
    reuse_fail 'Compose did not accept the prepared configuration'
  reuse_compose stage up -d >/dev/null 2>&1 ||
    reuse_fail 'could not start the isolated Marzban staging container'
  reuse_wait reuse_panel_ready --unix-socket "$work/stage-data/marzban.socket" http://localhost/api/admin &&
    docker exec "$project-stage" python -c 'import socket; socket.create_connection(("127.0.0.1", 443), 2).close()' >/dev/null 2>&1 &&
    reuse_seed_panel || reuse_fail 'the isolated Marzban, Xray or panel initialization failed'
  reuse_compose stage stop >/dev/null 2>&1 && reuse_compose stage rm --force >/dev/null 2>&1 ||
    reuse_fail 'could not stop and remove the staging container'
  rm -- "$work/login-form" "$work/auth-header"
  [[ -f $work/stage-data/db.sqlite3 ]] || reuse_fail 'staging did not create a SQLite database'
  reuse_compose live create >/dev/null 2>&1 || reuse_fail 'could not create the replacement Marzban container'
  candidate=$(reuse_compose live ps -aq marzban)
  [[ $candidate =~ ^[a-f0-9]{12,64}$ ]] || reuse_fail 'could not identify the prepared replacement container'
  printf '%s\n' "$candidate" > "$work/container"
  printf '%s\n' "$old" "$old_policy" "$data" > "$work/previous"

  [[ $(reuse_discover) == "$discovery" ]] && reuse_xray_listener "$old" ||
    reuse_fail 'the running topology or TCP 443 owner changed during preparation'
  for file in "${db_files[@]}"; do
    if [[ -L $data/$file || ( -e $data/$file && ! -f $data/$file ) ]]; then
      reuse_fail "unexpected file type in shared Marzban directory: $file"
    fi
  done
  [[ ! -L $data/marzban.socket && ( ! -e $data/marzban.socket || -S $data/marzban.socket ) ]] ||
    reuse_fail 'the Marzban socket path is occupied by another file'

  printf 'Marzban --reuse: switching TCP 443 to the prepared container.\n'
  ln -sT -- "$work" "$pending"
  if [[ -n $old ]]; then
    docker update --restart no "$old" >/dev/null 2>&1 && docker stop "$old" >/dev/null 2>&1 ||
      reuse_fail 'could not stop the previous Marzban container'
  fi
  reuse_xray_listener '' || reuse_fail 'TCP 443 remained busy after stopping the previous Marzban'
  for file in "${db_files[@]}"; do
    if [[ -f $data/$file ]]; then
      mv -T -- "$data/$file" "$work/backup/$file"
    fi
  done
  if [[ -S $data/marzban.socket ]]; then
    rm -- "$data/marzban.socket"
  fi
  touch -- "$work/activating"
  activated=1
  for file in "${db_files[@]}"; do
    if [[ -f $work/stage-data/$file ]]; then
      mv -T -- "$work/stage-data/$file" "$data/$file"
    fi
  done
  docker start "$candidate" >/dev/null 2>&1 || reuse_fail 'could not start the replacement Marzban'
  reuse_wait reuse_panel_ready --unix-socket "$data/marzban.socket" http://localhost/api/admin ||
    reuse_fail 'replacement Marzban did not become ready on its Unix socket'
  reuse_wait reuse_xray_listener "$candidate" || reuse_fail 'the replacement Xray did not take ownership of TCP 443'
  reuse_panel_ready "${via_caddy[@]}" "$panel_url" || reuse_fail 'Caddy could not reach the replacement panel'
  reuse_photo_health --resolve "$domain:443:127.0.0.1" "$photo_url" &&
    reuse_wait reuse_photo_health "$photo_url" ||
    reuse_fail 'PhotoHunt failed the HTTPS health check after switching'
  mv -T -- "$pending" "$root/current"
  printf 'Marzban --reuse: PhotoHunt and the panel are healthy. Files: %s\n' "$work"
)

if [[ ${1:-} == --reuse ]]; then
  if [[ $EUID -ne 0 ]]; then
    reuse_fail 'please run as root'
  fi
  shift
  marzban_reuse "$@"
  exit
fi

# Check if script started as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

# Install idn
apt-get update
apt-get install idn sudo dnsutils wamerican gettext-base zip unzip python3 -y

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

# Generate values for XRay + Marzban
export SSH_USER=$(grep -E '^[a-z]{4,6}$' /usr/share/dict/words | shuf -n 1)
export SSH_USER_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13; echo)
export SSH_PORT=${input_ssh_port:-22}
export XRAY_PIK=$(docker run --rm ghcr.io/xtls/xray-core:26.3.27 x25519 | head -n1 | cut -d' ' -f 2)
export XRAY_PBK=$(docker run --rm ghcr.io/xtls/xray-core:26.3.27 x25519 -i $XRAY_PIK | tail -2 | head -1 | cut -d' ' -f 3)
export XRAY_PATH=$(openssl rand -hex 8)
export XRAY_SEND_THROUGH=${input_egress_ip:-0.0.0.0}
export MARZBAN_USER=$(grep -E '^[a-z]{4,6}$' /usr/share/dict/words | shuf -n 1)
export MARZBAN_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13; echo)
export MARZBAN_PATH=$(openssl rand -hex 8)
export MARZBAN_SUB_PATH=$(openssl rand -hex 8)

marzban_setup() {
  mkdir -p /opt/xray-vps-setup/marzban
  mkdir -p /opt/xray-vps-setup/xray-core
  cd /opt/xray-vps-setup

  wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/confluence" | envsubst > ./index.html
  wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/compose-marzban" | envsubst > ./docker-compose.yml
  wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/marzban" | envsubst > ./marzban/.env
  wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/angie-marzban" | envsubst '$VLESS_DOMAIN $MARZBAN_PATH $MARZBAN_SUB_PATH' > ./angie.conf

  if [[ "$ARCH" == "amd64" ]]; then
    wget -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-linux-64.zip
  elif [[ "$ARCH" == "arm64" ]]; then
    wget -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-linux-arm64-v8a.zip
  fi
  unzip -qo /tmp/xray.zip -d /opt/xray-vps-setup/xray-core

  write_xray_config envsubst > ./marzban/xray_config.json
}

block_ip_geo_detect() {
  local cfg_path="$1"
  if ! wget -qO- "$ip_geo_detect_url" > /tmp/category-ip-geo-detect.json; then
    echo "Warning: could not download IP/geo-detection list, skipping"
    return 0
  fi
  add_ip_geo_detect_rule "$cfg_path" /tmp/category-ip-geo-detect.json
}

marzban_setup

if [[ ${configure_ipdetect_input,,} == "y" ]]; then
  block_ip_geo_detect "/opt/xray-vps-setup/marzban/xray_config.json"
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
    export XRAY_CONFIG_WARP="/opt/xray-vps-setup/marzban/xray_config.json"
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

  echo "Waiting for marzban to start..."
  sleep 8
  docker exec marzban marzban-cli admin import-from-env \
    || echo "Warning: admin import failed - run 'docker exec marzban marzban-cli admin import-from-env' manually"

  echo "Updating panel default host with domain $VLESS_DOMAIN and XHTTP path /$XRAY_PATH..."
  PANEL_TOKEN=$(curl -sf -X POST "https://$VLESS_DOMAIN/api/admin/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "username=$MARZBAN_USER" \
    --data-urlencode "password=$MARZBAN_PASS" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])" || echo "")
  if [[ -n "$PANEL_TOKEN" && "$PANEL_TOKEN" != "null" ]]; then
    PHOSTS_HTTP=$(curl -s -o /tmp/panel_hosts.json -w "%{http_code}" \
      "https://$VLESS_DOMAIN/api/hosts" \
      -H "Authorization: Bearer $PANEL_TOKEN" || echo "000")
    if [[ "$PHOSTS_HTTP" == "200" ]]; then
      export PANEL_HOST_DOMAIN="$VLESS_DOMAIN"
      export PANEL_HOST_PATH="/$XRAY_PATH"
      python3 << 'PYEOF' > /tmp/panel_hosts_updated.json
import json, os
with open('/tmp/panel_hosts.json') as f:
    hosts = json.load(f)
domain = os.environ['PANEL_HOST_DOMAIN']
path = os.environ['PANEL_HOST_PATH']
for host_list in hosts.values():
    for host in host_list:
        host['address'] = domain
        host['sni'] = domain
        host['host'] = domain
        host['path'] = path
        host['security'] = 'inbound_default'
        host['fingerprint'] = 'chrome'
print(json.dumps(hosts))
PYEOF
      curl -s -o /dev/null \
        -X PUT "https://$VLESS_DOMAIN/api/hosts" \
        -H "Authorization: Bearer $PANEL_TOKEN" \
        -H "Content-Type: application/json" \
        -d @/tmp/panel_hosts_updated.json || true
      echo "Panel host updated."
    else
      echo "Warning: could not fetch panel hosts (HTTP $PHOSTS_HTTP) - update address/SNI/path manually"
    fi
  else
    echo "Warning: could not authenticate to panel API - update default host address/SNI/path to $VLESS_DOMAIN /$XRAY_PATH manually"
  fi

  final_msg="Marzban panel: https://$VLESS_DOMAIN/$MARZBAN_PATH/
User: $MARZBAN_USER
Password: $MARZBAN_PASS

Reality public key (PBK): $XRAY_PBK
XHTTP path: /$XRAY_PATH
Outbound (egress) IP: $XRAY_SEND_THROUGH
Subscription path: /$MARZBAN_SUB_PATH

Create users in the panel, then use their subscription links.
"

  clear
  echo "$final_msg"
  if [[ ${configure_ssh_input,,} == "y" ]]; then
    echo "SSH user: $SSH_USER, SSH password: $SSH_USER_PASS, SSH port: $SSH_PORT"
  fi
}

end_script
set +e
