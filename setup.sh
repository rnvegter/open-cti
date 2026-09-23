#!/usr/bin/env bash
# Prepare a Linux host for the OpenCTI Docker stack (served over HTTPS by Caddy).
#
#   ./setup.sh --host <hostname-or-ip> [--email <you@example.org> | --internal-tls] [--start]
#
#   --host          name (or IP) users type in the browser; OpenCTI runs at https://<host>
#   --email         get a Let's Encrypt certificate (host must be public DNS, ports 80/443 open)
#   --internal-tls  use Caddy's own CA instead (default for IPs, localhost and single-label names)
#   --start         pull images and start the stack
#
# Checks Docker, Compose, RAM and ports 80/443, sets vm.max_map_count for Elasticsearch,
# and creates .env with random secrets. An existing .env keeps its secrets; missing keys are
# added and --host/--email/--internal-tls are applied to it.
set -euo pipefail

cd "$(dirname "$0")"

HOST=""
EMAIL=""
INTERNAL_TLS=false
START=false
MIN_MAP_COUNT=1048575
MIN_RAM_GB=16

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)         HOST="${2:?--host needs a value}"; shift 2 ;;
    --email)        EMAIL="${2:?--email needs a value}"; shift 2 ;;
    --internal-tls) INTERNAL_TLS=true; shift ;;
    --start)        START=true; shift ;;
    -h|--help)      usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 1 ;;
  esac
done

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -n "$EMAIL" ]] && $INTERNAL_TLS && die "Use either --email or --internal-tls, not both."

as_root() {
  if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

gen_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null; then uuidgen | tr '[:upper:]' '[:lower:]'
  else python3 -c 'import uuid; print(uuid.uuid4())'
  fi
}

gen_secret() { openssl rand -hex 24; }

get_env() { awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/, ""); print; exit}' .env; }

# Replace KEY=... in .env without sed delimiter issues (base64 contains / + =).
set_env() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1==k {print k "=" v; next} {print}' .env > "$tmp"
  cat "$tmp" > .env
  rm -f "$tmp"
}

# IPs, localhost and names without a dot can't get a public certificate.
needs_internal_tls() {
  local h="$1"
  [[ "$h" == "localhost" || "$h" != *.* || "$h" == *:* || "$h" =~ ^[0-9.]+$ ]]
}

port_in_use() {
  command -v ss >/dev/null && ss -Hltn "sport = :$1" 2>/dev/null | grep -q .
}

# --- Prerequisites ----------------------------------------------------------

[[ "$(uname -s)" == "Linux" ]] || warn "This script targets Linux; kernel tuning will be skipped."

command -v docker >/dev/null || die "Docker not found. Install it: https://docs.docker.com/engine/install/"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 plugin not found ('docker compose')."
docker info >/dev/null 2>&1 || die "Cannot talk to the Docker daemon. Is it running and is your user in the 'docker' group?"
command -v openssl >/dev/null || die "openssl not found."

if [[ -r /proc/meminfo ]]; then
  ram_gb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
  if (( ram_gb < MIN_RAM_GB )); then
    warn "Host has ~${ram_gb} GB RAM. OpenCTI needs at least ${MIN_RAM_GB} GB; lower ELASTIC_MEMORY_SIZE and OPENCTI_NODE_MEMORY_MB in .env on small hosts."
  else
    info "RAM: ~${ram_gb} GB"
  fi
fi

# Ports held by our own Caddy container are fine (re-runs).
if [[ -z "$(docker compose ps -q caddy 2>/dev/null)" ]]; then
  for p in 80 443; do
    port_in_use "$p" && warn "Port $p is already in use on this host; Caddy will fail to start until it is freed."
  done
fi

# --- Kernel tuning for Elasticsearch ----------------------------------------

if [[ "$(uname -s)" == "Linux" ]]; then
  current=$(cat /proc/sys/vm/max_map_count)
  if (( current < MIN_MAP_COUNT )); then
    info "Setting vm.max_map_count=${MIN_MAP_COUNT} (was ${current}); needs sudo"
    as_root sysctl -w vm.max_map_count="${MIN_MAP_COUNT}" >/dev/null
    echo "vm.max_map_count=${MIN_MAP_COUNT}" | as_root tee /etc/sysctl.d/99-opencti.conf >/dev/null
  else
    info "vm.max_map_count=${current} (ok)"
  fi
fi

# --- .env generation --------------------------------------------------------

if [[ -f .env ]]; then
  info ".env already exists; keeping its secrets"
  # Add keys introduced by newer versions of .env.example.
  while IFS= read -r line; do
    key="${line%%=*}"
    grep -q "^${key}=" .env || { echo "$line" >> .env; info "Added missing key ${key} to .env"; }
  done < <(grep -E '^[A-Z_]+=' .env.example)
else
  info "Generating .env with random secrets"
  cp .env.example .env
  chmod 600 .env
fi

# Fill every CHANGEME placeholder: all of them on a new install, and only keys
# added by a newer .env.example on an existing one.
fill() { if [[ "$(get_env "$1")" == "CHANGEME" ]]; then set_env "$1" "$2"; fi; }

fill MINIO_ROOT_PASSWORD            "$(gen_secret)"
fill RABBITMQ_DEFAULT_PASS          "$(gen_secret)"
fill OPENCTI_ADMIN_PASSWORD         "$(gen_secret)"
fill OPENCTI_ADMIN_TOKEN            "$(gen_uuid)"
fill OPENCTI_HEALTHCHECK_ACCESS_KEY "$(gen_secret)"
fill OPENCTI_ENCRYPTION_KEY         "$(openssl rand -base64 32)"

for key in $(grep -oE '^CONNECTOR_[A-Z_]+_ID' .env); do
  fill "$key" "$(gen_uuid)"
done

[[ -n "$HOST" ]] && set_env OPENCTI_HOST "$HOST"
HOST="$(get_env OPENCTI_HOST)"

# --- TLS mode ---------------------------------------------------------------

if $INTERNAL_TLS; then
  set_env CADDY_TLS internal
elif [[ -n "$EMAIL" ]]; then
  needs_internal_tls "$HOST" && die "'${HOST}' can't get a Let's Encrypt certificate (IP/localhost/no domain). Use a public DNS name or --internal-tls."
  set_env CADDY_TLS "$EMAIL"
elif ! needs_internal_tls "$HOST" && [[ "$(get_env CADDY_TLS)" == "internal" ]]; then
  warn "'${HOST}' looks like a domain but CADDY_TLS=internal (self-signed). Re-run with --email <you@example.org> for a Let's Encrypt certificate."
fi
TLS_MODE="$(get_env CADDY_TLS)"

# --- AlienVault OTX ---------------------------------------------------------

# Start the first import 30 days back instead of the connector's 2020 default.
if [[ -z "$(get_env ALIENVAULT_PULSE_START_TIMESTAMP)" ]]; then
  set_env ALIENVAULT_PULSE_START_TIMESTAMP \
    "$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-30d +%Y-%m-%dT%H:%M:%SZ)"
fi

# The connector only runs under the "alienvault" profile, enabled when a key is set.
profiles="$(get_env COMPOSE_PROFILES)"
profiles="$(echo ",${profiles}," | sed 's/,alienvault,/,/g; s/^,*//; s/,*$//')"
if [[ -n "$(get_env ALIENVAULT_API_KEY)" ]]; then
  profiles="${profiles:+${profiles},}alienvault"
  OTX_STATUS="on (pulses since $(get_env ALIENVAULT_PULSE_START_TIMESTAMP))"
else
  OTX_STATUS="off (set ALIENVAULT_API_KEY in .env, then re-run ./setup.sh)"
fi
set_env COMPOSE_PROFILES "$profiles"

# --- Validation -------------------------------------------------------------

if grep -q '=CHANGEME' .env; then
  die ".env still contains CHANGEME values: $(grep '=CHANGEME' .env | cut -d= -f1 | tr '\n' ' ')"
fi

[[ "$(get_env OPENCTI_BIND_ADDRESS)" == "127.0.0.1" ]] || \
  warn "OPENCTI_BIND_ADDRESS is not 127.0.0.1, so plain HTTP on port $(get_env OPENCTI_HOST_PORT) is exposed next to Caddy."

docker compose config --quiet || die "docker compose config failed; check .env"

# --- Start ------------------------------------------------------------------

if $START; then
  info "Pulling images"
  docker compose pull
  info "Starting stack (first boot takes a few minutes)"
  docker compose up -d
fi

cat <<EOF

OpenCTI is configured.
  URL:       https://${HOST}
  TLS:       $([[ "$TLS_MODE" == "internal" ]] && echo "Caddy internal CA (browsers warn until you trust its root, see README)" || echo "Let's Encrypt (contact: ${TLS_MODE})")
  Login:     $(get_env OPENCTI_ADMIN_EMAIL)
  Password:  stored in .env (OPENCTI_ADMIN_PASSWORD)
  AlienVault OTX: ${OTX_STATUS}

$($START && echo "Follow startup with: docker compose logs -f opencti caddy" || echo "Start with: docker compose up -d")
EOF
