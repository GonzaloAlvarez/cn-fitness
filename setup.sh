#!/usr/bin/env bash
# cn-fitness — idempotent bring-up.
#
# The .env is Kauket-managed (secret id kaiser.cn_fitness_env); secrets and the
# Headscale authkey are NO LONGER generated / harvested / minted here. This
# script fetches the step-ca root, renders promtail, brings the stack up, and
# (only on a genuinely fresh install where signup is still enabled) bootstraps
# the admin user.
#
#   kauket get kaiser.cn_fitness_env   # installs .env (0600)
#   ./setup.sh
set -euo pipefail

cd "$(dirname "$0")"

case "${1:-}" in
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

env_get()  { grep -E "^${1}=" .env 2>/dev/null | head -1 | cut -d= -f2- || true; }
env_set()  {
  local k="$1" v="$2"
  local esc
  esc=$(printf '%s\n' "$v" | sed -e 's/[\/&]/\\&/g')
  if grep -qE "^${k}=" .env; then
    sed -i.bak "s/^${k}=.*/${k}=${esc}/" .env && rm -f .env.bak
  else
    printf '%s=%s\n' "$k" "$v" >> .env
  fi
}

[[ -f .env ]] || die ".env not found. Run: kauket get kaiser.cn_fitness_env"

# ── step-ca root CA ─────────────────────────────────────────────────────────

mkdir -p certs
PKI_IP_VAL="$(env_get PKI_IP)"
PKI_IP_VAL="${PKI_IP_VAL:-pki.lan}"
if [[ ! -f certs/root_ca.crt ]]; then
  log "fetching step-ca root CA from http://${PKI_IP_VAL}/cert/ca.crt"
  curl -sSf "http://${PKI_IP_VAL}/cert/ca.crt" -o certs/root_ca.crt \
    || die "could not fetch root CA from ${PKI_IP_VAL}"
fi

# ── Render promtail config ──────────────────────────────────────────────────

INFRA_VPS_TAILNET_IP="$(env_get INFRA_VPS_TAILNET_IP)" \
  envsubst < promtail/promtail.yml.tmpl > promtail/promtail.yml
log "rendered promtail/promtail.yml"

mkdir -p backups uploads backup

# ── Bring the stack up ──────────────────────────────────────────────────────

log "docker compose up -d --remove-orphans"
docker compose up -d --remove-orphans

# ── First-user bootstrap (only when signup is still enabled) ────────────────

ADMIN_EMAIL_VAL="$(env_get ADMIN_EMAIL)"
if [[ -z "$ADMIN_EMAIL_VAL" ]]; then
  die "ADMIN_EMAIL is empty in the Kauket-managed .env — cannot bootstrap admin user."
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

# ── Summary ─────────────────────────────────────────────────────────────────

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

  ⚠  This is a one-time signup password — save it in your password manager
     NOW, then log in at https://fitness.kaiser.lan and change it.
EOF
fi

cat <<EOF
  The .env (DB passwords, encryption/auth secrets, FITNESS_AUTHKEY, SMTP,
  backup creds) is Kauket-managed (kaiser.cn_fitness_env).
===============================================================
EOF
