#!/usr/bin/env bash
# cn-fitness — idempotent bring-up.
#
# Flags:
#   --core   Harvest shared infra values (SMTP, S3, WebDAV, ADMIN_EMAIL,
#            and several domain/PKI vars) from passwords.lan:~/cn-vaultwarden/.env
#            over SSH. Same pattern as cn-netbox/seal-secrets.sh --core.
#
# What this script does (idempotent — safe to re-run):
#   1. Renders .env from .env.example if missing.
#   2. (--core) harvests shared values from passwords.lan.
#   3. Mints a Headscale preauth key if FITNESS_AUTHKEY is empty.
#   4. Auto-generates random secrets (API encryption, better-auth, DB passwords).
#   5. Fetches step-ca root CA over plain HTTP (chicken-and-egg).
#   6. Renders promtail/promtail.yml from the .tmpl.
#   7. Brings the stack up (docker compose up -d).
#   8. Auto-creates the admin user via POST /api/auth/sign-up/email, then
#      flips SPARKY_FITNESS_DISABLE_SIGNUP=true and restarts the server.
#   9. Prints the temporary admin password (one-shot; not stored on disk).
set -euo pipefail

cd "$(dirname "$0")"

CORE_ONLY=0
case "${1:-}" in
  --core) CORE_ONLY=1 ;;
  -h|--help)
    sed -n '/^#!/d; /^[^#]/q; s/^# \{0,1\}//p' "$0"
    exit 0
    ;;
  "") ;;
  *)
    echo "unknown argument: $1 (try --help)" >&2
    exit 2
    ;;
esac

# ── helpers ────────────────────────────────────────────────────────────────

log() { printf '\n\033[1;36m[setup]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# SSH key path differs across hosts: kaiser has ~/.ssh/main_private_key.pem,
# the laptop has ~/.ssh/gonzalo_main_private_key.pem. Auto-detect so the
# script is portable.
detect_ssh_key() {
  for p in ~/.ssh/main_private_key.pem ~/.ssh/gonzalo_main_private_key.pem; do
    [[ -f "$p" ]] && { echo "$p"; return; }
  done
}
SSH_KEY=$(detect_ssh_key)
SSH_OPTS=(-o BatchMode=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -l gonzalo)
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

prompt() {
  # echo >&2 keeps the trailing newline on stderr so it doesn't pollute
  # the value captured via $(prompt ...). See homelab/CLAUDE.md §15.
  local label="$1" default="${2:-}" hidden="${3:-}" value
  if [[ -n "$hidden" ]]; then
    read -rsp "${label}: " value; echo >&2
  elif [[ -n "$default" ]]; then
    read -rp "${label} [${default}]: " value
    value="${value:-$default}"
  else
    read -rp "${label}: " value
  fi
  printf '%s' "$value"
}

env_get()  { grep -E "^${1}=" .env 2>/dev/null | head -1 | cut -d= -f2- || true; }
env_set()  {
  local k="$1" v="$2"
  # Escape sed metacharacters in value.
  local esc
  esc=$(printf '%s\n' "$v" | sed -e 's/[\/&]/\\&/g')
  if grep -qE "^${k}=" .env; then
    sed -i.bak "s/^${k}=.*/${k}=${esc}/" .env && rm -f .env.bak
  else
    printf '%s=%s\n' "$k" "$v" >> .env
  fi
}

# ── 1. .env scaffold ───────────────────────────────────────────────────────

if [[ ! -f .env ]]; then
  log "creating .env from .env.example"
  cp .env.example .env
  chmod 600 .env
fi

# ── 2. Harvest from passwords.lan (--core) ─────────────────────────────────

harvest_from_vault() {
  local tmp keys
  tmp=$(mktemp)
  trap "rm -f '$tmp'" RETURN
  keys='^(BACKUP_S3_BUCKET|BACKUP_AWS_ACCESS_KEY_ID|BACKUP_AWS_SECRET_ACCESS_KEY|BACKUP_AWS_REGION|BACKUP_WEBDAV_URL|BACKUP_WEBDAV_USER|BACKUP_WEBDAV_PASSWORD|SMTP_HOST|SMTP_PORT|SMTP_USERNAME|SMTP_PASSWORD|SMTP_FROM|ALERT_EMAIL|ADMIN_EMAIL|INFRA_VPS_TAILNET_IP|HEADSCALE_DOMAIN|LAB_DOMAIN|TAILNET_DOMAIN|PKI_IP|TIMEZONE)='

  log "harvesting shared infra values from passwords.lan:~/cn-vaultwarden/.env"
  if ! ssh "${SSH_OPTS[@]}" passwords.lan \
        "grep -E '${keys}' ~/cn-vaultwarden/.env" > "$tmp"; then
    die "ssh to passwords.lan failed — is the Pi up and key authorized?"
  fi

  [[ -s "$tmp" ]] || die "no matching keys harvested from passwords.lan"

  # Source into a subshell-safe set, then mirror each into .env.
  set -a
  # shellcheck disable=SC1090
  . "$tmp"
  set +a

  local k v missing=()
  for k in BACKUP_S3_BUCKET BACKUP_AWS_ACCESS_KEY_ID BACKUP_AWS_SECRET_ACCESS_KEY BACKUP_AWS_REGION \
           SMTP_HOST SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_FROM ALERT_EMAIL ADMIN_EMAIL; do
    v="${!k:-}"
    [[ -n "$v" ]] || missing+=("$k")
    [[ -n "$v" ]] && env_set "$k" "$v"
  done
  # Optional / less-strict
  for k in BACKUP_WEBDAV_URL BACKUP_WEBDAV_USER BACKUP_WEBDAV_PASSWORD \
           INFRA_VPS_TAILNET_IP HEADSCALE_DOMAIN LAB_DOMAIN TAILNET_DOMAIN PKI_IP TIMEZONE; do
    v="${!k:-}"
    [[ -n "$v" ]] && env_set "$k" "$v"
  done

  (( ${#missing[@]} == 0 )) || die "missing required keys in source .env: ${missing[*]}"

  log "harvested: S3=${BACKUP_S3_BUCKET} smtp=${SMTP_HOST}:${SMTP_PORT} from=${SMTP_FROM} admin=${ADMIN_EMAIL}"
}

if (( CORE_ONLY == 1 )); then
  harvest_from_vault
fi

# ── 3. Headscale preauth key ───────────────────────────────────────────────

if [[ -z "$(env_get FITNESS_AUTHKEY)" ]]; then
  log "FITNESS_AUTHKEY empty — minting one from hs.gn.al"
  if KEY=$(ssh "${SSH_OPTS[@]}" hs.gn.al \
             'docker exec cloudnet-headscale-1 headscale preauthkeys create --user gonzaloalvarez --tags tag:svc --expiration 24h' \
             2>/dev/null | tr -d '\r\n'); then
    [[ -n "$KEY" ]] || die "headscale preauthkeys returned empty"
    env_set FITNESS_AUTHKEY "$KEY"
    log "minted preauth key (tag:svc, 24h expiry)"
  else
    die "failed to mint preauth key — fill FITNESS_AUTHKEY in .env manually"
  fi
fi

# ── 4. Auto-generate random secrets where empty ────────────────────────────

gen_hex32()    { openssl rand -hex 32; }
gen_b64_32()   { openssl rand -base64 32 | tr -d '\n'; }
gen_b64_24()   { openssl rand -base64 24 | tr -d '\n'; }

for KEY in SPARKY_FITNESS_API_ENCRYPTION_KEY:hex32 \
           BETTER_AUTH_SECRET:b64_32 \
           SPARKY_FITNESS_DB_PASSWORD:b64_24 \
           SPARKY_FITNESS_APP_DB_PASSWORD:b64_24; do
  name="${KEY%:*}" ; gen="${KEY#*:}"
  if [[ -z "$(env_get "$name")" ]]; then
    case "$gen" in
      hex32) val=$(gen_hex32) ;;
      b64_32) val=$(gen_b64_32) ;;
      b64_24) val=$(gen_b64_24) ;;
    esac
    env_set "$name" "$val"
    log "generated $name"
  fi
done

# ── 5. step-ca root CA ─────────────────────────────────────────────────────

PKI_IP_VAL="$(env_get PKI_IP)"
PKI_IP_VAL="${PKI_IP_VAL:-pki.lan}"
if [[ ! -f certs/root_ca.crt ]]; then
  log "fetching step-ca root CA from http://${PKI_IP_VAL}/cert/ca.crt"
  curl -sSf "http://${PKI_IP_VAL}/cert/ca.crt" -o certs/root_ca.crt \
    || die "could not fetch root CA from ${PKI_IP_VAL}"
fi

# ── 6. Render promtail config ──────────────────────────────────────────────

INFRA_VPS_TAILNET_IP="$(env_get INFRA_VPS_TAILNET_IP)" \
  envsubst < promtail/promtail.yml.tmpl > promtail/promtail.yml
log "rendered promtail/promtail.yml"

mkdir -p backups uploads backup

# ── 7. Bring the stack up ──────────────────────────────────────────────────

log "docker compose up -d --remove-orphans"
docker compose up -d --remove-orphans

# ── 8. First-user bootstrap ────────────────────────────────────────────────

ADMIN_EMAIL_VAL="$(env_get ADMIN_EMAIL)"
if [[ -z "$ADMIN_EMAIL_VAL" ]]; then
  die "ADMIN_EMAIL is empty — cannot bootstrap admin user. Set it in .env or rerun with --core."
fi

DISABLE_SIGNUP_VAL="$(env_get SPARKY_FITNESS_DISABLE_SIGNUP)"
if [[ "$DISABLE_SIGNUP_VAL" == "true" ]]; then
  log "SPARKY_FITNESS_DISABLE_SIGNUP already true — skipping bootstrap"
else
  log "waiting for backend to accept requests on 127.0.0.1:3004 (up to 5m)"
  for i in $(seq 1 60); do
    if curl -sf -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:3004/ 2>/dev/null | grep -qE '^(2|3|4)'; then
      log "frontend reachable after ${i}x5s"
      break
    fi
    sleep 5
    [[ $i -eq 60 ]] && die "frontend never came up — check 'docker compose logs sparkyfitness-frontend sparkyfitness-server'"
  done

  # Also wait a beat for the backend to finish migrations (no /metrics; we
  # poll the auth settings endpoint which is the cheapest 200 in the API).
  for i in $(seq 1 30); do
    if curl -sf -m 5 -o /dev/null http://127.0.0.1:3004/api/auth/settings 2>/dev/null; then
      log "backend /api/auth/settings reachable after ${i}x5s"
      break
    fi
    sleep 5
    [[ $i -eq 30 ]] && die "backend never accepted requests — check 'docker compose logs sparkyfitness-server'"
  done

  TEMP_PW=$(openssl rand -base64 18)

  log "creating admin user ${ADMIN_EMAIL_VAL} via POST /api/auth/sign-up/email"
  RESP=$(curl -sS -o /tmp/cn-fitness-signup.json -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' \
    -d "{\"name\":\"Admin\",\"email\":\"${ADMIN_EMAIL_VAL}\",\"password\":\"${TEMP_PW}\"}" \
    http://127.0.0.1:3004/api/auth/sign-up/email || echo "000")

  if [[ "$RESP" =~ ^(200|201)$ ]]; then
    log "signup OK (HTTP $RESP)"
    env_set SPARKY_FITNESS_DISABLE_SIGNUP true
    log "flipped SPARKY_FITNESS_DISABLE_SIGNUP=true; restarting server"
    docker compose up -d --force-recreate sparkyfitness-server
  else
    log "signup returned HTTP $RESP — body:"
    cat /tmp/cn-fitness-signup.json 2>/dev/null || true
    echo
    log "Falling back to MANUAL signup:"
    echo "  1. Open https://fitness.kaiser.lan in a browser"
    echo "  2. Sign up with email ${ADMIN_EMAIL_VAL}"
    echo "  3. Edit .env: SPARKY_FITNESS_DISABLE_SIGNUP=true"
    echo "  4. Run: docker compose up -d --force-recreate sparkyfitness-server"
    TEMP_PW=""
  fi

  rm -f /tmp/cn-fitness-signup.json
fi

# ── 9. Summary ─────────────────────────────────────────────────────────────

cat <<EOF


===============================================================
cn-fitness stack is up.

  LAN     :  https://fitness.kaiser.lan        (step-ca cert, browsers only)
  Tailnet :  https://fitness.lab.gn.al         (LE wildcard, mobile apps)

EOF

if [[ -n "${TEMP_PW:-}" ]]; then
  cat <<EOF
  Admin user CREATED:
    Email     : ${ADMIN_EMAIL_VAL}
    Password  : ${TEMP_PW}

  ⚠  This password is SHOWN ONCE — paste it into Vaultwarden NOW,
     then log in at https://fitness.kaiser.lan and change it.
EOF
fi

cat <<EOF
===============================================================
EOF
